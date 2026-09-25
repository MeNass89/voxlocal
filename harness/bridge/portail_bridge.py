"""Portal bridge: JSON-RPC 2.0 over loopback HTTP between the harness and a portal backend.

The bridge is the security boundary for writes (plan Amendment 1). The harness can read,
and it can store **drafts**; it cannot make a draft reach the portal. Only a human decision,
relayed over a second credential, can:

    tool side  (PORTAIL_BRIDGE_TOKEN)          approver side (PORTAIL_BRIDGE_APPROVER_TOKEN)
    draft_create / draft_restore  --drafted-->  approve_draft(draft_id, answerer)
                                                   mints a single-use approval, 10 min,
                                                   bound to patient, encounter, item,
                                                   attribute, mode, base and final digests
    apply(draft_id) / restore(backup_id)  <--approved--
       one lock: approval valid + live digest == base digest + final digest re-derived
       + patient/encounter binding -> journal line (approval consumed) -> write -> read-back
       must equal the approved final digest (else restore from the backup, fail) -> journal
       -> audit line. Replaying an applied draft returns the stored result, no second write.

Drafts need a dictation source: every quote is found verbatim in a dictation that declares the
draft's patient and encounter, or the draft is refused.

Run (from the repository root):

    PORTAIL_BRIDGE_TOKEN=... PORTAIL_BRIDGE_APPROVER_TOKEN=... \\
        python3 -m harness.bridge.portail_bridge [--port 47368] [--backend mock|real]

Environment: PORTAIL_BACKEND (mock|real, default mock), PORTAIL_MED_API_PATH (real backend),
PORTAIL_BRIDGE_DRAFTS (default harness/bridge/drafts.jsonl), PORTAIL_BRIDGE_AUDIT (default
harness/audit/portal-writes.jsonl), PORTAIL_BRIDGE_STATE_DIR (mock persistence, default
harness/bridge/state), PORTAIL_DICTATION_DIR (`dictation-*.json` records for quote checks),
VOXLOCAL_API_URL + VOXLOCAL_API_TOKEN (the VoxLocal loopback dictation API, same purpose). Both
may be set (directory first, then API); mock mode always adds the synthetic fixtures last. Real
mode with neither has no source and every draft is refused (quotes cannot be verified: fail
closed).

Stdlib only. The audit log carries ids and digests, never clinical prose.
"""
from __future__ import annotations

import argparse
import copy
import hmac
import json
import os
import re
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable

from .interface import (
    NARRATIVE_SECTIONS, BackupInfo, DigestMismatch, EditRefused, NotFound, PortalBackend,
    PortalError, VerificationFailed, digest, mutate,
)

HARNESS = Path(__file__).resolve().parent.parent
DEFAULT_PORT = 47368
APPROVAL_TTL_S = 600
MAX_BODY = 1 << 20

DEFAULT_DRAFTS = HARNESS / "bridge" / "drafts.jsonl"
DEFAULT_AUDIT = HARNESS / "audit" / "portal-writes.jsonl"
DEFAULT_STATE = HARNESS / "bridge" / "state"


class Forbidden(PortalError):
    status = 403


class Unauthorized(PortalError):
    status = 401


def _iso(t: float) -> str:
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _collapse(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


# ============================================================================ dictations
@dataclass(frozen=True)
class Dictation:
    dictation_id: str
    patient_id: str | None
    encounter_id: str | None
    text: str  # whitespace-collapsed, the form the agent is shown


class DictationSource:
    """Dictations the quotes of a draft must come from.

    Reads `dictation-*.json` records (`{dictation_id, patient_context, text | text_file}`) from
    a directory; `text_file` lines starting with '#' are headers and are dropped. The VoxLocal
    API plugs in behind the same `get()` (`ApiDictationSource`).
    """

    def __init__(self, directory: Path | str):
        self.directory = Path(directory)

    def get(self, dictation_id: str) -> Dictation | None:
        for path in sorted(self.directory.glob("dictation-*.json")):
            rec = json.loads(path.read_text(encoding="utf-8"))
            if rec.get("dictation_id") != dictation_id:
                continue
            text = rec.get("text")
            if text is None:
                raw = (self.directory / rec["text_file"]).read_text(encoding="utf-8")
                text = "\n".join(line for line in raw.splitlines() if not line.startswith("#"))
            ctx = rec.get("patient_context") or {}
            return Dictation(dictation_id, ctx.get("patient_id"), ctx.get("encounter_id"),
                             _collapse(text))
        return None


LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")
_COMPACT_CONTEXT = re.compile(r"^\s*patient=(\S+)\s+rencontre=(\S+)\s*$")
_FINISHED = ("completed", "completed_with_warning")


def parse_patient_context(value: object) -> tuple[str | None, str | None]:
    """`(patient_id, encounter_id)` from a VoxLocal `patientContext`.

    Two forms bind a dictation: a JSON object `{"patient_id": …, "encounter_id": …}` and the
    compact `patient=<id> rencontre=<id>`. Anything else (free text, null, one id only) binds
    nothing, and the bridge refuses drafts quoting such a dictation.
    """
    if not isinstance(value, str):
        return None, None
    try:
        obj = json.loads(value)
    except ValueError:
        obj = None
    if isinstance(obj, dict):
        pid, eid = obj.get("patient_id"), obj.get("encounter_id")
        if isinstance(pid, str) and pid.strip() and isinstance(eid, str) and eid.strip():
            return pid.strip(), eid.strip()
        return None, None
    m = _COMPACT_CONTEXT.match(value)
    return (m.group(1), m.group(2)) if m else (None, None)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect would carry the Bearer token to another host: refuse it."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirection refusée", headers, fp)


class ApiDictationSource:
    """Dictations read from the VoxLocal loopback API (`GET /v1/dictations/<id>`).

    Loopback only, token from `VOXLOCAL_API_TOKEN`, 5 s per request, no proxy, no redirect. An
    unreachable API fails the draft (503) instead of skipping the check.
    """

    def __init__(self, base_url: str, token: str, timeout: float = 5.0):
        parsed = urllib.parse.urlsplit(base_url)
        if parsed.scheme not in ("http", "https") or parsed.hostname not in LOOPBACK_HOSTS \
                or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError("VOXLOCAL_API_URL : URL http(s) en boucle locale (127.0.0.1), sans "
                             "identifiants, query ni fragment")
        if not token:
            raise ValueError("VOXLOCAL_API_TOKEN requis pour lire les dictées")
        self.base, self.token, self.timeout = base_url.rstrip("/"), token, timeout
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())

    def get(self, dictation_id: str) -> Dictation | None:
        url = f"{self.base}/v1/dictations/{urllib.parse.quote(dictation_id, safe='')}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.token}",
                                                   "Accept": "application/json"})
        try:
            with self.opener.open(req, timeout=self.timeout) as resp:
                envelope = json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            exc.close()
            if exc.code == 404:
                return None
            err = PortalError(f"API VoxLocal : HTTP {exc.code} en lisant la dictée citée")
            err.status = 503
            raise err from None
        except (OSError, ValueError):
            err = PortalError("API VoxLocal injoignable ou réponse illisible : citations "
                              "invérifiables")
            err.status = 503
            raise err from None
        rec = envelope.get("data") if isinstance(envelope, dict) and envelope.get("ok") else None
        if not isinstance(rec, dict) or rec.get("id") != dictation_id:
            err = PortalError("API VoxLocal : réponse invalide pour la dictée citée")
            err.status = 503
            raise err
        if rec.get("processingStatus") not in _FINISHED:
            raise EditRefused(f"dictée {dictation_id!r} pas encore terminée : citer la version "
                              "finale", dictation_id=dictation_id)
        pid, eid = parse_patient_context(rec.get("patientContext"))
        return Dictation(dictation_id, pid, eid, _collapse(str(rec.get("finalTranscription") or "")))


class ChainedDictationSource:
    """Several sources tried in order; the first that knows the id answers."""

    def __init__(self, sources: list):
        self.sources = list(sources)

    def get(self, dictation_id: str) -> Dictation | None:
        for source in self.sources:
            found = source.get(dictation_id)
            if found is not None:
                return found
        return None


# ============================================================================ bridge core
DRAFT_FIELDS_IMMUTABLE = ("draft_id", "kind", "patient_id", "encounter_id", "item_id",
                          "attribute", "mode", "old", "new_text", "rationale", "quotes",
                          "quotes_verified", "base_digest", "base_text", "final_text",
                          "final_text_digest", "backup_id")


class Bridge:
    """Drafts, approvals and gated writes around one `PortalBackend`. Thread-safe."""

    def __init__(self, backend: PortalBackend, drafts_path: Path | str, audit_path: Path | str,
                 dictations: DictationSource | None = None, clock: Callable[[], float] = time.time,
                 approval_ttl_s: int = APPROVAL_TTL_S):
        self.backend = backend
        self.drafts_path = Path(drafts_path)
        self.audit_path = Path(audit_path)
        self.dictations = dictations
        self.clock = clock
        self.approval_ttl_s = approval_ttl_s
        self._lock = threading.RLock()
        self.drafts: dict[str, dict] = {}
        self._load()

    # ------------------------------------------------------------------ journal
    def _load(self) -> None:
        if not self.drafts_path.exists():
            return
        for line in self.drafts_path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rec = json.loads(line)
                self.drafts[rec["draft_id"]] = rec  # last line per draft wins
        for rec in self.drafts.values():
            if rec["status"] == "applying":
                self._recover(rec)

    def _recover(self, rec: dict) -> None:
        """A crash between the pre-write journal line and the post-write one. The approval is
        already consumed; decide from the live text whether the write landed."""
        try:
            section = self.backend.read_section(rec["item_id"], rec["attribute"])
        except PortalError:
            section = None
        live = section.digest if section is not None else None
        rec = copy.deepcopy(rec)
        event = "restore" if rec["kind"] == "restore" else "apply"
        if section is not None and live == rec["final_text_digest"]:
            backup_id = self._recovered_backup(rec)
            rec["status"] = "applied"
            rec["apply"] = {"ts": _iso(self.clock()), "recovered": True, "readback_digest": live,
                            "item_id": rec["item_id"], "attribute": rec["attribute"],
                            "mode": rec["mode"],
                            # The write's own version pair is lost with the crash; the draft's
                            # base version and the live version bound it.
                            "version_before": rec.get("base_version"),
                            "version_after": section.version}
            if backup_id is not None:  # absent rather than null: the tool schema wants a string
                rec["apply"]["backup_id"] = backup_id
            if rec["kind"] == "restore":
                rec["apply"]["restored"] = True
            self._journal(rec)
            self._audit(event, rec, "ok", recovered=True, readback_digest=live,
                        backup_id=backup_id, version_after=section.version)
        else:
            rec["status"] = "failed"
            rec["error"] = {"status": 409, "message": "écriture interrompue non constatée : "
                                                      "refaire le brouillon"}
            self._journal(rec)
            self._audit(event, rec, "error", status=409, reason="interrupted-write-not-found",
                        live_digest=live)

    def _recovered_backup(self, rec: dict) -> str | None:
        """The backup a crashed write left behind, so `draft_restore` keeps working."""
        if rec["kind"] == "restore":
            return rec["backup_id"]  # the backup this restore put back
        find = getattr(self.backend, "find_backup", None)
        if find is None:
            return None
        try:
            info = find(rec["item_id"], rec["attribute"], rec["final_text_digest"])
        except PortalError:
            return None
        if info is None or info.original_digest != rec["base_digest"]:
            return None
        return info.backup_id

    def _journal(self, rec: dict) -> None:
        """Append the draft's new full state, fsync'd, then publish it in memory."""
        rec["ts"] = _iso(self.clock())
        self.drafts_path.parent.mkdir(parents=True, exist_ok=True)
        with self.drafts_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        self.drafts[rec["draft_id"]] = rec

    def _audit(self, event: str, rec: dict, result: str, **extra) -> None:
        approval = rec.get("approval") or {}
        line = {"ts": _iso(self.clock()), "event": event, "result": result,
                "backend": getattr(self.backend, "name", "?"), "draft_id": rec["draft_id"],
                "patient_id": rec["patient_id"], "encounter_id": rec["encounter_id"],
                "item_id": rec["item_id"], "attribute": rec["attribute"], "mode": rec["mode"],
                "base_digest": rec["base_digest"], "final_digest": rec["final_text_digest"],
                "approval_id": approval.get("id"), "who": approval.get("answerer"), **extra}
        self.audit_path.parent.mkdir(parents=True, exist_ok=True)
        with self.audit_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(line, ensure_ascii=False, sort_keys=True) + "\n")
            fh.flush()
            os.fsync(fh.fileno())

    # ------------------------------------------------------------------ views
    @staticmethod
    def _public(rec: dict) -> dict:
        """What the tool side may see: no approval secret."""
        out = {k: v for k, v in rec.items() if k != "approval"}
        if rec.get("approval"):
            a = rec["approval"]
            out["approval"] = {"ts": a["ts"], "answerer": a["answerer"],
                               "expires_at": a["expires_at"], "consumed": a["consumed"]}
        return out

    def _draft(self, draft_id: str) -> dict:
        rec = self.drafts.get(draft_id)
        if rec is None:
            raise NotFound(f"brouillon {draft_id!r} inconnu")
        return rec

    # ------------------------------------------------------------------ reads (pass-through)
    def resolve_patient(self, query: str) -> list[dict]:
        return [p.to_json() for p in self.backend.resolve_patient(query)]

    def read_patient(self, patient_id: str) -> dict:
        return self.backend.read_patient(patient_id)

    def find_sections(self, patient_id: str, query: str | None = None) -> list[dict]:
        return [loc.to_json() for loc in self.backend.find_sections(patient_id, query)]

    def read_section(self, item_id: str, attribute: str) -> dict:
        return self.backend.read_section(item_id, attribute).to_json()

    # ------------------------------------------------------------------ drafts
    def _check_quotes(self, patient_id: str, encounter_id: str, quotes: list) -> tuple[list, bool]:
        if not isinstance(quotes, list) or not quotes:
            raise EditRefused("au moins une citation de la dictée est exigée (quotes)")
        if self.dictations is None:  # draft_create refuses first; kept as a second lock
            raise EditRefused("aucune source de dictées : citations invérifiables")
        checked = []
        for q in quotes:
            if not isinstance(q, dict) or not isinstance(q.get("dictation_id"), str) \
                    or not isinstance(q.get("text"), str) or not q["text"].strip():
                raise EditRefused("citation mal formée : {dictation_id, offset, text} attendu")
            offset = q.get("offset")
            if offset is not None and (not isinstance(offset, int) or isinstance(offset, bool)
                                       or offset < 0):
                raise EditRefused("citation : offset doit être un entier positif")
            text = _collapse(q["text"])
            d = self.dictations.get(q["dictation_id"])
            if d is None:
                raise EditRefused(f"dictée {q['dictation_id']!r} inconnue : citation "
                                  "introuvable dans la dictée")
            if d.patient_id is None or d.encounter_id is None:
                raise Forbidden("la dictée citée ne déclare pas de patient/rencontre : "
                                "brouillon refusé", dictation_id=d.dictation_id)
            if d.patient_id != patient_id:
                raise Forbidden("la dictée citée appartient à un autre patient que le "
                                "brouillon", dictation_id=d.dictation_id)
            if d.encounter_id != encounter_id:
                raise Forbidden("la dictée citée appartient à une autre rencontre que le "
                                "brouillon", dictation_id=d.dictation_id)
            hits = [m.start() for m in re.finditer(re.escape(text), d.text)]
            if not hits:
                raise EditRefused("citation introuvable dans la dictée",
                                  dictation_id=d.dictation_id)
            at = min(hits, key=lambda h: abs(h - (offset or 0)))
            checked.append({"dictation_id": d.dictation_id, "offset": at, "text": text,
                            "verified": True})
        return checked, True

    def _check_binding(self, patient_id: str, encounter_id: str, section) -> None:
        if section.patient_id != patient_id:
            raise Forbidden("l'item appartient à un autre patient que celui du brouillon",
                            item_id=section.item_id)
        if not section.filed or section.encounter_id != encounter_id:
            raise Forbidden("l'item n'est pas classé sous la rencontre du brouillon",
                            item_id=section.item_id)

    def draft_create(self, patient_id: str, encounter_id: str, item_id: str, attribute: str,
                     mode: str, new_text: str, rationale: str, quotes: list,
                     old: str | None = None, base_digest: str | None = None) -> dict:
        for name, val in (("patient_id", patient_id), ("encounter_id", encounter_id),
                          ("item_id", item_id), ("attribute", attribute),
                          ("new_text", new_text), ("rationale", rationale)):
            if not isinstance(val, str) or not val.strip():
                raise EditRefused(f"{name} : texte non vide attendu")
        if attribute not in NARRATIVE_SECTIONS:
            raise EditRefused(f"attribut {attribute!r} non narratif ; sections éditables : "
                              f"{list(NARRATIVE_SECTIONS)}")
        if self.dictations is None:
            raise EditRefused("aucune source de dictées : citations invérifiables ; définir "
                              "PORTAIL_DICTATION_DIR ou VOXLOCAL_API_URL")
        with self._lock:
            section = self.backend.read_section(item_id, attribute)
            self._check_binding(patient_id, encounter_id, section)
            if base_digest is not None and base_digest != section.digest:
                raise DigestMismatch("la section a changé depuis sa lecture : relire puis "
                                     "refaire le brouillon", expected=base_digest,
                                     live=section.digest)
            final_text = mutate(section.text, mode, new_text, old)
            if final_text == section.text:
                raise EditRefused("brouillon sans effet sur la section")
            checked, verified = self._check_quotes(patient_id, encounter_id, quotes)
            rec = {"draft_id": f"drf-{secrets.token_hex(8)}", "kind": "edit",
                   "status": "drafted", "created": _iso(self.clock()),
                   "patient_id": patient_id, "encounter_id": encounter_id, "item_id": item_id,
                   "attribute": attribute, "mode": mode, "old": old, "new_text": new_text,
                   "rationale": rationale, "quotes": checked, "quotes_verified": verified,
                   "base_digest": section.digest, "base_version": section.version,
                   "base_text": section.text, "final_text": final_text,
                   "final_text_digest": digest(final_text), "backup_id": None,
                   "approval": None, "apply": None}
            self._journal(rec)
            return self._public(rec)

    def draft_restore(self, backup_id: str) -> dict:
        """A restore is a draft too: it needs its own approval. Idempotent per backup."""
        with self._lock:
            for rec in self.drafts.values():
                if rec["kind"] == "restore" and rec["backup_id"] == backup_id \
                        and rec["status"] in ("drafted", "approved", "applied"):
                    return self._public(rec)
            info = self.backend.backup_info(backup_id)
            origin = next((r for r in self.drafts.values() if r["kind"] == "edit"
                           and (r.get("apply") or {}).get("backup_id") == backup_id), None)
            if origin is None:
                raise NotFound(f"sauvegarde {backup_id!r} sans modification appliquée par ce pont")
            section = self.backend.read_section(info.item_id, info.attribute)
            if section.digest != info.current_digest:
                raise DigestMismatch("la section a changé depuis la modification : restauration "
                                     "à l'aveugle refusée", expected=info.current_digest,
                                     live=section.digest)
            rec = {"draft_id": f"drf-{secrets.token_hex(8)}", "kind": "restore",
                   "status": "drafted", "created": _iso(self.clock()),
                   "patient_id": origin["patient_id"], "encounter_id": origin["encounter_id"],
                   "item_id": info.item_id, "attribute": info.attribute, "mode": "restore",
                   "old": None, "new_text": info.original_text,
                   "rationale": f"annulation du brouillon {origin['draft_id']}",
                   "quotes": [], "quotes_verified": False,
                   "base_digest": info.current_digest, "base_version": section.version,
                   "base_text": section.text, "final_text": info.original_text,
                   "final_text_digest": info.original_digest, "backup_id": backup_id,
                   "restores_draft_id": origin["draft_id"], "approval": None, "apply": None}
            self._journal(rec)
            return self._public(rec)

    def draft_get(self, draft_id: str) -> dict:
        with self._lock:
            return self._public(self._draft(draft_id))

    # ------------------------------------------------------------------ approver side
    def approve_draft(self, draft_id: str, answerer: str) -> dict:
        if not isinstance(answerer, str) or not answerer.strip():
            raise EditRefused("answerer : identité de la personne qui approuve exigée")
        with self._lock:
            rec = copy.deepcopy(self._draft(draft_id))
            if rec["status"] != "drafted":
                raise DigestMismatch(f"brouillon au statut {rec['status']!r} : approbation "
                                     "impossible", draft_status=rec["status"])
            now = self.clock()
            rec["status"] = "approved"
            rec["approval"] = {
                "id": f"apr-{secrets.token_urlsafe(18)}", "ts": _iso(now),
                "answerer": answerer, "expires_at": _iso(now + self.approval_ttl_s),
                "expires_epoch": now + self.approval_ttl_s, "consumed": False,
                "binding": {k: rec[k] for k in ("patient_id", "encounter_id", "item_id",
                                                "attribute", "mode", "base_digest",
                                                "final_text_digest", "draft_id")},
            }
            self._journal(rec)
            return {"draft_id": draft_id, "status": "approved",
                    "approval_id": rec["approval"]["id"], "expires_at": rec["approval"]["expires_at"]}

    def reject_draft(self, draft_id: str, answerer: str) -> dict:
        with self._lock:
            rec = copy.deepcopy(self._draft(draft_id))
            if rec["status"] not in ("drafted", "approved"):
                raise DigestMismatch(f"brouillon au statut {rec['status']!r}",
                                     draft_status=rec["status"])
            rec["status"] = "rejected"
            rec["rejection"] = {"ts": _iso(self.clock()), "answerer": answerer}
            self._journal(rec)
            return {"draft_id": draft_id, "status": "rejected"}

    # ------------------------------------------------------------------ gated writes
    def _gate(self, rec: dict) -> None:
        """Every condition for a write, checked under the lock right before it."""
        event = "restore" if rec["kind"] == "restore" else "apply"
        approval = rec.get("approval")
        if rec["status"] != "approved" or not approval:
            self._audit(event, rec, "refused", status=403, reason="not-approved")
            raise Forbidden("aucun feu vert pour ce brouillon : application refusée",
                            draft_status=rec["status"])
        if approval["consumed"]:
            self._audit(event, rec, "refused", status=403, reason="approval-consumed")
            raise Forbidden("feu vert déjà utilisé")
        if self.clock() >= approval["expires_epoch"]:
            expired = copy.deepcopy(rec)
            expired["status"] = "expired"
            self._journal(expired)
            self._audit(event, rec, "refused", status=403, reason="approval-expired")
            raise Forbidden("feu vert expiré (10 min) : redemander l'approbation")
        bound = {k: rec[k] for k in approval["binding"]}
        if bound != approval["binding"]:
            self._audit(event, rec, "refused", status=403, reason="binding-mismatch")
            raise Forbidden("le feu vert ne correspond pas à ce brouillon")
        section = self.backend.read_section(rec["item_id"], rec["attribute"])
        try:
            self._check_binding(approval["binding"]["patient_id"],
                                approval["binding"]["encounter_id"], section)
        except Forbidden:
            self._audit(event, rec, "refused", status=403, reason="patient-mismatch")
            raise
        if section.digest != rec["base_digest"]:
            self._audit(event, rec, "refused", status=409, reason="live-digest-changed",
                        live_digest=section.digest)
            raise DigestMismatch("la section a changé depuis le brouillon : relire puis refaire "
                                 "le brouillon", expected=rec["base_digest"], live=section.digest)
        if rec["kind"] == "edit":
            final = mutate(section.text, rec["mode"], rec["new_text"], rec["old"])
            if digest(final) != rec["final_text_digest"]:
                self._audit(event, rec, "refused", status=409, reason="final-digest-changed")
                raise DigestMismatch("le texte final ne correspond plus au brouillon approuvé")

    def apply(self, draft_id: str) -> dict:
        with self._lock:
            rec = self._draft(draft_id)
            if rec["kind"] != "edit":
                raise EditRefused("ce brouillon est une restauration : utiliser restore")
            if rec["status"] == "applied":
                return self._applied_view(rec, replayed=True)
            self._gate(rec)
            return self._write(rec, lambda: self.backend.apply(
                rec["item_id"], rec["attribute"], rec["base_digest"], rec["new_text"],
                rec["mode"], rec["old"]).to_json())

    def restore(self, backup_id: str) -> dict:
        with self._lock:
            recs = [r for r in self.drafts.values()
                    if r["kind"] == "restore" and r["backup_id"] == backup_id]
            done = next((r for r in recs if r["status"] == "applied"), None)
            if done is not None:
                return self._applied_view(done, replayed=True)
            rec = next((r for r in recs if r["status"] == "approved"), None) \
                or next((r for r in recs if r["status"] == "drafted"), None)
            if rec is None:
                origin = next((r for r in self.drafts.values() if r["kind"] == "edit"
                               and (r.get("apply") or {}).get("backup_id") == backup_id), None)
                if origin is not None:
                    self._audit("restore", origin, "refused", status=403,
                                reason="no-restore-draft", backup_id=backup_id)
                raise Forbidden("aucun brouillon de restauration approuvé pour cette "
                                "sauvegarde : appeler draft_restore puis obtenir le feu vert")
            self._gate(rec)
            return self._write(rec, lambda: self.backend.restore(backup_id).to_json())

    def _write(self, rec: dict, write: Callable[[], dict]) -> dict:
        event = "restore" if rec["kind"] == "restore" else "apply"
        applying = copy.deepcopy(rec)
        applying["status"] = "applying"
        applying["approval"]["consumed"] = True
        self._journal(applying)  # the approval is spent before the portal is touched
        try:
            result = write()
        except PortalError as err:
            failed = copy.deepcopy(applying)
            failed["status"] = "failed"
            failed["error"] = {"status": err.status, "message": err.message}
            self._journal(failed)
            self._audit(event, applying, "error", status=err.status, reason=type(err).__name__)
            raise
        if result.get("readback_digest") != rec["final_text_digest"]:
            return self._readback_mismatch(applying, result)
        applied = copy.deepcopy(applying)
        applied["status"] = "applied"
        applied["apply"] = {"ts": _iso(self.clock()), **result}
        self._journal(applied)
        self._audit(event, applied, "ok", version_before=result.get("version_before"),
                    version_after=result.get("version_after"),
                    readback_digest=result.get("readback_digest"),
                    backup_id=result.get("backup_id"))
        return self._applied_view(applied, replayed=False)

    def _readback_mismatch(self, applying: dict, result: dict):
        """The backend wrote, but the text it read back is not the approved final text (another
        client edited between our check and its write). Backend-agnostic: undo from the backup
        when there is one, never report success."""
        event = "restore" if applying["kind"] == "restore" else "apply"
        failed = copy.deepcopy(applying)
        failed["status"] = "failed"
        failed["error"] = {"status": 409, "message": "relecture différente du texte approuvé"}
        failed["apply_readback"] = {"readback_digest": result.get("readback_digest"),
                                    "backup_id": result.get("backup_id")}
        self._journal(failed)
        backup_id, restored = result.get("backup_id"), False
        # Only an edit left a backup of the text it replaced; a restore has nothing to undo to.
        if backup_id and applying["kind"] == "edit":
            try:
                restored = bool(self.backend.restore(backup_id).restored)
                self._audit("restore-after-mismatch", failed, "ok" if restored else "error",
                            backup_id=backup_id)
            except PortalError as err:
                self._audit("restore-after-mismatch", failed, "error", status=err.status,
                            reason=type(err).__name__, backup_id=backup_id)
        self._audit(event, failed, "error", status=409, reason="final-readback-mismatch",
                    readback_digest=result.get("readback_digest"), backup_id=backup_id,
                    restored=restored)
        raise VerificationFailed("relecture différente du texte approuvé : "
                                 + ("sauvegarde restaurée" if restored
                                    else "vérifier la section, restauration non faite"),
                                 backup_id=backup_id, restored=restored)

    @staticmethod
    def _applied_view(rec: dict, replayed: bool) -> dict:
        """The result of an applied draft; identical on replay, plus `replayed`."""
        return {**rec["apply"], "draft_id": rec["draft_id"], "kind": rec["kind"],
                "replayed": replayed, "base_text": rec["base_text"],
                "final_text": rec["final_text"]}


# ============================================================================ JSON-RPC
TOOL = "tool"
APPROVER = "approver"

#: method -> (roles allowed, parameter names accepted)
METHODS: dict[str, tuple[frozenset, tuple[str, ...]]] = {
    "health": (frozenset({TOOL, APPROVER}), ()),
    "resolve_patient": (frozenset({TOOL}), ("query",)),
    "read_patient": (frozenset({TOOL}), ("patient_id",)),
    "find_sections": (frozenset({TOOL}), ("patient_id", "query")),
    "read_section": (frozenset({TOOL}), ("item_id", "attribute")),
    "draft_create": (frozenset({TOOL}), ("patient_id", "encounter_id", "item_id", "attribute",
                                         "mode", "new_text", "rationale", "quotes", "old",
                                         "base_digest")),
    "draft_restore": (frozenset({TOOL, APPROVER}), ("backup_id",)),
    "draft_get": (frozenset({TOOL, APPROVER}), ("draft_id",)),
    "apply": (frozenset({TOOL}), ("draft_id",)),
    "restore": (frozenset({TOOL}), ("backup_id",)),
    "approve_draft": (frozenset({APPROVER}), ("draft_id", "answerer")),
    "reject_draft": (frozenset({APPROVER}), ("draft_id", "answerer")),
}


def dispatch(bridge: Bridge, role: str, request: object) -> dict | None:
    """One JSON-RPC 2.0 request -> response (None for a notification)."""
    if not isinstance(request, dict) or request.get("jsonrpc") != "2.0" \
            or not isinstance(request.get("method"), str):
        return {"jsonrpc": "2.0", "id": None,
                "error": {"code": -32600, "message": "Invalid Request"}}
    rid, method = request.get("id"), request["method"]
    notification = "id" not in request

    def err(code: int, message: str, data: dict | None = None) -> dict:
        body = {"code": code, "message": message}
        if data:
            body["data"] = data
        return {"jsonrpc": "2.0", "id": rid, "error": body}

    spec = METHODS.get(method)
    if spec is None:
        return None if notification else err(-32601, f"Method not found: {method}")
    roles, names = spec
    if role not in roles:
        return None if notification else err(403, f"méthode {method!r} interdite pour ce jeton")
    params = request.get("params", {})
    if not isinstance(params, dict):
        return None if notification else err(-32602, "params : objet nommé attendu")
    unknown = sorted(set(params) - set(names))
    if unknown:
        return None if notification else err(-32602, f"paramètres inconnus : {unknown}")
    try:
        if method == "health":
            result = {"ok": True, "backend": getattr(bridge.backend, "name", "?"),
                      "quotes_checked": bridge.dictations is not None}
        else:
            result = getattr(bridge, method)(**params)
    except TypeError as exc:
        return None if notification else err(-32602, f"paramètres invalides : {exc}")
    except PortalError as exc:
        return None if notification else err(exc.status, exc.message,
                                             {"status": exc.status, **exc.data})
    return None if notification else {"jsonrpc": "2.0", "id": rid, "result": result}


class _Handler(BaseHTTPRequestHandler):
    server_version = "portail-bridge/1"  # HTTP/1.0: one request per connection

    def log_message(self, fmt, *args):  # no request lines: they could carry ids in paths
        pass

    def _send(self, status: int, payload: object) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _role(self) -> str | None:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return None
        presented = auth[7:].encode("utf-8")
        tokens: dict[str, str] = self.server.tokens  # type: ignore[attr-defined]
        for role, token in tokens.items():
            if hmac.compare_digest(presented, token.encode("utf-8")):
                return role
        return None

    def do_GET(self):
        self._send(405, {"jsonrpc": "2.0", "id": None,
                         "error": {"code": -32600, "message": "POST uniquement"}})

    def do_POST(self):
        if self.headers.get("Origin"):
            return self._send(403, {"jsonrpc": "2.0", "id": None, "error": {
                "code": 403, "message": "requêtes de navigateur refusées"}})
        role = self._role()
        if role is None:
            return self._send(401, {"jsonrpc": "2.0", "id": None, "error": {
                "code": 401, "message": "jeton Bearer absent ou invalide"}})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            return self._send(413, {"jsonrpc": "2.0", "id": None,
                                    "error": {"code": -32600, "message": "corps trop grand"}})
        try:
            request = json.loads(self.rfile.read(length) or b"null")
        except (ValueError, UnicodeDecodeError):
            return self._send(200, {"jsonrpc": "2.0", "id": None,
                                    "error": {"code": -32700, "message": "Parse error"}})
        bridge: Bridge = self.server.bridge  # type: ignore[attr-defined]
        if isinstance(request, list):
            if not request:
                return self._send(200, {"jsonrpc": "2.0", "id": None,
                                        "error": {"code": -32600, "message": "Invalid Request"}})
            out = [r for r in (dispatch(bridge, role, x) for x in request) if r is not None]
            if not out:
                self.send_response(204)
                self.send_header("Content-Length", "0")
                return self.end_headers()
            return self._send(200, out)
        response = dispatch(bridge, role, request)
        if response is None:
            self.send_response(204)
            self.send_header("Content-Length", "0")
            return self.end_headers()
        self._send(200, response)


def make_server(bridge: Bridge, tool_token: str, approver_token: str,
                host: str = "127.0.0.1", port: int = DEFAULT_PORT) -> ThreadingHTTPServer:
    if host not in ("127.0.0.1", "::1", "localhost"):
        raise ValueError("le pont n'écoute que sur la boucle locale")
    if not tool_token or not approver_token:
        raise ValueError("PORTAIL_BRIDGE_TOKEN et PORTAIL_BRIDGE_APPROVER_TOKEN sont requis")
    if hmac.compare_digest(tool_token, approver_token):
        raise ValueError("le jeton approbateur doit différer du jeton des outils")
    server = ThreadingHTTPServer((host, port), _Handler)
    server.daemon_threads = True
    server.bridge = bridge  # type: ignore[attr-defined]
    server.tokens = {TOOL: tool_token, APPROVER: approver_token}  # type: ignore[attr-defined]
    return server


# ============================================================================ backends
def make_backend(kind: str, state_dir: Path | None) -> PortalBackend:
    if kind == "mock":
        from .portail_mock import MockPortal
        return MockPortal(state_dir=state_dir)
    if kind == "real":
        return RealPortal(os.environ.get("PORTAIL_MED_API_PATH", ""))
    raise ValueError(f"PORTAIL_BACKEND inconnu : {kind!r} (mock|real)")


class RealPortal:
    """Adapter over `portail.records.Record` (portail-med-api). Not exercised while the portal
    is locked down; the write path maps one to one onto `Record`, patient search and section
    listing are wired when access returns."""

    name = "real"

    def __init__(self, repo_path: str):
        if not repo_path:
            raise ValueError("PORTAIL_MED_API_PATH doit pointer vers portail-med-api")
        sys.path.insert(0, str(Path(repo_path) / "src"))
        from portail import records  # noqa: PLC0415 - optional, only in real mode
        from portail.fhir_client import FhirClient  # noqa: PLC0415
        self._records = records
        self._rec = records.Record(ehr_id="")  # item-level calls do not use the ehr id
        self._fhir = FhirClient()

    def _todo(self, what: str):
        err = PortalError(f"{what} : pas encore câblé sur le portail réel")
        err.status = 501
        raise err

    def resolve_patient(self, query):
        self._todo("resolve_patient")

    def find_sections(self, patient_id, query=None):
        self._todo("find_sections")

    def read_patient(self, patient_id):
        def all_of(kind):
            return list(self._fhir.search_all(kind, patient=patient_id))
        return {"patient": {"patient_id": patient_id},
                "allergies": all_of("AllergyIntolerance"), "conditions": all_of("Condition"),
                "medications": all_of("MedicationStatement")}

    def read_section(self, item_id, attribute):
        from .interface import Section
        item = self._rec.get_item(item_id, 0)
        if item is None:
            raise NotFound("Item not found")
        text = self._rec.read(item_id, attribute)
        # In real mode the patient id is the EHR id and the encounter id is the item's
        # `contact` identifier; an item without `contact` is filed nowhere (invisible).
        contact = item["contact"]
        return Section(str(item["ehr-id"]), item_id, item["template-id"],
                       str(contact) if contact else None, bool(contact), attribute, text,
                       len(text), item["version"], digest(text))

    def apply(self, item_id, attribute, base_digest, new_text, mode, old=None):
        from .interface import EditResult
        live = self._rec.read(item_id, attribute)
        if digest(live) != base_digest:
            raise DigestMismatch("la section a changé depuis le brouillon",
                                 expected=base_digest, live=digest(live))
        before = self._rec.get_item(item_id, 0)["version"]
        if mode == "append":
            res = self._rec.append(item_id, attribute, new_text, commit=True)
        elif mode == "replace":
            mutate(live, mode, new_text, old)  # same refusals before touching the portal
            res = self._rec.replace(item_id, attribute, old, new_text, commit=True)
        else:
            raise EditRefused(f"mode inconnu {mode!r}")
        if res.old_digest != base_digest:
            # `Record.append/replace` re-read the item: another client wrote between our check
            # and the write, so the edit landed on a text nobody approved. Undo it.
            restored = bool(self._rec.restore(res.backup))
            if not restored:
                raise VerificationFailed("la section a changé entre la vérification et "
                                         "l'écriture ; restauration impossible : vérifier la "
                                         "section", backup_id=res.backup.name)
            raise DigestMismatch("la section a changé entre la vérification et l'écriture ; "
                                 "sauvegarde restaurée", expected=base_digest,
                                 live=res.old_digest, backup_id=res.backup.name)
        if not res.verified or (mode == "append" and not res.prefix_intact):
            raise VerificationFailed("relecture non conforme", backup_id=res.backup.name)
        return EditResult(item_id, attribute, mode, res.old_length, res.new_length,
                          res.old_digest, res.new_digest, res.new_digest, before, res.version,
                          res.verified, res.prefix_intact, res.backup.name)

    def find_backup(self, item_id, attribute, current_digest):
        """Newest `records.DATA` backup of this attribute whose edited text is `current_digest`."""
        found = []
        for path in self._records.DATA.glob("backup_*.json"):
            try:
                bak = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(bak, dict) and bak.get("item") == item_id \
                    and bak.get("attr") == attribute and bak.get("current_digest") == current_digest:
                found.append((path.stat().st_mtime, path.name, bak))
        if not found:
            return None
        _, name, bak = max(found, key=lambda f: (f[0], f[1]))
        return BackupInfo(name, bak["item"], bak["attr"], bak["original_text"],
                          bak["original_digest"], bak["current_digest"], bak["taken"])

    def backup_info(self, backup_id):
        path = self._records.DATA / Path(backup_id).name
        if not path.exists():
            raise NotFound(f"sauvegarde {backup_id!r} inconnue")
        bak = json.loads(path.read_text(encoding="utf-8"))
        return BackupInfo(path.name, bak["item"], bak["attr"], bak["original_text"],
                          bak["original_digest"], bak["current_digest"], bak["taken"])

    def restore(self, backup_id):
        from .interface import RestoreResult
        info = self.backup_info(backup_id)
        before = self._rec.get_item(info.item_id, 0)["version"]
        ok = self._rec.restore(self._records.DATA / info.backup_id)
        if not ok:
            raise DigestMismatch("restauration refusée : la section a changé")
        back = self._rec.read(info.item_id, info.attribute)
        return RestoreResult(backup_id, info.item_id, info.attribute, ok, before,
                             self._rec.get_item(info.item_id, 0)["version"], digest(back))


def build_bridge_from_env(backend_kind: str | None = None) -> Bridge:
    kind = backend_kind or os.environ.get("PORTAIL_BACKEND", "mock")
    state = Path(os.environ.get("PORTAIL_BRIDGE_STATE_DIR", DEFAULT_STATE))
    backend = make_backend(kind, state)
    return Bridge(backend, os.environ.get("PORTAIL_BRIDGE_DRAFTS", DEFAULT_DRAFTS),
                  os.environ.get("PORTAIL_BRIDGE_AUDIT", DEFAULT_AUDIT), dictations_from_env(kind))


def dictations_from_env(kind: str):
    """Directory source, then VoxLocal API source, then (mock mode only) the synthetic fixtures.
    None (real mode, nothing configured) makes every draft refused."""
    sources: list = []
    dict_dir = os.environ.get("PORTAIL_DICTATION_DIR")
    if dict_dir:
        sources.append(DictationSource(dict_dir))
    api_url, api_token = os.environ.get("VOXLOCAL_API_URL"), os.environ.get("VOXLOCAL_API_TOKEN")
    if api_url and api_token:
        sources.append(ApiDictationSource(api_url, api_token))
    elif api_url:
        raise ValueError("VOXLOCAL_API_URL défini sans VOXLOCAL_API_TOKEN")
    if kind == "mock":
        sources.append(DictationSource(Path(__file__).resolve().parent / "fixtures"))
    if not sources:
        return None
    return sources[0] if len(sources) == 1 else ChainedDictationSource(sources)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Pont JSON-RPC loopback vers le portail (mock|réel)")
    ap.add_argument("--port", type=int, default=int(os.environ.get("PORTAIL_BRIDGE_PORT",
                                                                   DEFAULT_PORT)))
    ap.add_argument("--backend", choices=("mock", "real"), default=None)
    args = ap.parse_args(argv)
    bridge = build_bridge_from_env(args.backend)
    server = make_server(bridge, os.environ.get("PORTAIL_BRIDGE_TOKEN", ""),
                         os.environ.get("PORTAIL_BRIDGE_APPROVER_TOKEN", ""), port=args.port)
    print(f"portail-bridge ({bridge.backend.name}) sur http://127.0.0.1:{server.server_port}",
          file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
