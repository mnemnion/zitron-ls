#!/Users/atman/Dropbox/deck/m/skills/.venv/bin/python
"""Replay extracted JSON-RPC client actions against zitron-ls."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

DEFAULT_LOG = Path.home() / "Library/Caches/zitron-ls/zitron-ls.log"


class RpcReader(threading.Thread):
    def __init__(self, proc: subprocess.Popen[bytes], write_lock: threading.Lock, pending_ids: set[int]):
        super().__init__(daemon=True)
        self.proc = proc
        self.write_lock = write_lock
        self.pending_ids = pending_ids
        self.completed_ids: set[int] = set()
        self.state_lock = threading.Lock()
        self.responses = 0
        self.duplicate_responses = 0
        self.unexpected_responses = 0
        self.unexpected_response_messages: list[dict[str, Any]] = []
        self.server_requests = 0
        self.notifications = 0
        self.errors: list[str] = []
        self.done = False

    def run(self) -> None:
        try:
            while not self.done:
                message = read_message(self.proc.stdout)
                if message is None:
                    return
                self.handle(message)
        except Exception as exc:  # noqa: BLE001 - diagnostic tool, report and stop.
            self.errors.append(str(exc))

    def handle(self, message: dict[str, Any]) -> None:
        if "id" in message and "method" not in message:
            self.record_response(message)
            return
        if "method" in message and "id" in message:
            self.server_requests += 1
            write_message(
                self.proc.stdin,
                {"jsonrpc": "2.0", "id": message["id"], "result": None},
                self.write_lock,
            )
            return
        if "method" in message:
            self.notifications += 1

    def record_response(self, message: dict[str, Any]) -> None:
        request_id = message.get("id")
        if not isinstance(request_id, int):
            self.unexpected_responses += 1
            self.unexpected_response_messages.append(compact_response(message))
            return
        with self.state_lock:
            if request_id in self.pending_ids:
                self.pending_ids.remove(request_id)
                self.completed_ids.add(request_id)
                self.responses += 1
            elif request_id in self.completed_ids:
                self.duplicate_responses += 1
            else:
                self.unexpected_responses += 1
                self.unexpected_response_messages.append(compact_response(message))

    def pending_count(self) -> int:
        with self.state_lock:
            return len(self.pending_ids)

    def expect_response(self, request_id: int) -> None:
        with self.state_lock:
            self.pending_ids.add(request_id)

    def completed(self, request_id: int) -> bool:
        with self.state_lock:
            return request_id in self.completed_ids


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--actions", type=Path, default=Path("zig-out/replay/latest.jsonl"))
    parser.add_argument("--server", default="zig-out/bin/zitron-ls")
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG)
    parser.add_argument("--delay-ms", type=float, default=0.0)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--no-auto-shutdown", action="store_true")
    parser.add_argument(
        "--semantic-update-probe",
        dest="semantic_update_probe",
        action="store_true",
        default=True,
        help="warm semantic tokens, apply an in-memory full-text edit, and request full tokens twice",
    )
    parser.add_argument(
        "--no-semantic-update-probe",
        dest="semantic_update_probe",
        action="store_false",
        help="replay without the semantic update timing probe",
    )
    parser.add_argument(
        "--semantic-update-max-ms",
        type=float,
        default=500.0,
        help="fail if a probed semantic current update exceeds this elapsed time",
    )
    args = parser.parse_args()

    actions = load_actions(args.actions)
    pending_ids = expected_request_ids(actions, args.no_auto_shutdown)
    next_probe_id = max(pending_ids | {900000}) + 1
    proc = subprocess.Popen(
        [args.server],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=None,
    )
    write_lock = threading.Lock()
    reader = RpcReader(proc, write_lock, pending_ids)
    reader.start()

    stats = {"request": 0, "notification": 0, "comment": 0}
    documents: dict[str, dict[str, Any]] = {}
    sent_shutdown = False
    ran_semantic_probe = False
    start = time.monotonic()
    try:
        for action in actions:
            kind = action.get("kind")
            if kind == "comment":
                stats["comment"] += 1
                continue
            if args.semantic_update_probe and not ran_semantic_probe and is_shutdown_action(action):
                next_probe_id = run_semantic_update_probe(
                    proc,
                    write_lock,
                    reader,
                    documents,
                    next_probe_id,
                    args.timeout,
                    stats,
                )
                ran_semantic_probe = True
            if kind == "request":
                stats["request"] += 1
                if action.get("method") == "shutdown":
                    sent_shutdown = True
                write_message(
                    proc.stdin,
                    request_message(action["id"], action["method"], action.get("params")),
                    write_lock,
                )
            elif kind == "notification":
                stats["notification"] += 1
                if action.get("method") == "exit":
                    sent_shutdown = True
                write_message(
                    proc.stdin,
                    notification_message(action["method"], action.get("params")),
                    write_lock,
                )
                record_document_notification(documents, action)
            else:
                raise ValueError(f"unknown action kind: {kind!r}")
            if args.delay_ms:
                time.sleep(args.delay_ms / 1000.0)

        if args.semantic_update_probe and not ran_semantic_probe:
            next_probe_id = run_semantic_update_probe(
                proc,
                write_lock,
                reader,
                documents,
                next_probe_id,
                args.timeout,
                stats,
            )
            ran_semantic_probe = True

        if not args.no_auto_shutdown and not sent_shutdown:
            stats["request"] += 1
            write_message(proc.stdin, request_message(900000, "shutdown", None), write_lock)
            stats["notification"] += 1
            write_message(proc.stdin, notification_message("exit", None), write_lock)

        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline and reader.pending_count() > 0:
            if proc.poll() is not None:
                break
            time.sleep(0.01)
    finally:
        reader.done = True
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)

    elapsed = time.monotonic() - start
    print(
        "replay_client: "
        f"sent_requests={stats['request']} sent_notifications={stats['notification']} "
        f"comments={stats['comment']} responses={reader.responses} "
        f"pending={reader.pending_count()} duplicate_responses={reader.duplicate_responses} "
        f"unexpected_responses={reader.unexpected_responses} "
        f"unexpected_response_messages={reader.unexpected_response_messages[:5]} "
        f"server_requests={reader.server_requests} server_notifications={reader.notifications} "
        f"elapsed_ms={elapsed * 1000:.3f}"
    )
    if reader.errors:
        print("reader_errors:", *reader.errors, sep="\n", file=sys.stderr)
        return 1
    if args.semantic_update_probe:
        probe_result = semantic_update_probe_result(args.log)
        if not probe_result.rows:
            print("semantic_update_probe: missing semantic current update log row", file=sys.stderr)
            return 1
        print("semantic_update_probe:")
        for row in probe_result.rows:
            print(f"  {row}")
        if probe_result.max_update_ms is not None and probe_result.max_update_ms > args.semantic_update_max_ms:
            print(
                "semantic_update_probe: "
                f"semantic current update took {probe_result.max_update_ms:.3f}ms "
                f"> max {args.semantic_update_max_ms:.3f}ms",
                file=sys.stderr,
            )
            return 1
    return 0 if reader.pending_count() == 0 and reader.duplicate_responses == 0 else 2


def load_actions(path: Path) -> list[dict[str, Any]]:
    actions = []
    for line in path.read_text().splitlines():
        if line.strip():
            actions.append(json.loads(line))
    return actions


def expected_request_ids(actions: list[dict[str, Any]], no_auto_shutdown: bool) -> set[int]:
    ids = {action["id"] for action in actions if action.get("kind") == "request"}
    has_shutdown = any(
        action.get("kind") == "request" and action.get("method") == "shutdown"
        for action in actions
    )
    if not no_auto_shutdown and not has_shutdown:
        ids.add(900000)
    return ids


def is_shutdown_action(action: dict[str, Any]) -> bool:
    return action.get("kind") == "request" and action.get("method") == "shutdown"


def record_document_notification(documents: dict[str, dict[str, Any]], action: dict[str, Any]) -> None:
    method = action.get("method")
    params = action.get("params") or {}
    if method == "textDocument/didOpen":
        text_document = params.get("textDocument") or {}
        uri = text_document.get("uri")
        if isinstance(uri, str):
            documents[uri] = {
                "version": int(text_document.get("version") or 1),
                "text": text_document.get("text") or "",
            }
    elif method == "textDocument/didChange":
        text_document = params.get("textDocument") or {}
        uri = text_document.get("uri")
        if not isinstance(uri, str) or uri not in documents:
            return
        documents[uri]["version"] = int(text_document.get("version") or documents[uri]["version"])
        changes = params.get("contentChanges") or []
        if changes and "text" in changes[-1] and "range" not in changes[-1]:
            documents[uri]["text"] = changes[-1]["text"]


def run_semantic_update_probe(
    proc: subprocess.Popen[bytes],
    write_lock: threading.Lock,
    reader: RpcReader,
    documents: dict[str, dict[str, Any]],
    next_id: int,
    timeout: float,
    stats: dict[str, int],
) -> int:
    if not documents:
        raise ValueError("semantic update probe needs an opened document")
    uri, document = next(iter(documents.items()))
    original_text = document["text"]
    probe_text = semantic_probe_text(original_text)
    if probe_text == original_text:
        raise ValueError(f"semantic update probe could not perturb {uri}")

    warm_id = next_id
    next_id += 1
    send_probe_request(proc, write_lock, reader, warm_id, "textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri},
    })
    stats["request"] += 1
    wait_for_response(reader, warm_id, timeout)

    version = int(document["version"]) + 1
    write_message(proc.stdin, notification_message("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": version},
        "contentChanges": [{
            "range": full_range(original_text),
            "rangeLength": len(original_text.encode()),
            "text": probe_text,
        }],
    }), write_lock)
    stats["notification"] += 1
    document["version"] = version
    document["text"] = probe_text

    first_full_id = next_id
    next_id += 1
    send_probe_request(proc, write_lock, reader, first_full_id, "textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri},
    })
    stats["request"] += 1
    wait_for_response(reader, first_full_id, timeout)

    second_full_id = next_id
    next_id += 1
    send_probe_request(proc, write_lock, reader, second_full_id, "textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri},
    })
    stats["request"] += 1
    wait_for_response(reader, second_full_id, timeout)

    print(
        "semantic_update_probe: "
        f"uri={uri} warm_id={warm_id} update_full_id={first_full_id} "
        f"warm_full_id={second_full_id} bytes={len(probe_text)}"
    )
    return next_id


def semantic_probe_text(text: str) -> str:
    probe = "\nconst __zitron_ls_replay_semantic_probe = 0;\n"
    start = text.find("%include {")
    if start == -1:
        return text
    close = text.find("\n}", start)
    if close == -1:
        return text
    return text[:close] + probe + text[close:]


def full_range(text: str) -> dict[str, Any]:
    lines = text.split("\n")
    return {
        "start": {"line": 0, "character": 0},
        "end": {"line": len(lines) - 1, "character": len(lines[-1])},
    }


def send_probe_request(
    proc: subprocess.Popen[bytes],
    write_lock: threading.Lock,
    reader: RpcReader,
    request_id: int,
    method: str,
    params: Any,
) -> None:
    reader.expect_response(request_id)
    write_message(proc.stdin, request_message(request_id, method, params), write_lock)


def wait_for_response(reader: RpcReader, request_id: int, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if reader.completed(request_id):
            return
        time.sleep(0.01)
    raise TimeoutError(f"timed out waiting for replay probe request {request_id}")


class SemanticUpdateProbeResult:
    def __init__(self, rows: list[str], max_update_ms: float | None):
        self.rows = rows
        self.max_update_ms = max_update_ms


def semantic_update_probe_result(log_path: Path) -> SemanticUpdateProbeResult:
    if not log_path.exists():
        return SemanticUpdateProbeResult([], None)
    lines = log_path.read_text(errors="replace").splitlines()
    latest = latest_session(lines)
    rows = [
        line.split("): ", 1)[-1]
        for line in latest
        if (
            ("Zig semantic current " in line and " zls_tokens=" in line)
            or "Zig forward semanticTokens/full -> " in line
        )
    ]
    update_elapsed = [
        elapsed_ms(row)
        for row in rows
        if "Zig semantic current update_" in row
    ]
    update_elapsed = [value for value in update_elapsed if value is not None]
    max_update_ms = max(update_elapsed) if update_elapsed else None
    return SemanticUpdateProbeResult(rows[-6:], max_update_ms)


def elapsed_ms(row: str) -> float | None:
    marker = "elapsed_ns="
    start = row.find(marker)
    if start == -1:
        return None
    start += len(marker)
    end = start
    while end < len(row) and row[end].isdigit():
        end += 1
    if end == start:
        return None
    return int(row[start:end]) / 1_000_000.0


def latest_session(lines: list[str]) -> list[str]:
    starts = [index for index, line in enumerate(lines) if "Log File:" in line]
    if not starts:
        return lines
    start = starts[-1]
    return lines[start:]


def compact_response(message: dict[str, Any]) -> dict[str, Any]:
    compact: dict[str, Any] = {"id": message.get("id")}
    if "error" in message:
        compact["error"] = message["error"]
    elif "result" in message:
        compact["result"] = message["result"]
    return compact


def write_message(pipe: Any, message: dict[str, Any], write_lock: threading.Lock) -> None:
    body = json.dumps(message, separators=(",", ":")).encode()
    header = f"Content-Length: {len(body)}\r\n\r\n".encode()
    with write_lock:
        pipe.write(header)
        pipe.write(body)
        pipe.flush()


def request_message(request_id: int, method: str, params: Any) -> dict[str, Any]:
    message = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    return message


def notification_message(method: str, params: Any) -> dict[str, Any]:
    message = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        message["params"] = params
    return message


def read_message(pipe: Any) -> dict[str, Any] | None:
    headers: list[bytes] = []
    while True:
        line = pipe.readline()
        if line == b"":
            return None
        if line in (b"\r\n", b"\n"):
            break
        headers.append(line)

    length = None
    for header in headers:
        name, _, value = header.partition(b":")
        if name.lower() == b"content-length":
            length = int(value.strip())
            break
    if length is None:
        raise ValueError(f"missing Content-Length in headers: {headers!r}")
    body = pipe.read(length)
    if len(body) != length:
        return None
    return json.loads(body)


if __name__ == "__main__":
    raise SystemExit(main())
