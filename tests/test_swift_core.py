"""Compile real Swift Core and exercise it against an independent socket peer."""
import json
from pathlib import Path
import queue
import shutil
import socket
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


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "Network.framework requires macOS Swift")
class SwiftCoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        # Multi-file executable entry point must be named main.swift.
        main = Path(cls.temp.name) / "main.swift"
        main.write_text((ROOT / "tests/swift_core_regression.swift").read_text())
        cls.binary = Path(cls.temp.name) / "core-regression"
        subprocess.run(["swiftc", *map(str, sorted((ROOT / "ios/Core/Sources").glob("*.swift"))), str(main), "-o", str(cls.binary)], check=True, capture_output=True, timeout=300)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_repeated_sessions_concurrent_audio_and_eof(self):
        self.run_peer(False)

    def test_partial_frame_does_not_survive_reconnect(self):
        self.run_peer(True)

    def run_peer(self, reconnect):
        failures = queue.Queue()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(2)
            listener.settimeout(15)
            port = listener.getsockname()[1]

            def serve():
                try:
                    if reconnect:
                        peer, _ = listener.accept()
                        with peer:
                            peer.settimeout(10)
                            self.assertEqual(receive(peer)[0], 1)
                            peer.sendall(b"\x00\x00\x00")
                    peer, _ = listener.accept()
                    with peer:
                        peer.settimeout(10)
                        kind, sid, seq, payload = receive(peer)
                        self.assertEqual((kind, sid, seq), (1, ZERO, 0))
                        self.assertEqual(json.loads(payload)["protocolVersion"], 1)
                        # The shipped server writes sequence 0 on every frame;
                        # the client must ignore the field on server frames.
                        send(peer, 1, ZERO, 0, {"accepted": True, "serverName": "Fixture", "selectedBackend": "voxlocal", "protocolVersion": 1, "availableBackends": ["voxlocal"]})
                        send(peer, 5, ZERO, 0, {"state": "ready", "backend": "voxlocal", "bytesReceived": 0})
                        sessions = set()
                        for _ in range(2):
                            kind, sid, seq, payload = receive(peer)
                            self.assertEqual((kind, seq), (2, 0))
                            self.assertNotIn(sid, sessions)
                            sessions.add(sid)
                            send(peer, 5, sid, 0, {"state": "recording", "backend": "voxlocal", "bytesReceived": 0})
                            # Audio chunks are numbered per session from 0, strictly
                            # contiguous on the wire whatever the producer interleaving.
                            for expected in range(20):
                                kind, audio_sid, seq, payload = receive(peer)
                                self.assertEqual((kind, audio_sid, seq, payload), (3, sid, expected, b"\x00\x00\x01\x00"))
                            kind, stop_sid, seq, payload = receive(peer)
                            self.assertEqual((kind, stop_sid, seq), (4, sid, 0))
                            # framesSent counts PCM samples: 20 chunks x 4 bytes / 2.
                            self.assertEqual(json.loads(payload)["framesSent"], 40)
                            send(peer, 5, sid, 0, {"state": "processing", "backend": "voxlocal", "bytesReceived": 80})
                            send(peer, 5, sid, 0, {"state": "completed", "backend": "voxlocal", "bytesReceived": 80, "finalText": "test"})
                except BaseException as exc:
                    failures.put(exc)

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            run = subprocess.run([str(self.binary), str(port), "reconnect" if reconnect else "plain"], text=True, capture_output=True, timeout=20)
            worker.join(timeout=2)
            if not failures.empty():
                raise failures.get()
            self.assertFalse(worker.is_alive(), "socket fixture did not terminate")
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
