"""Drive the iOS Core client against the compiled, shipped RemoteScribeHost.

This is the proof that the iPhone client and the real Swift server agree on the
wire contract: two consecutive dictations on one connection, per-session audio
sequence numbers, framesSent in PCM samples. Synthetic PCM only.
"""
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).parents[1]
SCRATCH = ROOT / ".build/remotescribe-host"  # git-ignored by `.build/`


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swift"), "the shipped host requires macOS Swift")
class RealHostInteropTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build = ["swift", "build", "-c", "release", "--product", "RemoteScribeHost", "--scratch-path", str(SCRATCH)]
        subprocess.run(build, cwd=ROOT / "RemoteScribe", check=True, capture_output=True, timeout=900)
        bin_path = subprocess.run([*build[:-2], "--scratch-path", str(SCRATCH), "--show-bin-path"], cwd=ROOT / "RemoteScribe",
                                  check=True, capture_output=True, text=True, timeout=900).stdout.strip()
        cls.host = Path(bin_path) / "RemoteScribeHost"
        cls.temp = tempfile.TemporaryDirectory()
        # Multi-file executable entry point must be named main.swift.
        main = Path(cls.temp.name) / "main.swift"
        main.write_text((ROOT / "tests/swift_core_regression.swift").read_text())
        cls.driver = Path(cls.temp.name) / "core-regression"
        subprocess.run(["swiftc", *map(str, sorted((ROOT / "ios/Core/Sources").glob("*.swift"))), str(main), "-o", str(cls.driver)],
                       check=True, capture_output=True, timeout=300)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_ios_client_completes_two_sessions_against_real_host(self):
        port = free_port()
        with tempfile.TemporaryDirectory() as sessions, tempfile.TemporaryFile() as log:
            host = subprocess.Popen([str(self.host), "--backend", "voxlocal", "--pairing-code", "test-code", "--port", str(port), "--sessions", sessions],
                                    stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 15
                while True:
                    try:
                        socket.create_connection(("127.0.0.1", port), timeout=1).close()
                        break
                    except OSError:
                        if host.poll() is not None or time.monotonic() > deadline:
                            log.seek(0)
                            self.fail(f"RemoteScribeHost did not listen on {port}: {log.read().decode(errors='replace')}")
                        time.sleep(0.2)
                run = subprocess.run([str(self.driver), str(port), "realhost"], text=True, capture_output=True, timeout=60)
                log.seek(0)
                host_log = log.read().decode(errors="replace")
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr + host_log)
                wavs = sorted(Path(sessions).glob("*/remote.wav"))
                self.assertEqual(len(wavs), 2, host_log)
                # 44-byte WAV header + 20 chunks x 4 bytes of PCM per session.
                self.assertEqual([wav.stat().st_size for wav in wavs], [44 + 80, 44 + 80])
            finally:
                host.terminate()
                try:
                    host.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait()


if __name__ == "__main__":
    unittest.main()
