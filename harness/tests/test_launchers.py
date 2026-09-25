"""Bash launchers: the model URL rule of run-web.ps1, enforced by run-web.sh and run-demo.sh.

Run from the repository root: python3 -m unittest harness.tests.test_launchers -v
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path

HARNESS = Path(__file__).resolve().parent.parent
RUN_WEB = HARNESS / "run-web.sh"
RUN_DEMO = HARNESS / "demo" / "run-demo.sh"
PLAINTEXT = "uses plaintext HTTP to a remote host; use https:// or 127.0.0.1"
MALFORMED = "must be an absolute http(s) URL without credentials"


def check_function(script: Path) -> str:
    """The `check_llm_url` definition, verbatim, from a launcher."""
    m = re.search(r"^check_llm_url\(\) \{.*?^\}$", script.read_text(encoding="utf-8"), re.S | re.M)
    if m is None:
        raise AssertionError(f"check_llm_url absent de {script}")
    return m.group(0)


@unittest.skipUnless(shutil.which("bash"), "bash absent")
class LlmUrlCheck(unittest.TestCase):
    def run_script(self, *argv: str, **env: str) -> subprocess.CompletedProcess:
        base = {k: v for k, v in os.environ.items() if not k.startswith(("VOXLOCAL_", "PORTAIL_"))}
        return subprocess.run(["bash", *argv], env={**base, **env}, capture_output=True, text=True,
                              timeout=60)

    def check(self, url: str) -> subprocess.CompletedProcess:
        return self.run_script("-c", f'{check_function(RUN_WEB)}\ncheck_llm_url VOXLOCAL_LLM_URL "$1"',
                               "_", url)

    def test_both_launchers_parse(self):
        self.assertEqual(self.run_script("-n", str(RUN_WEB), str(RUN_DEMO)).returncode, 0)

    def test_the_demo_carries_the_same_check(self):
        self.assertEqual(check_function(RUN_DEMO), check_function(RUN_WEB))

    def test_rule(self):
        for url in ("https://pod.example:8443/llm/v1", "http://127.0.0.1:47381/v1",
                    "http://localhost/v1", "http://[::1]:8080/v1", "HTTP://LOCALHOST/v1"):
            self.assertEqual(self.check(url).returncode, 0, url)
        for url, message in (("http://pod.example/v1", PLAINTEXT),
                             ("http://127.0.0.1.evil.example/v1", PLAINTEXT),
                             ("http://[::2]/v1", PLAINTEXT),
                             ("http://user:pw@127.0.0.1/v1", MALFORMED),
                             ("https://token@pod.example/v1", MALFORMED),
                             ("http://localhost@evil.example/v1", MALFORMED),
                             ("ftp://127.0.0.1/v1", MALFORMED),
                             ("pod.example/v1", MALFORMED),
                             ("https:///v1", MALFORMED)):
            res = self.check(url)
            self.assertEqual(res.returncode, 2, url)
            self.assertIn(message, res.stderr, url)

    def test_run_web_refuses_a_plaintext_remote_model_before_anything_starts(self):
        res = self.run_script(str(RUN_WEB), VOXLOCAL_LLM_URL="http://pod.example:8000/v1",
                              VOXLOCAL_LLM_TOKEN="x")
        self.assertEqual(res.returncode, 2)
        self.assertIn(f"VOXLOCAL_LLM_URL {PLAINTEXT}: http://pod.example:8000/v1", res.stderr)

    def test_run_demo_pod_refuses_a_plaintext_remote_model(self):
        res = self.run_script(str(RUN_DEMO), "--provider", "pod",
                              VOXLOCAL_LLM_URL="http://pod.example:8000/v1", VOXLOCAL_LLM_TOKEN="x")
        self.assertEqual(res.returncode, 2)
        self.assertIn(PLAINTEXT, res.stderr)


if __name__ == "__main__":
    unittest.main()
