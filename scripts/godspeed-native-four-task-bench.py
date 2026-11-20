#!/usr/bin/env python3
"""Measure four scripted tasks using native AppKit, installed Godspeed, and an independent receipt."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import subprocess
import tempfile
from time import monotonic, sleep
from uuid import uuid4


FIXTURE = Path(__file__).with_name("tests") / "fixtures" / "MacOSFourTaskFixture.swift"
DOCUMENT = "The first benchmark line.\nThe second benchmark line."
TASKS = (
    ("Multiply 37 × 24", [{"tool": "click", "label": key} for key in
                         ("Digit 3", "Digit 7", "Multiply", "Digit 2", "Digit 4", "Equals")],
     "Result: 888", lambda _, state: state.get("answer") == 888),
    ("Write two lines", [{"tool": "set_value", "label": "Benchmark document", "value": DOCUMENT}],
     "The second benchmark line.", lambda _, state: state.get("document") == DOCUMENT),
    ("Create a folder", [{"tool": "set_value", "label": "Folder name", "value": "Benchmark folder"},
                        {"tool": "click", "label": "Create folder"}],
     "Folder created", lambda root, _: (root / "Benchmark folder").is_dir()),
    ("Select a file", [{"tool": "click", "label": "target-file.txt"}],
     "Selected: target-file.txt", lambda _, state: state.get("selected") == "target-file.txt"),
)


def grouped_tasks():
    return (("Four operations in the same window", [step for _, steps, _, _ in TASKS for step in steps],
             [{"text": expected} for _, _, expected, _ in TASKS],
             lambda root, state: all(check(root, state) for _, _, _, check in TASKS)),)


def compile_fixture(root):
    identifier = "dev.godspeed.fixture." + str(uuid4())
    contents = root / "Godspeed Four Task Fixture.app" / "Contents"
    binary = contents / "MacOS" / "GodspeedFourTaskFixture"
    binary.parent.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleExecutable": binary.name,
        "CFBundleName": "Godspeed Four Task Fixture", "CFBundlePackageType": "APPL",
        "LSUIElement": True,
    }))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(FIXTURE), "-o", str(binary)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(contents.parent)],
                   check=True, capture_output=True)
    return identifier, binary


class MCP:
    def __init__(self, binary, stderr):
        environment = {**os.environ, "OPEN_COMPUTER_USE_BACKGROUND_ONLY": "1",
                       "OPEN_COMPUTER_USE_FOCUS_BORROW": "0",
                       "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "0",
                       "OPEN_COMPUTER_USE_VISUAL_CURSOR": "0", "OPEN_COMPUTER_USE_TRAJECTORY_LOG": "0"}
        environment.pop("OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY", None)
        self.process = subprocess.Popen([str(binary), "mcp"], env=environment, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=stderr)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.next_id = 1
        self.pending = b""

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=4)
        self.selector.close()

    def request(self, method, params, notify=False):
        packet = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notify:
            packet["id"] = self.next_id
            self.next_id += 1
        self.process.stdin.write(json.dumps(packet, ensure_ascii=False).encode() + b"\n")
        self.process.stdin.flush()
        if notify:
            return None
        deadline = monotonic() + 28
        while monotonic() < deadline:
            if b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                decoded = json.loads(line)
                if decoded.get("id") == packet["id"]:
                    return decoded, len(line)
            elif self.selector.select(max(0, deadline - monotonic())):
                received = os.read(self.process.stdout.fileno(), 65536)
                if not received:
                    raise RuntimeError("Godspeed closed its MCP output before responding")
                self.pending += received
        raise TimeoutError(f"Godspeed did not answer {method}")

    def handshake(self):
        reply, count = self.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "Godspeed Four Task Bench", "version": "1"}})
        self.request("notifications/initialized", {}, notify=True)
        tools, list_count = self.request("tools/list", {})
        return {"server": reply["result"]["serverInfo"], "initialize_bytes": count,
                "tools_list_bytes": list_count, "tool_count": len(tools["result"]["tools"])}

    def call(self, name, arguments):
        started = monotonic()
        payload, raw_bytes = self.request("tools/call", {"name": name, "arguments": arguments})
        result = payload.get("result", {})
        reply = "\n".join(item["text"] for item in result.get("content", []) if item.get("type") == "text")
        return {"tool": name, "seconds": round(monotonic() - started, 4), "response_text_bytes": len(reply.encode()),
                "response_json_bytes": raw_bytes, "error": bool(payload.get("error") or result.get("isError")),
                "reply": reply}


def read_receipt(root, check):
    deadline = monotonic() + 1.5
    state = {}
    while monotonic() < deadline:
        try:
            state = json.loads((root / "state.json").read_text())
        except FileNotFoundError:
            pass
        if state and check(root, state):
            return state, True
        sleep(0.035)
    return state, False


def trial(client, app, root, task, batch_per_task):
    name, steps, expected, verify = task
    started = monotonic()
    observe = {"compact": True, "max_tree_nodes": 100}
    condition = {"text": expected} if isinstance(expected, str) else expected
    args = {"app": app, "steps": steps, "goal": name, "done_when": condition,
            "compact": True, "effects": False}
    commands_submitted = 1
    if batch_per_task:
        args["steps"] = [{"tool": "get_app_state", **observe}, *steps]
        calls = [client.call("batch", args)]
        commands_submitted += len(steps)
    else:
        snapshot = client.call("get_app_state", {"app": app, **observe})
        calls = [snapshot]
        if not snapshot["error"]:
            window = re.search(r"^Window ID: (\d+)", snapshot["reply"], re.MULTILINE)
            if window:
                args["window_id"] = int(window[1])
            calls.append(client.call("batch", args))
            commands_submitted += len(steps)
    driver_seconds = monotonic() - started
    _, verified = read_receipt(root, verify)
    return {"task": name, "seconds": round(driver_seconds, 4), "mcp_calls": len(calls),
            "native_commands_submitted": commands_submitted, "tool_errors": sum(call["error"] for call in calls),
            "response_text_bytes": sum(call["response_text_bytes"] for call in calls),
            "response_json_bytes": sum(call["response_json_bytes"] for call in calls),
            "independent_pass": verified, "calls": calls}


def run_once(binary, fixture, identifier, directory, tasks, batch_per_task):
    for name in ("other-file.txt", "target-file.txt"):
        (directory / name).write_text("Owned benchmark fixture.\n")
    environment = {**os.environ, "GODSPEED_BENCH_FIXTURE_ROOT": str(directory)}
    app = subprocess.Popen([str(fixture)], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        initial, ready = read_receipt(directory, lambda *_: True)
        if not ready:
            raise RuntimeError("The background fixture failed to start")
        with (directory / "driver.err").open("wb") as stderr:
            client = MCP(binary, stderr)
            try:
                handshake = client.handshake()
                trials = [trial(client, identifier, directory, task, batch_per_task) for task in tasks]
            finally:
                client.close()
        final, _ = read_receipt(directory, lambda *_: True)
        return {"mcp": handshake, "tasks": trials, "fixture_activations": final["activations"],
                "fixture_active_before_or_after": initial["active"] or final["active"],
                "foreground_same_before_and_after": initial["frontPID"] == final["frontPID"]}
    finally:
        if app.poll() is None:
            app.terminate()
            app.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, default=Path("/Applications/GODSPEED.app/Contents/MacOS/OpenComputerUse"))
    parser.add_argument("--repeat", type=int, default=1, choices=range(1, 11))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--single-window-batch", action="store_true", help="Group the four known operations in one verified batch.")
    mode.add_argument("--batch-per-task", action="store_true", help="Put each initial observation inside its own verified batch.")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="godspeed-four-task-") as temporary:
        root = Path(temporary)
        identifier, fixture = compile_fixture(root)
        runs = []
        for number in range(args.repeat):
            directory = root / f"trial-{number + 1}"
            directory.mkdir()
            tasks = grouped_tasks() if args.single_window_batch else TASKS
            runs.append(run_once(args.driver, fixture, identifier, directory, tasks, args.batch_per_task))
        report = {"protocol": "Scripted MCP calls against an isolated native AppKit fixture, no language model",
                  "grouped": args.single_window_batch,
                  "batch_per_task": args.batch_per_task,
                  "timing_scope": "Steady MCP session from app observation through the last action response. Setup and independent check excluded.",
                  "runs": runs}
        output = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
        if args.output:
            args.output.write_text(output)
        else:
            print(output, end="")
        return 0 if all(task["independent_pass"] for run in runs for task in run["tasks"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
