"""Recorded Portail Médical EHR: the `PortalBackend` contract over synthetic JSON fixtures.

It reproduces the traps documented in portail-med-api (CLAUDE.md, docs/status-and-roadblocks.md,
src/portail/records.py) so that code which works here keeps working against the real portal:

- `get_item` requires `version` (0 = latest) and the `ERA_EHR` source-id; anything else is
  "Item not found", exactly like the real `getItem`.
- attribute values are shaped `{_value_1: [{text: {content: ...}}]}`; text is found by the same
  walk as `records._text_nodes`, which steps into the plain dict in the middle.
- only items filed under an encounter (`contact`) and a service (`domain`) are visible: unfiled
  items stay retrievable by id and never show up in `find_sections`, and editing them is refused.
- item suggestions are never exposed (they are invisible to the clinician).
- only the 8 narrative attributes on `*-care-procedure` templates are editable; an unknown
  attribute raises an error listing the attributes present.
- append/replace only; `replace` refuses 0 or >1 occurrences; the caller's base digest is
  checked against the live text before the write; the original is backed up first; the write is
  verified by reading back; every write increments the item `version` (history kept).
- `restore` matches the live text on the backup's `current_digest`, so it cannot restore blind.

No third-party dependency. With a `state_dir`, writes and backups survive a restart.
"""
from __future__ import annotations

import copy
import json
import secrets
import threading
from datetime import datetime, timezone
from pathlib import Path

from .interface import (
    NARRATIVE_SECTIONS, NARRATIVE_TEMPLATES, SOURCE_ID, BackupInfo, DigestMismatch, EditMode,
    EditRefused, EditResult, Location, NotFound, PatientRef, PortalError, RestoreResult, Section,
    VerificationFailed, digest, mutate, norm,
)

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _text_nodes(attr: dict):
    """Yield the `text` objects (dicts carrying a str `content`) inside an attribute's values.

    Same walk as `records._text_nodes`: lists, then the plain `_value_1` dict, then the text
    objects. A walker that stops at the first dict never reaches the prose.
    """
    vals = attr.get("values")
    if vals is None:
        return
    stack, seen = [vals], set()
    while stack:
        cur = stack.pop()
        if id(cur) in seen:
            continue
        seen.add(id(cur))
        if isinstance(cur, list):
            stack.extend(cur)
        elif isinstance(cur, dict):
            if isinstance(cur.get("content"), str):
                yield cur
            else:
                stack.extend(cur.values())


def _prose_node(item: dict, attribute: str) -> dict:
    """The longest text node of one attribute, as `Record.read` / `Record._edit` pick it."""
    target = next((a for a in item["attributes"] if a["name"] == attribute), None)
    if target is None:
        present = [a["name"] for a in item["attributes"]]
        raise NotFound(f"attribut {attribute!r} absent de l'item {item['item_id']} ; "
                       f"présents : {present}", present=present)
    nodes = list(_text_nodes(target))
    if not nodes:
        raise NotFound(f"attribut {attribute!r} sans texte sur l'item {item['item_id']}")
    return max(nodes, key=lambda n: len(n["content"]))


def _filed(item: dict) -> bool:
    contact, domain = item.get("contact"), item.get("domain")
    return bool(contact and contact.get("encounter_id") and domain and domain.get("code"))


class MockPortal:
    """In-memory EHR loaded from `fixtures/patient-*.json`."""

    name = "mock"

    def __init__(self, fixtures_dir: Path | str = FIXTURES, state_dir: Path | str | None = None):
        self.fixtures_dir = Path(fixtures_dir)
        self.state_dir = Path(state_dir) if state_dir else None
        self._lock = threading.RLock()
        self.patients: dict[str, dict] = {}
        self.items: dict[str, dict] = {}            # item_id -> latest item (mutable)
        self.history: dict[str, dict[int, dict]] = {}  # item_id -> version -> snapshot
        self.item_patient: dict[str, str] = {}
        self.backups: dict[str, dict] = {}
        self.write_count = 0                        # every saveItem, for tests
        for path in sorted(self.fixtures_dir.glob("patient-*.json")):
            doc = json.loads(path.read_text(encoding="utf-8"))
            pid = doc["patient"]["patient_id"]
            self.patients[pid] = doc
            for item in doc["items"]:
                self.items[item["item_id"]] = item
                self.item_patient[item["item_id"]] = pid
                self.history[item["item_id"]] = {item["version"]: copy.deepcopy(item)}
            # doc["suggestions"] are deliberately never indexed: invisible to the clinician.
        if self.state_dir:
            self._load_state()

    # ------------------------------------------------------------------ persistence
    def _load_state(self) -> None:
        for path in sorted((self.state_dir / "items").glob("*.json")):
            item = json.loads(path.read_text(encoding="utf-8"))
            if item["item_id"] in self.items:
                self.items[item["item_id"]] = item
                self.history[item["item_id"]][item["version"]] = copy.deepcopy(item)
        for path in sorted((self.state_dir / "backups").glob("*.json")):
            bak = json.loads(path.read_text(encoding="utf-8"))
            self.backups[bak["backup_id"]] = bak

    def _persist_item(self, item: dict) -> None:
        if not self.state_dir:
            return
        d = self.state_dir / "items"
        d.mkdir(parents=True, exist_ok=True)
        tmp = d / f"{item['item_id']}.json.tmp"
        tmp.write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
        tmp.replace(d / f"{item['item_id']}.json")

    def _persist_backup(self, bak: dict) -> None:
        if not self.state_dir:
            return
        d = self.state_dir / "backups"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{bak['backup_id']}.json").write_text(json.dumps(bak, ensure_ascii=False),
                                                   encoding="utf-8")

    # ------------------------------------------------------------------ wire-level primitives
    def get_item(self, item_id: str, version: int | None = None, source_id: str = SOURCE_ID) -> dict:
        """`EhrBank.getItem(itemReference{source-id, item-id, version})`.

        `version` is mandatory on the wire, even to fetch the latest (0 = latest). A wrong
        source-id answers "Item not found" like the real store.
        """
        if version is None:
            raise PortalError("getItem : 'version' est obligatoire (0 = dernière version)")
        if source_id != SOURCE_ID or item_id not in self.items:
            raise NotFound("Item not found")
        with self._lock:
            if version == 0:
                return copy.deepcopy(self.items[item_id])
            snap = self.history[item_id].get(version)
            if snap is None:
                raise NotFound("Item not found")
            return copy.deepcopy(snap)

    def save_item(self, item: dict) -> None:
        """`EhrBank.saveItem`: store and bump the version."""
        with self._lock:
            item = copy.deepcopy(item)
            item["version"] = self.items[item["item_id"]]["version"] + 1
            self.items[item["item_id"]] = item
            self.history[item["item_id"]][item["version"]] = copy.deepcopy(item)
            self.write_count += 1
            self._persist_item(item)

    def _read(self, item_id: str, attribute: str) -> str:
        return _prose_node(self.get_item(item_id, 0), attribute)["content"]

    # ------------------------------------------------------------------ PortalBackend
    def resolve_patient(self, query: str) -> list[PatientRef]:
        q = norm(query.strip())
        if not q:
            return []
        out = []
        for doc in self.patients.values():
            p = doc["patient"]
            fields = [p["patient_id"], p["tpms"], p["birth_date"], p["display_name"]]
            if any(q in norm(f) for f in fields):
                out.append(PatientRef(**p))
        return out

    def read_patient(self, patient_id: str) -> dict:
        doc = self.patients.get(patient_id)
        if doc is None:
            raise NotFound(f"patient {patient_id!r} inconnu")
        return {"patient": PatientRef(**doc["patient"]).to_json(),
                "allergies": copy.deepcopy(doc["fhir"]["allergies"]),
                "conditions": copy.deepcopy(doc["fhir"]["conditions"]),
                "medications": copy.deepcopy(doc["fhir"]["medications"])}

    def find_sections(self, patient_id: str, query: str | None = None) -> list[Location]:
        if patient_id not in self.patients:
            raise NotFound(f"patient {patient_id!r} inconnu")
        needle = norm(query) if query else None
        out = []
        with self._lock:
            for item_id, pid in self.item_patient.items():
                item = self.items[item_id]
                if pid != patient_id or not _filed(item) \
                        or item["template_id"] not in NARRATIVE_TEMPLATES:
                    continue
                for attr in item["attributes"]:
                    if attr["name"] not in NARRATIVE_SECTIONS:
                        continue
                    text = _prose_node(item, attr["name"])["content"]
                    if needle and needle not in norm(text):
                        continue
                    out.append(Location(item_id, item["template_id"],
                                        item["contact"]["encounter_id"], attr["name"],
                                        NARRATIVE_SECTIONS[attr["name"]], text, len(text),
                                        item["version"], digest(text)))
        return out

    def read_section(self, item_id: str, attribute: str) -> Section:
        item = self.get_item(item_id, 0)
        text = _prose_node(item, attribute)["content"]
        contact = item.get("contact") or {}
        return Section(self.item_patient[item_id], item_id, item["template_id"],
                       contact.get("encounter_id"), _filed(item), attribute, text, len(text),
                       item["version"], digest(text))

    def _check_editable(self, item: dict, attribute: str) -> None:
        if not _filed(item):
            raise EditRefused("item non classé sous une rencontre et un service : il existe mais "
                              "aucune vue ne l'affiche, l'édition serait invisible",
                              item_id=item["item_id"])
        if item["template_id"] not in NARRATIVE_TEMPLATES:
            raise EditRefused(f"modèle {item['template_id']!r} sans sections narratives éditables")
        if attribute not in NARRATIVE_SECTIONS:
            present = [a["name"] for a in item["attributes"] if a["name"] in NARRATIVE_SECTIONS]
            raise EditRefused(f"attribut {attribute!r} non narratif ; sections éditables "
                              f"présentes : {present}", present=present)

    def apply(self, item_id: str, attribute: str, base_digest: str, new_text: str,
              mode: EditMode, old: str | None = None) -> EditResult:
        with self._lock:
            item = self.get_item(item_id, 0)
            self._check_editable(item, attribute)
            node = _prose_node(item, attribute)
            original = node["content"]
            if digest(original) != base_digest:
                raise DigestMismatch("la section a changé depuis le brouillon (empreinte "
                                     "différente) : relire puis refaire le brouillon",
                                     expected=base_digest, live=digest(original))
            updated = mutate(original, mode, new_text, old)
            if updated == original:
                raise EditRefused("modification sans effet")
            backup_id = f"bak-{item_id[:8]}-{attribute}-{secrets.token_hex(4)}"
            bak = {"backup_id": backup_id, "item": item_id, "attr": attribute,
                   "original_text": original, "original_digest": digest(original),
                   "current_digest": digest(updated), "taken": _now()}
            self.backups[backup_id] = bak
            self._persist_backup(bak)
            version_before = item["version"]
            node["content"] = updated
            self.save_item(item)
            back = self._read(item_id, attribute)
            result = EditResult(item_id, attribute, mode, len(original), len(updated),
                                digest(original), digest(updated), digest(back), version_before,
                                self.get_item(item_id, 0)["version"],
                                verified=digest(back) == digest(updated),
                                prefix_intact=back.startswith(original) if mode == "append"
                                else True,
                                backup_id=backup_id)
            if not result.verified or not result.prefix_intact:
                raise VerificationFailed("relecture non conforme après écriture ; restaurer "
                                         "depuis la sauvegarde", backup_id=backup_id)
            return result

    def backup_info(self, backup_id: str) -> BackupInfo:
        bak = self.backups.get(backup_id)
        if bak is None:
            raise NotFound(f"sauvegarde {backup_id!r} inconnue")
        return BackupInfo(backup_id, bak["item"], bak["attr"], bak["original_text"],
                          bak["original_digest"], bak["current_digest"], bak["taken"])

    def restore(self, backup_id: str) -> RestoreResult:
        with self._lock:
            info = self.backup_info(backup_id)
            item = self.get_item(info.item_id, 0)
            target = next((a for a in item["attributes"] if a["name"] == info.attribute), None)
            if target is None:
                raise NotFound(f"attribut {info.attribute!r} absent de l'item {info.item_id}")
            for node in _text_nodes(target):
                if digest(node["content"]) == info.current_digest:
                    version_before = item["version"]
                    node["content"] = info.original_text
                    self.save_item(item)
                    back = self._read(info.item_id, info.attribute)
                    return RestoreResult(backup_id, info.item_id, info.attribute,
                                         digest(back) == info.original_digest, version_before,
                                         self.get_item(info.item_id, 0)["version"], digest(back))
            raise DigestMismatch("la section a changé depuis la modification sauvegardée : "
                                 "restauration à l'aveugle refusée",
                                 expected=info.current_digest,
                                 live=digest(_prose_node(item, info.attribute)["content"]))
