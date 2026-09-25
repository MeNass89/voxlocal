#!/usr/bin/env python3
"""Feed finished VoxLocal dictations to the clinical agent (dsh).

Reads the VoxLocal dictation API (Mac loopback API, or the Python agent API in
``--mock`` mode), and for each **completed** dictation delivers the message

    « Nouvelle dictée <id> (<durée>) : <finalTranscription> »
    « Patient déclaré : <patientContext | aucun> »

Real-time semantics (plan Amendment 1, D):

* a dictation is delivered as an **inject** — durable context, no new turn;
* a **followup** (a turn) is triggered only by a pause of ``--pause-seconds``
  (20 s) after the last dictation, by an explicit clinician command (text that
  starts with one of ``--command-prefixes``), or by a dictation whose text ends
  with one of ``--end-words`` (« fin »).

Restart safety: ``state.json`` keeps the acknowledged cursor, the ids already
delivered, and the ids injected but not yet followed up. No clinical text is
stored in the state; a followup re-reads its dictations from the API.

Backends (``HarnessClient``):

* ``dryrun`` writes one JSONL line per call it would make; idempotent by
  dictation id even if the state file is lost.
* ``sdk`` drives the DeepSeek Harness Python SDK. The SDK exposes only
  ``session/prompt`` (= ``agent.followup``); it has no inject. Injects are
  therefore held in the state and sent with the next followup as one ``run()``.

The token comes from ``VOXLOCAL_API_TOKEN`` (never an argument). Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional, Protocol

TERMINAL_OK = ("completed", "completed_with_warning")
TERMINAL_SKIP = ("error", "interrupted")
IN_PROGRESS = ("recording", "processing")
MAX_DELIVERED = 1000
MAX_WAIT = 25.0
DEFAULT_PAUSE = 20.0
DEFAULT_END_WORDS = ("fin",)
DEFAULT_COMMAND_PREFIXES = ("agent", "commande")
STATE_VERSION = 1


# ---------------------------------------------------------------- formatting

def format_duration(seconds: float) -> str:
    total = max(0, round(float(seconds)))
    minutes, rest = divmod(total, 60)
    return f"{minutes} min {rest:02d} s" if minutes else f"{rest} s"


def dictation_message(record: dict[str, Any]) -> str:
    patient = record.get("patientContext") or "aucun"
    return (f"Nouvelle dictée {record['id']} ({format_duration(record.get('duration', 0))}) : "
            f"{record.get('finalTranscription', '')}\nPatient déclaré : {patient}")


def _words(text: str) -> list[str]:
    return re.findall(r"[\w’']+", text.lower())


def trigger_for(record: dict[str, Any], end_words: tuple[str, ...], command_prefixes: tuple[str, ...]) -> Optional[str]:
    """``command`` | ``fin`` | None (plain inject)."""
    words = _words(record.get("finalTranscription", ""))
    if not words:
        return None
    if words[0] in command_prefixes:
        return "command"
    if words[-1] in end_words:
        return "fin"
    return None


# ------------------------------------------------------------------ backends

@dataclass
class FeedItem:
    record: dict[str, Any]
    text: str


class HarnessClient(Protocol):
    """Where messages go. ``inject`` must not start a turn; ``followup`` does."""

    def inject(self, item: FeedItem) -> None: ...

    def followup(self, reason: str, items: list[FeedItem], trigger: Optional[FeedItem]) -> None: ...

    def already_delivered(self, dictation_id: str) -> bool: ...

    def close(self) -> None: ...


class DryRunClient:
    """Writes what it would send; dedupes by dictation id from its own file."""

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._seen: set[str] = set()
        if path.exists():
            for line in path.read_text(encoding="utf-8").splitlines():
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("dictationId"):
                    self._seen.add(entry["dictationId"])

    def _write(self, entry: dict[str, Any]) -> None:
        entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **entry}
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
            handle.flush(); os.fsync(handle.fileno())
        if entry.get("dictationId"):
            self._seen.add(entry["dictationId"])

    def already_delivered(self, dictation_id: str) -> bool:
        return dictation_id in self._seen

    def inject(self, item: FeedItem) -> None:
        self._write({"action": "inject", "dictationId": item.record["id"],
                     "patientContext": item.record.get("patientContext"), "text": item.text})

    def followup(self, reason: str, items: list[FeedItem], trigger: Optional[FeedItem]) -> None:
        entry: dict[str, Any] = {"action": "followup", "reason": reason,
                                 "withInjected": [i.record["id"] for i in items]}
        if trigger is not None:
            entry.update({"dictationId": trigger.record["id"],
                          "patientContext": trigger.record.get("patientContext"), "text": trigger.text})
        self._write(entry)

    def close(self) -> None:
        pass


PAUSE_PROMPT = ("Pause de dictée : aucune nouvelle dictée depuis {pause:g} s. Préparez les modifications "
                "à partir des dictées reçues, sans rien appliquer au dossier patient.")


class SdkClient:
    """DeepSeek Harness Python SDK (``deepseek_harness``). No inject exists in
    the SDK wire protocol, so injects are sent with the next followup."""

    def __init__(self, *, dsh_home: str, profile: str, session_id: str, provider: Optional[str], model: Optional[str], pause: float):
        try:
            from deepseek_harness import DeepSeekHarness  # type: ignore[import-not-found]
        except ImportError as exc:
            raise SystemExit("Backend sdk : le paquet Python deepseek-harness-sdk n'est pas installé "
                             "(il n'est pas publié sur PyPI au 25/09/2026 ; installez-le depuis la source dsh dans harness/.venv).") from exc
        options: dict[str, Any] = {"dsh_home": dsh_home, "profile": profile}
        if provider:
            options["provider"] = provider
        if model:
            options["model"] = model
        self.harness = DeepSeekHarness(**options)
        self.session_id, self.pause = session_id, pause

    def already_delivered(self, dictation_id: str) -> bool:
        return False  # The SDK has no idempotency key: the feeder state is the only guard.

    def inject(self, item: FeedItem) -> None:
        pass  # Held in the feeder state; delivered with the next followup.

    def followup(self, reason: str, items: list[FeedItem], trigger: Optional[FeedItem]) -> None:
        parts = [i.text for i in items]
        if trigger is not None:
            parts.append(trigger.text)
        if reason == "pause":
            parts.append(PAUSE_PROMPT.format(pause=self.pause))
        self.harness.run("\n\n".join(parts), session_id=self.session_id)

    def close(self) -> None:
        self.harness.close()


# ---------------------------------------------------------------------- API

class APIError(RuntimeError):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.status, self.code = status, code


def validate_api_url(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("--api-url : URL HTTP(S) sans identifiants, query ni fragment.")
    if parsed.scheme == "http" and parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("--api-url : HTTP est réservé à 127.0.0.1 ; utilisez HTTPS pour un autre hôte.")
    return value.rstrip("/")


class DictationAPI:
    def __init__(self, base_url: str, token: str):
        self.base, self.token = validate_api_url(base_url), token
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def _call(self, method: str, path: str, body: Any = None, timeout: float = 10) -> Any:
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=timeout) as response:
                envelope = json.loads(response.read())
        except urllib.error.HTTPError as exc:
            try:
                error = json.loads(exc.read()).get("error", {})
            except ValueError:
                error = {}
            raise APIError(exc.code, error.get("code", "http_error"), error.get("message", str(exc))) from None
        if not envelope.get("ok"):
            error = envelope.get("error", {})
            raise APIError(0, error.get("code", "invalid_response"), error.get("message", "réponse invalide"))
        return envelope["data"]

    def list(self, since: Optional[str], wait: float) -> list[dict[str, Any]]:
        query = {}
        if since:
            query["since"] = since
        if wait > 0:
            query["wait"] = f"{min(wait, MAX_WAIT):g}"
        path = "/v1/dictations" + ("?" + urllib.parse.urlencode(query) if query else "")
        return self._call("GET", path, timeout=min(wait, MAX_WAIT) + 10)["dictations"]

    def get(self, dictation_id: str) -> dict[str, Any]:
        return self._call("GET", "/v1/dictations/" + urllib.parse.quote(dictation_id, safe=""))

    def set_patient_context(self, value: Optional[str]) -> None:
        self._call("POST", "/v1/patient-context", {"patientContext": value})

    def inject_synthetic(self, text: str, duration: float) -> dict[str, Any]:
        return self._call("POST", "/v1/dictations", {"finalTranscription": text, "rawTranscription": text, "duration": duration})


# -------------------------------------------------------------------- state

@dataclass
class FeederState:
    cursor: Optional[str] = None
    delivered: list[str] = field(default_factory=list)
    pending: list[str] = field(default_factory=list)
    last_dictation_at: Optional[float] = None

    @classmethod
    def load(cls, path: Path) -> "FeederState":
        if not path.exists():
            return cls()
        raw = json.loads(path.read_text(encoding="utf-8"))
        if raw.get("version") != STATE_VERSION:
            raise SystemExit(f"{path} : version d'état inconnue ({raw.get('version')}).")
        return cls(raw.get("cursor"), list(raw.get("delivered", [])), list(raw.get("pending", [])), raw.get("lastDictationAt"))

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"version": STATE_VERSION, "cursor": self.cursor, "delivered": self.delivered[-MAX_DELIVERED:],
                   "pending": self.pending, "lastDictationAt": self.last_dictation_at}
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".state-", suffix=".json")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.flush(); os.fsync(handle.fileno())
        os.replace(tmp, path)


# ------------------------------------------------------------------- feeder

@dataclass
class FeederConfig:
    pause_seconds: float = DEFAULT_PAUSE
    end_words: tuple[str, ...] = DEFAULT_END_WORDS
    command_prefixes: tuple[str, ...] = DEFAULT_COMMAND_PREFIXES


class Feeder:
    def __init__(self, api: DictationAPI, client: HarnessClient, state_path: Path, config: FeederConfig,
                 clock: Callable[[], float] = time.time, log: Callable[[str], None] = lambda m: print(m, file=sys.stderr)):
        self.api, self.client, self.state_path, self.config = api, client, state_path, config
        self.state = FeederState.load(state_path)
        self.clock, self.log = clock, log

    def _is_delivered(self, dictation_id: str) -> bool:
        return dictation_id in self.state.delivered or self.client.already_delivered(dictation_id)

    def _items(self, ids: list[str]) -> list[FeedItem]:
        items = []
        for dictation_id in ids:
            try:
                record = self.api.get(dictation_id)
            except APIError as exc:
                self.log(f"dictée {dictation_id} introuvable pour la relance ({exc.code}) : ignorée")
                continue
            items.append(FeedItem(record, dictation_message(record)))
        return items

    def process(self, records: list[dict[str, Any]]) -> bool:
        """Deliver a batch (oldest first). Returns True if a record is still in
        progress, i.e. the cursor is held before it."""
        blocked = False
        for record in records:
            status = record.get("processingStatus")
            if status in IN_PROGRESS or status not in TERMINAL_OK + TERMINAL_SKIP:
                # Not finished yet: never move the cursor past it, or its final
                # text would be lost. Later finished records may still go out;
                # the delivered set keeps them from being sent twice.
                blocked = True
                continue
            dictation_id = record["id"]
            if status in TERMINAL_OK and not self._is_delivered(dictation_id):
                item = FeedItem(record, dictation_message(record))
                reason = trigger_for(record, self.config.end_words, self.config.command_prefixes)
                if reason is None:
                    self.client.inject(item)
                    self.state.pending.append(dictation_id)
                else:
                    self.client.followup(reason, self._items(self.state.pending), item)
                    self.state.pending = []
                self.state.delivered.append(dictation_id)
                self.state.last_dictation_at = self.clock()
                self.log(f"dictée {dictation_id} : {'inject' if reason is None else 'followup/' + reason}")
            if not blocked:
                self.state.cursor = dictation_id
            self.state.save(self.state_path)
        return blocked

    def pause_due(self) -> Optional[float]:
        """Seconds until the pause followup (<= 0: due), None if nothing pending."""
        if not self.state.pending or self.state.last_dictation_at is None:
            return None
        return self.state.last_dictation_at + self.config.pause_seconds - self.clock()

    def maybe_pause_followup(self) -> None:
        remaining = self.pause_due()
        if remaining is not None and remaining <= 0:
            self.client.followup("pause", self._items(self.state.pending), None)
            self.log(f"pause ≥ {self.config.pause_seconds:g} s : followup ({len(self.state.pending)} dictée(s))")
            self.state.pending = []
            self.state.save(self.state_path)

    def step(self, wait: float) -> bool:
        blocked = self.process(self.api.list(self.state.cursor, wait))
        self.maybe_pause_followup()
        return blocked

    def run_forever(self) -> None:
        blocked = False
        while True:
            if blocked:
                wait = 0.0
                time.sleep(1.0)
            else:
                remaining = self.pause_due()
                wait = MAX_WAIT if remaining is None else max(0.0, min(MAX_WAIT, remaining))
            try:
                blocked = self.step(wait)
            except (APIError, OSError) as exc:
                self.log(f"API VoxLocal indisponible ({exc}) : nouvel essai dans 5 s")
                time.sleep(5)


def read_seed(path: Path) -> str:
    lines = [line for line in path.read_text(encoding="utf-8").splitlines() if not line.lstrip().startswith("#")]
    text = "\n".join(lines).strip()
    if not text:
        raise SystemExit(f"{path} : fichier de dictée vide.")
    return text


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="dictation_feeder", description="Transmet les dictées VoxLocal terminées à l'agent dsh.")
    parser.add_argument("--api-url", default=os.environ.get("VOXLOCAL_API_URL", "http://127.0.0.1:47367"))
    parser.add_argument("--state-file", type=Path, default=Path(__file__).resolve().parent / "state" / "state.json")
    parser.add_argument("--once", action="store_true", help="un seul passage sans attente, puis sortie")
    parser.add_argument("--backend", choices=("sdk", "dryrun"), default="dryrun")
    parser.add_argument("--dryrun-file", type=Path, default=None, help="JSONL du backend dryrun (défaut : à côté du state)")
    parser.add_argument("--seed-file", type=Path, help="texte synthétique injecté comme dictée (API agent en --mock uniquement)")
    parser.add_argument("--seed-duration", type=float, default=300.0)
    parser.add_argument("--patient-context", help="patient déclaré avant l'injection du seed (synthétique)")
    parser.add_argument("--pause-seconds", type=float, default=DEFAULT_PAUSE)
    parser.add_argument("--end-words", default=",".join(DEFAULT_END_WORDS))
    parser.add_argument("--command-prefixes", default=",".join(DEFAULT_COMMAND_PREFIXES))
    parser.add_argument("--dsh-home", default=os.environ.get("DSH_HOME"))
    parser.add_argument("--dsh-profile", default="sdk")
    parser.add_argument("--session-id", default="voxlocal-scribe")
    parser.add_argument("--provider")
    parser.add_argument("--model")
    args = parser.parse_args(argv)
    token = os.environ.get("VOXLOCAL_API_TOKEN", "")
    if not token:
        parser.error("VOXLOCAL_API_TOKEN requis (Réglages › iPhone › Harness local › Copier) ; jamais en argument.")
    try:
        api = DictationAPI(args.api_url, token)
    except ValueError as exc:
        parser.error(str(exc))
    split = lambda value: tuple(w.strip().lower() for w in value.split(",") if w.strip())
    config = FeederConfig(args.pause_seconds, split(args.end_words), split(args.command_prefixes))
    if args.backend == "sdk":
        if not args.dsh_home:
            parser.error("--dsh-home (ou DSH_HOME) est obligatoire pour le backend sdk.")
        client: HarnessClient = SdkClient(dsh_home=args.dsh_home, profile=args.dsh_profile, session_id=args.session_id,
                                          provider=args.provider, model=args.model, pause=config.pause_seconds)
    else:
        client = DryRunClient(args.dryrun_file or args.state_file.with_name("dryrun.jsonl"))
    try:
        if args.patient_context is not None:
            api.set_patient_context(args.patient_context or None)
        if args.seed_file:
            seeded = api.inject_synthetic(read_seed(args.seed_file), args.seed_duration)
            print(f"dictée synthétique injectée : {seeded['id']}", file=sys.stderr)
        feeder = Feeder(api, client, args.state_file, config)
        if args.once:
            feeder.step(0.0)
        else:
            feeder.run_forever()
    except APIError as exc:
        print(f"Erreur API VoxLocal : {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        pass
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
