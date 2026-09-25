import asyncio
import base64
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "server"))
from voxlocal_server import (KINDS, MAX_FRAME_SIZE, OpenAICompatibleBackend, RemoteScribeServer, ServerConfig,
                             bonjour_txt_properties, certificate_fingerprint, encode_frame, read_frame)

OPENSSL = shutil.which("openssl")


def make_test_identity(directory: Path) -> tuple[Path, Path]:
    """RSA-2048 self-signed identity, same shape as the Mac app and the generation scripts.

    The subject comes from a minimal config file (as in windows/new-tls-identity.ps1)
    so the test also runs with Windows openssl builds that lack a default openssl.cnf.
    """
    cert, key, config = directory / "server.cert.pem", directory / "server.key.pem", directory / "req.cnf"
    config.write_text("[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = testhost.local\nO = VoxLocal\n")
    subprocess.run([OPENSSL, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert),
                    "-days", "1", "-config", str(config),
                    "-addext", "subjectAltName=DNS:testhost.local,DNS:localhost,IP:127.0.0.1"],
                   check=True, capture_output=True)
    return cert, key


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
        # Shipped Core contract: only audio chunks are numbered (per session,
        # from 0); framesSent counts PCM samples (200 bytes = 100 samples).
        writer.write(encode_frame("startSession", session, 0, json.dumps(start).encode()))
        writer.write(encode_frame("audioChunk", session, 0, b"\x00\x00" * 100))
        writer.write(encode_frame("stopSession", session, 0, json.dumps({"framesSent": 100}).encode()))
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

    def test_stop_with_wrong_frames_sent_is_rejected(self):
        error = asyncio.run(self._session_error([(0, b"\x00\x00" * 100)], frames_sent=1))
        self.assertEqual(error["code"], "protocolViolation")

    def test_audio_sequence_must_be_contiguous(self):
        error = asyncio.run(self._session_error([(1, b"\x00\x00" * 100)], frames_sent=100))
        self.assertEqual(error["code"], "protocolViolation")

    async def _session_error(self, chunks, frames_sent):
        server = RemoteScribeServer(ServerConfig(host="127.0.0.1", port=0, pairing_code="123456", mock=True, insecure_test_only=True))
        await server.start()
        try:
            sock = server._server.sockets[0].getsockname()
            reader, writer = await asyncio.open_connection(sock[0], sock[1])
            pair = {"protocolVersion": 1, "deviceID": "test-device", "deviceName": "pytest", "pairingCode": "123456"}
            writer.write(encode_frame("pair", uuid.UUID(int=0), 0, json.dumps(pair).encode()))
            session = uuid.uuid4()
            start = {"format": {"sampleRate": 16000, "channels": 1, "bitsPerSample": 16, "codec": "pcm_s16le"}, "language": "fr", "backend": "voxlocal"}
            writer.write(encode_frame("startSession", session, 0, json.dumps(start).encode()))
            for sequence, pcm in chunks:
                writer.write(encode_frame("audioChunk", session, sequence, pcm))
            writer.write(encode_frame("stopSession", session, 0, json.dumps({"framesSent": frames_sent}).encode()))
            await writer.drain()
            states = []
            while True:
                kind, _, _, payload = await asyncio.wait_for(read_frame(reader), 2)
                if kind == "error":
                    # START was accepted: the error is about audio/STOP, not START.
                    self.assertEqual(states, ["ready", "recording"])
                    writer.close()
                    return json.loads(payload)
                if kind == "sessionStatus":
                    states.append(json.loads(payload)["state"])
        finally:
            server._server.close()
            await server._server.wait_closed()


class TLSFingerprintTests(unittest.TestCase):
    @unittest.skipUnless(OPENSSL, "openssl not installed")
    def test_certificate_fingerprint_matches_openssl(self):
        with tempfile.TemporaryDirectory() as tmp:
            cert, _ = make_test_identity(Path(tmp))
            der = subprocess.run([OPENSSL, "x509", "-in", str(cert), "-outform", "der"], check=True, capture_output=True).stdout
            self.assertEqual(certificate_fingerprint(cert), hashlib.sha256(der).digest())
            self.assertEqual(len(certificate_fingerprint(cert)), 32)

    @unittest.skipUnless(OPENSSL, "openssl not installed")
    def test_fingerprint_uses_leaf_certificate_of_a_chain_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            leaf, _ = make_test_identity(Path(tmp))
            other_dir = Path(tmp) / "other"
            other_dir.mkdir()
            other, _ = make_test_identity(other_dir)
            chain = Path(tmp) / "chain.pem"
            chain.write_text(leaf.read_text() + other.read_text())
            self.assertEqual(certificate_fingerprint(chain), certificate_fingerprint(leaf))

    def test_bonjour_txt_properties_publish_fingerprint_when_tls(self):
        fp = base64.b64encode(bytes(range(32))).decode("ascii")
        config = ServerConfig(pairing_code="a" * 12, tls_cert=Path("c.pem"), tls_key=Path("k.pem"))
        properties = bonjour_txt_properties(config, fp)
        self.assertEqual(properties[b"tls"], b"1")
        self.assertEqual(properties[b"fp"], fp.encode("ascii"))
        self.assertEqual(properties[b"version"], b"1")
        self.assertEqual(properties[b"test"], b"0")

    def test_bonjour_txt_properties_without_tls_have_no_fingerprint(self):
        config = ServerConfig(pairing_code="123456", mock=True, insecure_test_only=True)
        properties = bonjour_txt_properties(config, None)
        self.assertEqual(properties[b"tls"], b"0")
        self.assertNotIn(b"fp", properties)
        self.assertEqual(properties[b"test"], b"1")

    @unittest.skipUnless(OPENSSL, "openssl not installed")
    def test_tls_server_logs_fingerprint_and_no_secret(self):
        asyncio.run(self._start_tls_server_and_capture_log())

    async def _start_tls_server_and_capture_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            cert, key = make_test_identity(Path(tmp))
            expected = base64.b64encode(certificate_fingerprint(cert)).decode("ascii")
            server = RemoteScribeServer(ServerConfig(host="127.0.0.1", port=0, pairing_code="test-only-123456",
                                                     mock=True, tls_cert=cert, tls_key=key))
            with self.assertLogs("voxlocal.remote_scribe", level="INFO") as captured:
                await server.start()
            try:
                ready = [line for line in captured.output if "server_ready" in line]
                self.assertEqual(len(ready), 1)
                self.assertIn(f"tls_fingerprint_sha256={expected}", ready[0])
                self.assertEqual(server.tls_fingerprint_b64, expected)
                joined = "\n".join(captured.output)
                self.assertNotIn("test-only-123456", joined)
                self.assertNotIn("PRIVATE KEY", joined)
            finally:
                server._server.close()
                await server._server.wait_closed()


if __name__ == "__main__":
    unittest.main()
