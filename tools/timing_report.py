#!/Users/atman/Dropbox/deck/m/skills/.venv/bin/python
"""Summarize elapsed_ns timings from lsp_zitron runtime logs."""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path


DEFAULT_LOG = Path.home() / "Library/Caches/lsp_zitron/lsp_zitron.log"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG)
    parser.add_argument("--all-sessions", action="store_true")
    parser.add_argument("--include-replay-sessions", action="store_true")
    parser.add_argument("--format", choices=("tsv", "json"), default="tsv")
    parser.add_argument("--raw", action="store_true")
    parser.add_argument("--no-split-first", action="store_true")
    args = parser.parse_args()

    lines = args.log.read_text(errors="replace").splitlines()
    if not args.all_sessions:
        start, end = latest_real_session_range(lines, args.include_replay_sessions)
        lines = lines[start:end]

    rows = timing_rows(lines)
    if args.raw:
        emit_raw(rows, args.format)
    else:
        emit_summary(rows, args.format, split_first=not args.no_split_first)
    return 0


def latest_real_session_range(lines: list[str], include_replay_sessions: bool) -> tuple[int, int]:
    ranges = session_ranges(lines)
    if not ranges:
        return 0, len(lines)
    if include_replay_sessions:
        return ranges[-1]
    for start, end in reversed(ranges):
        if not any("lsp_zitron_replay_client" in line for line in lines[start:end]):
            return start, end
    return ranges[-1]


def session_ranges(lines: list[str]) -> list[tuple[int, int]]:
    starts = [index for index, line in enumerate(lines) if "Log File:" in line]
    if not starts:
        return []
    return [
        (start, starts[offset + 1] if offset + 1 < len(starts) else len(lines))
        for offset, start in enumerate(starts)
    ]


def timing_rows(lines: list[str]) -> list[dict]:
    rows = []
    occurrences: dict[str, int] = defaultdict(int)
    for line in lines:
        match = re.search(r"elapsed_ns=(\d+)", line)
        if not match:
            continue
        metric = normalize_metric(line)
        occurrences[metric] += 1
        rows.append(
            {
                "metric": metric,
                "occurrence": occurrences[metric],
                "phase": "first" if occurrences[metric] == 1 else "repeat",
                "elapsed_ns": int(match.group(1)),
                "elapsed_ms": int(match.group(1)) / 1_000_000,
            }
        )
    return rows


def normalize_metric(line: str) -> str:
    message = line.split("): ", 1)[-1]
    message = message.split(" elapsed_ns=", 1)[0]
    route = field(message, "route")
    reason = field(message, "reason")
    for marker in (" uri=", " id=", " client=", " version=", " range=", " position=", " previous=", " zls_tokens="):
        if marker in message:
            message = message.split(marker, 1)[0]
            break
    if route:
        message += f" route={route}"
    if reason:
        message += f" reason={reason}"
    return message


def field(message: str, name: str) -> str | None:
    match = re.search(rf"\b{name}=([^ ]+)", message)
    return match.group(1) if match else None


def emit_raw(rows: list[dict], fmt: str) -> None:
    if fmt == "json":
        json.dump(rows, sys.stdout, indent=2)
        print()
        return
    print("metric\tphase\toccurrence\telapsed_ms\telapsed_ns")
    for row in rows:
        print(
            f"{row['metric']}\t{row['phase']}\t{row['occurrence']}\t"
            f"{row['elapsed_ms']:.6f}\t{row['elapsed_ns']}"
        )


def emit_summary(rows: list[dict], fmt: str, split_first: bool) -> None:
    grouped: dict[tuple[str, str], list[float]] = defaultdict(list)
    for row in rows:
        phase = row["phase"] if split_first else "all"
        grouped[(row["metric"], phase)].append(row["elapsed_ms"])

    summaries = []
    for (metric, phase), values in sorted(grouped.items()):
        values.sort()
        summaries.append(
            {
                "metric": metric,
                "phase": phase,
                "count": len(values),
                "min_ms": values[0],
                "p50_ms": percentile(values, 50),
                "p90_ms": percentile(values, 90),
                "p95_ms": percentile(values, 95),
                "max_ms": values[-1],
                "mean_ms": statistics.fmean(values),
            }
        )

    if fmt == "json":
        json.dump(summaries, sys.stdout, indent=2)
        print()
        return

    print("metric\tphase\tcount\tmin_ms\tp50_ms\tp90_ms\tp95_ms\tmax_ms\tmean_ms")
    for row in summaries:
        print(
            f"{row['metric']}\t{row['phase']}\t{row['count']}\t"
            f"{row['min_ms']:.6f}\t{row['p50_ms']:.6f}\t"
            f"{row['p90_ms']:.6f}\t{row['p95_ms']:.6f}\t"
            f"{row['max_ms']:.6f}\t{row['mean_ms']:.6f}"
        )


def percentile(values: list[float], pct: int) -> float:
    if len(values) == 1:
        return values[0]
    rank = (len(values) - 1) * pct / 100
    low = int(rank)
    high = min(low + 1, len(values) - 1)
    fraction = rank - low
    return values[low] * (1 - fraction) + values[high] * fraction


if __name__ == "__main__":
    raise SystemExit(main())
