#!/Users/atman/Dropbox/deck/m/skills/.venv/bin/python
"""Exercise conflict diagnostics over stdio, with deterministic explanation gates.

Run after `zig build`. Requires the installed Zitron with --explain-conflicts.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

from replay_client import read_message, write_message

ROOT = Path(__file__).resolve().parents[1]
CONFLICT = "start ::= expr.\nexpr ::= expr PLUS expr.\nexpr ::= ID.\n"
CLEAN = "%left PLUS.\n" + CONFLICT

WRAPPER = r'''
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ["CONFLICT_TEST_DIR"])
real = os.environ["CONFLICT_TEST_ZITRON"]
if "-FulX" not in sys.argv:
    os.execv(real, [real, *sys.argv[1:]])
text = sys.stdin.buffer.read()
number = len(list(root.glob("started-*.json"))) + 1
active = root / "active"
try:
    active.mkdir()
except FileExistsError:
    (root / "overlap").touch()
(root / f"started-{number}.json").write_text(json.dumps({"pid": os.getpid(), "text": text.decode(), "path": sys.argv[-1]}))
while not (root / f"release-{number}").exists():
    time.sleep(0.01)
if (root / f"fail-{number}").exists():
    sys.stderr.write("explanation failed\n")
    result = 1
else:
    output = subprocess.run([real, *sys.argv[1:]], input=text, capture_output=True)
    sys.stdout.buffer.write(output.stdout)
    sys.stderr.buffer.write(output.stderr)
    result = output.returncode
active.rmdir()
(root / f"done-{number}").touch()
sys.exit(result)
'''


class Client:
    def __init__(self, directory: Path):
        self.directory = directory
        self.messages: list[dict] = []
        self.incoming: queue.Queue = queue.Queue()
        self.lock = threading.Lock()
        self.next_id = 1
        real = shutil.which("zitron")
        assert real, "zitron must be on PATH"
        wrapper = directory / "zitron"
        wrapper.write_text(f"#!{sys.executable}\n" + WRAPPER)
        wrapper.chmod(0o755)
        env = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}",
                   CONFLICT_TEST_DIR=str(directory), CONFLICT_TEST_ZITRON=real)
        self.stderr = (directory / "server.stderr").open("wb")
        self.process = subprocess.Popen(
            [str(ROOT / "zig-out/bin/zitron-ls"), "--log-file", str(directory / "server.log")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, env=env,
        )
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        self.request("initialize", {"processId": None, "rootUri": ROOT.as_uri(), "capabilities": {}})
        self.notify("initialized", {})

    def read(self):
        try:
            while (message := read_message(self.process.stdout)) is not None:
                if "method" in message and "id" in message:
                    write_message(self.process.stdin, {"jsonrpc": "2.0", "id": message["id"], "result": None}, self.lock)
                self.incoming.put(message)
        except Exception as error:
            self.incoming.put(error)

    def drain(self):
        while True:
            try:
                message = self.incoming.get_nowait()
            except queue.Empty:
                return
            if isinstance(message, Exception):
                raise message
            self.messages.append(message)

    def wait(self, predicate, description: str, timeout: float = 15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.drain()
            if result := predicate():
                return result
            assert self.process.poll() is None, (description, self.process.returncode)
            time.sleep(0.01)
        raise AssertionError(f"Timed out: {description}; log: {self.directory / 'server.log'}")

    def notify(self, method, params):
        write_message(self.process.stdin, {"jsonrpc": "2.0", "method": method, "params": params}, self.lock)

    def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        write_message(self.process.stdin, {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}, self.lock)
        message = self.wait(lambda: next((m for m in self.messages if m.get("id") == request_id and "method" not in m), None), method)
        assert "error" not in message, message
        return message.get("result")

    def open(self, uri, version, text):
        self.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "zitron", "version": version, "text": text}})

    def change(self, uri, version, text):
        self.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": version}, "contentChanges": [{"text": text}]})

    def barrier(self, uri):
        self.request("textDocument/documentSymbol", {"textDocument": {"uri": uri}})

    def diagnostics(self, uri, since=0):
        return [m["params"] for m in self.messages[since:] if m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == uri]

    def started(self, number):
        path = self.directory / f"started-{number}.json"
        self.wait(path.exists, f"explanation {number} starts")
        return json.loads(path.read_text())

    def release(self, number, fail=False):
        if fail:
            (self.directory / f"fail-{number}").touch()
        (self.directory / f"release-{number}").touch()
        self.wait((self.directory / f"done-{number}").exists, f"explanation {number} completes")
        self.wait(lambda: (self.directory / "server.log").read_text().count("Conflict report finished") >= number,
                  f"explanation {number} processed by server")

    def close(self, uri):
        self.notify("textDocument/didClose", {"textDocument": {"uri": uri}})

    def stop(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        self.reader.join(timeout=5)
        self.stderr.close()


def details(params):
    return [d for d in params["diagnostics"] if d["message"].startswith("Conflict ")]


def summary(params):
    return any(d["message"] == "1 parsing conflicts" and d["range"]["start"]["line"] == 0 and d["severity"] == 1 for d in params["diagnostics"])


def after_invalidation(client, uri, version, mark):
    publications = client.diagnostics(uri, mark)
    first = next(i for i, p in enumerate(publications) if p.get("version") == version)
    assert publications[first]["diagnostics"] == [], publications[first]
    return publications[first:]


def run(directory):
    client = Client(directory)
    uri = (directory / "grammar.zy").as_uri()
    other = (directory / "other.zy").as_uri()
    try:
        client.open(uri, 1, CONFLICT)
        client.wait(lambda: any(summary(p) for p in client.diagnostics(uri)), "immediate conflict count")
        client.started(1)
        client.barrier(uri)  # Must respond while the explanation subprocess is blocked.
        client.change(uri, 2, "// superseded\n" + CONFLICT)
        client.change(uri, 3, "// latest\n\n" + CONFLICT)
        client.barrier(uri)
        assert not (directory / "started-2.json").exists()
        client.release(1)
        assert client.started(2)["text"] == "// latest\n\n" + CONFLICT
        assert not any(details(p) for p in client.diagnostics(uri))
        client.release(2)
        client.wait(lambda: any(p.get("version") == 3 and details(p) for p in client.diagnostics(uri)), "latest explanation")
        latest = next(p for p in reversed(client.diagnostics(uri)) if details(p))
        assert summary(latest), latest
        assert len(details(latest)) == 1, latest
        assert details(latest)[0]["range"]["start"]["line"] == 3, latest
        assert "Unifying counterexample:" in details(latest)[0]["message"]
        assert "derivation:" not in details(latest)[0]["message"]

        mark = len(client.messages)
        client.change(uri, 4, CLEAN)
        client.barrier(uri)
        assert client.diagnostics(uri, mark)[-1]["diagnostics"] == []
        assert not any(details(p) or summary(p) for p in client.diagnostics(uri, mark))
        assert not (directory / "started-3.json").exists()

        # One active explanation globally, with another document pending.
        client.change(uri, 5, CONFLICT)
        client.started(3)
        client.open(other, 1, CONFLICT)
        client.barrier(other)
        assert not (directory / "started-4.json").exists()
        client.close(uri)
        client.open(uri, 5, CLEAN)  # Reuse the old version deliberately.
        client.barrier(uri)
        mark = len(client.messages)
        client.release(3)
        assert client.started(4)["path"].endswith("other.zy")
        assert not any(details(p) for p in client.diagnostics(uri, mark))
        assert client.diagnostics(uri)[-1]["diagnostics"] == []
        client.release(4, fail=True)
        client.change(other, 2, "// retry\n" + CONFLICT)
        client.barrier(other)
        client.started(5)
        client.release(5)
        client.wait(lambda: any(p.get("version") == 2 and details(p) for p in client.diagnostics(other)), "recovery after failed explanation")

        # Closing leaves an empty replacement; nothing may resurrect this URI.
        mark = len(client.messages)
        client.close(other)
        client.barrier(uri)
        assert client.diagnostics(other, mark)[-1]["diagnostics"] == []
        assert not any(details(p) for p in client.diagnostics(other, mark))

        # Fixing the grammar during analysis must clear every old conflict.
        client.change(uri, 6, CONFLICT)
        client.started(6)
        mark = len(client.messages)
        client.change(uri, 7, CLEAN)
        client.barrier(uri)
        client.release(6)
        assert client.diagnostics(uri, mark)[-1]["diagnostics"] == []
        assert not any(details(p) or summary(p) for p in after_invalidation(client, uri, 7, mark))
        assert not (directory / "started-7.json").exists()

        # A syntax error replaces conflicts and cannot be overwritten by old analysis.
        client.change(uri, 8, CONFLICT)
        client.started(7)
        mark = len(client.messages)
        client.change(uri, 9, "start ::= ID.\n%unknown\n")
        client.barrier(uri)
        client.release(7)
        latest = client.diagnostics(uri, mark)[-1]
        assert any("Unknown declaration keyword" in d["message"] for d in latest["diagnostics"]), latest
        assert not any(details(p) or summary(p) for p in after_invalidation(client, uri, 9, mark))

        # Shutdown must cancel a subprocess still blocked on analysis.
        client.change(uri, 10, CONFLICT)
        pid = client.started(8)["pid"]
        client.request("shutdown", None)
        client.notify("exit", None)
        client.process.wait(timeout=5)
        assert client.process.returncode == 0
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("Explanation subprocess survived shutdown")
        assert not (directory / "overlap").exists(), "Concurrent explanations detected"
        print("PASS: count, rule locations, responsive requests, coalescing, stale rejection, clean clear, close/reopen, multiple documents, failure recovery, in-flight fixes and syntax errors, shutdown")
    finally:
        client.stop()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="zitron-conflicts-") as temporary:
        try:
            run(Path(temporary))
        except Exception:
            log = Path(temporary) / "server.log"
            if log.exists():
                print(log.read_text()[-12000:], file=sys.stderr)
            raise
