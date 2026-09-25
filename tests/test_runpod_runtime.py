import configparser
import importlib.util
import io
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import threading
import time
import unittest
import wave
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("check_services", ROOT / "cloud/runpod/check-services.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
RUNPOD = ROOT / "cloud/runpod"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BENCH = _load("benchmark", RUNPOD / "benchmark.py")
REPORT = _load("bench_report", RUNPOD / "bench-report.py")


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


def _gitmodules():
    parser = configparser.ConfigParser()
    parser.read(ROOT / ".gitmodules", encoding="utf-8")
    modules = {}
    for section in parser.sections():
        path = parser[section]["path"]
        modules[Path(path).name] = {"path": path, "url": parser[section]["url"]}
    return modules


def _gitlink(path):
    result = subprocess.run(["git", "-C", str(ROOT), "ls-tree", "HEAD", path],
                            capture_output=True, text=True, check=True)
    fields = result.stdout.split()
    if len(fields) < 3 or fields[0] != "160000" or fields[1] != "commit":
        raise AssertionError(f"{path} is not a submodule gitlink: {result.stdout!r}")
    return fields[2]


def _dockerfile_args():
    text = (RUNPOD / "Dockerfile").read_text(encoding="utf-8")
    return dict(re.findall(r"^ARG ([A-Z0-9_]+)=(\S+)$", text, re.MULTILINE)), text


def _caddyfile_template():
    text = (RUNPOD / "entrypoint.sh").read_text(encoding="utf-8")
    match = re.search(r"<<'CADDYFILE'\n(.*?)\nCADDYFILE\n", text, re.DOTALL)
    if not match:
        raise AssertionError("Caddyfile heredoc not found in entrypoint.sh")
    return match.group(1)


def _site_blocks(caddyfile):
    """Return (address, body) for each top-level Caddyfile block."""
    blocks, depth, address, body = [], 0, None, []
    for raw in caddyfile.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        stripped = line.strip()
        if not stripped:
            continue
        if depth == 0:
            address, body = stripped[:-1].strip(), []
        else:
            body.append(stripped)
        depth += line.count("{") - line.count("}")
        if depth == 0 and address is not None:
            blocks.append((address, body[:-1]))
            address = None
    return blocks


class RunpodImageTests(unittest.TestCase):
    def test_dockerfile_pins_submodule_commits(self):
        if shutil.which("git") is None or not (ROOT / ".git").exists():
            self.skipTest("git checkout required to read submodule gitlinks")
        modules = _gitmodules()
        args, text = _dockerfile_args()
        for name, prefix in (("whisper.cpp", "WHISPER_CPP"), ("llama.cpp", "LLAMA_CPP")):
            with self.subTest(submodule=name):
                self.assertIn(name, modules)
                self.assertEqual(args[f"{prefix}_COMMIT"], _gitlink(modules[name]["path"]))
                self.assertEqual(args[f"{prefix}_REPO"].rstrip("/"), modules[name]["url"].rstrip("/"))
                self.assertIn(f'"${{{prefix}_COMMIT}}"', text)
        # The build must check out exactly the pinned commit and verify it.
        self.assertIn('test "$(git -C "$1" rev-parse HEAD)" = "$3"', text)

    def test_dockerfile_bases_and_servers(self):
        _args, text = _dockerfile_args()
        self.assertRegex(text, r"(?m)^FROM nvidia/cuda:\$\{CUDA_VERSION\}-runtime-ubuntu\$\{UBUNTU_VERSION\}$")
        args, _ = _dockerfile_args()
        self.assertEqual((args["CUDA_VERSION"], args["UBUNTU_VERSION"]), ("12.4.1", "22.04"))
        for flag in ("-DGGML_CUDA=ON", "--target whisper-server", "--target llama-server", "python3.11"):
            self.assertIn(flag, text)
        self.assertIn('ENTRYPOINT ["/bin/bash", "/opt/voxlocal/entrypoint.sh"]', text)

    def test_dockerfile_bakes_no_secret(self):
        _args, text = _dockerfile_args()
        for forbidden in ("api-token", "RUNPOD_API_KEY", "VOXLOCAL_API_TOKEN", "key.pem", "HF_TOKEN"):
            self.assertNotIn(forbidden, text)
        self.assertNotRegex(text, r"(?mi)^(ENV|ARG) \S*(TOKEN|SECRET|PASSWORD)")

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "bash and POSIX file modes required")
    def test_shell_scripts_parse(self):
        for script in sorted(RUNPOD.glob("*.sh")):
            with self.subTest(script=script.name):
                result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_caddyfile_requires_bearer_and_has_no_plaintext_listener(self):
        caddyfile = _caddyfile_template()
        self.assertIn('@auth header Authorization "Bearer {env.VOXLOCAL_API_TOKEN}"', caddyfile)
        self.assertNotRegex(caddyfile, r"basic_?auth")
        blocks = _site_blocks(caddyfile)
        self.assertEqual(blocks[0][0], "", "first block must be the global options block")
        self.assertIn("auto_https off", blocks[0][1])
        sites = blocks[1:]
        self.assertEqual([address for address, _ in sites], [":{$VOXLOCAL_EDGE_PORT}"])
        _address, body = sites[0]
        self.assertTrue(any(line.startswith("tls {$VOXLOCAL_TLS_CERT} {$VOXLOCAL_TLS_KEY}") for line in body))
        self.assertIn("protocols tls1.3", body)
        self.assertIn("handle @auth {", body)
        # Unauthenticated requests end on the site's last directive.
        self.assertEqual(body[-1], "respond 401")
        upstreams = set(re.findall(r"reverse_proxy (\S+)", caddyfile))
        self.assertEqual(upstreams, {"127.0.0.1:8001", "127.0.0.1:8003"})
        self.assertNotIn("http://", caddyfile)

    def test_caddyfile_is_valid_when_caddy_is_available(self):
        caddy = shutil.which("caddy")
        if caddy is None:
            self.skipTest("caddy is not installed")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Caddyfile"
            path.write_text(_caddyfile_template(), encoding="utf-8")
            env = {**os.environ, "VOXLOCAL_EDGE_PORT": "18443", "VOXLOCAL_TLS_CERT": "/nonexistent/cert.pem",
                   "VOXLOCAL_TLS_KEY": "/nonexistent/key.pem", "VOXLOCAL_WHISPER_MODEL_ID": "ggml-tiny.bin",
                   "VOXLOCAL_MODELS_DATA": '{"id":"ggml-tiny.bin","object":"model"}'}
            result = subprocess.run([caddy, "adapt", "--config", str(path), "--adapter", "caddyfile"],
                                    capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"Bearer {env.VOXLOCAL_API_TOKEN}"', result.stdout)

    def test_llm_routes_answer_json_404_when_llm_is_off(self):
        caddyfile = _caddyfile_template()
        off = caddyfile.index("@llm_off {")
        # The LLM-off matcher must precede the proxying LLM handlers, or those
        # would answer first with a 502 from an empty upstream.
        self.assertLess(off, caddyfile.index("handle @llm {"))
        self.assertLess(off, caddyfile.index("handle @root_chat {"))
        block = caddyfile[off:caddyfile.index("\n\t\t}", caddyfile.index("handle @llm_off {"))]
        self.assertIn("path /llm/* /v1/chat/completions", block)
        self.assertIn('expression `{env.VOXLOCAL_LLM_ENABLED} == "off"`', block)
        body = re.search(r"respond `(\{.*\})` 404", block)
        self.assertIsNotNone(body, block)
        self.assertEqual(json.loads(body.group(1))["error"]["code"], 404)
        entrypoint = (RUNPOD / "entrypoint.sh").read_text(encoding="utf-8")
        self.assertIn("export VOXLOCAL_LLM_ENABLED=off", entrypoint)

    def test_edge_waits_for_model_health_before_caddy(self):
        text = (RUNPOD / "entrypoint.sh").read_text(encoding="utf-8")
        self.assertIn('READY_TIMEOUT="${VOXLOCAL_READY_TIMEOUT:-60}"', text)
        self.assertIn("http://127.0.0.1:8001/v1/audio/transcriptions/health", text)
        self.assertIn("http://127.0.0.1:8003/health", text)
        self.assertRegex(text, r'VOXLOCAL_EDGE_CMD="bash \$wait_path \$READY_TIMEOUT \$health_urls && exec caddy run')

    def test_entrypoint_service_commands(self):
        text = (RUNPOD / "entrypoint.sh").read_text(encoding="utf-8")
        self.assertIn("openssl rand -hex 32", text)
        self.assertIn('--request-path /v1/audio/transcriptions --inference-path \\"\\"', text)
        self.assertIn("llama-server --host 127.0.0.1 --port 8003", text)
        self.assertIn("-ngl 99 -fa on", text)
        self.assertIn("--api-key-file $token_path", text)
        self.assertIn('exec bash "$ROOT_DIR/start-all.sh"', text)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "bash and POSIX file modes required")
class StartAllTlsTests(unittest.TestCase):
    def _run(self, directory, key_mode, extra_env=None):
        token = Path(directory) / "api-token"
        token.write_text("synthetic-secret\n", encoding="utf-8")
        token.chmod(0o600)
        cert, key = Path(directory) / "cert.pem", Path(directory) / "key.pem"
        cert.write_text("cert", encoding="utf-8")
        key.write_text("key", encoding="utf-8")
        key.chmod(key_mode)
        out = Path(directory) / "seen"
        env = {**os.environ, "VOXLOCAL_TOKEN_FILE": str(token), "VOXLOCAL_ROOT": directory,
               "VOXLOCAL_TLS_CERT": str(cert), "VOXLOCAL_TLS_KEY": str(key),
               "VOXLOCAL_VOICE_CMD": f'printf "%s|%s" "$VOXLOCAL_TLS_CERT" "$VOXLOCAL_TLS_KEY" > {out}',
               **(extra_env or {})}
        result = subprocess.run(["bash", str(RUNPOD / "start-all.sh")], env=env,
                                capture_output=True, text=True, timeout=10)
        return result, out, cert, key

    def test_tls_paths_reach_services(self):
        with tempfile.TemporaryDirectory() as directory:
            result, out, cert, key = self._run(directory, 0o600)
            # The one-shot command exits, so the supervisor stops with status 2.
            self.assertEqual(result.returncode, 2)
            self.assertEqual(out.read_text(encoding="utf-8"), f"{cert}|{key}")
            self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_tls_key_must_be_private(self):
        with tempfile.TemporaryDirectory() as directory:
            result, out, _cert, _key = self._run(directory, 0o644)
            self.assertEqual(result.returncode, 2)
            self.assertIn("TLS key must not be group/world accessible", result.stderr)
            self.assertFalse(out.exists())

    def test_tls_cert_and_key_go_together(self):
        with tempfile.TemporaryDirectory() as directory:
            result, out, _cert, _key = self._run(directory, 0o600, {"VOXLOCAL_TLS_KEY": ""})
            self.assertEqual(result.returncode, 2)
            self.assertIn("must be set together", result.stderr)
            self.assertFalse(out.exists())


class ReadyHandler(BaseHTTPRequestHandler):
    ready_after = 0.0

    def do_GET(self):
        ok = self.path == "/health" and time.monotonic() >= type(self).ready_after
        self.send_response(200 if ok else 503)
        self.end_headers()

    def log_message(self, *_args):
        pass


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "bash and POSIX file modes required")
class WaitReadyTests(unittest.TestCase):
    def _server(self, delay):
        handler = type("Handler", (ReadyHandler,), {"ready_after": time.monotonic() + delay})
        server = HTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}/health"

    def _run(self, *args):
        return subprocess.run(["bash", str(RUNPOD / "wait-ready.sh"), *args],
                              capture_output=True, text=True, timeout=20)

    def test_waits_until_every_service_is_ready(self):
        fast, slow = self._server(0), self._server(1.5)
        started = time.monotonic()
        result = self._run("10", fast, slow)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(time.monotonic() - started, 1.0)
        self.assertIn(f"ready {fast}", result.stdout)
        self.assertIn(f"ready {slow}", result.stdout)

    def test_timeout_warns_and_lets_the_edge_start(self):
        never = self._server(3600)
        result = self._run("1", never)
        self.assertEqual(result.returncode, 0)
        self.assertIn("not ready after 1s", result.stderr)

    def test_rejects_non_loopback_urls_and_bad_timeout(self):
        self.assertEqual(self._run("5", "http://10.0.0.1:8001/health").returncode, 2)
        self.assertEqual(self._run("5s", "http://127.0.0.1:8001/health").returncode, 2)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "bash and POSIX file modes required")
class DeployGuardTests(unittest.TestCase):
    def _run(self, path_dirs, api_key=None):
        env = {key: value for key, value in os.environ.items() if key != "RUNPOD_API_KEY"}
        env["PATH"] = os.pathsep.join(path_dirs)
        if api_key is not None:
            env["RUNPOD_API_KEY"] = api_key
        return subprocess.run(["/bin/bash", str(RUNPOD / "deploy.sh")], env=env,
                              capture_output=True, text=True, timeout=10)

    def test_missing_runpodctl_exits_2_with_documented_install_line(self):
        if shutil.which("runpodctl", path="/usr/bin:/bin"):
            self.skipTest("runpodctl is installed system-wide")
        result = self._run(["/usr/bin", "/bin"], api_key="synthetic-key")
        self.assertEqual(result.returncode, 2)
        audit = (ROOT / "docs/runpod-guide-audit.md").read_text(encoding="utf-8")
        for line in ("curl -sSL https://cli.runpod.net | bash", "brew install runpod/runpodctl/runpodctl"):
            self.assertIn(line, audit)
            self.assertIn(line, result.stderr)
        self.assertNotIn("synthetic-key", result.stdout + result.stderr)

    def test_missing_api_key_exits_2(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "runpodctl"
            fake.write_text("#!/bin/sh\necho called >> \"$0.log\"\n", encoding="utf-8")
            fake.chmod(0o755)
            result = self._run([directory, "/usr/bin", "/bin"])
            self.assertEqual(result.returncode, 2)
            self.assertIn("RUNPOD_API_KEY is not set", result.stderr)
            self.assertIn("export RUNPOD_API_KEY=<key>", result.stderr)
            self.assertFalse(Path(str(fake) + ".log").exists(), "runpodctl must not run before the guards pass")

    def test_missing_token_secret_exits_2(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "runpodctl"
            fake.write_text("#!/bin/sh\necho called >> \"$0.log\"\n", encoding="utf-8")
            fake.chmod(0o755)
            env_path = [directory, "/usr/bin", "/bin"]
            env = {key: value for key, value in os.environ.items() if key != "VOXLOCAL_TOKEN_SECRET"}
            env.update({"PATH": os.pathsep.join(env_path), "RUNPOD_API_KEY": "synthetic-key",
                        "VOXLOCAL_IMAGE": "docker.io/example/voxlocal:test", "VOXLOCAL_SKIP_BUILD": "1"})
            result = subprocess.run(["/bin/bash", str(RUNPOD / "deploy.sh")], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("VOXLOCAL_TOKEN_SECRET is not set", result.stderr)
            self.assertNotIn("synthetic-key", result.stdout + result.stderr)
            self.assertFalse(Path(str(fake) + ".log").exists())


class StubOpenAIHandler(BaseHTTPRequestHandler):
    delays = {}
    counts = {}
    completion_tokens = 40

    def _send(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        StubOpenAIHandler.counts[self.path] = StubOpenAIHandler.counts.get(self.path, 0) + 1
        self._send({"object": "list", "data": [{"id": "stub"}]})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        StubOpenAIHandler.counts[self.path] = StubOpenAIHandler.counts.get(self.path, 0) + 1
        time.sleep(StubOpenAIHandler.delays.get(self.path, 0))
        if self.path == "/v1/chat/completions":
            self._send({"choices": [{"message": {"content": "STUB-RESPONSE-TEXT"}}],
                        "usage": {"prompt_tokens": 10, "completion_tokens": StubOpenAIHandler.completion_tokens}})
        else:
            self._send({"text": "STUB-RESPONSE-TEXT"})

    def log_message(self, *_args):
        pass


class BenchmarkTests(unittest.TestCase):
    def test_percentile_nearest_rank(self):
        self.assertEqual(BENCH.percentile([30.0, 10.0, 20.0], 50), 20.0)
        self.assertEqual(BENCH.percentile([30.0, 10.0, 20.0], 95), 30.0)
        values = [float(v) for v in range(1, 21)]
        self.assertEqual(BENCH.percentile(values, 50), 10.0)
        self.assertEqual(BENCH.percentile(values, 95), 19.0)
        self.assertEqual(BENCH.percentile(values, 100), 20.0)
        self.assertIsNone(BENCH.percentile([], 95))
        self.assertEqual(BENCH.summarize([4.0, 1.0, 2.0, 3.0]),
                         {"min": 1.0, "mean": 2.5, "p50": 2.0, "p95": 4.0, "max": 4.0})

    def test_fixtures_are_deterministic_and_not_silent(self):
        tone = BENCH.synthetic_tone_wav(10)
        self.assertEqual(tone, BENCH.synthetic_tone_wav(10))
        with wave.open(io.BytesIO(tone)) as wav:
            self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getframerate()), (1, 2, 16000))
            self.assertEqual(wav.getnframes(), 160000)
            pcm = wav.readframes(wav.getnframes())
        self.assertGreater(max(abs(int.from_bytes(pcm[i:i + 2], "little", signed=True))
                               for i in range(0, len(pcm), 2)), 8000)
        with wave.open(io.BytesIO(BENCH.synthetic_wav())) as wav:
            self.assertEqual(wav.getnframes(), 4000)

    def test_iterations_are_validated(self):
        for bad in ("0", "101", "x"):
            with self.subTest(value=bad), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    BENCH.main(["--voice-url", "http://127.0.0.1:1", "--iterations", bad])

    def test_iterations_p95_and_tokens_per_second_on_stub(self):
        StubOpenAIHandler.counts = {}
        StubOpenAIHandler.delays = {"/v1/chat/completions": 0.05, "/v1/audio/transcriptions": 0.01}
        httpd = HTTPServer(("127.0.0.1", 0), StubOpenAIHandler)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{httpd.server_port}"
        stdout, stderr = io.StringIO(), io.StringIO()
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = BENCH.main(["--voice-url", base, "--llm-url", base, "--iterations", "4",
                                   "--timeout", "5", "--note", "stub run"])
        finally:
            httpd.shutdown()
            httpd.server_close()
            thread.join()
        self.assertEqual(code, 0, stderr.getvalue())
        self.assertNotIn("STUB-RESPONSE-TEXT", stdout.getvalue() + stderr.getvalue())
        result = json.loads(stdout.getvalue())
        self.assertEqual((result["benchmark"], result["ok"], result["iterations"], result["note"]),
                         ("voxlocal-runpod-synthetic-v2", True, 4, "stub run"))
        self.assertEqual([a["id"] for a in result["synthetic"]["audio"]], ["250ms", "10s"])
        # 2 audio fixtures x 4 on voice, 4 chats on llm, one /v1/models each.
        self.assertEqual(StubOpenAIHandler.counts["/v1/audio/transcriptions"], 8)
        self.assertEqual(StubOpenAIHandler.counts["/v1/chat/completions"], 4)
        self.assertEqual(StubOpenAIHandler.counts["/v1/models"], 2)
        ops = {(s["name"], o["operation"]): o for s in result["services"] for o in s["operations"]}
        self.assertEqual(set(ops), {("voice", "models"), ("voice", "audio_transcriptions_250ms"),
                                    ("voice", "audio_transcriptions_10s"), ("llm", "models"),
                                    ("llm", "chat_completions")})
        chat = ops[("llm", "chat_completions")]
        self.assertEqual((chat["iterations"], chat["ok_count"], len(chat["samples"])), (4, 4, 4))
        latencies = [sample["latency_ms"] for sample in chat["samples"]]
        self.assertEqual(chat["latency_ms"]["p95"], round(max(latencies), 2))
        self.assertEqual(chat["latency_ms"]["p50"], round(sorted(latencies)[1], 2))
        # Timer granularity on Windows lets a 50 ms sleep return a few ms early.
        self.assertGreaterEqual(chat["latency_ms"]["p50"], 40)
        for sample in chat["samples"]:
            self.assertEqual(sample["completion_tokens"], 40)
            expected = 40 / (sample["latency_ms"] / 1000)
            self.assertAlmostEqual(sample["tokens_per_second"], expected, delta=expected * 0.02)
        self.assertLess(chat["tokens_per_second"]["p50"], 800)
        self.assertNotIn("tokens_per_second", ops[("voice", "audio_transcriptions_10s")])

    def test_failed_samples_are_excluded_from_statistics(self):
        op = BENCH._operation("chat_completions", [
            {"status": "ok", "latency_ms": 10.0},
            {"status": "unavailable", "latency_ms": 5000.0},
        ])
        self.assertEqual((op["iterations"], op["ok_count"]), (2, 1))
        self.assertEqual(op["latency_ms"]["p95"], 10.0)

    def test_bench_report_renders_markdown(self):
        result = {"benchmark": "voxlocal-runpod-synthetic-v2", "ok": True, "iterations": 3,
                  "started_at": "2026-09-25T00:00:00Z", "note": "stub",
                  "services": [{"name": "llm", "ok": True, "operations": [{
                      "operation": "chat_completions", "iterations": 3, "ok_count": 3, "samples": [],
                      "latency_ms": {"min": 1.0, "mean": 2.0, "p50": 2.0, "p95": 3.0, "max": 3.0},
                      "tokens_per_second": {"min": 10.0, "mean": 20.0, "p50": 20.0, "p95": 30.0, "max": 30.0}}]}]}
        table = REPORT.render(result)
        self.assertIn("| llm | chat_completions | 3/3 | 2.00 | 3.00 | 2.00 | 20.0 | 30.0 |", table)
        with self.assertRaises(ValueError):
            REPORT.render({"benchmark": "other"})


if __name__ == "__main__":
    unittest.main()
