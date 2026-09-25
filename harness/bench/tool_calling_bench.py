#!/usr/bin/env python3
"""Tool-calling benchmark for the VoxLocal scribe model behind an OpenAI-compatible endpoint.

Sends a fixed set of French clinical prompts with the three scribe tool schemas
(dictation.get, patient.read, record.draft_edit) to ``POST {base}/chat/completions``
and reports, per run:

* tool-call validity rate: a tool call is present, names a declared tool, its
  arguments parse as JSON and satisfy the schema's required fields and types;
* expected-tool rate: the call names the tool the prompt asks for, valid or not;
* SOAP draft completeness for record.draft_edit calls (four sections, each with
  proposed text and at least one source quote);
* p50/p95 end-to-end latency and completion tokens/s.

Stdlib only (Python 3.11+). The bearer token is read from the environment,
never from the command line, so it does not land in shell history or in the report.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import platform
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# OpenAI function names must match ^[a-zA-Z0-9_-]{1,64}$, so the dotted logical
# names used by the harness travel on the wire with underscores.
WIRE_NAMES = {
    "dictation.get": "dictation_get",
    "patient.read": "patient_read",
    "record.draft_edit": "record_draft_edit",
}
LOGICAL_NAMES = {wire: logical for logical, wire in WIRE_NAMES.items()}

SOAP_SECTION = {
    "type": "object",
    "properties": {
        "proposed_text": {"type": "string", "description": "Texte proposé pour la section, en français clinique."},
        "source_quotes": {
            "type": "array",
            "items": {"type": "string"},
            "description": "Citations exactes de la dictée qui justifient le texte proposé.",
        },
    },
    "required": ["proposed_text", "source_quotes"],
}

TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": WIRE_NAMES["dictation.get"],
            "description": "Récupère le texte nettoyé d'une dictée du médecin. Utiliser 'latest' pour la plus récente.",
            "parameters": {
                "type": "object",
                "properties": {
                    "dictation_id": {"type": "string", "description": "Identifiant de la dictée, ou 'latest'."},
                },
                "required": ["dictation_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": WIRE_NAMES["patient.read"],
            "description": "Lit le dossier du patient (identité, séjour en cours, documents classés au séjour). Lecture seule.",
            "parameters": {
                "type": "object",
                "properties": {
                    "patient_id": {"type": "string", "description": "Identifiant du patient, par exemple P-001."},
                    "sections": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Parties à lire (identite, sejour, documents). Toutes si absent.",
                    },
                },
                "required": ["patient_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": WIRE_NAMES["record.draft_edit"],
            "description": (
                "Prépare un brouillon de modification du dossier, section par section (SOAP), "
                "avec les citations de la dictée. N'écrit rien dans le dossier : l'application "
                "exige un feu vert explicite du médecin."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "patient_id": {"type": "string"},
                    "document_id": {"type": "string", "description": "Document classé au séjour à modifier."},
                    "sections": {
                        "type": "object",
                        "properties": {
                            "subjective": SOAP_SECTION,
                            "objective": SOAP_SECTION,
                            "assessment": SOAP_SECTION,
                            "plan": SOAP_SECTION,
                        },
                        "required": ["subjective", "objective", "assessment", "plan"],
                    },
                },
                "required": ["patient_id", "document_id", "sections"],
            },
        },
    },
]
SCHEMAS = {tool["function"]["name"]: tool["function"]["parameters"] for tool in TOOLS}

SYSTEM_PROMPT = (
    "Tu es l'assistant de rédaction clinique d'un médecin urgentiste. Tu disposes d'outils. "
    "Réponds à chaque demande en appelant exactement l'outil approprié, avec des arguments complets. "
    "Tu prépares des brouillons ; tu n'écris jamais directement dans le dossier."
)

# Synthetic dictation (no PHI): copied from portail-med-api/samples/transcript_entorse.txt.
ENTORSE = (
    "Alors patient jeune, la vingtaine, se présente aux urgences pour une douleur de la cheville droite "
    "suite à un traumatisme en inversion ce matin en jouant au foot. Pas de craquement entendu. A pu poser "
    "le pied mais avec douleur. Pas d'antécédent particulier, pas de traitement habituel, pas d'allergie connue. "
    "A l'examen, oedème modéré de la malléole externe droite, douleur à la palpation du ligament talo-fibulaire "
    "antérieur. Pas de douleur osseuse à la palpation de la malléole postérieure, pas de douleur base du "
    "cinquième métatarsien. Appui possible sur quatre pas. Critères d'Ottawa négatifs. Reste de l'examen sans "
    "particularité. Donc entorse de cheville droite stade deux probable, critères d'Ottawa négatifs donc pas "
    "d'indication de radiographie. Je mets en place le protocole entorse: repos, glace, compression par bandage, "
    "élévation. Antalgie par paracétamol et AINS si pas de contre indication. Attelle de cheville pour deux "
    "semaines. Arrêt de travail trois jours. Contrôle chez le médecin traitant dans une semaine, reconsulter si "
    "aggravation."
)

PROMPTS: list[dict[str, str]] = [
    {"id": "dictation-latest", "expected": "dictation.get",
     "text": "Récupère ma dernière dictée."},
    {"id": "dictation-by-id", "expected": "dictation.get",
     "text": "Montre-moi la dictée D-2026-0925-0007."},
    {"id": "patient-read", "expected": "patient.read",
     "text": "Ouvre le dossier du patient P-001, je veux voir son séjour en cours."},
    {"id": "patient-read-docs", "expected": "patient.read",
     "text": "Quels documents sont classés au séjour du patient P-002 ?"},
    {"id": "draft-entorse", "expected": "record.draft_edit",
     "text": (
         "Voici ma dictée pour le patient P-001, document DOC-URG-0001 (note d'urgence). "
         "Prépare le brouillon SOAP des quatre sections avec les citations exactes de la dictée.\n\n"
         f"Dictée : « {ENTORSE} »"
     )},
]


def percentile(values: list[float], pct: float) -> float | None:
    """Nearest-rank percentile; None on an empty series."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(pct / 100 * len(ordered)))
    return ordered[rank - 1]


def schema_errors(value: Any, schema: dict[str, Any], path: str = "$") -> list[str]:
    """Check the JSON-Schema subset the tool schemas use: type, required, properties, items."""
    errors: list[str] = []
    kind = schema.get("type")
    checks = {"object": dict, "array": list, "string": str}
    if kind in checks and not isinstance(value, checks[kind]):
        return [f"{path}: expected {kind}"]
    if kind == "string" and not value.strip():
        return [f"{path}: empty string"]
    if kind == "object":
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}.{key}: missing")
        for key, sub in schema.get("properties", {}).items():
            if key in value:
                errors.extend(schema_errors(value[key], sub, f"{path}.{key}"))
    if kind == "array" and "items" in schema:
        for index, item in enumerate(value):
            errors.extend(schema_errors(item, schema["items"], f"{path}[{index}]"))
    return errors


def soap_complete(args: dict[str, Any]) -> bool:
    sections = args.get("sections")
    if not isinstance(sections, dict):
        return False
    for name in ("subjective", "objective", "assessment", "plan"):
        section = sections.get(name)
        if not isinstance(section, dict):
            return False
        text, quotes = section.get("proposed_text"), section.get("source_quotes")
        if not (isinstance(text, str) and text.strip()):
            return False
        if not (isinstance(quotes, list) and any(isinstance(q, str) and q.strip() for q in quotes)):
            return False
    return True


def grade(message: dict[str, Any], expected: str) -> dict[str, Any]:
    """Grade the first tool call of an assistant message."""
    calls = message.get("tool_calls") or []
    result: dict[str, Any] = {"tool_call": bool(calls), "valid": False, "expected_tool": False,
                              "tool": None, "errors": []}
    if not calls:
        result["errors"].append("no tool call")
        return result
    function = calls[0].get("function") or {}
    wire = function.get("name")
    result["tool"] = LOGICAL_NAMES.get(wire, wire)
    result["expected_tool"] = result["tool"] == expected
    if wire not in SCHEMAS:
        result["errors"].append(f"undeclared tool {wire!r}")
        return result
    raw = function.get("arguments")
    try:
        args = json.loads(raw) if isinstance(raw, str) else raw
    except json.JSONDecodeError as error:
        result["errors"].append(f"arguments are not JSON: {error.msg}")
        return result
    if not isinstance(args, dict):
        result["errors"].append("arguments are not a JSON object")
        return result
    errors = schema_errors(args, SCHEMAS[wire])
    result["errors"].extend(errors)
    result["valid"] = not errors
    if result["tool"] == "record.draft_edit":
        result["soap_complete"] = soap_complete(args)
    return result


def call(base_url: str, token: str, body: dict[str, Any], timeout: float) -> tuple[dict[str, Any], float]:
    request = urllib.request.Request(
        base_url.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.load(response)
    return payload, time.perf_counter() - started


def run(options: argparse.Namespace, token: str) -> dict[str, Any]:
    samples: list[dict[str, Any]] = []
    for repeat in range(options.repeats):
        for prompt in PROMPTS:
            body = {
                "model": options.model,
                "messages": [{"role": "system", "content": SYSTEM_PROMPT},
                             {"role": "user", "content": prompt["text"]}],
                "tools": TOOLS,
                "tool_choice": "auto",
                "temperature": options.temperature,
                "max_tokens": options.max_tokens,
            }
            sample: dict[str, Any] = {"prompt": prompt["id"], "repeat": repeat, "expected": prompt["expected"]}
            try:
                payload, latency = call(options.base_url, token, body, options.timeout)
            except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as error:
                detail = error.read().decode(errors="replace")[:300] if isinstance(error, urllib.error.HTTPError) else ""
                sample.update(ok=False, error=f"{type(error).__name__}: {error} {detail}".strip())
                samples.append(sample)
                print(f"[{repeat}] {prompt['id']}: request failed: {sample['error']}", file=sys.stderr)
                continue
            usage = payload.get("usage") or {}
            completion_tokens = usage.get("completion_tokens")
            choice = (payload.get("choices") or [{}])[0]
            message = choice.get("message") or {}
            sample.update(ok=True, latency_s=round(latency, 4), completion_tokens=completion_tokens,
                          finish_reason=choice.get("finish_reason"),
                          prompt_tokens=usage.get("prompt_tokens"),
                          tokens_per_s=round(completion_tokens / latency, 2) if completion_tokens and latency > 0 else None,
                          **grade(message, prompt["expected"]))
            samples.append(sample)
            print(f"[{repeat}] {prompt['id']}: tool={sample['tool']} valid={sample['valid']} "
                  f"latency={latency:.2f}s errors={sample['errors'][:2]}", file=sys.stderr)
    return summarize(samples)


def summarize(samples: list[dict[str, Any]]) -> dict[str, Any]:
    answered = [s for s in samples if s.get("ok")]
    latencies = [s["latency_s"] for s in answered]
    speeds = [s["tokens_per_s"] for s in answered if s.get("tokens_per_s")]
    drafts = [s for s in answered if s.get("tool") == "record.draft_edit"]
    total = len(samples)

    def rate(count: int, over: int) -> float | None:
        return round(count / over, 4) if over else None

    return {
        "requests": total,
        "request_errors": total - len(answered),
        "tool_call_rate": rate(sum(s["tool_call"] for s in answered), total),
        "tool_call_validity_rate": rate(sum(s["valid"] for s in answered), total),
        "expected_tool_rate": rate(sum(s["expected_tool"] for s in answered), total),
        "soap_draft_complete_rate": rate(sum(bool(s.get("soap_complete")) for s in drafts), len(drafts)),
        "latency_s": {"p50": percentile(latencies, 50), "p95": percentile(latencies, 95)},
        "completion_tokens_per_s": {"p50": percentile(speeds, 50), "p95": percentile(speeds, 95)},
        "samples": samples,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", default=os.environ.get("VOXLOCAL_LLM_URL"),
                        help="OpenAI-compatible base URL ending in /v1 (default: $VOXLOCAL_LLM_URL)")
    parser.add_argument("--token-env", default="VOXLOCAL_LLM_TOKEN",
                        help="environment variable holding the bearer token (default: VOXLOCAL_LLM_TOKEN)")
    parser.add_argument("--model", default="qwen3.8-27b", help="model id sent in the request")
    parser.add_argument("--repeats", type=int, default=4, help="passes over the prompt set")
    parser.add_argument("--max-tokens", type=int, default=2048)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--timeout", type=float, default=180.0, help="per-request timeout in seconds")
    parser.add_argument("--note", default="", help="free text stored in the report")
    parser.add_argument("--out", type=Path, help="write the JSON report here (default: stdout)")
    options = parser.parse_args()
    if not options.base_url:
        parser.error("--base-url or VOXLOCAL_LLM_URL is required")
    token = os.environ.get(options.token_env)
    if not token:
        parser.error(f"set {options.token_env} to the endpoint's bearer token")

    report = {
        "benchmark": "voxlocal-scribe-tool-calling",
        "version": 1,
        "started_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "endpoint": options.base_url,
        "model": options.model,
        "note": options.note,
        "config": {"repeats": options.repeats, "prompts": [p["id"] for p in PROMPTS],
                   "tools": list(WIRE_NAMES), "max_tokens": options.max_tokens,
                   "temperature": options.temperature, "tool_choice": "auto"},
        "host": {"python": platform.python_version(), "platform": platform.platform()},
    }
    report.update(run(options, token))
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if options.out:
        options.out.parent.mkdir(parents=True, exist_ok=True)
        options.out.write_text(text, encoding="utf-8")
        print(f"wrote {options.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0 if report["request_errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
