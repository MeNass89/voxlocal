"""Remote Scribe protocol v1 compatibility helpers.

This module is deliberately transport-agnostic.  It implements the wire format
used by the macOS VoxLocal binary and the iOS Portable Client so a Windows host
can be built without the missing Swift ``RemoteScribeCore`` sources.

Protocol v1 is *plaintext TCP*.  Keep it behind a hospital VLAN/VPN and a
Windows Firewall rule during the pilot.  Production deployments should wrap
the socket in TLS 1.3 (with certificate pinning on iOS) before exposing PHI.
The framing and JSON payloads remain unchanged inside TLS.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
import json
import struct
from typing import Any, Final, Mapping
from uuid import UUID


PROTOCOL_VERSION: Final[int] = 1
DEFAULT_PORT: Final[int] = 47365
SERVICE_TYPE: Final[str] = "_remotescribe._tcp"
MAX_FRAME_SIZE: Final[int] = 1 * 1024 * 1024
HEADER_SIZE: Final[int] = 4
BODY_HEADER_SIZE: Final[int] = 1 + 36 + 8
NO_SESSION: Final[UUID] = UUID(int=0)


class MessageKind(IntEnum):
    """Swift ``RemoteMessageKind`` raw values (the enum is 1-based)."""

    PAIR = 1
    START_SESSION = 2
    AUDIO_CHUNK = 3
    STOP_SESSION = 4
    SESSION_STATUS = 5
    PING = 6
    ERROR = 7


class ProtocolError(ValueError):
    """Raised for malformed, oversized, or unsupported protocol data."""


def _uuid_text(value: UUID | str) -> str:
    try:
        parsed = value if isinstance(value, UUID) else UUID(str(value))
    except (ValueError, AttributeError, TypeError) as exc:
        raise ProtocolError("session id must be a UUID") from exc
    # Foundation.UUID.uuidString emits 36 ASCII characters with uppercase
    # hexadecimal digits. The decoder is case-insensitive, but matching the
    # spelling keeps captures byte-for-byte compatible with the Swift client.
    return str(parsed).upper()


def _json_bytes(value: Mapping[str, Any] | Any) -> bytes:
    try:
        return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ProtocolError("payload is not JSON encodable") from exc


def encode_frame(kind: MessageKind, session_id: UUID | str, sequence: int, payload: bytes = b"") -> bytes:
    """Encode one v1 frame.

    Layout (all integer fields are network/big-endian order)::

        uint32 body_length
        uint8  message_kind
        char[36] UUID (uppercase canonical text from Foundation.UUID.uuidString)
        uint64 sequence
        bytes payload

    ``body_length`` excludes the four-byte length prefix and must be at least
    45 bytes.  The implementation enforces the same 1 MiB maximum as the Mac
    binary, before allocating or sending a frame.
    """

    if not isinstance(kind, MessageKind):
        try:
            kind = MessageKind(int(kind))
        except (TypeError, ValueError) as exc:
            raise ProtocolError("unknown message kind") from exc
    if not isinstance(sequence, int) or not 0 <= sequence <= 0xFFFFFFFFFFFFFFFF:
        raise ProtocolError("sequence must be an unsigned 64-bit integer")
    if not isinstance(payload, (bytes, bytearray, memoryview)):
        raise ProtocolError("payload must be bytes")
    payload_bytes = bytes(payload)
    body_length = BODY_HEADER_SIZE + len(payload_bytes)
    if body_length > MAX_FRAME_SIZE:
        raise ProtocolError("frame exceeds 1 MiB maximum")
    body = (
        bytes((int(kind),))
        + _uuid_text(session_id).encode("ascii")
        + struct.pack(">Q", sequence)
        + payload_bytes
    )
    return struct.pack(">I", body_length) + body


def encode_json_frame(
    kind: MessageKind,
    session_id: UUID | str,
    sequence: int,
    value: Mapping[str, Any] | Any,
) -> bytes:
    """Encode a Codable-compatible JSON frame."""

    return encode_frame(kind, session_id, sequence, _json_bytes(value))


def encode_audio_frame(session_id: UUID | str, sequence: int, pcm_s16le: bytes) -> bytes:
    """Encode an ``AUDIO_CHUNK`` containing signed 16-bit PCM bytes."""

    if len(pcm_s16le) % 2:
        raise ProtocolError("PCM chunk must contain complete Int16 samples")
    return encode_frame(MessageKind.AUDIO_CHUNK, session_id, sequence, pcm_s16le)


@dataclass(frozen=True)
class Frame:
    kind: MessageKind
    session_id: UUID
    sequence: int
    payload: bytes

    def json(self) -> Any:
        """Decode this frame payload as UTF-8 JSON."""

        try:
            return json.loads(self.payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ProtocolError("frame payload is not valid UTF-8 JSON") from exc


def decode_frame(data: bytes | bytearray | memoryview) -> Frame:
    """Decode exactly one frame, rejecting trailing or truncated bytes."""

    raw = bytes(data)
    if len(raw) < HEADER_SIZE:
        raise ProtocolError("truncated frame length")
    body_length = struct.unpack(">I", raw[:HEADER_SIZE])[0]
    if body_length < BODY_HEADER_SIZE:
        raise ProtocolError("frame body is shorter than protocol header")
    if body_length > MAX_FRAME_SIZE:
        raise ProtocolError("frame exceeds 1 MiB maximum")
    if len(raw) != HEADER_SIZE + body_length:
        raise ProtocolError("frame is truncated or has trailing bytes")
    body = raw[HEADER_SIZE:]
    try:
        kind = MessageKind(body[0])
    except ValueError as exc:
        raise ProtocolError("unknown message kind") from exc
    try:
        session_id = UUID(body[1:37].decode("ascii"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise ProtocolError("invalid session UUID") from exc
    sequence = struct.unpack(">Q", body[37:45])[0]
    return Frame(kind, session_id, sequence, body[45:])


class FrameDecoder:
    """Incremental decoder for TCP reads that may split or coalesce frames."""

    def __init__(self, *, max_frame_size: int = MAX_FRAME_SIZE) -> None:
        if max_frame_size < BODY_HEADER_SIZE or max_frame_size > MAX_FRAME_SIZE:
            raise ValueError("invalid max_frame_size")
        self._max_frame_size = max_frame_size
        self._buffer = bytearray()

    def feed(self, data: bytes | bytearray | memoryview) -> list[Frame]:
        self._buffer.extend(data)
        frames: list[Frame] = []
        while True:
            if len(self._buffer) < HEADER_SIZE:
                break
            body_length = struct.unpack(">I", self._buffer[:HEADER_SIZE])[0]
            if body_length < BODY_HEADER_SIZE or body_length > self._max_frame_size:
                raise ProtocolError("invalid frame length")
            total = HEADER_SIZE + body_length
            if len(self._buffer) < total:
                break
            frame_bytes = bytes(self._buffer[:total])
            del self._buffer[:total]
            frames.append(decode_frame(frame_bytes))
        return frames

    @property
    def buffered_bytes(self) -> int:
        return len(self._buffer)


def validate_start_session(payload: Mapping[str, Any]) -> None:
    """Validate the audio contract before opening a server-side session."""

    audio = payload.get("format")
    if not isinstance(audio, Mapping):
        raise ProtocolError("START_SESSION.format is required")
    expected = {"sampleRate": 16_000, "channels": 1, "bitsPerSample": 16, "codec": "pcm_s16le"}
    for key, value in expected.items():
        if audio.get(key) != value:
            raise ProtocolError(f"unsupported audio format: {key}")
    for key in ("modeIdentifier", "language", "backend"):
        if key in payload and payload[key] is not None and not isinstance(payload[key], str):
            raise ProtocolError(f"{key} must be a string or null")
