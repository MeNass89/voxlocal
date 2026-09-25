"""Small Windows-friendly Remote Scribe v1 host.

The host is intentionally a reference service for the pilot: it keeps audio in
memory, enforces session limits, and delegates transcription to an injected
backend.  It is useful for protocol integration and can call an
OpenAI-compatible, HTTPS-only, ZDR endpoint.  It is not a substitute for the
TLS/mTLS migration described in ``docs/windows-security-plan.md``.

Examples (PowerShell)::

    $env:REMOTESCRIBE_PAIRING_CODE = "change-this"
    python .\windows\remotescribe_host.py --bind 0.0.0.0 --backend voxlocal

    # Optional OpenAI-compatible gateway (HTTPS is required by default):
    $env:REMOTESCRIBE_GPU_URL = "https://gpu-gateway.hospital.example"
    $env:REMOTESCRIBE_GPU_TOKEN = "..."
    python .\windows\remotescribe_host.py --backend voxlocal

Install no third-party package is required for the host itself.  DNS-SD
publication and a Windows Service wrapper can be added around this process once
the hospital network policy is approved.
"""

from __future__ import annotations

import argparse
import asyncio
import hmac
import json
import logging
import os
import ssl
import time
from dataclasses import dataclass, field
from io import BytesIO
from typing import Any, Protocol
from urllib import error as urlerror
from urllib import request as urlrequest
import uuid
import wave

try:  # Supports both ``python windows/remotescribe_host.py`` and ``-m``.
    from remotescribe_protocol import (
        DEFAULT_PORT,
        NO_SESSION,
        Frame,
        FrameDecoder,
        MessageKind,
        ProtocolError,
        encode_json_frame,
        encode_frame,
        validate_start_session,
    )
except ImportError:  # pragma: no cover - exercised when run as a package
    from .remotescribe_protocol import (
        DEFAULT_PORT,
        NO_SESSION,
        Frame,
        FrameDecoder,
        MessageKind,
        ProtocolError,
        encode_json_frame,
        encode_frame,
        validate_start_session,
    )


LOGGER = logging.getLogger("remotescribe.host")
MAX_DEVICE_ID = 128
MAX_DEVICE_NAME = 128
MAX_LANGUAGE = 32
MAX_SESSION_SECONDS = 10 * 60
MAX_AUDIO_BYTES = 64 * 1024 * 1024


class Transcriber(Protocol):
    async def transcribe(self, pcm: bytes, *, language: str | None, backend: str) -> str: ...


class EmptyTranscriber:
    """Safe integration stub; never persists or logs audio."""

    async def transcribe(self, pcm: bytes, *, language: str | None, backend: str) -> str:
        del pcm, language, backend
        return ""


class OpenAICompatibleTranscriber:
    """Call an OpenAI-compatible ``/v1/audio/transcriptions`` HTTPS endpoint."""

    def __init__(self, base_url: str, token: str, model: str, *, ca_file: str | None = None) -> None:
        if not base_url.startswith("https://"):
            raise ValueError("GPU endpoint must use https://")
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.model = model
        self.ssl_context = ssl.create_default_context(cafile=ca_file)

    async def transcribe(self, pcm: bytes, *, language: str | None, backend: str) -> str:
        del backend
        return await asyncio.to_thread(self._transcribe_blocking, pcm, language)

    def _transcribe_blocking(self, pcm: bytes, language: str | None) -> str:
        wav = BytesIO()
        with wave.open(wav, "wb") as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(16_000)
            writer.writeframes(pcm)
        boundary = "----RemoteScribe" + uuid.uuid4().hex
        parts = [
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{self.model}\r\n".encode(),
            (
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
                "Content-Type: audio/wav\r\n\r\n"
            ).encode()
            + wav.getvalue()
            + b"\r\n",
        ]
        if language:
            parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n{language}\r\n".encode())
        body = b"".join(parts) + f"--{boundary}--\r\n".encode()
        request = urlrequest.Request(
            self.base_url + "/v1/audio/transcriptions",
            data=body,
            method="POST",
            headers={
                "Authorization": "Bearer " + self.token,
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Content-Length": str(len(body)),
                # A compliant gateway must not retain or train on this body.
                "X-Remote-Scribe-ZDR": "required",
            },
        )
        try:
            with urlrequest.urlopen(request, context=self.ssl_context, timeout=120) as response:
                result = json.loads(response.read())
        except (OSError, urlerror.URLError, json.JSONDecodeError) as exc:
            raise RuntimeError("GPU transcription request failed") from exc
        text = result.get("text") if isinstance(result, dict) else None
        if not isinstance(text, str):
            raise RuntimeError("GPU transcription response did not contain text")
        return text


@dataclass
class ActiveSession:
    session_id: uuid.UUID
    backend: str
    language: str | None
    started_at: float = field(default_factory=time.monotonic)
    pcm: bytearray = field(default_factory=bytearray)
    bytes_received: int = 0
    frames_received: int = 0


class ClientSession:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, host: "RemoteScribeHost") -> None:
        self.reader = reader
        self.writer = writer
        self.host = host
        self.decoder = FrameDecoder()
        self.paired = False
        self.device_id: str | None = None
        self.device_name: str | None = None
        self.active: ActiveSession | None = None
        self.closed = False

    @property
    def peer(self) -> str:
        peer = self.writer.get_extra_info("peername")
        return str(peer[0]) if isinstance(peer, tuple) and peer else "unknown"

    async def send(self, data: bytes) -> None:
        self.writer.write(data)
        await self.writer.drain()

    async def send_json(self, kind: MessageKind, session_id: uuid.UUID, payload: dict[str, Any]) -> None:
        # Shipped Core contract: server frames always carry sequence 0.
        await self.send(encode_json_frame(kind, session_id, 0, payload))

    async def send_error(self, code: str, message: str) -> None:
        # Error text is intentionally generic: it must not expose paths,
        # tokens, stack traces, or provider response bodies to a phone.
        await self.send_json(MessageKind.ERROR, self.active.session_id if self.active else NO_SESSION, {"code": code, "message": message})

    async def run(self) -> None:
        # Keep event logs free of device IDs, IPs, and dictated content.
        LOGGER.debug("connection accepted")
        try:
            while not self.reader.at_eof():
                chunk = await self.reader.read(64 * 1024)
                if not chunk:
                    break
                try:
                    frames = self.decoder.feed(chunk)
                except ProtocolError:
                    await self.send_error("protocolViolation", "Invalid frame")
                    break
                for frame in frames:
                    if not await self.handle(frame):
                        return
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            self.close()

    async def handle(self, frame: Frame) -> bool:
        try:
            if frame.kind is MessageKind.PAIR:
                return await self.handle_pair(frame)
            if not self.paired:
                await self.send_error("notPaired", "Pair first")
                return False
            if frame.kind is MessageKind.START_SESSION:
                return await self.handle_start(frame)
            if frame.kind is MessageKind.AUDIO_CHUNK:
                return await self.handle_audio(frame)
            if frame.kind is MessageKind.STOP_SESSION:
                return await self.handle_stop(frame)
            if frame.kind is MessageKind.PING:
                await self.send(encode_frame(MessageKind.PING, frame.session_id, 0, frame.payload))
                return True
            await self.send_error("protocolViolation", "Unexpected message")
            return False
        except (ProtocolError, ValueError, KeyError, TypeError):
            await self.send_error("protocolViolation", "Invalid payload")
            return False

    async def handle_pair(self, frame: Frame) -> bool:
        # PAIR must be the first frame: any earlier frame already closed the
        # connection as notPaired, so only a second PAIR remains to refuse.
        # The sequence field is only meaningful on audio chunks and is ignored.
        if self.paired:
            await self.send_error("protocolViolation", "PAIR must be the first and only pairing frame")
            return False
        if frame.session_id != NO_SESSION:
            await self.send_error("protocolViolation", "PAIR must use noSession")
            return False
        value = frame.json()
        if not isinstance(value, dict):
            raise ProtocolError("PAIR must be an object")
        if value.get("protocolVersion") != 1:
            await self.send_error("protocolViolation", "Unsupported protocol version")
            return False
        device_id = value.get("deviceID")
        device_name = value.get("deviceName")
        code = value.get("pairingCode")
        if not isinstance(device_id, str) or not 1 <= len(device_id) <= MAX_DEVICE_ID:
            raise ProtocolError("invalid device id")
        if not isinstance(device_name, str) or not 1 <= len(device_name) <= MAX_DEVICE_NAME:
            raise ProtocolError("invalid device name")
        expected = self.host.pairing_code
        accepted = expected is not None and isinstance(code, str) and hmac.compare_digest(code, expected)
        if not accepted:
            await asyncio.sleep(self.host.pair_backoff)
            await self.send_json(MessageKind.PAIR, NO_SESSION, {
                "accepted": False,
                "serverName": self.host.server_name,
                "selectedBackend": self.host.backend,
                "protocolVersion": 1,
                "availableBackends": [self.host.backend],
            })
            return False
        self.paired, self.device_id, self.device_name = True, device_id, device_name
        await self.send_json(MessageKind.PAIR, NO_SESSION, {
            "accepted": True,
            "serverName": self.host.server_name,
            "selectedBackend": self.host.backend,
            "protocolVersion": 1,
            "availableBackends": [self.host.backend],
        })
        # The Swift client accepts the PAIR response immediately, while the
        # original RemoteSessionHandler also emits an explicit ready status on
        # noSession. Keep both events for wire compatibility.
        await self.send_json(MessageKind.SESSION_STATUS, NO_SESSION, {
            "state": "ready",
            "backend": self.host.backend,
            "bytesReceived": 0,
            "message": "Ready",
            "transcription": None,
            "rawTranscription": None,
            "finalText": None,
            "audioLocation": None,
            "resultLocation": None,
        })
        return True

    async def handle_start(self, frame: Frame) -> bool:
        if self.active is not None:
            await self.send_error("alreadyRecording", "Session already active")
            return False
        value = frame.json()
        if not isinstance(value, dict):
            raise ProtocolError("START_SESSION must be an object")
        validate_start_session(value)
        language = value.get("language")
        if language is not None and len(language) > MAX_LANGUAGE:
            raise ProtocolError("language too long")
        backend = value.get("backend") or self.host.backend
        if backend == "voxLocal":
            backend = "voxlocal"
        if backend != self.host.backend:
            await self.send_error("unsupportedBackend", "Backend unavailable")
            return False
        if frame.session_id == NO_SESSION:
            await self.send_error("protocolViolation", "START_SESSION requires a session UUID")
            return False
        self.active = ActiveSession(frame.session_id, backend, language)
        await self.status("recording", message="Recording")
        return True

    async def handle_audio(self, frame: Frame) -> bool:
        session = self.active
        if session is None or frame.session_id != session.session_id:
            await self.send_error("sessionMismatch", "No active session")
            return False
        # Audio chunks are numbered per session from 0, strictly contiguous.
        if frame.sequence != session.frames_received:
            await self.send_error("protocolViolation", "Sequence gap or replay")
            return False
        if len(frame.payload) % 2:
            await self.send_error("unsupportedAudioFormat", "PCM chunk must be Int16")
            return False
        if time.monotonic() - session.started_at > self.host.max_duration:
            await self.send_error("sessionLimit", "Session duration limit reached")
            return False
        if session.bytes_received + len(frame.payload) > self.host.max_audio_bytes:
            await self.send_error("sessionLimit", "Session size limit reached")
            return False
        session.pcm.extend(frame.payload)
        session.bytes_received += len(frame.payload)
        session.frames_received += 1
        return True

    async def handle_stop(self, frame: Frame) -> bool:
        session = self.active
        if session is None or frame.session_id != session.session_id:
            await self.send_error("noActiveSession", "No active session")
            return False
        value = frame.json()
        if not isinstance(value, dict):
            await self.send_error("protocolViolation", "STOP_SESSION must be an object")
            return False
        frames_sent = value.get("framesSent")
        # ``bool`` is an ``int`` subclass in Python, but it is not a valid
        # UInt64 Codable value for this field.  framesSent counts PCM sample
        # frames (mono 16-bit, bytes / 2), exactly as the shipped Swift Core.
        if isinstance(frames_sent, bool) or not isinstance(frames_sent, int) or frames_sent != session.bytes_received // 2:
            await self.send_error("protocolViolation", "framesSent does not match received samples")
            return False
        await self.status("processing", message="Processing")
        pcm = bytes(session.pcm)
        try:
            text = await self.host.transcriber.transcribe(pcm, language=session.language, backend=session.backend)
            if not isinstance(text, str):
                raise RuntimeError("transcriber returned non-text")
            await self.status("completed", message="Completed", final_text=text)
        except Exception:
            LOGGER.exception("transcription failed for paired device")
            await self.status("failed", message="Transcription failed")
        finally:
            # Drop the only server-side copy immediately.  No WAV is written.
            session.pcm.clear()
            self.active = None
        return True

    async def status(self, state: str, *, message: str, final_text: str | None = None) -> None:
        session = self.active
        if session is None:
            return
        await self.send_json(MessageKind.SESSION_STATUS, session.session_id, {
            "state": state,
            "backend": session.backend,
            "bytesReceived": session.bytes_received,
            "message": message,
            "transcription": final_text if state == "completed" else None,
            "rawTranscription": final_text if state == "completed" else None,
            "finalText": final_text if state == "completed" else None,
            "audioLocation": None,
            "resultLocation": None,
        })

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        if self.active:
            self.active.pcm.clear()
            self.active = None
        self.writer.close()


class RemoteScribeHost:
    def __init__(self, *, pairing_code: str, backend: str, transcriber: Transcriber, server_name: str, max_duration: int, max_audio_bytes: int) -> None:
        if not pairing_code:
            raise ValueError("a pairing code is mandatory")
        self.pairing_code = pairing_code
        self.backend = backend
        self.transcriber = transcriber
        self.server_name = server_name
        self.max_duration = max_duration
        self.max_audio_bytes = max_audio_bytes
        self.pair_backoff = 0.4

    async def serve_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await ClientSession(reader, writer, self).run()


def build_transcriber(args: argparse.Namespace) -> Transcriber:
    url = os.environ.get("REMOTESCRIBE_GPU_URL", "").strip()
    token = os.environ.get("REMOTESCRIBE_GPU_TOKEN", "").strip()
    model = os.environ.get("REMOTESCRIBE_GPU_MODEL", "whisper")
    if url or token:
        if not (url and token):
            raise SystemExit("REMOTESCRIBE_GPU_URL and REMOTESCRIBE_GPU_TOKEN must be set together")
        return OpenAICompatibleTranscriber(url, token, model, ca_file=args.gpu_ca_file)
    return EmptyTranscriber()


async def main_async(args: argparse.Namespace) -> None:
    code = args.pairing_code or os.environ.get("REMOTESCRIBE_PAIRING_CODE", "")
    host = RemoteScribeHost(
        pairing_code=code,
        backend=("voxlocal" if args.backend == "voxLocal" else args.backend),
        transcriber=build_transcriber(args),
        server_name=args.server_name,
        max_duration=args.max_duration,
        max_audio_bytes=args.max_audio_bytes,
    )
    server = await asyncio.start_server(host.serve_client, args.bind, args.port, limit=64 * 1024)
    addresses = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
    LOGGER.info("Remote Scribe host listening on %s (v1 plaintext compatibility)", addresses)
    async with server:
        await server.serve_forever()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Remote Scribe v1 Windows host")
    parser.add_argument("--bind", default="127.0.0.1", help="listen address; use 0.0.0.0 only with a Private firewall rule")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--pairing-code", help="required code; prefer REMOTESCRIBE_PAIRING_CODE")
    parser.add_argument("--backend", default="voxlocal", choices=("voxlocal", "voxLocal", "superwhisper"))
    parser.add_argument("--server-name", default="VoxLocal Windows")
    parser.add_argument("--max-duration", type=int, default=MAX_SESSION_SECONDS)
    parser.add_argument("--max-audio-bytes", type=int, default=MAX_AUDIO_BYTES)
    parser.add_argument("--gpu-ca-file", help="optional PEM CA bundle for the HTTPS GPU gateway")
    parser.add_argument("--log-level", default="INFO", choices=("CRITICAL", "ERROR", "WARNING", "INFO"))
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    logging.basicConfig(level=getattr(logging, args.log_level), format="%(asctime)s %(levelname)s %(message)s")
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass
