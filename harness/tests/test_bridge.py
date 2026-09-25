"""Bridge and recorded-mock tests: portal traps, drafts, approval gate, audit, restart safety.

Run from the repository root: python3 -m unittest harness.tests.test_bridge -v
"""
from __future__ import annotations

import json
import os
import tempfile
import threading
import types
import unittest
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from harness.bridge import portail_bridge as pb
from harness.bridge.interface import (
    NARRATIVE_SECTIONS, DigestMismatch, EditRefused, NotFound, PortalBackend, PortalError,
    VerificationFailed, digest,
)
from harness.bridge.portail_bridge import (
    ApiDictationSource, Bridge, ChainedDictationSource, DictationSource, Forbidden,
    parse_patient_context,
)
from harness.bridge.portail_mock import FIXTURES, MockPortal

P1, E1 = "pat-001", "enc-001-urg"
ITEM1 = "1f19a001-aaaa-4000-8000-000000000101"
UNFILED = "1f19a001-bbbb-4000-8000-000000000102"
SUGGESTION = "1f19a001-cccc-4000-8000-000000000103"
ITEM2 = "1f19a002-aaaa-4000-8000-000000000201"
DICT = "dict-entorse-001"
EXAM = "physical-exam-text"
QUOTE = {"dictation_id": DICT, "offset": 0,
         "text": "douleur à la palpation du ligament talo-fibulaire antérieur"}
TOOL_TOKEN, APPROVER_TOKEN = "tool-" + "a" * 40, "approver-" + "b" * 40


class Clock:
    def __init__(self, t: float = 1_790_000_000.0):
        self.t = t

    def __call__(self) -> float:
        return self.t


class Env:
    """A mock portal + bridge over a fresh temp dir; `reopen()` simulates a bridge restart."""

    def __init__(self, dictations: bool = True):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.clock = Clock()
        self.with_dictations = dictations
        self.reopen()

    def reopen(self) -> Bridge:
        self.portal = MockPortal(state_dir=self.root / "state")
        self.bridge = Bridge(self.portal, self.root / "drafts.jsonl", self.root / "audit.jsonl",
                             DictationSource(FIXTURES) if self.with_dictations else None,
                             clock=self.clock)
        return self.bridge

    def audit(self) -> list[dict]:
        path = self.root / "audit.jsonl"
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

    def journal(self) -> list[dict]:
        return [json.loads(x) for x in (self.root / "drafts.jsonl").read_text().splitlines()]

    def draft(self, **over) -> dict:
        args = dict(patient_id=P1, encounter_id=E1, item_id=ITEM1, attribute=EXAM,
                    mode="append", new_text="Douleur du LTFA, Ottawa négatif.",
                    rationale="examen dicté", quotes=[QUOTE])
        args.update(over)
        return self.bridge.draft_create(**args)

    def close(self):
        self.tmp.cleanup()


# ============================================================================ mock traps
class MockPortalTraps(unittest.TestCase):
    def setUp(self):
        self.p = MockPortal()

    def test_satisfies_the_backend_protocol(self):
        self.assertIsInstance(self.p, PortalBackend)

    def test_three_synthetic_patients_each_with_eight_narrative_sections(self):
        for pid in ("pat-001", "pat-002", "pat-003"):
            attrs = {loc.attribute for loc in self.p.find_sections(pid)}
            self.assertEqual(attrs, set(NARRATIVE_SECTIONS), pid)

    def test_get_item_requires_version_and_era_ehr_source(self):
        with self.assertRaisesRegex(PortalError, "version"):
            self.p.get_item(ITEM1)
        with self.assertRaisesRegex(NotFound, "Item not found"):
            self.p.get_item(ITEM1, 0, source_id="ehrbank")
        self.assertEqual(self.p.get_item(ITEM1, 0)["version"], 3)

    def test_unfiled_item_is_retrievable_but_invisible_and_not_editable(self):
        self.assertEqual(self.p.get_item(UNFILED, 0)["item_id"], UNFILED)
        self.assertNotIn(UNFILED, {loc.item_id for loc in self.p.find_sections(P1)})
        sec = self.p.read_section(UNFILED, EXAM)
        self.assertFalse(sec.filed)
        with self.assertRaisesRegex(EditRefused, "aucune vue"):
            self.p.apply(UNFILED, EXAM, sec.digest, "x", "append")

    def test_suggestions_are_never_exposed(self):
        with self.assertRaises(NotFound):
            self.p.get_item(SUGGESTION, 0)

    def test_unknown_attribute_lists_present_ones(self):
        with self.assertRaises(NotFound) as cm:
            self.p.read_section(ITEM1, "text-plan")
        self.assertIn("physical-exam-text", cm.exception.data["present"])
        sec = self.p.read_section(ITEM1, "title")  # present but not narrative
        with self.assertRaises(EditRefused) as cm:
            self.p.apply(ITEM1, "title", sec.digest, "x", "append")
        self.assertIn("disposition", cm.exception.data["present"])

    def test_values_use_the_value_1_text_shape(self):
        attr = next(a for a in self.p.get_item(ITEM1, 0)["attributes"] if a["name"] == EXAM)
        self.assertIsInstance(attr["values"]["_value_1"][0]["text"]["content"], str)

    def test_append_verifies_readback_and_bumps_version(self):
        before = self.p.read_section(ITEM1, EXAM)
        res = self.p.apply(ITEM1, EXAM, before.digest, "Ottawa négatif.", "append")
        after = self.p.read_section(ITEM1, EXAM)
        self.assertEqual(after.text, before.text + "\nOttawa négatif.")
        self.assertTrue(res.verified and res.prefix_intact)
        self.assertEqual((res.version_before, res.version_after), (3, 4))
        self.assertEqual(after.version, 4)
        self.assertEqual(self.p.get_item(ITEM1, 3)["version"], 3)  # history kept

    def test_replace_refuses_absent_or_ambiguous_substring(self):
        sec = self.p.read_section(ITEM1, EXAM)
        with self.assertRaises(EditRefused) as cm:
            self.p.apply(ITEM1, EXAM, sec.digest, "y", "replace", old="introuvable")
        self.assertEqual(cm.exception.data["occurrences"], 0)
        with self.assertRaises(EditRefused) as cm:
            self.p.apply(ITEM1, EXAM, sec.digest, "y", "replace", old="cheville droite")
        self.assertEqual(cm.exception.data["occurrences"], 2)
        res = self.p.apply(ITEM1, EXAM, sec.digest, "EVA 5/10", "replace", old="EVA 6/10")
        self.assertIn("EVA 5/10", self.p.read_section(ITEM1, EXAM).text)
        self.assertTrue(res.verified)

    def test_only_append_and_replace_exist(self):
        sec = self.p.read_section(ITEM1, EXAM)
        with self.assertRaises(EditRefused):
            self.p.apply(ITEM1, EXAM, sec.digest, "x", "overwrite")

    def test_digest_mismatch_refuses_the_write(self):
        writes = self.p.write_count
        with self.assertRaises(DigestMismatch):
            self.p.apply(ITEM1, EXAM, digest("stale"), "x", "append")
        self.assertEqual(self.p.write_count, writes)

    def test_restore_round_trip_and_blind_restore_refused(self):
        original = self.p.read_section(ITEM1, EXAM)
        res = self.p.apply(ITEM1, EXAM, original.digest, "ajout", "append")
        back = self.p.restore(res.backup_id)
        self.assertTrue(back.restored)
        now = self.p.read_section(ITEM1, EXAM)
        self.assertEqual(now.digest, original.digest)
        self.assertEqual(now.version, original.version + 2)
        res2 = self.p.apply(ITEM1, EXAM, now.digest, "ajout 2", "append")
        mid = self.p.read_section(ITEM1, EXAM)
        self.p.apply(ITEM1, EXAM, mid.digest, "modification concurrente", "append")
        with self.assertRaises(DigestMismatch):
            self.p.restore(res2.backup_id)

    def test_resolve_patient_is_accent_insensitive(self):
        self.assertEqual([p.patient_id for p in self.p.resolve_patient("martin")], [P1])
        self.assertEqual([p.patient_id for p in self.p.resolve_patient("TPMS-900003")],
                         ["pat-003"])
        self.assertEqual(self.p.resolve_patient("zzz"), [])

    def test_read_patient_returns_fhir_subset(self):
        data = self.p.read_patient("pat-003")
        self.assertEqual(set(data), {"patient", "allergies", "conditions", "medications"})
        self.assertEqual(data["allergies"][0]["code"]["text"], "Pénicillines")

    def test_entorse_fixture_matches_the_transcript(self):
        d = DictationSource(FIXTURES).get(DICT)
        self.assertEqual((d.patient_id, d.encounter_id), (P1, E1))
        self.assertIn("Critères d'Ottawa négatifs", d.text)
        self.assertIn("cheville droite", self.p.read_section(ITEM1, "current-affliction").text)


# ============================================================================ bridge core
class BridgeDrafts(unittest.TestCase):
    def setUp(self):
        self.env = Env()

    def tearDown(self):
        self.env.close()

    def test_draft_is_stored_in_the_journal_and_touches_nothing(self):
        writes = self.env.portal.write_count
        d = self.env.draft()
        self.assertEqual(d["status"], "drafted")
        self.assertTrue(d["quotes_verified"])
        self.assertTrue(d["quotes"][0]["verified"])
        self.assertEqual(d["final_text_digest"], digest(d["final_text"]))
        self.assertEqual(self.env.journal()[-1]["draft_id"], d["draft_id"])
        self.assertEqual(self.env.portal.write_count, writes)
        self.assertNotIn("approval", self.env.bridge.draft_get(d["draft_id"]))

    def test_quote_absent_from_the_dictation_is_rejected(self):
        with self.assertRaisesRegex(EditRefused, "citation introuvable dans la dictée"):
            self.env.draft(quotes=[{"dictation_id": DICT, "offset": 0,
                                    "text": "fracture de la malléole"}])
        with self.assertRaisesRegex(EditRefused, "citation introuvable"):
            self.env.draft(quotes=[{"dictation_id": "dict-inconnue", "offset": 0, "text": "x"}])
        with self.assertRaises(EditRefused):
            self.env.draft(quotes=[])

    def test_without_a_dictation_source_every_draft_is_refused(self):
        env = Env(dictations=False)
        try:
            writes = env.portal.write_count
            with self.assertRaisesRegex(EditRefused, "aucune source de dictées : citations "
                                                     "invérifiables"):
                env.draft()
            self.assertFalse((env.root / "drafts.jsonl").exists())
            self.assertEqual(env.portal.write_count, writes)
        finally:
            env.close()

    def test_real_mode_without_a_source_has_none_and_mock_keeps_the_fixtures(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(pb.dictations_from_env("real"))
            self.assertIsInstance(pb.dictations_from_env("mock"), DictationSource)
        with patch.dict(os.environ, {"VOXLOCAL_API_URL": "http://127.0.0.1:47367"}, clear=True):
            with self.assertRaisesRegex(ValueError, "VOXLOCAL_API_TOKEN"):
                pb.dictations_from_env("real")
        with patch.dict(os.environ, {"VOXLOCAL_API_URL": "http://127.0.0.1:47367",
                                     "VOXLOCAL_API_TOKEN": "t" * 32,
                                     "PORTAIL_DICTATION_DIR": str(FIXTURES)}, clear=True):
            chained = pb.dictations_from_env("real")
            self.assertIsInstance(chained, ChainedDictationSource)
            self.assertEqual([type(s) for s in chained.sources],
                             [DictationSource, ApiDictationSource])

    def test_dictation_without_patient_or_encounter_is_forbidden(self):
        tmp = tempfile.TemporaryDirectory()
        try:
            src = Path(tmp.name)
            text = DictationSource(FIXTURES).get(DICT).text
            for name, ctx in (("none", None), ("patient-only", {"patient_id": P1}),
                              ("encounter-only", {"encounter_id": E1})):
                (src / f"dictation-{name}.json").write_text(json.dumps(
                    {"dictation_id": f"dict-{name}", "patient_context": ctx, "text": text}))
            self.env.bridge.dictations = DictationSource(src)
            for name in ("none", "patient-only", "encounter-only"):
                with self.assertRaisesRegex(Forbidden, "ne déclare pas de patient/rencontre"):
                    self.env.draft(quotes=[dict(QUOTE, dictation_id=f"dict-{name}")])
        finally:
            tmp.cleanup()

    def test_draft_on_another_patients_item_is_forbidden(self):
        with self.assertRaises(Forbidden):
            self.env.draft(item_id=ITEM2)
        with self.assertRaises(Forbidden):
            self.env.draft(encounter_id="enc-002-urg")

    def test_dictation_of_another_patient_is_forbidden(self):
        with self.assertRaises(Forbidden):
            self.env.draft(patient_id="pat-002", encounter_id="enc-002-urg", item_id=ITEM2)

    def test_draft_rejects_unfiled_items_and_stale_base(self):
        with self.assertRaises(Forbidden):
            self.env.draft(item_id=UNFILED)
        with self.assertRaises(DigestMismatch):
            self.env.draft(base_digest=digest("vieux texte"))
        with self.assertRaises(EditRefused):
            self.env.draft(mode="replace", old="introuvable")


class BridgeApprovalGate(unittest.TestCase):
    def setUp(self):
        self.env = Env()
        self.b = self.env.bridge

    def tearDown(self):
        self.env.close()

    def test_apply_without_approval_is_403_and_writes_nothing(self):
        d = self.env.draft()
        writes = self.env.portal.write_count
        with self.assertRaises(Forbidden) as cm:
            self.b.apply(d["draft_id"])
        self.assertEqual(cm.exception.status, 403)
        self.assertEqual(self.env.portal.write_count, writes)
        self.assertEqual(self.env.audit()[-1]["reason"], "not-approved")

    def test_approved_apply_writes_once_and_audits(self):
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        res = self.b.apply(d["draft_id"])
        self.assertFalse(res["replayed"])
        self.assertTrue(res["verified"])
        self.assertEqual(self.env.portal.read_section(ITEM1, EXAM).digest,
                         d["final_text_digest"])
        line = self.env.audit()[-1]
        for key in ("ts", "patient_id", "encounter_id", "item_id", "attribute", "mode",
                    "base_digest", "final_digest", "readback_digest", "approval_id", "who",
                    "version_before", "version_after", "backup_id", "draft_id"):
            self.assertIn(key, line)
        self.assertEqual((line["event"], line["result"], line["who"]), ("apply", "ok", "dr.test"))
        self.assertEqual(line["readback_digest"], d["final_text_digest"])
        self.assertNotIn(d["new_text"], json.dumps(line, ensure_ascii=False))  # no prose

    def test_apply_after_live_text_changed_is_409(self):
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        live = self.env.portal.read_section(ITEM1, EXAM)
        self.env.portal.apply(ITEM1, EXAM, live.digest, "modification concurrente", "append")
        writes = self.env.portal.write_count
        with self.assertRaises(DigestMismatch) as cm:
            self.b.apply(d["draft_id"])
        self.assertEqual(cm.exception.status, 409)
        self.assertEqual(self.env.portal.write_count, writes)
        self.assertEqual(self.env.audit()[-1]["reason"], "live-digest-changed")

    def test_expired_approval_is_403(self):
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        self.env.clock.t += pb.APPROVAL_TTL_S + 1
        with self.assertRaisesRegex(Forbidden, "expiré"):
            self.b.apply(d["draft_id"])
        self.assertEqual(self.b.draft_get(d["draft_id"])["status"], "expired")

    def test_approval_bound_to_another_patient_is_403(self):
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        self.b.drafts[d["draft_id"]]["approval"]["binding"]["patient_id"] = "pat-002"
        with self.assertRaises(Forbidden):
            self.b.apply(d["draft_id"])
        self.assertEqual(self.env.audit()[-1]["reason"], "binding-mismatch")

    def test_draft_changed_after_approval_is_refused(self):
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        self.b.drafts[d["draft_id"]]["final_text_digest"] = digest("autre texte")
        with self.assertRaises(Forbidden):
            self.b.apply(d["draft_id"])
        self.b.drafts[d["draft_id"]]["final_text_digest"] = d["final_text_digest"]
        self.b.drafts[d["draft_id"]]["new_text"] = "texte modifié après feu vert"
        with self.assertRaises(DigestMismatch) as cm:
            self.b.apply(d["draft_id"])
        self.assertEqual(cm.exception.status, 409)

    def test_approval_is_single_use_and_cannot_be_reissued(self):
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        self.b.apply(d["draft_id"])
        with self.assertRaises(DigestMismatch):
            self.b.approve_draft(d["draft_id"], "dr.test")

    def test_replay_after_restart_is_idempotent(self):
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        first = self.b.apply(d["draft_id"])
        text = self.env.portal.read_section(ITEM1, EXAM).text
        audit_lines = len(self.env.audit())
        bridge = self.env.reopen()
        writes = self.env.portal.write_count
        again = bridge.apply(d["draft_id"])
        self.assertTrue(again["replayed"])
        self.assertEqual({k: v for k, v in again.items() if k != "replayed"},
                         {k: v for k, v in first.items() if k != "replayed"})
        self.assertEqual(self.env.portal.write_count, writes)
        self.assertEqual(self.env.portal.read_section(ITEM1, EXAM).text, text)
        self.assertEqual(len(self.env.audit()), audit_lines)

    def test_concurrent_applies_write_exactly_once(self):
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        writes = self.env.portal.write_count
        results, errors = [], []

        def go():
            try:
                results.append(self.b.apply(d["draft_id"]))
            except PortalError as exc:
                errors.append(exc)

        threads = [threading.Thread(target=go) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(self.env.portal.write_count, writes + 1)
        self.assertEqual(errors, [])
        self.assertEqual(sum(1 for r in results if not r["replayed"]), 1)

    def test_journal_precedes_the_write_and_crash_recovery_decides_from_live_text(self):
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        seen = []
        real_apply = self.env.portal.apply

        def spy(*a, **kw):
            seen.append(self.env.journal()[-1]["status"])
            return real_apply(*a, **kw)

        self.env.portal.apply = spy
        self.b.apply(d["draft_id"])
        self.assertEqual(seen, ["applying"])
        # Simulate a crash after the write but before the "applied" line.
        path = self.env.root / "drafts.jsonl"
        lines = path.read_text().splitlines()
        path.write_text("\n".join(lines[:-1]) + "\n")
        bridge = self.env.reopen()
        self.assertEqual(bridge.draft_get(d["draft_id"])["status"], "applied")
        self.assertTrue(bridge.apply(d["draft_id"])["replayed"])

    def test_recovered_write_keeps_its_backup_and_can_be_restored(self):
        original = self.env.portal.read_section(ITEM1, EXAM)
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        first = self.b.apply(d["draft_id"])
        # Crash after the write, before the "applied" journal line.
        path = self.env.root / "drafts.jsonl"
        path.write_text("\n".join(path.read_text().splitlines()[:-1]) + "\n")
        bridge = self.env.reopen()
        again = bridge.apply(d["draft_id"])
        self.assertTrue(again["replayed"] and again["recovered"])
        self.assertEqual(again["backup_id"], first["backup_id"])
        for key in ("item_id", "attribute", "mode", "readback_digest", "version_after"):
            self.assertEqual(again[key], first[key], key)
        self.assertEqual(again["version_before"], d["base_version"])
        line = self.env.audit()[-1]
        self.assertEqual((line["event"], line["result"], line["recovered"], line["backup_id"]),
                         ("apply", "ok", True, first["backup_id"]))
        r = bridge.draft_restore(first["backup_id"])
        bridge.approve_draft(r["draft_id"], "dr.test")
        self.assertTrue(bridge.restore(first["backup_id"])["restored"])
        self.assertEqual(self.env.portal.read_section(ITEM1, EXAM).digest, original.digest)

    def test_crash_before_the_write_fails_closed(self):
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        rec = dict(self.b.drafts[d["draft_id"]], status="applying")
        rec["approval"] = dict(rec["approval"], consumed=True)
        with (self.env.root / "drafts.jsonl").open("a") as fh:
            fh.write(json.dumps(rec) + "\n")
        bridge = self.env.reopen()
        self.assertEqual(bridge.draft_get(d["draft_id"])["status"], "failed")
        with self.assertRaises(Forbidden):
            bridge.apply(d["draft_id"])

    def test_restore_is_gated_and_round_trips(self):
        original = self.env.portal.read_section(ITEM1, EXAM)
        d = self.env.draft()
        self.b.approve_draft(d["draft_id"], "dr.test")
        backup_id = self.b.apply(d["draft_id"])["backup_id"]
        with self.assertRaises(Forbidden):
            self.b.restore(backup_id)  # no restore draft at all
        r = self.b.draft_restore(backup_id)
        self.assertEqual(r["kind"], "restore")
        self.assertEqual(self.b.draft_restore(backup_id)["draft_id"], r["draft_id"])
        with self.assertRaises(Forbidden):
            self.b.restore(backup_id)  # drafted, not approved
        self.b.approve_draft(r["draft_id"], "dr.test")
        res = self.b.restore(backup_id)
        self.assertTrue(res["restored"])
        self.assertEqual(self.env.portal.read_section(ITEM1, EXAM).digest, original.digest)
        self.assertEqual(self.env.audit()[-1]["event"], "restore")
        self.assertTrue(self.b.restore(backup_id)["replayed"])


class ForeignWriteBackend:
    """A mock portal whose write lands on a text another client changed in between: the
    read-back is the digest of that foreign text, not of the approved one."""

    def __init__(self, portal: MockPortal):
        self.portal, self.name = portal, "foreign"

    def __getattr__(self, name):
        return getattr(self.portal, name)

    def apply(self, item_id, attribute, base_digest, new_text, mode, old=None):
        res = self.portal.apply(item_id, attribute, base_digest, new_text, mode, old)
        return replace(res, readback_digest=digest("texte écrit par un autre client"))


class BridgeReadbackCheck(unittest.TestCase):
    def setUp(self):
        self.env = Env()

    def tearDown(self):
        self.env.close()

    def test_a_readback_other_than_the_approved_text_fails_and_restores(self):
        original = self.env.portal.read_section(ITEM1, EXAM)
        bridge = Bridge(ForeignWriteBackend(self.env.portal), self.env.root / "drafts.jsonl",
                        self.env.root / "audit.jsonl", DictationSource(FIXTURES),
                        clock=self.env.clock)
        d = bridge.draft_create(patient_id=P1, encounter_id=E1, item_id=ITEM1, attribute=EXAM,
                                mode="append", new_text="Ottawa négatif.", rationale="examen",
                                quotes=[QUOTE])
        bridge.approve_draft(d["draft_id"], "dr.test")
        with self.assertRaisesRegex(VerificationFailed, "relecture différente du texte approuvé"):
            bridge.apply(d["draft_id"])
        rec = bridge.draft_get(d["draft_id"])
        self.assertEqual(rec["status"], "failed")
        self.assertEqual(rec["error"], {"status": 409,
                                        "message": "relecture différente du texte approuvé"})
        self.assertEqual(self.env.portal.read_section(ITEM1, EXAM).digest, original.digest)
        audit = self.env.audit()
        self.assertEqual([(a["event"], a["result"]) for a in audit[-2:]],
                         [("restore-after-mismatch", "ok"), ("apply", "error")])
        self.assertEqual(audit[-1]["reason"], "final-readback-mismatch")
        with self.assertRaises(Forbidden):  # the approval was spent: no second try
            bridge.apply(d["draft_id"])


class RealPortalAdapter(unittest.TestCase):
    """`RealPortal` over a fake `portail.records` (the real portal is not reachable)."""

    def make(self, live: str, landed_on: str):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        data = Path(tmp.name)
        calls = {"restore": []}

        class FakeRecord:
            def read(self, item_id, attribute, version=0):
                return live

            def get_item(self, item_id, version=0):
                return {"version": 7}

            def append(self, item_id, attribute, text, commit=False):
                backup = data / f"backup_{item_id[:8]}_{attribute}_20260925T120000.json"
                backup.write_text(json.dumps({
                    "item": item_id, "attr": attribute, "original_text": landed_on,
                    "original_digest": digest(landed_on),
                    "current_digest": digest(landed_on + "\n" + text),
                    "taken": "20260925T120000"}))
                return types.SimpleNamespace(
                    old_length=len(landed_on), new_length=len(landed_on) + len(text) + 1,
                    old_digest=digest(landed_on), new_digest=digest(landed_on + "\n" + text),
                    version=8, verified=True, prefix_intact=True, backup=backup)

            def restore(self, backup):
                calls["restore"].append(Path(backup).name)
                return True

        portal = pb.RealPortal.__new__(pb.RealPortal)
        portal._records = types.SimpleNamespace(DATA=data)
        portal._rec = FakeRecord()
        return portal, calls

    def test_write_on_a_text_changed_after_the_check_is_restored_and_refused(self):
        portal, calls = self.make(live="texte vérifié", landed_on="texte changé entre-temps")
        with self.assertRaises(DigestMismatch) as cm:
            portal.apply(ITEM1, EXAM, digest("texte vérifié"), "ajout", "append")
        self.assertIn("sauvegarde restaurée", cm.exception.message)
        self.assertEqual(cm.exception.data["live"], digest("texte changé entre-temps"))
        self.assertEqual(calls["restore"], [cm.exception.data["backup_id"]])

    def test_matching_write_goes_through_and_find_backup_sees_it(self):
        portal, calls = self.make(live="texte vérifié", landed_on="texte vérifié")
        res = portal.apply(ITEM1, EXAM, digest("texte vérifié"), "ajout", "append")
        self.assertEqual(calls["restore"], [])
        self.assertEqual(res.readback_digest, digest("texte vérifié\najout"))
        found = portal.find_backup(ITEM1, EXAM, digest("texte vérifié\najout"))
        self.assertEqual(found.backup_id, res.backup_id)
        self.assertIsNone(portal.find_backup(ITEM1, EXAM, digest("autre")))


# ============================================================================ VoxLocal API source
class StubVoxLocalApi:
    """`GET /v1/dictations/<id>` of the VoxLocal loopback API, with the Mac app's envelope."""

    TOKEN = "voxlocal-api-token-" + "c" * 32

    def __init__(self, records: dict[str, dict], fail_with: int | None = None):
        stub = self
        self.records, self.fail_with, self.seen_auth = records, fail_with, []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                stub.seen_auth.append(self.headers.get("Authorization"))
                did = urllib.parse.unquote(self.path.rsplit("/", 1)[1])
                if self.headers.get("Authorization") != f"Bearer {stub.TOKEN}":
                    status, body = 401, {"ok": False, "error": {"code": "unauthorized"}}
                elif stub.fail_with:
                    status, body = stub.fail_with, {"ok": False, "error": {"code": "busy"}}
                elif did not in stub.records:
                    status, body = 404, {"ok": False, "error": {"code": "not_found"}}
                else:
                    status, body = 200, {"ok": True, "data": stub.records[did]}
                raw = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def api_record(did: str, context, status: str = "completed") -> dict:
    return {"id": did, "timestamp": "2026-09-25T10:00:00Z", "deviceName": "iPhone",
            "modeId": "medical", "rawTranscription": "brut",
            "finalTranscription": DictationSource(FIXTURES).get(DICT).text.replace(" ", "  "),
            "processingStatus": status, "duration": 300.0, "patientContext": context}


class ApiDictations(unittest.TestCase):
    def setUp(self):
        self.api = StubVoxLocalApi({
            "vox-json": api_record("vox-json", json.dumps({"patient_id": P1, "encounter_id": E1})),
            "vox-compact": api_record("vox-compact", f"patient={P1} rencontre={E1}"),
            "vox-free": api_record("vox-free", "Patient fictif, box 4"),
            "vox-null": api_record("vox-null", None),
            "vox-busy": api_record("vox-busy", f"patient={P1} rencontre={E1}", "processing"),
        })
        self.env = Env()
        self.env.bridge.dictations = ApiDictationSource(self.api.url, StubVoxLocalApi.TOKEN)

    def tearDown(self):
        self.api.close()
        self.env.close()

    def quote(self, did: str) -> list[dict]:
        return [dict(QUOTE, dictation_id=did)]

    def test_patient_context_forms(self):
        self.assertEqual(parse_patient_context(json.dumps({"patient_id": P1, "encounter_id": E1})),
                         (P1, E1))
        self.assertEqual(parse_patient_context(f"patient={P1} rencontre={E1}"), (P1, E1))
        for value in (None, "", "Patient fictif", f"patient={P1}", json.dumps({"patient_id": P1}),
                      json.dumps([P1, E1]), f"patient={P1} rencontre={E1} extra"):
            self.assertEqual(parse_patient_context(value), (None, None), value)

    def test_drafts_quote_api_dictations_in_both_bound_forms(self):
        for did in ("vox-json", "vox-compact"):
            d = self.env.draft(quotes=self.quote(did))
            self.assertTrue(d["quotes_verified"] and d["quotes"][0]["verified"])
        self.assertEqual(set(self.api.seen_auth), {f"Bearer {StubVoxLocalApi.TOKEN}"})

    def test_unbound_unknown_unfinished_or_unreachable_dictations_are_refused(self):
        for did in ("vox-free", "vox-null"):
            with self.assertRaisesRegex(Forbidden, "ne déclare pas de patient/rencontre"):
                self.env.draft(quotes=self.quote(did))
        with self.assertRaisesRegex(EditRefused, "inconnue"):
            self.env.draft(quotes=self.quote("vox-absent"))
        with self.assertRaisesRegex(EditRefused, "pas encore terminée"):
            self.env.draft(quotes=self.quote("vox-busy"))
        self.api.fail_with = 503
        with self.assertRaises(PortalError) as cm:
            self.env.draft(quotes=self.quote("vox-json"))
        self.assertEqual(cm.exception.status, 503)
        self.env.bridge.dictations = ApiDictationSource(self.api.url, "mauvais-jeton")
        self.api.fail_with = None
        with self.assertRaises(PortalError) as cm:
            self.env.draft(quotes=self.quote("vox-json"))
        self.assertEqual(cm.exception.status, 503)

    def test_chained_directory_then_api(self):
        self.env.bridge.dictations = ChainedDictationSource(
            [DictationSource(FIXTURES), ApiDictationSource(self.api.url, StubVoxLocalApi.TOKEN)])
        self.assertTrue(self.env.draft()["quotes_verified"])                       # fixture
        self.assertTrue(self.env.draft(quotes=self.quote("vox-compact"))["quotes_verified"])

    def test_loopback_only_and_token_required(self):
        for url in ("http://10.0.0.8:47367", "https://api.example:47367",
                    "http://user:pw@127.0.0.1:47367", "ftp://127.0.0.1"):
            with self.assertRaises(ValueError, msg=url):
                ApiDictationSource(url, StubVoxLocalApi.TOKEN)
        with self.assertRaises(ValueError):
            ApiDictationSource(self.api.url, "")


# ============================================================================ HTTP / JSON-RPC
class BridgeHttp(unittest.TestCase):
    def setUp(self):
        self.env = Env()
        self.server = pb.make_server(self.env.bridge, TOOL_TOKEN, APPROVER_TOKEN, port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/"
        self.n = 0

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.env.close()

    def post(self, body, token=TOOL_TOKEN, headers=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        req = urllib.request.Request(self.url, data=data, method="POST",
                                     headers={"Content-Type": "application/json",
                                              **({"Authorization": f"Bearer {token}"}
                                                 if token else {}), **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                raw = r.read()
                return r.status, json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            with e:
                return e.code, json.loads(e.read())

    def call(self, method, token=TOOL_TOKEN, **params):
        self.n += 1
        status, body = self.post({"jsonrpc": "2.0", "id": self.n, "method": method,
                                  "params": params}, token)
        self.assertEqual(status, 200)
        self.assertEqual(body["id"], self.n)
        return body

    def draft_params(self):
        return dict(patient_id=P1, encounter_id=E1, item_id=ITEM1, attribute=EXAM, mode="append",
                    new_text="Ottawa négatif.", rationale="examen", quotes=[QUOTE])

    def test_default_port_and_loopback_only(self):
        self.assertEqual(pb.DEFAULT_PORT, 47368)
        with self.assertRaises(ValueError):
            pb.make_server(self.env.bridge, TOOL_TOKEN, APPROVER_TOKEN, host="0.0.0.0", port=0)
        with self.assertRaises(ValueError):
            pb.make_server(self.env.bridge, TOOL_TOKEN, TOOL_TOKEN, port=0)

    def test_auth_origin_and_protocol_errors(self):
        self.assertEqual(self.post({"jsonrpc": "2.0", "id": 1, "method": "health"}, None)[0], 401)
        self.assertEqual(self.post({"jsonrpc": "2.0", "id": 1, "method": "health"}, "nope")[0], 401)
        self.assertEqual(self.post({"jsonrpc": "2.0", "id": 1, "method": "health"},
                                   headers={"Origin": "http://evil.example"})[0], 403)
        self.assertEqual(self.post(b"{not json")[1]["error"]["code"], -32700)
        self.assertEqual(self.post({"id": 1, "method": "health"})[1]["error"]["code"], -32600)
        self.assertEqual(self.call("nope")["error"]["code"], -32601)
        self.assertEqual(self.call("read_patient", patient_id=P1, extra=1)["error"]["code"],
                         -32602)
        self.assertEqual(self.post({"jsonrpc": "2.0", "method": "health"})[0], 204)
        self.assertTrue(self.call("health")["result"]["ok"])

    def test_read_methods(self):
        self.assertEqual(self.call("resolve_patient", query="martin")["result"][0]["patient_id"],
                         P1)
        self.assertEqual(self.call("read_patient", patient_id="pat-003")["result"]
                         ["medications"][0]["medicationCodeableConcept"]["text"],
                         "Metformine 1000 mg")
        locs = self.call("find_sections", patient_id=P1)["result"]
        self.assertEqual(len(locs), 8)
        sec = self.call("read_section", item_id=ITEM1, attribute=EXAM)["result"]
        self.assertEqual(sec["digest"], digest(sec["text"]))
        err = self.call("read_section", item_id=ITEM1, attribute="nope")["error"]
        self.assertEqual(err["code"], 404)
        self.assertIn("present", err["data"])

    def test_tool_token_cannot_approve(self):
        d = self.call("draft_create", **self.draft_params())["result"]
        err = self.call("approve_draft", draft_id=d["draft_id"], answerer="model")["error"]
        self.assertEqual(err["code"], 403)
        self.assertEqual(self.env.bridge.draft_get(d["draft_id"])["status"], "drafted")

    def test_approver_token_cannot_write(self):
        d = self.call("draft_create", **self.draft_params())["result"]
        self.call("approve_draft", APPROVER_TOKEN, draft_id=d["draft_id"], answerer="dr.test")
        self.assertEqual(self.call("apply", APPROVER_TOKEN, draft_id=d["draft_id"])
                         ["error"]["code"], 403)
        self.assertEqual(self.call("draft_create", APPROVER_TOKEN, **self.draft_params())
                         ["error"]["code"], 403)

    def test_full_http_flow_apply_then_restore(self):
        before = self.call("read_section", item_id=ITEM1, attribute=EXAM)["result"]
        d = self.call("draft_create", **self.draft_params())["result"]
        denied = self.call("apply", draft_id=d["draft_id"])["error"]
        self.assertEqual((denied["code"], denied["data"]["status"]), (403, 403))
        ok = self.call("approve_draft", APPROVER_TOKEN, draft_id=d["draft_id"],
                       answerer="dr.test")["result"]
        self.assertTrue(ok["approval_id"].startswith("apr-"))
        self.assertNotIn("id", self.call("draft_get", draft_id=d["draft_id"])["result"]
                         ["approval"])  # the tool side never sees the approval id
        res = self.call("apply", draft_id=d["draft_id"])["result"]
        self.assertEqual(res["version_after"], before["version"] + 1)
        self.assertEqual(res["base_text"], before["text"])
        self.assertTrue(self.call("apply", draft_id=d["draft_id"])["result"]["replayed"])
        self.assertEqual(self.call("restore", backup_id=res["backup_id"])["error"]["code"], 403)
        r = self.call("draft_restore", backup_id=res["backup_id"])["result"]
        self.call("approve_draft", APPROVER_TOKEN, draft_id=r["draft_id"], answerer="dr.test")
        back = self.call("restore", backup_id=res["backup_id"])["result"]
        self.assertTrue(back["restored"])
        after = self.call("read_section", item_id=ITEM1, attribute=EXAM)["result"]
        self.assertEqual(after["digest"], before["digest"])
        events = [(a["event"], a["result"]) for a in self.env.audit()]
        self.assertEqual(events, [("apply", "refused"), ("apply", "ok"), ("restore", "refused"),
                                  ("restore", "ok")])

    def test_batch_requests(self):
        status, body = self.post([{"jsonrpc": "2.0", "id": 1, "method": "health"},
                                  {"jsonrpc": "2.0", "method": "health"},
                                  {"jsonrpc": "2.0", "id": 2, "method": "nope"}])
        self.assertEqual(status, 200)
        self.assertEqual([r["id"] for r in body], [1, 2])


if __name__ == "__main__":
    unittest.main()
