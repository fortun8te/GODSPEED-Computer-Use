"""Run with python3 -I -m unittest discover -s scripts/flywheel -p 'test_*.py'. Uses synthetic logs in temp folders only."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("flywheel", Path(__file__).with_name("flywheel.py"))
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)


def step(tool, label, role="AXButton", n=None, done=None, run="run-a", app="Notes", **extra):
    row = {"kind": "step", "ts": "2026-11-20T09:00:00.000Z", "run_id": run, "app": app, "tool": tool,
           "target_role": role, "delivery_state": "delivered", "done_when": done, **extra}
    if label is not None:
        row["target_label"] = label
    if n is not None:
        row["n"] = n
    return row


def episode(goal, run="run-a", app="Notes", outcome="verified"):
    return {"kind": "episode", "ts": "2026-11-20T09:00:01.000Z", "run_id": run, "app": app, "goal": goal,
            "outcome": outcome}


def write_log(folder, rows, name="learning-2026-11-20.jsonl"):
    (Path(folder) / name).write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def numbered(steps):
    """Adds n (1-based) to each step row, the way BatchTool.learn does."""
    for index, row in enumerate(steps, start=1):
        row["n"] = index
    return steps


class LearningEpisodeTests(unittest.TestCase):
    def test_episode_row_closes_its_steps(self):
        with tempfile.TemporaryDirectory() as temporary:
            rows = numbered([step("click", "Compose", n=None), step("type_text", "To", role="AXTextField")])
            rows[-1]["done_when"] = "verified"
            rows += [episode("Email bob@x.com", run="run-a"), episode("Second goal", run="run-b")]
            write_log(temporary, rows)
            episodes, dropped = f.learning_episodes(Path(temporary))
            self.assertEqual(len(episodes), 2)
            self.assertEqual([s["tool"] for s in episodes[0]["steps"]], ["click", "type_text"])
            self.assertEqual(episodes[1]["steps"], [])
            self.assertEqual(dropped, {})

    def test_open_steps_from_a_crashed_batch_are_incomplete(self):
        with tempfile.TemporaryDirectory() as temporary:
            rows = numbered([step("click", "Compose")]) + numbered([step("click", "Save")])
            rows += [episode("Save the note")]
            write_log(temporary, rows)
            episodes, dropped = f.learning_episodes(Path(temporary))
            self.assertEqual(dropped["incomplete"], 1)
            self.assertEqual([s["target_label"] for s in episodes[0]["steps"]], ["Save"])

    def test_other_row_kinds_and_bad_rows(self):
        with tempfile.TemporaryDirectory() as temporary:
            write_log(temporary, [{"kind": "decide", "label": "act"}, step("click", "Save", n=1), episode("Go")])
            episodes, _ = f.learning_episodes(Path(temporary))
            self.assertEqual(len(episodes[0]["steps"]), 1)
            (Path(temporary) / "learning-2026-11-21.jsonl").write_text("not json\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                f.learning_episodes(Path(temporary))
            with self.assertRaises(ValueError):
                f.learning_episodes(Path(temporary) / "missing")


def batch(goal, done="verified", run="run-a", label="To", amount_label="Amount", extra=None):
    """A four-step batch. The typing steps carry values that must never reach the output."""
    typed = {"after": "bob@x.com", "value": "bob@x.com"} | (extra or {})
    rows = numbered([
        step("click", "Compose", run=run),
        step("type_text", label, role="AXTextField", run=run, **typed),
        step("type_text", amount_label, role="AXTextField", run=run, **{"value": "7777"}),
        step("click", "Save", run=run, done=done),
    ])
    return rows + [episode(goal, run=run, outcome="verified" if done == "verified" else "unmet")]


class MiningTests(unittest.TestCase):
    def mine(self, rows, min_support=3):
        with tempfile.TemporaryDirectory() as temporary:
            write_log(temporary, rows)
            return f.mine_recipes(Path(temporary), min_support)

    def test_repeated_sequence_becomes_one_candidate_with_slots(self):
        rows = []
        for index, goal in enumerate(["Charge bob@x.com 7777 dollars", "Charge ann@y.org 1200 dollars",
                                      "Charge cy@z.net 45 dollars"]):
            rows += batch(goal, run=f"run-{index}")
        candidates, dropped = self.mine(rows)
        self.assertEqual(len(candidates), 1)
        candidate = candidates[0]
        self.assertEqual(candidate["support"], 3)
        self.assertEqual(candidate["goal"], "Charge {{email}} {{number}} dollars")
        self.assertEqual(len(candidate["steps"]), 4)
        self.assertEqual(candidate["steps"][1], {"tool": "type_text", "label": "To", "text": "{{to}}"})
        self.assertEqual(candidate["slot_kinds"], {"to": "recipient", "amount": "number"})
        self.assertEqual(candidate["params"], {"to": "", "amount": ""})
        self.assertFalse(candidate["verified"])
        self.assertEqual(candidate["done_when"], [])
        self.assertFalse(candidate["requiresConfirmation"])
        self.assertEqual(dropped, {})

    def test_sequence_that_only_sometimes_verified_is_dropped(self):
        rows = batch("Charge bob@x.com 7777", run="run-1") + batch("Charge bob@x.com 7777", run="run-2")
        rows += batch("Charge bob@x.com 7777", run="run-3") + batch("Charge bob@x.com 7777", run="run-4", done="unmet")
        candidates, dropped = self.mine(rows)
        self.assertEqual(candidates, [])
        self.assertEqual(dropped, {"groups_sometimes_verified": 1})

    def test_below_min_support_is_dropped(self):
        rows = batch("Charge bob@x.com 7777", run="run-1") + batch("Charge bob@x.com 7777", run="run-2")
        self.assertEqual(self.mine(rows)[0], [])
        self.assertEqual(len(self.mine(rows, min_support=2)[0]), 1)

    def test_secure_and_redacted_values_never_appear(self):
        secure_rows = []
        for index in range(3):
            run = f"secure-{index}"
            secure_rows += numbered([
                step("click", "Sign in", run=run),
                {"kind": "step", "run_id": run, "app": "Notes", "tool": "type_text",
                 "target_role": "AXSecureTextField", "value": "hunter2", "done_when": None},
                step("click", "Continue", run=run, done="verified"),
            ]) + [episode("Sign in to Notes", run=run)]
        redacted_rows = []
        for index in range(3):
            run = f"redacted-{index}"
            redacted_rows += numbered([
                step("click", "Open", run=run),
                step("type_text", "[redacted]", role="AXTextField", run=run),
                step("click", "Save", run=run, done="verified"),
            ]) + [episode("Open the file", run=run)]
        good = []
        for index in range(3):
            good += batch("Charge bob@x.com 7777", run=f"good-{index}")
        candidates, dropped = self.mine(secure_rows + redacted_rows + good)
        self.assertEqual(dropped.get("secure_or_redacted"), 6)
        self.assertEqual(len(candidates), 1)
        text = json.dumps(candidates)
        for leaked in ("hunter2", "[redacted]", "Sign in", "bob@x.com", "7777", "AXSecureTextField"):
            self.assertNotIn(leaked, text)

    def test_sequences_with_send_or_delete_need_confirmation(self):
        rows = []
        for index in range(3):
            run = f"send-{index}"
            rows += numbered([
                step("click", "Compose", run=run),
                step("click", "Send", run=run, done="verified"),
            ]) + [episode("Send the note", run=run)]
        candidates, _ = self.mine(rows)
        self.assertEqual(len(candidates), 1)
        self.assertTrue(candidates[0]["requiresConfirmation"])
        self.assertTrue(candidates[0]["steps"][1]["requiresConfirmation"])
        self.assertNotIn("requiresConfirmation", candidates[0]["steps"][0])

    def test_output_path_must_stay_outside_live_folders(self):
        with self.assertRaises(ValueError):
            f.writable(Path.home() / ".godspeed" / "candidates.json")

    def test_cli_writes_a_new_candidates_file(self):
        script = Path(__file__).with_name("flywheel.py")
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "log"
            log.mkdir()
            rows = []
            for index in range(3):
                rows += batch("Charge bob@x.com 7777", run=f"cli-{index}")
            write_log(log, rows)
            out = Path(temporary) / "candidates.json"
            command = [sys.executable, "-I", str(script), "mine-recipes", str(log), "--out", str(out)]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(out.read_text(encoding="utf-8"))[0]["support"], 3)
            again = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(again.returncode, 1)
            self.assertIn("flywheel:", again.stderr)


if __name__ == "__main__":
    unittest.main()
