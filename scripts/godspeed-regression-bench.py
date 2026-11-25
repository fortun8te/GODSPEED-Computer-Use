#!/usr/bin/env python3
"""Run a 43-step native Godspeed regression workload and grade fixture state.

Example: python3 scripts/godspeed-regression-bench.py --repeat 20 --output regression.json
Requires an existing Godspeed binary with Accessibility access and the Swift toolchain.
Timings cover a scripted native workload, with source telemetry when returned by MCP.
"""

import argparse
from collections import Counter
import importlib.util
import json
from math import ceil
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
from time import monotonic, sleep
from uuid import uuid4


SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("native_bench", SCRIPTS / "godspeed-native-four-task-bench.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)

PHASES = ("Original", "New fixture tab", "Moved fixture tab", "Relaunched")
EXPECTED = [
    "Load fixture",
    *(f"Original/Mark {i}" for i in range(1, 9)),
    "Open fixture tab",
    *(f"New fixture tab/Mark {i}" for i in range(1, 9)),
    "Move fixture window",
    *(f"Moved fixture tab/Mark {i}" for i in range(1, 9)),
    *(f"Relaunched/Mark {i}" for i in range(1, 9)),
]
STEP_COUNT = 43


class Driver(native.MCP):
    def request(self, method, params, **kwargs):
        reply = super().request(method, params, **kwargs)
        if method == "tools/call" and reply:
            if self.drop_reply:
                return {}, reply[1]
            result = reply[0].get("result", {})
            self.telemetry = (result.get("_meta") or {}).get("godspeed/telemetry")
        return reply

    def call(self, name, arguments, *, drop_reply=False):
        self.telemetry = None
        self.drop_reply = drop_reply
        try:
            result = super().call(name, arguments)
        finally:
            self.drop_reply = False
        if drop_reply:
            return {"tool": name, "seconds": result["seconds"], "reply_dropped": True}
        if isinstance(self.telemetry, dict):
            result["telemetry"] = self.telemetry
        return result


def compile_fixture(root):
    identifier = "dev.godspeed.regression." + str(uuid4())
    contents = root / "Godspeed Regression Fixture.app" / "Contents"
    binary = contents / "MacOS" / "GodspeedRegressionFixture"
    binary.parent.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleExecutable": binary.name,
        "CFBundleName": "Godspeed Regression Fixture", "CFBundlePackageType": "APPL",
        "LSUIElement": True,
    }))
    source = SCRIPTS / "tests/fixtures/MacOSRegressionFixture.swift"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(contents.parent)], check=True, capture_output=True)
    return identifier, binary


def grade(before_restart, final):
    events = final.get("events", [])
    observed = Counter(events)
    expected = Counter(EXPECTED)
    wrong = sum(count for action, count in observed.items() if action not in expected)
    duplicates = sum(count - 1 for count in observed.values())
    transitions = {
        "tab": before_restart.get("tabCount") == 2 and before_restart.get("windows") == ["Original", "Moved fixture tab"],
        "move": before_restart.get("moved") is True,
        "relaunch": bool(before_restart.get("pid") and final.get("pid")
                         and before_restart["pid"] != final["pid"] and final.get("generation") == 2
                         and final.get("windows") == ["Relaunched"]),
    }
    return {"fixture_pass": events == EXPECTED and all(transitions.values()),
            "wrong_targets": wrong, "duplicate_actions": duplicates, "transitions": transitions}


def summarize(runs):
    durations = sorted(run["wall_seconds"] for run in runs)
    fixture_passes = sum(run["fixture_pass"] for run in runs)
    aborted_runs = sum(run.get("error") is not None for run in runs)
    completed_passes = sum(run["fixture_pass"] and run.get("error") is None for run in runs)
    return {
        "runs": len(runs),
        "p95_wall_seconds": durations[ceil(0.95 * len(durations)) - 1],
        # Effects can be correct even when the final observation fails. Keep the
        # fixture metric, but do not count that aborted workload as a complete pass.
        "fixture_passes": fixture_passes,
        "fixture_pass_rate": fixture_passes / len(runs),
        "aborted_runs": aborted_runs,
        "completed_runs": len(runs) - aborted_runs,
        "completed_passes": completed_passes,
        "completed_pass_rate": completed_passes / len(runs),
        "wrong_targets": sum(run["wrong_targets"] for run in runs),
        "duplicate_actions": sum(run["duplicate_actions"] for run in runs),
    }


def run_workload(client, app, restart, steps):
    def call(tool, *, drop_reply=False, **arguments):
        result = client.call(tool, {"app": app, **arguments}, drop_reply=drop_reply)
        steps.append(result)
        if result.get("error"):
            raise RuntimeError(f"{tool} failed: {result['reply']}")
        return result.get("reply", "")

    def snapshot(title, **arguments):
        for attempt in range(2):
            try:
                reply = call("get_app_state", compact=True, max_tree_nodes=100, **arguments)
                break
            except RuntimeError as exc:
                if attempt or arguments or "appNotFound(" not in str(exc):
                    raise
                sleep(0.25)
        observed = re.search(r"^Window ID: (\d+)$", reply, re.MULTILINE)
        if not observed or f'Window: "{title}",' not in reply:
            raise RuntimeError(f"Expected to observe {title}")
        return int(observed[1]), reply

    for phase, title in enumerate(PHASES):
        window_id, _ = snapshot(title)
        if phase == 0:
            call("click", label="Load fixture", window_id=window_id)
            call("wait_for", label="Fixture ready", condition="appears", timeout=5, window_id=window_id)
        for index in range(1, 9):
            label = f"Mark {index}"
            lost = phase == 2 and index == 4
            call("click", label=label, window_id=window_id, drop_reply=lost)
            if lost:
                _, reply = snapshot(title, window_id=window_id)
                if f"Recorded {label}" not in reply:
                    raise RuntimeError("Could not reconcile the dropped reply from current UI state")
        if phase < 2:
            label = ("Open fixture tab", "Move fixture window")[phase]
            call("click", label=label, window_id=window_id)
        elif phase == 2:
            steps.append({"tool": "relaunch_fixture"})
            restart()
    snapshot(PHASES[-1], window_id=window_id)


def run_once(driver, fixture, app, root):
    process = None
    before_restart = {}

    def stop():
        if process is not None and process.poll() is None:
            process.terminate()
            native.stop_process(process, timeout=3)

    def launch(generation):
        nonlocal process
        process = subprocess.Popen([str(fixture), str(root), str(generation)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _, ready = native.read_receipt(root, lambda _, state: state.get("generation") == generation)
        if not ready:
            raise RuntimeError(f"Fixture generation {generation} never published state")

    def restart():
        nonlocal before_restart
        before_restart, _ = native.read_receipt(root, lambda *_: True)
        stop()
        launch(2)

    try:
        launch(1)
        with (root / "driver.err").open("wb") as stderr:
            client = Driver(driver, stderr)
            try:
                mcp = client.handshake()
                steps = []
                error = None
                started = monotonic()
                try:
                    run_workload(client, app, restart, steps)
                except (RuntimeError, OSError) as exc:
                    error = str(exc) or type(exc).__name__
                duration = monotonic() - started
                final, _ = native.read_receipt(root, lambda *_: True)
                return {"mcp": mcp, "wall_seconds": duration, "steps": steps,
                        "error": error, **grade(before_restart, final),
                        "before_relaunch": before_restart, "final": final}
            finally:
                client.close()
    finally:
        stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path,
                        default=Path("/Applications/GODSPEED.app/Contents/MacOS/OpenComputerUse"))
    parser.add_argument("--repeat", type=int, default=5)
    parser.add_argument("--output", type=Path, help="Write the full JSON readout here")
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    if not args.driver.is_file():
        parser.error(f"Driver binary not found: {args.driver}")
    runs = []
    with tempfile.TemporaryDirectory(prefix="godspeed-regression-") as temporary:
        root = Path(temporary)
        app, fixture = compile_fixture(root)
        for index in range(args.repeat):
            directory = root / str(index)
            directory.mkdir()
            runs.append(run_once(args.driver, fixture, app, directory))
    report = {
        "workload": "Native AppKit tab, delayed control, window move and relaunch, dropped click reply",
        "planned_steps": STEP_COUNT,
        "timing_scope": "First snapshot through final snapshot or abort, including recovery and relaunch",
        "p95_method": "Nearest rank across completed and aborted trials",
        "pass_scope": "Both pass rates use all runs; completed passes require correct fixture state and no workload error",
        "summary": summarize(runs),
        "runs": runs,
    }
    native.write_report(report, args.output)
    if args.output:
        print(json.dumps(report["summary"], indent=2))
        for index, run in enumerate(runs, start=1):
            if run["error"] is not None:
                print(f"Run {index} stopped after {len(run['steps'])} steps. {run['error'].strip()}")
    return int(any(run["error"] is not None or not run["fixture_pass"] for run in runs))


if __name__ == "__main__":
    raise SystemExit(main())
