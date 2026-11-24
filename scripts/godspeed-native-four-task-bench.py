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


def stop_process(process, timeout):
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=timeout)


def verified_background(run):
    return (run["fixture_activations"] == 0
            and not run["fixture_active_before_or_after"]
            and run["foreground_same_before_and_after"])


class MCP:
    def __init__(self, binary, stderr, helper=None):
        environment = {**os.environ, "OPEN_COMPUTER_USE_BACKGROUND_ONLY": "1",
                       "OPEN_COMPUTER_USE_FOCUS_BORROW": "0",
                       "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "0",
                       "OPEN_COMPUTER_USE_VISUAL_CURSOR": "0", "OPEN_COMPUTER_USE_TRAJECTORY_LOG": "0",
                       "OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS": "1"}
        if helper is not None:
            environment.update({
                "OPEN_COMPUTER_USE_HANDOFF_HELPER": "1" if helper else "0",
                "OPEN_COMPUTER_USE_REFEREE_URL": "http://127.0.0.1:8765" if helper else "0",
                "OPEN_COMPUTER_USE_VISION_URL": "0",
                "OPEN_COMPUTER_USE_RECIPES": "0",
            })
        environment.pop("OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY", None)
        self.process = subprocess.Popen([str(binary), "mcp"], env=environment, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=stderr)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.next_id = 1
        self.pending = b""

    def close(self):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            stop_process(self.process, timeout=4)
        finally:
            self.selector.close()
            self.process.stdout.close()

    def request(self, method, params, notify=False, timeout=28):
        packet = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notify:
            packet["id"] = self.next_id
            self.next_id += 1
        self.process.stdin.write(json.dumps(packet, ensure_ascii=False).encode() + b"\n")
        self.process.stdin.flush()
        if notify:
            return None
        deadline = monotonic() + timeout
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
        # Batch can spend up to 75 seconds on the app plus cleanup and readback.
        timeout = 90 if name == "batch" else 28
        payload, raw_bytes = self.request("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)
        result = payload.get("result", {})
        reply = "\n".join(item["text"] for item in result.get("content", []) if item.get("type") == "text")
        if not reply and isinstance(payload.get("error"), dict):
            reply = str(payload["error"].get("message") or "MCP request failed")
        return {"tool": name, "seconds": round(monotonic() - started, 4), "response_text_bytes": len(reply.encode()),
                "response_json_bytes": raw_bytes, "error": bool(payload.get("error") or result.get("isError")),
                "reply": reply, "handoff": (result.get("_meta") or {}).get("godspeed/handoff")}


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


def choice_trial(client, app, root):
    call = client.call("handoff", {
        "app": app, "goal": "Select target-file.txt in the fixture file list.",
        "done_when": {"text": "Selected: target-file.txt"}, "max_steps": 1, "time_budget_s": 8,
    })
    state, verified = read_receipt(root, lambda _, data: data.get("selected") == "target-file.txt")
    return {"task": "Local file selection", "independent_pass": verified, "selected": state.get("selected"),
            "mcp_calls": 1, "calls": [call]}


def resume_trial(client, app, root, pinned=False):
    snapshot = client.call("get_app_state", {"app": app, "compact": True})
    window = re.search(r"^Window ID: (\d+)", snapshot["reply"], re.MULTILINE)
    if not window:
        return {"task": "Resume a stopped local workflow", "independent_pass": False, "calls": [snapshot]}
    binding = {"window_id": int(window[1])} if pinned else {}
    initial = client.call("batch", {
        **binding, "app": app, "goal": "Finish the multiplication after the folder is created",
        "steps": [
            {"tool": "click", "label": "Digit 3"},
            {"tool": "set_value", "label": "Folder name", "value": "Benchmark folder"},
            {"tool": "wait", "text": "Folder created", "timeout_ms": 250},
            *({"tool": "click", "label": key} for key in ("Digit 7", "Multiply", "Digit 2", "Digit 4", "Equals")),
        ],
        "done_when": {"appeared": "Result: 888"}, "compact": True,
    })
    calls = [snapshot, initial]
    token = re.search(r"Resume ([0-9A-Fa-f-]{36})", initial["reply"])
    if not initial["error"] or not token or "3. wait" not in initial["reply"]:
        return {"task": "Resume a stopped local workflow", "independent_pass": False, "calls": calls}
    calls.append(client.call("click", {"app": app, "label": "Create folder"}))
    resume_args = {"resume": token[1], "values": {"step-3-text": "Folder created"}}
    resumed = client.call("batch", resume_args)
    duplicate = client.call("batch", resume_args)
    calls.extend((resumed, duplicate))
    state, verified = read_receipt(root, lambda folder, data: data.get("answer") == 888
                                   and (folder / "Benchmark folder").is_dir())
    return {"task": "Resume a stopped local workflow", "answer": state.get("answer"),
            "independent_pass": (verified and not resumed["error"] and duplicate["error"]
                                 and "RESUME_NOT_FOUND" in duplicate["reply"]),
            "mcp_calls": len(calls), "calls": calls}


def run_once(binary, fixture, identifier, directory, tasks, batch_per_task, helper=None, resume_chain=False, pinned_resume=False):
    for name in ("other-file.txt", "target-file.txt"):
        (directory / name).write_text("Owned benchmark fixture.\n")
    environment = {**os.environ, "GODSPEED_BENCH_FIXTURE_ROOT": str(directory)}
    app = subprocess.Popen([str(fixture)], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        initial, ready = read_receipt(directory, lambda *_: True)
        if not ready:
            raise RuntimeError("The background fixture failed to start")
        with (directory / "driver.err").open("wb") as stderr:
            client = MCP(binary, stderr, helper=helper)
            try:
                handshake = client.handshake()
                if resume_chain:
                    trials = [resume_trial(client, identifier, directory, pinned=pinned_resume)]
                elif helper is None:
                    trials = [trial(client, identifier, directory, task, batch_per_task) for task in tasks]
                else:
                    trials = [choice_trial(client, identifier, directory)]
            finally:
                client.close()
        final, _ = read_receipt(directory, lambda *_: True)
        diagnostics = (directory / "driver.err").read_text(errors="replace").splitlines()
        return {"helper": helper, "mcp": handshake, "tasks": trials,
                "window_pin_diagnostics": [line for line in diagnostics if "window pin:" in line], "fixture_activations": final["activations"],
                "fixture_active_before_or_after": initial["active"] or final["active"],
                "foreground_same_before_and_after": initial["frontPID"] == final["frontPID"]}
    finally:
        if app.poll() is None:
            app.terminate()
            stop_process(app, timeout=5)


def write_report(report, output):
    serialized = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if output is None:
        print(serialized, end="")
        return
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent, delete=False) as stream:
        path = Path(stream.name)
        stream.write(serialized)
    try:
        path.replace(output)
    finally:
        path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, default=Path("/Applications/GODSPEED.app/Contents/MacOS/OpenComputerUse"))
    parser.add_argument("--repeat", type=int, default=1, choices=range(1, 11))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--resume-chain", action="store_true", help="Interrupt and resume a multi-step local workflow.")
    mode.add_argument("--local-choice", action="store_true", help="Compare a live handoff with the local chooser off and on.")
    mode.add_argument("--single-window-batch", action="store_true", help="Group the four known operations in one verified batch.")
    mode.add_argument("--batch-per-task", action="store_true", help="Put each initial observation inside its own verified batch.")
    parser.add_argument("--pin-resume-window", action="store_true", help="Pin the resume fixture batch to its observed window.")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.pin_resume_window and not args.resume_chain:
        parser.error("--pin-resume-window requires --resume-chain")
    runs = []
    report = {"protocol": "Scripted MCP calls against an isolated native AppKit fixture; no cloud model",
              "local_choice": args.local_choice, "resume_chain": args.resume_chain,
              "grouped": args.single_window_batch, "batch_per_task": args.batch_per_task,
              "timing_scope": "Steady MCP session from app observation through the last action response. Setup and independent check excluded.",
              "status": "running", "expected_runs": args.repeat * (2 if args.local_choice else 1), "runs": runs}
    try:
        with tempfile.TemporaryDirectory(prefix="godspeed-four-task-") as temporary:
            root = Path(temporary)
            identifier, fixture = compile_fixture(root)
            helper_modes = (False, True) if args.local_choice else (None,)
            tasks = grouped_tasks() if args.single_window_batch else TASKS
            for number in range(args.repeat):
                for helper in helper_modes:
                    directory = root / f"trial-{number + 1}-{helper}"
                    directory.mkdir()
                    runs.append(run_once(args.driver, fixture, identifier, directory, tasks, args.batch_per_task,
                                         helper, args.resume_chain, args.pin_resume_window))
                    if args.output:
                        write_report(report, args.output)
    except KeyboardInterrupt:
        report["status"] = "interrupted"
        write_report(report, args.output)
        return 130
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        report.update(status="failed", error=f"{type(error).__name__}: {error}")
        write_report(report, args.output)
        return 1
    report["status"] = "completed"
    write_report(report, args.output)
    if args.local_choice:
        def passes_choice(run):
            task = run["tasks"][0]
            metrics = task["calls"][0]["handoff"] or {}
            return (verified_background(run)
                    and task["independent_pass"] == run["helper"]
                    and metrics.get("model", 0) == int(run["helper"])
                    and metrics.get("verified", 0) == int(run["helper"]))
        return 0 if all(passes_choice(run) for run in runs) else 1
    return 0 if all(verified_background(run) and all(task["independent_pass"] for task in run["tasks"])
                    for run in runs) else 1


if __name__ == "__main__":
    raise SystemExit(main())
