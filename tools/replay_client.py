#!/Users/atman/Dropbox/deck/m/skills/.venv/bin/python
"""Replay extracted JSON-RPC client actions against lsp_zitron."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any


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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--actions", type=Path, default=Path("zig-out/replay/latest.jsonl"))
    parser.add_argument("--server", default="zig-out/bin/lsp_zitron")
    parser.add_argument("--delay-ms", type=float, default=0.0)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--no-auto-shutdown", action="store_true")
    args = parser.parse_args()

    actions = load_actions(args.actions)
    pending_ids = expected_request_ids(actions, args.no_auto_shutdown)
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
    sent_shutdown = False
    start = time.monotonic()
    try:
        for action in actions:
            kind = action.get("kind")
            if kind == "comment":
                stats["comment"] += 1
                continue
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
            else:
                raise ValueError(f"unknown action kind: {kind!r}")
            if args.delay_ms:
                time.sleep(args.delay_ms / 1000.0)

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
