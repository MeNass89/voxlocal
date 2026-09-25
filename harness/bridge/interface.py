"""The portal backend contract shared by the recorded mock and the real client.

It mirrors `portail.records.Record` (MeNass89/portail-med-api) exactly:

- only the narrative attributes of documents filed under an encounter are visible to the
  clinician, so they are the only editable surface;
- every mutation is append- or replace-only on one attribute;
- `replace` refuses an absent or ambiguous substring;
- the caller's base digest is checked against the live text before the write;
- the original is backed up before the write, and the write is verified by reading back
  (digest + original prefix byte-identical for an append);
- `restore` puts the backup back only if the live text is still the edited one.

Digests are `sha256(text)[:16]`, the same as `portail.records.digest`. No clinical prose is
logged by this layer; errors carry names, lengths and digests only.
"""
from __future__ import annotations

import hashlib
import unicodedata
from dataclasses import asdict, dataclass
from typing import Literal, Protocol, runtime_checkable

#: The EhrBank store's own source-id. With any other value `getItem` answers "Item not found".
SOURCE_ID = "ERA_EHR"

#: Narrative attributes that render in the clinician's web UI (records.NARRATIVE_SECTIONS).
NARRATIVE_SECTIONS: dict[str, str] = {
    "current-affliction": "anamnèse / histoire de la maladie actuelle",
    "main-problem-history": "histoire du problème principal",
    "physical-exam-text": "examen clinique",
    "systematic-review-text": "revue des systèmes",
    "text-conclusion": "conclusion",
    "text-evolution": "évolution",
    "disposition": "orientation / suite à donner",
    "other-risk-text": "facteurs de risque (tabagisme, alcool…)",
}

#: Templates whose items carry the sections above (records.NARRATIVE_TEMPLATES).
NARRATIVE_TEMPLATES = ("in-patient-care-procedure", "out-patient-care-procedure")

#: Separator `Record.append` puts between the current text and the appended text.
APPEND_SEPARATOR = "\n"

EditMode = Literal["append", "replace"]


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def norm(text: str) -> str:
    """Lowercase and strip accents, so 'Entorse' matches 'entorsé' (records._norm)."""
    return "".join(c for c in unicodedata.normalize("NFD", text.lower())
                   if unicodedata.category(c) != "Mn")


def mutate(current: str, mode: str, new_text: str, old: str | None = None) -> str:
    """The exact text transformation of `Record.append` / `Record.replace`."""
    if mode == "append":
        if old is not None:
            raise EditRefused("un ajout (append) ne prend pas de texte à remplacer")
        return current + APPEND_SEPARATOR + new_text
    if mode == "replace":
        if not old:
            raise EditRefused("un remplacement exige le texte exact à remplacer (old)")
        n = current.count(old)
        if n == 0:
            raise EditRefused("texte à remplacer absent de la section", occurrences=0)
        if n > 1:
            raise EditRefused(f"texte à remplacer présent {n} fois : remplacement ambigu refusé",
                              occurrences=n)
        return current.replace(old, new_text)
    raise EditRefused(f"mode inconnu {mode!r} : seuls 'append' et 'replace' existent")


# --------------------------------------------------------------------------- errors
class PortalError(Exception):
    """A refusal with an HTTP-like status the bridge forwards as the JSON-RPC error code."""
    status = 500

    def __init__(self, message: str, **data):
        super().__init__(message)
        self.message = message
        self.data = data


class NotFound(PortalError):
    status = 404


class EditRefused(PortalError):
    """The edit is malformed or targets something that is not an editable, visible section."""
    status = 422


class DigestMismatch(PortalError):
    """The live text is not the text the caller based its edit on (concurrent edit)."""
    status = 409


class VerificationFailed(PortalError):
    """The write was accepted but the read-back does not match: restore from the backup."""
    status = 500


# --------------------------------------------------------------------------- values
@dataclass(frozen=True)
class PatientRef:
    patient_id: str
    ehr_id: str
    tpms: str
    display_name: str
    birth_date: str
    sex: str

    def to_json(self) -> dict:
        return asdict(self)


@dataclass(frozen=True)
class Location:
    """One editable narrative section of an encounter-filed document."""
    item_id: str
    template_id: str
    encounter_id: str
    attribute: str
    label: str
    current_text: str
    length: int
    version: int
    digest: str

    def to_json(self) -> dict:
        return asdict(self)


@dataclass(frozen=True)
class Section:
    """The live state of one attribute. `filed` is False for an item with no encounter:
    it exists and is retrievable, and no clinician view renders it."""
    patient_id: str
    item_id: str
    template_id: str
    encounter_id: str | None
    filed: bool
    attribute: str
    text: str
    length: int
    version: int
    digest: str

    def to_json(self) -> dict:
        return asdict(self)


@dataclass(frozen=True)
class EditResult:
    item_id: str
    attribute: str
    mode: str
    old_length: int
    new_length: int
    old_digest: str
    new_digest: str
    readback_digest: str
    version_before: int
    version_after: int
    verified: bool
    prefix_intact: bool
    backup_id: str

    def to_json(self) -> dict:
        return asdict(self)


@dataclass(frozen=True)
class BackupInfo:
    backup_id: str
    item_id: str
    attribute: str
    original_text: str
    original_digest: str
    current_digest: str
    taken: str

    def to_json(self) -> dict:
        return asdict(self)


@dataclass(frozen=True)
class RestoreResult:
    backup_id: str
    item_id: str
    attribute: str
    restored: bool
    version_before: int
    version_after: int
    readback_digest: str

    def to_json(self) -> dict:
        return asdict(self)


# --------------------------------------------------------------------------- contract
@runtime_checkable
class PortalBackend(Protocol):
    """What the bridge needs from a portal. The mock and the real client both satisfy it."""

    name: str

    def resolve_patient(self, query: str) -> list[PatientRef]:
        """Patients matching a name, TPMS identifier or birth date (accent-insensitive)."""

    def read_patient(self, patient_id: str) -> dict:
        """`{patient, allergies, conditions, medications}` from the read-only FHIR subset."""

    def find_sections(self, patient_id: str, query: str | None = None) -> list[Location]:
        """Every narrative section of the patient's encounter-filed care documents, optionally
        only those whose text contains `query` (accent- and case-insensitive, like
        `Record.find`)."""

    def read_section(self, item_id: str, attribute: str) -> Section:
        """The live text of one attribute; unknown attribute -> error listing present ones."""

    def apply(self, item_id: str, attribute: str, base_digest: str, new_text: str,
              mode: EditMode, old: str | None = None) -> EditResult:
        """Check `base_digest` against the live text, back up, write, read back, verify."""

    def backup_info(self, backup_id: str) -> BackupInfo:
        """What a backup would put back, so the restore can be shown before it is approved."""

    def restore(self, backup_id: str) -> RestoreResult:
        """Put the backup back if the live text still is the edited text (digest-matched)."""

    # Optional, used by the bridge's crash recovery when present (mock and real both have it):
    #   find_backup(item_id, attribute, current_digest) -> BackupInfo | None
    # the newest backup of that attribute whose edited text has `current_digest`.
