"""The real-time loop, end to end, with a scripted model: dictation -> drafts -> approval -> write.

What runs for real:
  * dsh 0.1.7-rc.2 (`harness/profile/node_modules/.bin/dsh`), one-shot `headless` bundle over
    `dsh-base`, with the tracked scribe layer `harness/profile/cordis.patch.yml` (provider, the
    four VoxLocal plugins, approval policy) and a test overlay (see `_overlay`);
  * the portal bridge (`python3 -m harness.bridge.portail_bridge`, mock backend) on its own
    temp dir, with the tool and approver tokens;
  * the scribe plugins: portail-tools, scribe-approval, scribe-persona (and voxlocal-tools).

What is scripted: the model. `ScriptedProvider` is an OpenAI-compatible `/v1/chat/completions`
server (stdlib `http.server`, SSE streaming) that answers each request from the conversation it
receives: `record_find_sections` -> `record_draft_edit` (`physical-exam-text`, then
`disposition`, with verbatim quotes of the entorse dictation) -> `record_apply` on each draft ->
a final French summary. It records every request so the test can check what the model was shown
(system prompt, tool list). The 0.5B local model cannot follow the tool protocol reliably; the
real-model run stays a manual bench (`harness/bench`).

Why a subprocess and not the Python SDK: the published `deepseek-harness-sdk` wheel is 0.1.5rc1
(no 0.1.7-rc.2 on PyPI), older than the pinned dsh, and the SDK protocol only has
`session/prompt` anyway. `dsh --profile … --json` is the same agent loop with the same plugins.

How the approval is answered in a headless run: `dsh-headless` composes no human answerer, so
policy `ask` fails closed (`unavailable`). The "clinician allows" case mounts a test-only
answerer plugin (`harness/tests/fixtures/test_answerer.ts`) that returns `allowed-once` and
records each request, standing in for the click in the dsh web chat.

Run from the repository root: python3 -m unittest harness.tests.test_loop -v
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HARNESS = Path(__file__).resolve().parent.parent
REPO = HARNESS.parent
DSH = HARNESS / "profile" / "node_modules" / ".bin" / "dsh"
PATCH = HARNESS / "profile" / "cordis.patch.yml"
ANSWERER = HARNESS / "tests" / "fixtures" / "test_answerer.ts"
DICTATION = HARNESS / "bridge" / "fixtures" / "transcript_entorse.txt"

P1, E1, DICT = "pat-001", "enc-001-urg", "dict-entorse-001"
ITEM1 = "1f19a001-aaaa-4000-8000-000000000101"
TOOL_TOKEN = "tool-" + "c" * 40
APPROVER_TOKEN = "approver-" + "d" * 40
REFUSAL = "Application refusée : aucun feu vert."

#: The two drafts the scripted model proposes, each backed by verbatim dictation quotes.
DRAFTS = [
    {"attribute": "physical-exam-text",
     "new_text": "Œdème modéré de la malléole externe droite. Douleur à la palpation du ligament "
                 "talo-fibulaire antérieur. Pas de douleur osseuse (malléole postérieure, base du "
                 "5e métatarsien). Appui possible (4 pas). Critères d'Ottawa négatifs.",
     "quotes": ["oedème modéré de la malléole externe droite",
                "douleur à la palpation du ligament talo-fibulaire antérieur",
                "Critères d'Ottawa négatifs"]},
    {"attribute": "disposition",
     "new_text": "Protocole entorse : repos, glace, compression par bandage, élévation. Paracétamol "
                 "et AINS si pas de contre-indication. Attelle de cheville 2 semaines. Arrêt de "
                 "travail 3 jours. Contrôle chez le médecin traitant dans une semaine ; "
                 "reconsulter si aggravation.",
     "quotes": ["Attelle de cheville pour deux semaines",
                "Arrêt de travail trois jours",
                "Contrôle chez le médecin traitant dans une semaine"]},
]


def dictation_text() -> str:
    raw = DICTATION.read_text(encoding="utf-8")
    return re.sub(r"\s+", " ", "\n".join(l for l in raw.splitlines() if not l.startswith("#"))).strip()


def task_prompt() -> str:
    """What the feeder sends (H2 `dictation_message`), in one turn: SDK/headless have no inject."""
    return (f"Nouvelle dictée {DICT} (5 min 00 s) : {dictation_text()}\n"
            f"Patient déclaré : {P1}\n\n"
            "Préparez les modifications du dossier (examen clinique et orientation), puis "
            "appliquez-les après mon feu vert.")


# ============================================================================ scripted model
class ScriptedProvider:
    """OpenAI-compatible chat-completions stub whose next move depends on the tool results so far."""

    def __init__(self):
        self.requests: list[dict] = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_port}/v1"

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self.server.shutdown()
        self.server.server_close()

    # ------------------------------------------------------------ policy
    @staticmethod
    def next_move(messages: list[dict]) -> tuple[str, dict | None]:
        """(text, tool_call) for the conversation so far. Pure: the conversation decides."""
        results: dict[str, str] = {}
        calls: list[tuple[str, str, dict]] = []  # (id, name, args) in order
        for m in messages:
            if m.get("role") == "assistant":
                for tc in m.get("tool_calls") or []:
                    calls.append((tc["id"], tc["function"]["name"],
                                  json.loads(tc["function"]["arguments"] or "{}")))
            if m.get("role") == "tool":
                content = m.get("content")
                if isinstance(content, list):
                    content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
                results[m.get("tool_call_id")] = content or ""
        done = [(name, args, results.get(cid, "")) for cid, name, args in calls]
        names = [d[0] for d in done]
        if "record_find_sections" not in names:
            return "", ("record_find_sections", {"patient_id": P1})
        drafted = [d for d in done if d[0] == "record_draft_edit"]
        if len(drafted) < len(DRAFTS):
            spec = DRAFTS[len(drafted)]
            dtext = dictation_text()
            quotes = [{"dictation_id": DICT, "offset": max(dtext.find(q), 0), "text": q}
                      for q in spec["quotes"]]
            return "", ("record_draft_edit", {
                "patient_id": P1, "encounter_id": E1, "item_id": ITEM1,
                "attribute": spec["attribute"], "mode": "append", "new_text": spec["new_text"],
                "rationale": "dicté par le médecin", "quotes": quotes})
        draft_ids = [m.group(1) for _, _, r in drafted
                     for m in [re.search(r"Brouillon (drf-[0-9a-f]+) enregistré", r)] if m]
        applied = [d for d in done if d[0] == "record_apply"]
        if len(applied) < len(draft_ids):
            return "", ("record_apply", {"draft_id": draft_ids[len(applied)]})
        outcome = "; ".join(r.splitlines()[0] for _, _, r in applied)
        return f"Brouillons {', '.join(draft_ids)} traités. {outcome}", None

    # ------------------------------------------------------------ HTTP
    def _handler(self):
        provider = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def do_GET(self):  # /v1/models, if anything asks
                body = json.dumps({"object": "list", "data": [{"id": "qwen3.8-27b", "object": "model"}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                provider.requests.append({"auth": self.headers.get("Authorization"), **body})
                text, call = ScriptedProvider.next_move(body.get("messages", []))
                n = len(provider.requests)
                chunks: list[dict] = [{"role": "assistant", "content": text}] if text else []
                if call:
                    chunks.append({"role": "assistant", "tool_calls": [{
                        "index": 0, "id": f"call_{n}", "type": "function",
                        "function": {"name": call[0], "arguments": json.dumps(call[1], ensure_ascii=False)}}]})
                finish = "tool_calls" if call else "stop"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()

                def emit(obj):
                    self.wfile.write(f"data: {json.dumps(obj, ensure_ascii=False)}\n\n".encode())

                base = {"id": f"chatcmpl-{n}", "object": "chat.completion.chunk", "created": 0,
                        "model": body.get("model")}
                for delta in chunks:
                    emit({**base, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]})
                emit({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]})
                emit({**base, "choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 20,
                                                       "total_tokens": 120}})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True

        return Handler


# ============================================================================ bridge
class BridgeProcess:
    def __init__(self, root: Path):
        self.root = root
        self.proc: subprocess.Popen | None = None
        self.url = ""

    def start(self) -> "BridgeProcess":
        env = {**os.environ, "PORTAIL_BRIDGE_TOKEN": TOOL_TOKEN,
               "PORTAIL_BRIDGE_APPROVER_TOKEN": APPROVER_TOKEN,
               "PORTAIL_BRIDGE_DRAFTS": str(self.root / "drafts.jsonl"),
               "PORTAIL_BRIDGE_AUDIT": str(self.root / "portal-writes.jsonl"),
               "PORTAIL_BRIDGE_STATE_DIR": str(self.root / "state")}
        self.proc = subprocess.Popen(
            ["python3", "-m", "harness.bridge.portail_bridge", "--port", "0", "--backend", "mock"],
            cwd=REPO, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        line = self.proc.stderr.readline()
        m = re.search(r"http://127\.0\.0\.1:(\d+)", line)
        if not m:
            self.stop()
            raise RuntimeError(f"bridge did not start: {line}")
        self.url = f"http://127.0.0.1:{m.group(1)}/"
        return self

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.proc and self.proc.stderr:
            self.proc.stderr.close()

    def jsonl(self, name: str) -> list[dict]:
        path = self.root / name
        return [json.loads(l) for l in path.read_text().splitlines() if l.strip()] if path.exists() else []

    def writes(self) -> list[dict]:
        return [l for l in self.jsonl("portal-writes.jsonl") if l["result"] == "ok"]

    def drafts(self) -> dict[str, dict]:
        out: dict[str, dict] = {}
        for rec in self.jsonl("drafts.jsonl"):
            out[rec["draft_id"]] = rec
        return out


# ============================================================================ dsh
def _overlay(provider_url: str, answerer: bool) -> str:
    """Test layer applied after the tracked scribe patch: scripted model, no shell/file/web
    tools (the headless bundle mounts the coding tool rows globally), no LLM side calls."""
    rows = [
        "- id: session-title-llm\n  disabled: true",
        "- id: compaction-basic\n  disabled: true",
        "- id: command-compact\n  disabled: true",
        # Agent presets are a Web-app service; headless runs every tool row globally.
        "- id: preset-scribe\n  disabled: true",
        "- id: session-log-deepseek\n  disabled: true",
        # The Web permission selector; headless has none, and `never` + workspace-write match
        # no preset of its table (it would fail to mount and warn).
        "- id: permission\n  disabled: true",
    ]
    for row in ("tool-bash", "tool-pwsh", "tool-jobs", "tool-fs", "tool-fs-search", "tool-skill",
                "tool-subagent", "tool-subagent-fork", "tool-subagent-control",
                "tool-subagent-list-agents", "tool-workflow", "workflow-ptc", "tool-todo",
                "tool-goal", "tool-web", "agent-instructions", "skill-filesystem"):
        rows.append(f"- id: {row}\n  disabled: true")
    if answerer:
        rows.append(f"- insert:\n    - id: test-answerer\n      name: '{ANSWERER.as_posix()}'\n"
                    f"      config:\n        outcome: allowed-once")
    return "\n".join(rows) + "\n"


class Harness:
    """A throwaway Harness home with a `scribe-loop` profile: dsh-base + dsh-headless bundles,
    the tracked scribe patch copied as its profile patch, the plugins linked into node_modules."""

    def __init__(self, root: Path, provider: ScriptedProvider, bridge: BridgeProcess):
        self.root, self.provider, self.bridge = root, provider, bridge
        self.home = root / "dsh-home"
        self.work = root / "workspace"
        self.approvals = root / "approvals.jsonl"
        self.answers = root / "answers.jsonl"
        profile = self.home / "profiles" / "scribe-loop"
        (profile / "node_modules" / "@voxlocal").mkdir(parents=True)
        self.work.mkdir()
        (profile / "package.json").write_text(json.dumps({
            "name": "scribe-loop", "private": True, "dependencies": {},
            "dsh": {"profile": {"bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-headless"]}}}))
        shutil.copyfile(PATCH, profile / "cordis.patch.yml")
        for pkg, target in (("dsh-voxlocal-tools", "voxlocal-tools"), ("portail-tools", "portail-tools"),
                            ("scribe-approval", "scribe-approval"), ("scribe-persona", "scribe-persona")):
            (profile / "node_modules" / "@voxlocal" / pkg).symlink_to(HARNESS / "plugins" / target)

    def run(self, policy: str, answerer: bool) -> tuple[subprocess.CompletedProcess, list[dict]]:
        overlay = self.root / f"overlay-{policy}-{int(answerer)}.yml"
        overlay.write_text(_overlay(self.provider.url, answerer))
        env = {**os.environ,
               "DSH_HOME": str(self.home), "DSH_AGENTS_HOME": str(self.home / "agents"),
               "DSH_PERMISSION_MODE": "workspace-write", "DSH_TELEMETRY_MODE": "DISABLED",
               "VOXLOCAL_LLM_URL": self.provider.url, "VOXLOCAL_LLM_TOKEN": "scripted-token",
               "PORTAIL_BRIDGE_URL": self.bridge.url,
               "PORTAIL_BRIDGE_TOKEN": TOOL_TOKEN, "PORTAIL_BRIDGE_APPROVER_TOKEN": APPROVER_TOKEN,
               "SCRIBE_APPROVALS_AUDIT": str(self.approvals), "SCRIBE_CLINICIAN": "dr.test",
               "SCRIBE_TEST_ANSWERS": str(self.answers)}
        for key in ("DEEPSEEK_API_KEY", "OPENAI_API_KEY"):
            env.pop(key, None)
        policy_patch = self.root / f"policy-{policy}.yml"
        policy_patch.write_text(f"- id: approval\n  config:\n    policy: {policy}\n")
        proc = subprocess.run(
            [str(DSH), "--profile", "scribe-loop", "--patch", str(overlay), "--patch", str(policy_patch),
             "--json", task_prompt()],
            cwd=self.work, env=env, capture_output=True, text=True, timeout=180)
        events = [json.loads(l) for l in proc.stdout.splitlines() if l.startswith("{")]
        return proc, events

    def approval_lines(self) -> list[dict]:
        return [json.loads(l) for l in self.approvals.read_text().splitlines()] if self.approvals.exists() else []

    def answered(self) -> list[dict]:
        return [json.loads(l) for l in self.answers.read_text().splitlines()] if self.answers.exists() else []


def tool_events(events: list[dict], kind: str) -> list[dict]:
    return [e for e in events if e.get("type") == kind]


def calls_of(events: list[dict], tool: str) -> list[dict]:
    """`--json` tool events: {type: tool_call, callId, tool, input} / {type: tool_result, callId, status, result}."""
    return [e for e in tool_events(events, "tool_call") if e.get("tool") == tool]


def results_of(events: list[dict], tool: str) -> list[dict]:
    ids = {c["callId"] for c in calls_of(events, tool)}
    return [e for e in tool_events(events, "tool_result") if e.get("callId") in ids]


@unittest.skipUnless(DSH.exists(), "dsh not installed: cd harness/profile && pnpm install --frozen-lockfile")
class LoopTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="scribe-loop-")
        self.root = Path(self.tmp.name)
        (self.root / "bridge").mkdir()
        self.provider = ScriptedProvider().start()
        self.bridge = BridgeProcess(self.root / "bridge").start()
        self.h = Harness(self.root, self.provider, self.bridge)

    def tearDown(self):
        self.bridge.stop()
        self.provider.stop()
        self.tmp.cleanup()

    def assertCleanBoot(self, proc: subprocess.CompletedProcess):
        self.assertEqual(proc.returncode, 0, proc.stderr[-3000:])
        self.assertNotIn("did not activate", proc.stderr, proc.stderr[-3000:])

    def assertDrafted(self, events: list[dict]) -> list[str]:
        calls = calls_of(events, "record_draft_edit")
        self.assertEqual([c["input"]["attribute"] for c in calls], ["physical-exam-text", "disposition"])
        self.assertEqual([r["status"] for r in results_of(events, "record_draft_edit")], ["completed", "completed"])
        drafts = self.bridge.drafts()
        by_attr = {d["attribute"]: d for d in drafts.values()}
        self.assertEqual(set(by_attr), {"physical-exam-text", "disposition"})
        for spec in DRAFTS:
            d = by_attr[spec["attribute"]]
            self.assertEqual((d["patient_id"], d["encounter_id"], d["item_id"]), (P1, E1, ITEM1))
            self.assertTrue(d["new_text"].strip())
            self.assertTrue(d["quotes_verified"])
            self.assertEqual([q["text"] for q in d["quotes"]], spec["quotes"])
        return [by_attr[s["attribute"]]["draft_id"] for s in DRAFTS]

    # ------------------------------------------------------------------ the loop
    def test_policy_never_drafts_but_writes_nothing(self):
        proc, events = self.h.run("never", answerer=True)
        self.assertCleanBoot(proc)
        draft_ids = self.assertDrafted(events)
        applies = results_of(events, "record_apply")
        self.assertEqual(len(applies), 2)
        for r in applies:
            self.assertEqual(r["status"], "error")
            self.assertIn(REFUSAL, r["result"])
        self.assertEqual(self.bridge.writes(), [])
        self.assertEqual([self.bridge.drafts()[d]["status"] for d in draft_ids], ["drafted", "drafted"])
        self.assertEqual(self.h.answered(), [])  # `never` consults nobody
        self.assertEqual([l["decision"] for l in self.h.approval_lines()], ["rejected", "rejected"])

    def test_ask_without_an_answerer_fails_closed(self):
        proc, events = self.h.run("ask", answerer=False)
        self.assertCleanBoot(proc)
        self.assertDrafted(events)
        self.assertTrue(all(REFUSAL in r["result"] for r in results_of(events, "record_apply")))
        self.assertEqual(self.bridge.writes(), [])
        self.assertEqual([l["decision"] for l in self.h.approval_lines()], ["unavailable", "unavailable"])

    def test_clinician_allows_each_draft_is_written_exactly_once(self):
        proc, events = self.h.run("ask", answerer=True)
        self.assertCleanBoot(proc)
        draft_ids = self.assertDrafted(events)

        # Order: both drafts existed on the bridge before the first approval was asked, and each
        # write follows its own approval (no apply before approval).
        answered = self.h.answered()
        self.assertEqual([a["toolName"] for a in answered], ["record_apply", "record_apply"])
        for a, draft_id in zip(answered, draft_ids):
            self.assertIn(f"Brouillon : {draft_id}", a["displayReason"])
            self.assertIn("Patient : pat-001 (MARTIN Lucas", a["displayReason"])
            self.assertIn("Rencontre : enc-001-urg", a["displayReason"])
            self.assertIn("Citations de la dictée :", a["displayReason"])
        writes = self.bridge.writes()
        self.assertEqual([w["draft_id"] for w in writes], draft_ids)
        self.assertEqual([w["who"] for w in writes], ["poste:dr.test", "poste:dr.test"])
        approvals = [l for l in self.h.approval_lines() if l["event"] == "decision"]
        self.assertEqual([(l["decision"], l["draft_id"]) for l in approvals],
                         [("allowed", d) for d in draft_ids])
        for line, write in zip(approvals, writes):
            self.assertEqual(line["approval_id"], write["approval_id"])  # the bridge-minted id
            self.assertLess(line["ts"], write["ts"])
        self.assertEqual([r["status"] for r in results_of(events, "record_apply")], ["completed", "completed"])
        results = [l for l in self.h.approval_lines() if l["event"] == "result"]
        self.assertEqual([r["ok"] for r in results], [True, True])
        self.assertEqual([self.bridge.drafts()[d]["status"] for d in draft_ids], ["applied", "applied"])
        final = [e for e in events if e.get("type") == "final"][-1]
        self.assertIn("Appliqué", final["text"])

    def test_the_model_sees_the_scribe_persona_and_only_scribe_tools(self):
        proc, _ = self.h.run("never", answerer=False)
        self.assertCleanBoot(proc)
        first = self.provider.requests[0]
        self.assertEqual(first["auth"], "Bearer scripted-token")
        system = next(m for m in first["messages"] if m["role"] == "system")["content"]
        system = system if isinstance(system, str) else "".join(p.get("text", "") for p in system)
        self.assertIn("Vous êtes le scribe clinique VoxLocal", system)
        self.assertIn("Correspondance SOAP", system)
        self.assertNotIn("coding agent", system)
        names = {t["function"]["name"] for t in first.get("tools", [])}
        self.assertTrue({"record_draft_edit", "record_apply", "record_restore", "dictation_get"} <= names, names)
        self.assertFalse(names & {"bash", "write", "edit", "read"}, names)


if __name__ == "__main__":
    unittest.main()
