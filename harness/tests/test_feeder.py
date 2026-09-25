"""Feeder tests against the real agent API in mock mode (no dsh, no network)."""
import io
import json
import sys
import types
import tempfile
import threading
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

from agent.voxlocal_agent_api import AgentHTTPServer, AgentService, InMemoryDictationSource, VoiceProvider
from harness.ingest import dictation_feeder as feeder_module
from harness.ingest.dictation_feeder import (RESEND_PREFIX, APIError, DictationAPI, DryRunClient, Feeder, FeederConfig,
                                             SdkClient, build_parser, dictation_message, format_duration, trigger_for)

TOKEN = "feeder-test-token-0123456789"


class FakeClock:
    def __init__(self):
        self.now = 1_000.0

    def __call__(self):
        return self.now


class FeederTest(unittest.TestCase):
    def setUp(self):
        self.source = InMemoryDictationSource()
        service = AgentService(voice=VoiceProvider(None, None, "mock", True), llm=None, llm_model="test",
                               chat_enabled=False, auth_token=TOKEN, dictations=self.source)
        self.server = AgentHTTPServer(("127.0.0.1", 0), service)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.tmp = Path(tempfile.mkdtemp(prefix="feeder-test-"))
        self.state = self.tmp / "state.json"
        self.dryrun = self.tmp / "dryrun.jsonl"
        self.clock = FakeClock()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)

    def feeder(self, dryrun=None, pause=20.0):
        return Feeder(DictationAPI(self.url, TOKEN), DryRunClient(dryrun or self.dryrun), self.state,
                      FeederConfig(pause_seconds=pause), clock=self.clock, log=lambda _m: None)

    def add(self, text, **extra):
        return self.source.add({"finalTranscription": text, "duration": 65, **extra})

    def lines(self, path=None):
        path = path or self.dryrun
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []

    # ---------------------------------------------------------------- basics

    def test_message_format_is_french_with_duration_and_patient(self):
        self.source.set_patient_context("Patient fictif, chambre 12")
        record = self.add("Entorse de cheville droite.")
        self.assertEqual(dictation_message(record),
                         f"Nouvelle dictée {record['id']} (1 min 05 s) : Entorse de cheville droite.\n"
                         "Patient déclaré : Patient fictif, chambre 12")
        self.assertEqual(format_duration(12.4), "12 s")

    def test_triggers(self):
        cfg = FeederConfig()
        self.assertIsNone(trigger_for({"finalTranscription": "Œdème malléolaire externe."}, cfg.end_words, cfg.command_prefixes))
        self.assertEqual(trigger_for({"finalTranscription": "Pas de fracture. Fin."}, cfg.end_words, cfg.command_prefixes), "fin")
        self.assertEqual(trigger_for({"finalTranscription": "Agent, prépare la note."}, cfg.end_words, cfg.command_prefixes), "command")
        # « fin » inside a word or mid-sentence is not a trigger.
        self.assertIsNone(trigger_for({"finalTranscription": "Fin de la douleur hier, finalement stable."}, cfg.end_words, cfg.command_prefixes))

    # ----------------------------------------------------------- idempotence

    def test_same_dictation_fed_twice_yields_one_message(self):
        record = self.add("Douleur à la palpation du LTFA.")
        feeder = self.feeder()
        feeder.process([record])
        feeder.process([record])                 # same batch replayed in-process
        self.feeder().process([record])          # replayed by a new process with the same state
        self.state.unlink()                      # state lost: the dryrun file still dedupes
        self.feeder().process([record])
        self.assertEqual([(l["action"], l["dictationId"]) for l in self.lines()], [("inject", record["id"])])

    def test_inject_then_followup_on_fin_carries_pending_ids(self):
        first = self.add("Patient jeune, traumatisme en inversion.")
        second = self.add("Pas de douleur osseuse, Ottawa négatif. Fin.")
        self.feeder().step(0)
        lines = self.lines()
        self.assertEqual([l["action"] for l in lines], ["inject", "followup"])
        self.assertEqual(lines[1]["reason"], "fin")
        self.assertEqual(lines[1]["dictationId"], second["id"])
        self.assertEqual(lines[1]["withInjected"], [first["id"]])
        self.assertEqual(json.loads(self.state.read_text())["pending"], [])

    def test_pause_triggers_one_followup(self):
        record = self.add("Œdème modéré de la malléole externe.")
        feeder = self.feeder()
        feeder.step(0)
        self.clock.now += 19
        feeder.step(0)
        self.assertEqual([l["action"] for l in self.lines()], ["inject"])
        self.clock.now += 1
        feeder.step(0)
        feeder.step(0)
        lines = self.lines()
        self.assertEqual([l["action"] for l in lines], ["inject", "followup"])
        self.assertEqual(lines[1]["reason"], "pause")
        self.assertEqual(lines[1]["withInjected"], [record["id"]])

    def test_patient_context_is_in_the_text_and_the_jsonl(self):
        self.source.set_patient_context("Patient fictif, box 4")
        record = self.add("Laxité ligamentaire absente.")
        self.feeder().step(0)
        line = self.lines()[0]
        self.assertEqual(line["patientContext"], "Patient fictif, box 4")
        self.assertIn("Patient déclaré : Patient fictif, box 4", line["text"])
        self.assertIn(f"Nouvelle dictée {record['id']}", line["text"])

    # ---------------------------------------------------------------- resume

    def test_killed_feeder_resumes_without_replay_or_gap(self):
        a, b = self.add("Un."), self.add("Deux.")
        self.feeder().step(0)
        self.assertEqual(json.loads(self.state.read_text())["cursor"], b["id"])
        c, d = self.add("Trois."), self.add("Quatre.")   # arrive while the feeder is down
        self.feeder().step(0)                            # fresh process, same state file
        self.assertEqual([l["dictationId"] for l in self.lines()], [a["id"], b["id"], c["id"], d["id"]])

    def test_cursor_is_held_before_an_unfinished_dictation(self):
        done = self.add("Terminée.")
        busy = self.add("En cours.", processingStatus="processing")
        later = self.add("Après.")
        feeder = self.feeder()
        feeder.step(0)
        state = json.loads(self.state.read_text())
        self.assertEqual(state["cursor"], done["id"])
        self.assertEqual([l["dictationId"] for l in self.lines()], [done["id"], later["id"]])
        # The busy record completes: it goes out once, the later one is not replayed.
        for record in self.source._records:
            if record["id"] == busy["id"]:
                record["processingStatus"] = "completed"
        feeder.step(0)
        self.assertEqual([l["dictationId"] for l in self.lines()], [done["id"], later["id"], busy["id"]])
        self.assertEqual(json.loads(self.state.read_text())["cursor"], later["id"])

    def test_errors_are_skipped_but_acknowledged(self):
        failed = self.add("Échec.", processingStatus="error")
        self.feeder().step(0)
        self.assertEqual(self.lines(), [])
        self.assertEqual(json.loads(self.state.read_text())["cursor"], failed["id"])

    # ------------------------------------------------------------- seed file

    def test_seed_file_path_end_to_end(self):
        seed = self.tmp / "entorse.txt"
        seed.write_text("# SYNTHETIC — pas un vrai patient\n\nPatient jeune, entorse de la cheville droite.\nOttawa négatif. Fin.\n", encoding="utf-8")
        with patch.dict("os.environ", {"VOXLOCAL_API_TOKEN": TOKEN}), redirect_stderr(io.StringIO()):
            code = feeder_module.main(["--api-url", self.url, "--state-file", str(self.state), "--once", "--backend", "dryrun",
                                       "--dryrun-file", str(self.dryrun), "--seed-file", str(seed),
                                       "--patient-context", "Patient fictif, entorse", "--seed-duration", "300"])
            self.assertEqual(code, 0)
            again = feeder_module.main(["--api-url", self.url, "--state-file", str(self.state), "--once", "--backend", "dryrun",
                                        "--dryrun-file", str(self.dryrun)])
            self.assertEqual(again, 0)
        lines = self.lines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["action"], "followup")
        self.assertEqual(lines[0]["reason"], "fin")
        self.assertTrue(lines[0]["text"].startswith(f"Nouvelle dictée {lines[0]['dictationId']} (5 min 00 s) : Patient jeune"))
        self.assertNotIn("SYNTHETIC", lines[0]["text"])
        self.assertEqual(lines[0]["patientContext"], "Patient fictif, entorse")

    def test_sdk_backend_sends_injects_with_the_next_followup_as_one_run(self):
        runs = []

        class FakeHarness:
            def __init__(self, **options):
                self.options = options

            def run(self, prompt, session_id=None):
                runs.append((prompt, session_id))

            def close(self):
                pass

        fake = types.ModuleType("deepseek_harness"); fake.DeepSeekHarness = FakeHarness
        (self.tmp / "profiles" / "scribe").mkdir(parents=True)
        with patch.dict(sys.modules, {"deepseek_harness": fake}), patch.dict("os.environ", {}):
            client = SdkClient(dsh_home=str(self.tmp), profile="scribe", session_id="scribe-1", provider=None, model=None, pause=20)
        feeder = Feeder(DictationAPI(self.url, TOKEN), client, self.state, FeederConfig(), clock=self.clock, log=lambda _m: None)
        first = self.add("Traumatisme en inversion.")
        feeder.step(0)
        self.assertEqual(runs, [])                        # inject = no turn
        second = self.add("Agent, prépare la note SOAP.")
        feeder.step(0)
        self.assertEqual(len(runs), 1)
        prompt, session = runs[0]
        self.assertEqual(session, "scribe-1")
        self.assertLess(prompt.index(first["id"]), prompt.index(second["id"]))
        self.add("Pas de fracture.")
        feeder.step(0); self.clock.now += 20; feeder.step(0)
        self.assertEqual(len(runs), 2)
        self.assertIn("Pause de dictée", runs[1][0])

    # ------------------------------------------------------- sdk profile (A5)

    def test_sdk_backend_defaults_to_the_scribe_profile_and_refuses_a_missing_one(self):
        self.assertEqual(build_parser().parse_args([]).dsh_profile, "scribe")
        fake = types.ModuleType("deepseek_harness")
        fake.DeepSeekHarness = lambda **options: types.SimpleNamespace(options=options)
        with patch.dict(sys.modules, {"deepseek_harness": fake}), patch.dict("os.environ", {}, clear=True):
            with self.assertRaises(SystemExit) as cm:
                SdkClient(dsh_home=str(self.tmp), profile="scribe", session_id="s", provider=None, model=None, pause=20)
            self.assertIn("harness/run-web.sh", str(cm.exception))
            self.assertNotIn("DSH_AGENTS_HOME", __import__("os").environ)
            (self.tmp / "profiles" / "scribe").mkdir(parents=True)
            client = SdkClient(dsh_home=str(self.tmp), profile="scribe", session_id="s", provider=None, model=None, pause=20)
            self.assertEqual(client.harness.options["profile"], "scribe")
            self.assertEqual(__import__("os").environ["DSH_AGENTS_HOME"], str(self.tmp / "agents"))

    # ------------------------------------------------ at-least-once (A6)

    def test_crash_between_save_and_send_resends_with_the_marker_then_delivers_once(self):
        record = self.add("Traumatisme en inversion. Fin.")

        class Crash(Exception):
            pass

        class CrashingClient(DryRunClient):
            def followup(self, *a, **kw):
                raise Crash()

        crashing = Feeder(DictationAPI(self.url, TOKEN), CrashingClient(self.dryrun), self.state, FeederConfig(),
                          clock=self.clock, log=lambda _m: None)
        with self.assertRaises(Crash):
            crashing.step(0)
        saved = json.loads(self.state.read_text())
        self.assertEqual((saved["inflight"], saved["inflightReason"]), ([record["id"]], "fin"))
        self.assertEqual(saved["delivered"], [])
        self.assertEqual(self.lines(), [])
        logs = []
        restarted = Feeder(DictationAPI(self.url, TOKEN), DryRunClient(self.dryrun), self.state, FeederConfig(),
                           clock=self.clock, log=logs.append)
        restarted.step(0)
        restarted.step(0)
        lines = self.lines()
        self.assertEqual([(l["action"], l["dictationId"]) for l in lines], [("followup", record["id"])])
        self.assertTrue(lines[0]["text"].startswith(RESEND_PREFIX + "\nNouvelle dictée " + record["id"]))
        self.assertTrue(any("renvoi après interruption" in m for m in logs))
        saved = json.loads(self.state.read_text())
        self.assertEqual((saved["inflight"], saved["delivered"]), ([], [record["id"]]))

    def test_sdk_send_that_landed_before_the_crash_is_resent_marked(self):
        runs = []

        class FakeHarness:
            def __init__(self, **options):
                pass

            def run(self, prompt, session_id=None):
                runs.append(prompt)

            def close(self):
                pass

        fake = types.ModuleType("deepseek_harness"); fake.DeepSeekHarness = FakeHarness
        (self.tmp / "profiles" / "scribe").mkdir(parents=True)
        with patch.dict(sys.modules, {"deepseek_harness": fake}), patch.dict("os.environ", {}):
            client = SdkClient(dsh_home=str(self.tmp), profile="scribe", session_id="s", provider=None, model=None, pause=20)
        first, second = self.add("Traumatisme en inversion."), self.add("Agent, prépare la note.")
        feeder = Feeder(DictationAPI(self.url, TOKEN), client, self.state, FeederConfig(), clock=self.clock, log=lambda _m: None)
        real_save = feeder.state.save
        calls = {"n": 0}

        def save_then_die(path):  # the save after the send never happens
            calls["n"] += 1
            if feeder.state.inflight == [] and calls["n"] > 1 and runs:
                raise KeyboardInterrupt
            real_save(path)

        feeder.state.save = save_then_die
        with self.assertRaises(KeyboardInterrupt):
            feeder.step(0)
        self.assertEqual(len(runs), 1)
        again = Feeder(DictationAPI(self.url, TOKEN), client, self.state, FeederConfig(), clock=self.clock, log=lambda _m: None)
        again.step(0)
        self.assertEqual(len(runs), 2)
        self.assertEqual(runs[1].count(RESEND_PREFIX), 2)
        self.assertLess(runs[1].index(first["id"]), runs[1].index(second["id"]))
        again.step(0)
        self.assertEqual(len(runs), 2)

    # ------------------------------------------------- relecture errors (A7)

    def test_a_transient_api_error_on_relecture_keeps_pending_and_the_next_pass_delivers(self):
        first = self.add("Œdème malléolaire externe.")
        feeder = self.feeder()
        feeder.step(0)
        self.assertEqual(json.loads(self.state.read_text())["pending"], [first["id"]])
        second = self.add("Pas de fracture. Fin.")
        real_get = feeder.api.get
        feeder.api.get = lambda _id: (_ for _ in ()).throw(APIError(503, "unavailable", "occupé"))
        with self.assertRaises(APIError):
            feeder.step(0)
        saved = json.loads(self.state.read_text())
        self.assertEqual(saved["pending"], [first["id"]])
        self.assertNotIn(second["id"], saved["delivered"])
        self.assertEqual(saved["inflight"], [])
        feeder.api.get = real_get
        feeder.step(0)
        lines = self.lines()
        self.assertEqual([l["action"] for l in lines], ["inject", "followup"])
        self.assertEqual((lines[1]["dictationId"], lines[1]["withInjected"]), (second["id"], [first["id"]]))
        self.assertEqual(json.loads(self.state.read_text())["pending"], [])

    def test_a_deleted_dictation_is_skipped_on_relecture(self):
        first = self.add("Œdème malléolaire externe.")
        feeder = self.feeder()
        feeder.step(0)
        feeder.api.get = lambda _id: (_ for _ in ()).throw(APIError(404, "not_found", "Dictée introuvable."))
        self.clock.now += 20
        feeder.step(0)
        lines = self.lines()
        self.assertEqual([(l["action"], l.get("withInjected")) for l in lines], [("inject", None), ("followup", [])])
        self.assertEqual(json.loads(self.state.read_text())["pending"], [])

    def test_pause_followup_error_keeps_pending(self):
        first = self.add("Œdème malléolaire externe.")
        feeder = self.feeder()
        feeder.step(0)
        self.clock.now += 20
        feeder.api.get = lambda _id: (_ for _ in ()).throw(OSError("connexion refusée"))
        with self.assertRaises(OSError):
            feeder.step(0)
        self.assertEqual(json.loads(self.state.read_text())["pending"], [first["id"]])

    def test_token_is_required_from_the_environment(self):
        with patch.dict("os.environ", {"VOXLOCAL_API_TOKEN": ""}), redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                feeder_module.main(["--api-url", self.url, "--once"])
        with self.assertRaises(ValueError):
            DictationAPI("http://10.0.0.8:47367", TOKEN)


if __name__ == "__main__":
    unittest.main()
