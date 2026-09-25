#!/usr/bin/env python3
"""Render a benchmark.py JSON result as a Markdown table for the docs.

    python3 cloud/runpod/bench-report.py docs/superpowers/evidence/<file>.json
    python3 cloud/runpod/benchmark.py ... | python3 cloud/runpod/bench-report.py

Only the numeric fields of the benchmark JSON are rendered (the benchmark keeps
no response text). Exit status 2 means the input is not a benchmark result.
"""
from __future__ import annotations

import argparse
import json
import sys

SUPPORTED = {"voxlocal-runpod-synthetic-v2"}


def _cell(value: object) -> str:
    if value is None:
        return "–"
    if isinstance(value, float):
        return f"{value:.1f}" if value >= 10 else f"{value:.2f}"
    return str(value).replace("|", "\\|")


def render(result: dict) -> str:
    if result.get("benchmark") not in SUPPORTED:
        raise ValueError(f"unsupported benchmark id: {result.get('benchmark')!r}")
    lines = [
        f"Benchmark `{result['benchmark']}`, {result.get('started_at', 'unknown date')}, "
        f"{result.get('iterations', 1)} iteration(s) per operation, "
        f"overall **{'PASS' if result.get('ok') else 'FAIL'}**.",
        "",
    ]
    note = result.get("note")
    if note:
        lines += [f"> {note}", ""]
    lines += [
        "| Service | Operation | OK | p50 ms | p95 ms | mean ms | tokens/s p50 | tokens/s p95 |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for service in result.get("services", []):
        for op in service.get("operations", []):
            latency = op.get("latency_ms") or {}
            rate = op.get("tokens_per_second") or {}
            lines.append("| " + " | ".join([
                _cell(service.get("name")),
                _cell(op.get("operation")),
                f"{op.get('ok_count', 0)}/{op.get('iterations', 0)}",
                _cell(latency.get("p50")),
                _cell(latency.get("p95")),
                _cell(latency.get("mean")),
                _cell(rate.get("p50")),
                _cell(rate.get("p95")),
            ]) + " |")
    lines += [
        "",
        "Latency is the full HTTP request measured by the client. Percentiles are "
        "nearest-rank over successful samples. tokens/s = `usage.completion_tokens` "
        "divided by request latency (prefill included).",
    ]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("json_file", nargs="?", help="benchmark JSON (default: stdin)")
    args = parser.parse_args(argv)
    try:
        if args.json_file:
            with open(args.json_file, encoding="utf-8") as handle:
                result = json.load(handle)
        else:
            result = json.load(sys.stdin)
        if not isinstance(result, dict):
            raise ValueError("benchmark JSON must be an object")
        sys.stdout.write(render(result))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"bench-report: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
