import asyncio
import json
import unittest
import uuid

from remotescribe_host import EmptyTranscriber, RemoteScribeHost
from remotescribe_protocol import FrameDecoder, MessageKind, NO_SESSION, encode_audio_frame, encode_json_frame


class HostTests(unittest.TestCase):
    def test_client_session_uses_client_session_id_and_releases_pcm(self):
        asyncio.run(self._run())

    async def _run(self):
        host = RemoteScribeHost(pairing_code="123456", backend="voxlocal", transcriber=EmptyTranscriber(), server_name="test", max_duration=60, max_audio_bytes=1024 * 1024)
        server = await asyncio.start_server(host.serve_client, "127.0.0.1", 0)
        address = server.sockets[0].getsockname()
        reader, writer = await asyncio.open_connection(*address)
        device = {"protocolVersion": 1, "deviceID": "device", "deviceName": "pytest", "pairingCode": "123456"}
        writer.write(encode_json_frame(MessageKind.PAIR, NO_SESSION, 0, device))
        await writer.drain()
        decoder = FrameDecoder()
        states = []
        while "ready" not in states:
            frames = decoder.feed(await asyncio.wait_for(reader.read(4096), 2))
            states.extend(frame.json().get("state") for frame in frames if frame.kind is MessageKind.SESSION_STATUS)
        session_id = uuid.uuid4()
        start = {"format": {"sampleRate": 16000, "channels": 1, "bitsPerSample": 16, "codec": "pcm_s16le"}, "modeIdentifier": None, "language": "fr", "backend": "voxlocal"}
        writer.write(encode_json_frame(MessageKind.START_SESSION, session_id, 1, start))
        writer.write(encode_audio_frame(session_id, 2, b"\x00\x00" * 10))
        writer.write(encode_json_frame(MessageKind.STOP_SESSION, session_id, 3, {"framesSent": 1}))
        await writer.drain()
        while states[-1:] != ["completed"]:
            frames = decoder.feed(await asyncio.wait_for(reader.read(4096), 2))
            for frame in frames:
                if frame.kind is MessageKind.SESSION_STATUS:
                    states.append(frame.json().get("state"))
        self.assertEqual(states, ["ready", "recording", "processing", "completed"])
        writer.close()
        await writer.wait_closed()
        server.close()
        await server.wait_closed()

    def test_stop_rejects_incorrect_chunk_count(self):
        asyncio.run(self._run_bad_stop())

    async def _run_bad_stop(self):
        host = RemoteScribeHost(pairing_code="123456", backend="voxlocal", transcriber=EmptyTranscriber(), server_name="test", max_duration=60, max_audio_bytes=1024 * 1024)
        server = await asyncio.start_server(host.serve_client, "127.0.0.1", 0)
        address = server.sockets[0].getsockname()
        reader, writer = await asyncio.open_connection(*address)
        decoder = FrameDecoder()
        writer.write(encode_json_frame(MessageKind.PAIR, NO_SESSION, 0, {"protocolVersion": 1, "deviceID": "device", "deviceName": "pytest", "pairingCode": "123456"}))
        await writer.drain()
        while True:
            frames = decoder.feed(await asyncio.wait_for(reader.read(4096), 2))
            if any(frame.kind is MessageKind.SESSION_STATUS and frame.json().get("state") == "ready" for frame in frames):
                break
        session_id = uuid.uuid4()
        start = {"format": {"sampleRate": 16000, "channels": 1, "bitsPerSample": 16, "codec": "pcm_s16le"}, "modeIdentifier": None, "language": "fr", "backend": "voxlocal"}
        writer.write(encode_json_frame(MessageKind.START_SESSION, session_id, 1, start))
        writer.write(encode_audio_frame(session_id, 2, b"\x00\x00" * 10))
        writer.write(encode_json_frame(MessageKind.STOP_SESSION, session_id, 3, {"framesSent": 0}))
        await writer.drain()
        while True:
            frames = decoder.feed(await asyncio.wait_for(reader.read(4096), 2))
            if any(frame.kind is MessageKind.ERROR for frame in frames):
                self.assertEqual(next(frame for frame in frames if frame.kind is MessageKind.ERROR).json()["code"], "protocolViolation")
                break
        writer.close()
        await writer.wait_closed()
        server.close()
        await server.wait_closed()


if __name__ == "__main__":
    unittest.main()
