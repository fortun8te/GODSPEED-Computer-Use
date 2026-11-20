"""Run with python3 -I -m unittest discover -s scripts/flywheel -p 'test_*.py'. Uses synthetic logs in temp folders only."""
import importlib.util
import json
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


if __name__ == "__main__":
    unittest.main()
