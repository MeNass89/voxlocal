import base64
import io
import json
import threading
import unittest
import urllib.error
import urllib.request
import wave
from unittest.mock import patch

from agent.voxlocal_agent_api import APIError, AgentHTTPServer, AgentService, HTTPSJSONClient, VoiceProvider, _json_bytes, _request


class AgentAPITest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.token = "test-agent-token"
        service = AgentService(voice=VoiceProvider(None, None, "mock", True), llm=None,
                               llm_model="test", chat_enabled=False, auth_token=cls.token)
        cls.server = AgentHTTPServer(("127.0.0.1", 0), service)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(timeout=2)

    def req(self, path, method="GET", body=None, content_type="application/json", token=None):
        headers = {"Authorization": f"Bearer {token or self.token}", "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = content_type
        req = urllib.request.Request(self.base + path, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=3) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def wav(self):
        out = io.BytesIO()
        with wave.open(out, "wb") as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000); wav.writeframes(b"\0\0" * 800)
        return out.getvalue()

    def test_auth_and_capabilities(self):
        status, data = self.req("/v1/capabilities", token="wrong")
        self.assertEqual(status, 401); self.assertEqual(data["error"]["code"], "unauthorized")
        status, data = self.req("/v1/capabilities")
        self.assertEqual(status, 200); self.assertTrue(data["data"]["zdr"]); self.assertTrue(data["data"]["transcribe"])

    def test_wav_transcription_zdr(self):
        status, data = self.req("/v1/transcribe", "POST", self.wav(), "audio/wav")
        self.assertEqual(status, 200); self.assertTrue(data["ok"]); self.assertFalse(data["data"]["persisted"])
        self.assertIn("1600", data["data"]["text"])

    def test_json_base64_and_clean(self):
        body = _json_bytes({"audioBase64": base64.b64encode(self.wav()).decode(), "format": "wav", "language": "fr-FR"})
        status, data = self.req("/v1/transcribe", "POST", body)
        self.assertEqual(status, 200); self.assertTrue(data["ok"])
        status, data = self.req("/v1/clean", "POST", _json_bytes({"text": "  négation\n   médicament  "}))
        self.assertEqual(status, 200); self.assertEqual(data["data"]["cleanedText"], "négation médicament")

    def test_chat_disabled_and_machine_error(self):
        status, data = self.req("/v1/chat", "POST", _json_bytes({"messages": [{"role": "user", "content": "x"}]}))
        self.assertEqual(status, 403); self.assertEqual(data["error"]["code"], "capability_disabled")
        status, data = self.req("/v1/transcribe", "POST", b"not-audio", "text/plain")
        self.assertEqual(status, 415); self.assertEqual(data["error"]["code"], "unsupported_media_type")

    def test_strict_json_and_query_are_rejected(self):
        duplicate = b'{"text":"a","text":"b"}'
        status, data = self.req("/v1/clean", "POST", duplicate)
        self.assertEqual(status, 400); self.assertEqual(data["error"]["code"], "invalid_json")
        non_finite = b'{"text":NaN}'
        status, data = self.req("/v1/clean", "POST", non_finite)
        self.assertEqual(status, 400); self.assertEqual(data["error"]["code"], "invalid_json")
        status, data = self.req("/v1/capabilities?token=should-not-be-logged")
        self.assertEqual(status, 404); self.assertEqual(data["error"]["code"], "not_found")

    def test_upstream_errors_are_actionable_and_request_id_is_propagated(self):
        client = HTTPSJSONClient("https://gpu.example", "remote-token", timeout=2)

        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self, _limit): return b'{"choices":[{"message":{"content":"ok"}}]}'

        class Opener:
            def open(self, request, timeout):
                self.request = request
                self.timeout = timeout
                return Response()

        opener = Opener(); client.opener = opener
        data = client.post("/v1/chat/completions", b"{}", "application/json", "request-123")
        self.assertEqual(data["choices"][0]["message"]["content"], "ok")
        self.assertEqual(opener.request.get_header("X-request-id"), "request-123")
        self.assertEqual(opener.timeout, 2)

        class RefusingOpener:
            def open(self, request, timeout):
                raise urllib.error.HTTPError(request.full_url, 401, "unauthorized", {}, io.BytesIO())

        client.opener = RefusingOpener()
        with self.assertRaises(APIError) as error:
            client.post("/v1/chat/completions", b"{}", "application/json", "request-124")
        self.assertEqual(error.exception.code, "upstream_auth")
        self.assertFalse(error.exception.retryable)

    def test_upstream_timeout_is_bounded(self):
        with self.assertRaises(ValueError):
            HTTPSJSONClient("https://gpu.example", None, timeout=0.5)
        with self.assertRaises(ValueError):
            HTTPSJSONClient("https://gpu.example", None, timeout=301)

    def test_cli_rejects_process_argument_secrets(self):
        from agent.voxlocal_agent_api import main
        with patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit):
                main(["--token", "visible-in-process-list", "status"])
            with self.assertRaises(SystemExit):
                main(["serve", "--auth-token", "visible-in-process-list", "--mock"])

    def test_cli_refuses_remote_plain_http_and_mock_endpoints(self):
        remote = _request("http://10.0.0.8:47366", self.token, "GET", "/healthz")
        self.assertEqual(remote["error"]["code"], "invalid_url")
        from agent.voxlocal_agent_api import main
        with patch.dict("os.environ", {"VOXLOCAL_AGENT_TOKEN": self.token, "VOXLOCAL_GPU_URL": "https://gpu.example"}, clear=False):
            with patch("sys.stderr", new_callable=io.StringIO):
                with self.assertRaises(SystemExit):
                    main(["serve", "--mock"])


if __name__ == "__main__": unittest.main()
