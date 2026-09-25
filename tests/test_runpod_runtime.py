import importlib.util
import json
import os
import shutil
import stat
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("check_services", ROOT / "cloud/runpod/check-services.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class ModelsHandler(BaseHTTPRequestHandler):
    seen_auth = None

    def do_GET(self):
        ModelsHandler.seen_auth = self.headers.get("Authorization")
        body = json.dumps({"object": "list", "data": [{"id": "synthetic"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class RunpodRuntimeTests(unittest.TestCase):
  def test_check_services_uses_bearer(self):
    httpd = HTTPServer(("127.0.0.1", 0), ModelsHandler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        ok, detail = CHECK.check(f"http://127.0.0.1:{httpd.server_port}", "synthetic-secret", 2)
        self.assertEqual((ok, detail), (True, "ready"))
        self.assertEqual(ModelsHandler.seen_auth, "Bearer synthetic-secret")
    finally:
        httpd.shutdown()
        thread.join()


  def test_check_services_rejects_plain_http_non_loopback(self):
    ok, detail = CHECK.check("http://gpu.example", "secret", 1)
    self.assertFalse(ok)
    self.assertIn("loopback", detail)


  def test_check_services_bounds_timeout(self):
    ok, detail = CHECK.check("http://127.0.0.1:1", "secret", 31)
    self.assertFalse(ok)
    self.assertIn("30", detail)


  @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "POSIX permissions and bash required")
  def test_start_all_rejects_permissive_token(self):
    import tempfile
    with tempfile.TemporaryDirectory() as directory:
      token = Path(directory) / "api-token"
      token.write_text("secret", encoding="utf-8")
      token.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP)
      result = subprocess.run(
          ["bash", str(ROOT / "cloud/runpod/start-all.sh")],
          env={**os.environ, "VOXLOCAL_TOKEN_FILE": str(token), "VOXLOCAL_VOICE_CMD": "true"},
          capture_output=True,
          text=True,
          timeout=3,
      )
      self.assertEqual(result.returncode, 2)
      self.assertNotIn("secret", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
