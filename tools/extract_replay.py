#!/Users/atman/Dropbox/deck/m/skills/.venv/bin/python
"""Extract a replayable action stream from the latest zitron-ls log session."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse


DEFAULT_LOG = Path.home() / "Library/Caches/zitron-ls/zitron-ls.log"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--all-sessions", action="store_true")
    parser.add_argument("--include-replay-sessions", action="store_true")
    args = parser.parse_args()

    lines = args.log.read_text(errors="replace").splitlines()
    if not args.all_sessions:
        start, end = latest_real_session_range(lines, args.include_replay_sessions)
        lines = lines[start:end]

    actions, stats = extract_actions(lines)
    if args.out is not None:
        args.out.parent.mkdir(parents=True, exist_ok=True)
    out = sys.stdout if args.out is None else args.out.open("w")
    try:
        for action in actions:
            print(json.dumps(action, separators=(",", ":")), file=out)
    finally:
        if args.out is not None:
            out.close()

    print(
        "extract_replay: "
        f"actions={len(actions)} requests={stats['request']} "
        f"notifications={stats['notification']} comments={stats['comment']} "
        f"unreplayable={stats['unreplayable']}",
        file=sys.stderr,
    )
    return 0


def latest_real_session_range(lines: list[str], include_replay_sessions: bool) -> tuple[int, int]:
    ranges = session_ranges(lines)
    if not ranges:
        return 0, len(lines)
    if include_replay_sessions:
        return ranges[-1]
    for start, end in reversed(ranges):
        if not any("zitron-ls-replay-client" in line for line in lines[start:end]):
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


def extract_actions(lines: list[str]) -> tuple[list[dict], dict[str, int]]:
    actions: list[dict] = []
    stats = {"request": 0, "notification": 0, "comment": 0, "unreplayable": 0}
    opened: set[str] = set()
    saw_initialize = False
    next_id = 1

    for line in lines:
        if "LSP <- initialize" in line:
            if not saw_initialize:
                actions.append(initialize_action(next_id))
                stats["request"] += 1
                next_id += 1
                saw_initialize = True
            continue
        if "LSP <- initialized" in line:
            actions.append({"kind": "notification", "method": "initialized", "params": {}})
            stats["notification"] += 1
            continue
        if "LSP <- textDocument/didOpen" in line:
            uri = field(line, "uri")
            version = int(field(line, "version", "0"))
            if uri and uri not in opened:
                actions.append(did_open_action(uri, version))
                opened.add(uri)
                stats["notification"] += 1
            continue
        if "LSP <- textDocument/didChange" in line:
            actions.append(comment("unreplayable didChange: log has count but not edit payload", line))
            stats["comment"] += 1
            stats["unreplayable"] += 1
            continue

        parsed = request_from_log_line(line, next_id)
        if parsed is None:
            continue
        action, next_id = parsed
        actions.append(action)
        stats["request"] += 1

    if actions and not any(action.get("method") == "shutdown" for action in actions):
        actions.append({"kind": "request", "id": next_id, "method": "shutdown", "params": None})
        stats["request"] += 1
        next_id += 1
        actions.append({"kind": "notification", "method": "exit", "params": None})
        stats["notification"] += 1

    return actions, stats


def request_from_log_line(line: str, next_id: int) -> tuple[dict, int] | None:
    marker = "LSP <- textDocument/"
    if marker not in line:
        if "LSP <- shutdown" in line:
            return {"kind": "request", "id": next_id, "method": "shutdown", "params": None}, next_id + 1
        return None

    method_tail = line.split(marker, 1)[1].split(None, 1)[0]
    method = f"textDocument/{method_tail}"
    uri = field(line, "uri")
    if not uri:
        return None

    params: dict | None
    if method == "textDocument/semanticTokens/full":
        params = {"textDocument": {"uri": uri}}
    elif method == "textDocument/semanticTokens/full/delta":
        previous = field(line, "previous")
        params = {"textDocument": {"uri": uri}, "previousResultId": previous or ""}
    elif method == "textDocument/semanticTokens/range":
        rng = parse_range(line)
        if rng is None:
            return None
        params = {"textDocument": {"uri": uri}, "range": rng}
    elif method in POSITION_METHODS:
        position = parse_position(line)
        if position is None:
            return None
        params = {"textDocument": {"uri": uri}, "position": position}
        if method == "textDocument/references":
            params["context"] = {"includeDeclaration": field(line, "include_declaration") == "true"}
    elif method == "textDocument/documentSymbol":
        params = {"textDocument": {"uri": uri}}
    elif method == "textDocument/rename":
        position = parse_position(line)
        if position is None:
            return None
        params = {"textDocument": {"uri": uri}, "position": position, "newName": "replay_name"}
    else:
        return None

    return {"kind": "request", "id": next_id, "method": method, "params": params}, next_id + 1


POSITION_METHODS = {
    "textDocument/completion",
    "textDocument/declaration",
    "textDocument/definition",
    "textDocument/documentHighlight",
    "textDocument/hover",
    "textDocument/references",
    "textDocument/signatureHelp",
}


def initialize_action(request_id: int) -> dict:
    return {
        "kind": "request",
        "id": request_id,
        "method": "initialize",
        "params": {
            "processId": None,
            "clientInfo": {"name": "zitron-ls-replay-client"},
            "capabilities": {
                "general": {"positionEncodings": ["utf-8", "utf-16"]},
                "workspace": {"semanticTokens": {"refreshSupport": True}},
                "window": {"workDoneProgress": True},
            },
        },
    }


def did_open_action(uri: str, version: int) -> dict:
    text = ""
    path = uri_to_path(uri)
    if path is not None and path.exists():
        text = path.read_text(errors="replace")
    return {
        "kind": "notification",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "zitron",
                "version": version,
                "text": text,
            }
        },
    }


def comment(reason: str, line: str) -> dict:
    return {"kind": "comment", "reason": reason, "source": line}


def field(line: str, name: str, default: str | None = None) -> str | None:
    match = re.search(rf"\b{name}=([^ ]+)", line)
    return match.group(1) if match else default


def parse_position(line: str) -> dict | None:
    match = re.search(r"position=\.?\{ \.line = (\d+), \.character = (\d+) \}", line)
    if not match:
        return None
    return {"line": int(match.group(1)), "character": int(match.group(2))}


def parse_range(line: str) -> dict | None:
    nums = [int(value) for value in re.findall(r"\.line = (\d+)|\.character = (\d+)", line) for value in value if value]
    if len(nums) < 4:
        return None
    return {
        "start": {"line": nums[0], "character": nums[1]},
        "end": {"line": nums[2], "character": nums[3]},
    }


def uri_to_path(uri: str) -> Path | None:
    parsed = urlparse(uri)
    if parsed.scheme != "file":
        return None
    return Path(unquote(parsed.path))


if __name__ == "__main__":
    raise SystemExit(main())
