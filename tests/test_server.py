import asyncio
import json
import struct
import sys
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "server"))
from voxlocal_server import KINDS, MAX_FRAME_SIZE, OpenAICompatibleBackend, RemoteScribeServer, ServerConfig, encode_frame, read_frame


class ServerTests(unittest.TestCase):
    def test_wire_header_is_big_endian_and_uuid_is_canonical(self):
        session = uuid.UUID("11111111-1111-1111-1111-111111111111")
        frame = encode_frame("pair", session, 7, b"{}")
        self.assertEqual(struct.unpack(">I", frame[:4])[0], len(frame) - 4)
        self.assertEqual(frame[4], KINDS["pair"])
        self.assertEqual(frame[5:41], str(session).upper().encode("ascii"))
        self.assertEqual(struct.unpack(">Q", frame[41:49])[0], 7)

    def test_wire_length_guard(self):
        with self.assertRaises(Exception):
            encode_frame("audioChunk", uuid.uuid4(), 0, b"x" * MAX_FRAME_SIZE)

    def test_gpu_endpoint_requires_https(self):
        with self.assertRaises(ValueError):
            OpenAICompatibleBackend("voxlocal", "http://gpu.example", None, "whisper")

    def test_real_gpu_requires_tls_and_token(self):
        with self.assertRaises(ValueError):
            RemoteScribeServer(ServerConfig(
                host="127.0.0.1", port=47365, pairing_code="a" * 12,
                backend_url="https://gpu.example", backend_token="token"
            ))

    def test_real_gpu_rejects_wildcard_bind(self):
        with self.assertRaisesRegex(ValueError, "interface réseau explicite"):
            RemoteScribeServer(ServerConfig(
                host="0.0.0.0", port=47365, pairing_code="a" * 12,
                backend_url="https://gpu.example", backend_token="token",
                tls_cert=Path("cert.pem"), tls_key=Path("key.pem")
            ))

    def test_plaintext_requires_explicit_mock_profile(self):
        with self.assertRaises(ValueError):
            RemoteScribeServer(ServerConfig(
                host="127.0.0.1", port=47365, pairing_code="test-only",
                mock=True, insecure_test_only=False
            ))

    def test_mock_server_end_to_end(self):
        asyncio.run(self._handshake_and_mock_session())

    async def _handshake_and_mock_session(self):
        server = RemoteScribeServer(ServerConfig(host="127.0.0.1", port=0, pairing_code="123456", mock=True, insecure_test_only=True))
        await server.start()
        sock = server._server.sockets[0].getsockname()
        reader, writer = await asyncio.open_connection(sock[0], sock[1])
        no_session = uuid.UUID(int=0)
        pair = {"protocolVersion": 1, "deviceID": "test-device", "deviceName": "pytest", "pairingCode": "123456"}
        writer.write(encode_frame("pair", no_session, 0, json.dumps(pair).encode()))
        await writer.drain()
        self.assertEqual((await read_frame(reader))[0], "pair")
        self.assertEqual((await read_frame(reader))[0], "sessionStatus")
        session = uuid.uuid4()
        start = {"format": {"sampleRate": 16000, "channels": 1, "bitsPerSample": 16, "codec": "pcm_s16le"}, "modeIdentifier": None, "language": "fr", "backend": "voxlocal"}
        writer.write(encode_frame("startSession", session, 1, json.dumps(start).encode()))
        writer.write(encode_frame("audioChunk", session, 2, b"\x00\x00" * 100))
        writer.write(encode_frame("stopSession", session, 3, json.dumps({"framesSent": 1}).encode()))
        await writer.drain()
        states = []
        for _ in range(3):
            kind, _, _, payload = await asyncio.wait_for(read_frame(reader), 2)
            if kind == "sessionStatus":
                states.append(json.loads(payload)["state"])
        self.assertEqual(states, ["recording", "processing", "completed"])
        writer.close()
        await writer.wait_closed()
        server._server.close()
        await server._server.wait_closed()


if __name__ == "__main__":
    unittest.main()
