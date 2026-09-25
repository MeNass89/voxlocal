"""Compile real Swift Core and exercise it against an independent socket peer."""
import base64
import hashlib
import json
from pathlib import Path
import queue
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid

ROOT = Path(__file__).parents[1]
ZERO = str(uuid.UUID(int=0)).encode()


def exact(peer, count):
    data = bytearray()
    while len(data) < count:
        chunk = peer.recv(count - len(data))
        if not chunk:
            raise EOFError("client closed an incomplete frame")
        data.extend(chunk)
    return bytes(data)


def receive(peer):
    size = struct.unpack(">I", exact(peer, 4))[0]
    if not 45 <= size <= 1_048_576:
        raise ValueError("invalid client frame size")
    body = exact(peer, size)
    return body[0], body[1:37], struct.unpack(">Q", body[37:45])[0], body[45:]


def send(peer, kind, session, sequence, value):
    body = bytes([kind]) + session + struct.pack(">Q", sequence) + json.dumps(value).encode()
    wire = struct.pack(">I", len(body)) + body
    # Split the length prefix and header deliberately.
    peer.sendall(wire[:2])
    peer.sendall(wire[2:30])
    peer.sendall(wire[30:])


def serve_two_sessions(test, peer):
    """Play the shipped server's side of PAIR plus two complete sessions."""
    kind, sid, seq, payload = receive(peer)
    test.assertEqual((kind, sid, seq), (1, ZERO, 0))
    test.assertEqual(json.loads(payload)["protocolVersion"], 1)
    # The shipped server writes sequence 0 on every frame;
    # the client must ignore the field on server frames.
    send(peer, 1, ZERO, 0, {"accepted": True, "serverName": "Fixture", "selectedBackend": "voxlocal", "protocolVersion": 1, "availableBackends": ["voxlocal"]})
    send(peer, 5, ZERO, 0, {"state": "ready", "backend": "voxlocal", "bytesReceived": 0})
    sessions = set()
    for _ in range(2):
        kind, sid, seq, payload = receive(peer)
        test.assertEqual((kind, seq), (2, 0))
        test.assertNotIn(sid, sessions)
        sessions.add(sid)
        send(peer, 5, sid, 0, {"state": "recording", "backend": "voxlocal", "bytesReceived": 0})
        # Audio chunks are numbered per session from 0, strictly
        # contiguous on the wire whatever the producer interleaving.
        for expected in range(20):
            kind, audio_sid, seq, payload = receive(peer)
            test.assertEqual((kind, audio_sid, seq, payload), (3, sid, expected, b"\x00\x00\x01\x00"))
        kind, stop_sid, seq, payload = receive(peer)
        test.assertEqual((kind, stop_sid, seq), (4, sid, 0))
        # framesSent counts PCM samples: 20 chunks x 4 bytes / 2.
        test.assertEqual(json.loads(payload)["framesSent"], 40)
        send(peer, 5, sid, 0, {"state": "processing", "backend": "voxlocal", "bytesReceived": 80})
        send(peer, 5, sid, 0, {"state": "completed", "backend": "voxlocal", "bytesReceived": 80, "finalText": "test"})


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "Network.framework requires macOS Swift")
class SwiftCoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        # Multi-file executable entry point must be named main.swift.
        main = Path(cls.temp.name) / "main.swift"
        main.write_text((ROOT / "tests/swift_core_regression.swift").read_text())
        cls.binary = Path(cls.temp.name) / "core-regression"
        subprocess.run(["swiftc", *map(str, sorted((ROOT / "ios/Core/Sources").glob("*.swift"))), str(main), "-o", str(cls.binary)], check=True, capture_output=True, timeout=600)
        cls.certificate = cls.key = cls.fingerprint = None
        openssl = shutil.which("openssl", path="/usr/bin") or shutil.which("openssl")
        if openssl:
            # Synthetic self-signed RSA-2048 identity, the same kind VoxLocal generates.
            cls.certificate = Path(cls.temp.name) / "server.cert.pem"
            cls.key = Path(cls.temp.name) / "server.key.pem"
            subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(cls.key), "-out", str(cls.certificate),
                            "-days", "2", "-subj", "/CN=fixture.local/O=VoxLocal", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                           check=True, capture_output=True, timeout=120)
            der = ssl.PEM_cert_to_DER_cert(cls.certificate.read_text())
            cls.fingerprint = base64.b64encode(hashlib.sha256(der).digest()).decode()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_repeated_sessions_concurrent_audio_and_eof(self):
        self.run_peer(False)

    def test_partial_frame_does_not_survive_reconnect(self):
        self.run_peer(True)

    def test_tls_without_pin_requires_confirmation_before_pair(self):
        run, received = self.run_tls("tls-nopin", expect_session=False)
        self.assertEqual(run.returncode, 3, run.stdout + run.stderr)
        self.assertEqual(run.stdout.split(), ["untrustedServer", self.fingerprint])
        self.assertEqual(received, b"", "no application data may leave the phone before trust")

    def test_tls_with_matching_pin_completes_two_sessions(self):
        run, _ = self.run_tls("tls-pin:" + self.fingerprint, expect_session=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_tls_with_wrong_pin_is_refused_before_pair(self):
        wrong = base64.b64encode(hashlib.sha256(b"another server").digest()).decode()
        run, received = self.run_tls("tls-pin:" + wrong, expect_session=False)
        self.assertEqual(run.returncode, 4, run.stdout + run.stderr)
        self.assertEqual(run.stdout.split(), ["pinMismatch", self.fingerprint])
        self.assertEqual(received, b"", "no application data may leave the phone after a pin mismatch")

    def run_tls(self, mode, expect_session):
        if not self.certificate:
            self.skipTest("openssl is required to generate the TLS fixture identity")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        context.load_cert_chain(self.certificate, self.key)
        received = bytearray()

        def serve(listener):
            raw, _ = listener.accept()
            raw.settimeout(10)
            try:
                peer = context.wrap_socket(raw, server_side=True)
            except (ssl.SSLError, OSError):
                raw.close()  # The client refused the certificate during the handshake.
                return
            with peer:
                if expect_session:
                    serve_two_sessions(self, peer)
                    return
                # A refused identity must not be followed by any application byte.
                while True:
                    try:
                        chunk = peer.recv(4096)
                    except (ssl.SSLError, OSError):
                        return
                    if not chunk:
                        return
                    received.extend(chunk)

        run = self.run_fixture(mode, serve)
        return run, bytes(received)

    def run_peer(self, reconnect):
        def serve(listener):
            if reconnect:
                peer, _ = listener.accept()
                with peer:
                    peer.settimeout(10)
                    self.assertEqual(receive(peer)[0], 1)
                    peer.sendall(b"\x00\x00\x00")
            peer, _ = listener.accept()
            with peer:
                peer.settimeout(10)
                serve_two_sessions(self, peer)

        run = self.run_fixture("reconnect" if reconnect else "plain", serve)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def run_fixture(self, mode, serve):
        failures = queue.Queue()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(2)
            listener.settimeout(15)
            port = listener.getsockname()[1]

            def guarded():
                try:
                    serve(listener)
                except BaseException as exc:
                    failures.put(exc)

            worker = threading.Thread(target=guarded, daemon=True)
            worker.start()
            run = subprocess.run([str(self.binary), str(port), mode], text=True, capture_output=True, timeout=30)
            worker.join(timeout=5)
            if not failures.empty():
                raise failures.get()
            self.assertFalse(worker.is_alive(), "socket fixture did not terminate")
            return run

if __name__ == "__main__":
    unittest.main()
