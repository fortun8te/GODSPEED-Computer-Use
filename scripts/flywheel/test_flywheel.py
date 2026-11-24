"""Run with python3 -I scripts/flywheel/test_flywheel.py."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("flywheel", Path(__file__).with_name("flywheel.py"))
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)


class FlywheelTests(unittest.TestCase):
    def setUp(self):
        self.rows = f.heldout()
        self.replies = {
            row["meta"]["id"]: {"prediction": row["answer"], "raw": row["answer"], "model_ms": 1, "wall_ms": 2}
            for row in self.rows
        }

    def row_id(self, check, answer):
        return next(row["meta"]["id"] for row in self.rows
                    if row["meta"]["check"] == check and row["answer"] == answer)

    def test_frozen_family_partition_and_grounding(self):
        self.assertEqual(len(self.rows), 128)
        self.assertEqual(sum(len(families) for families in f.FAMILIES.values()), len(set.union(*f.FAMILIES.values())))
        ground = f.grounding_rows()
        self.assertEqual(len(ground), 9)
        dev = json.loads((f.HERE / "grounding-development.json").read_bytes())
        self.assertFalse({row["family"] for row in ground} & {row["family"] for row in dev})

    def test_refuses_same_rate_if_failures_move_to_new_rows(self):
        a, b = [row["meta"]["id"] for row in self.rows
                if row["meta"]["check"] == "click" and row["answer"] == "look_again"][:2]
        missed = self.row_id("decision", "done")
        diff = {"prediction": "done", "raw": "done", "model_ms": 1, "wall_ms": 2}
        baseline = self.replies | {a: diff, missed: {**diff, "prediction": "abstain"}}
        candidate = self.replies | {b: diff}
        old, new = [f.score(self.rows, arm) for arm in (baseline, candidate)]
        self.assertEqual(old["false_pass_rate"], new["false_pass_rate"])
        self.assertGreater(new["accuracy"], old["accuracy"])
        self.assertIn("New false click on held-out rows", f.gate(old, new, False, "d1"))

    def test_gate_blocks_new_false_done_above_and_below_threshold(self):
        wrong = self.row_id("decision", "act")
        old = f.score(self.rows, self.replies)
        for confidence, reason in [(0.80, "raw false done"), (0.90, "false done")]:
            record = {**f.decision_reply({"label": "done", "confidence": confidence, "ms": 1}, .86, .60),
                      "wall_ms": 1}
            with self.subTest(confidence=confidence):
                new = f.score(self.rows, self.replies | {wrong: record})
                self.assertIn(f"New {reason} on held-out rows", f.gate(old, new, False, "d1"))

    def test_improvement_can_only_recommend_with_valid_results(self):
        missed = self.row_id("decision", "done")
        baseline_replies = self.replies | {missed: {**self.replies[missed], "prediction": "abstain"}}
        baseline, good = [f.score(self.rows, arm) for arm in (baseline_replies, self.replies)]
        self.assertEqual(f.gate(baseline, good, False, "d1"), [])
        self.assertTrue(f.gate(baseline, good, True, "d1"))
        self.assertTrue(f.gate(good, good, False, "d1"))
        broken = f.score(self.rows, self.replies | {missed: {"error": "timeout"}})
        self.assertIn("An evaluation arm is incomplete", f.gate(broken, good, False, "d1"))

    def test_inference_omits_labels_and_refuses_over_budget(self):
        rows = self.rows[:2]
        seen = []

        class FakeRuntime:
            models = {}
            last_used = {}

            @staticmethod
            def clear_cache():
                pass

            @staticmethod
            def decide(body, log=True):
                self.assertFalse(log)
                seen.append(body)
                return {"label": "done", "confidence": .86, "ms": 1}

        def parse(row, reply):
            self.assertIn(row, rows)
            return f.decision_reply(reply, .86, .60)

        results = f.local_infer(FakeRuntime(), "d1", Path("/fake"), rows, parse)
        self.assertEqual([set(body) for body in seen], [set(f.LIMITS)] * 2)
        self.assertTrue(all(record["prediction"] == "done" for record in results.values()))
        with self.assertRaises(ValueError):
            f.samples(rows, FakeRuntime.decide, parse, 1)
        self.assertEqual(len(seen), 2)

    def test_helper_failures_stop_serial_calls_and_never_pass(self):
        seen = []

        def fail(row):
            seen.append(row)
            raise OSError("private details")

        records = f.samples(self.rows, fail, lambda row, reply: reply, 150)
        self.assertEqual(len(seen), 1)
        self.assertEqual([record["error"] for record in records.values()][:2], ["OSError", "not_run_after_error"])

    def test_grounding_uses_independent_boxes_and_rejects_bad_points(self):
        self.assertEqual(f.ground_reply({"found": True, "x": 0.5, "y": 0.5, "ms": 1}, (.4, .4, .6, .6))["prediction"], "hit")
        self.assertEqual(f.ground_reply({"found": True, "x": 0.5, "y": 0.5, "ms": 1}, None)["prediction"], "wrong_point")
        with self.assertRaises(ValueError):
            f.ground_reply({"found": True, "x": True, "y": 0.5, "ms": 1}, None)
        with self.assertRaises(ValueError):
            f.decision_reply({"label": "act", "confidence": 1, "ms": float("inf")}, .86, .60)

    def test_metadata_counts_keep_only_known_outcomes(self):
        entry = {"event": "tool_call", "tool": "batch", "capture_mode": "metadata",
                 "batch_step_receipts": [{"observation": "no_effect_seen"}, {"observation": "outcome_unknown"}],
                 "batch_stop_code": "window_changed", "batch_done_check": "unmet", "batch_not_run": 1}
        self.assertEqual(f.metadata_counts([entry]), {
            "no_effect_seen": 1, "outcome_unknown": 1, "window_changed": 1, "batch_unmet_with_unrun_steps": 1,
        })
        for key in ("result_text", "arguments", "failure_detail"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                f.metadata_counts([entry | {key: "private"}])

    def test_output_follows_symlinks_and_rejects_live_dirs(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            helper = path / "helper"
            helper.mkdir()
            alias = path / "alias"
            alias.symlink_to(helper, target_is_directory=True)
            with patch.object(f, "HELPER", helper), self.assertRaises(ValueError):
                f.writable(alias / "output.jsonl")

    def test_export_learning_labels_only_observed_outcomes(self):
        rows = [
            {"kind": "decide", "outcome": "act", "probabilities": {"a": .99}, "run_id": "r"},
            {"kind": "locate", "verified": True, "run_id": "r"},
            {"kind": "step", "tool": "click", "target_role": "AXButton", "target_label": "Save",
             "delivery_state": "delivered", "done_when": "verified", "run_id": "r", "app": "x"},
            {"kind": "step", "tool": "click", "target_role": "AXButton", "target_label": "Next",
             "delivery_state": "delivered", "done_when": "unmet", "run_id": "r"},
            {"kind": "step", "tool": "click", "delivery_state": "delivered", "run_id": "r"},
            {"kind": "step", "tool": "click", "failure_code": "stuck", "run_id": "r"},
            {"kind": "step", "tool": "click", "done_when": "weak", "run_id": "r"},
            {"kind": "episode", "goal": "Save the note", "outcome": "done", "run_id": "r"},
        ]
        with tempfile.TemporaryDirectory() as temporary:
            source, out = Path(temporary) / "src", Path(temporary) / "out.jsonl"
            source.mkdir()
            (source / "learning-2026-11-20.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows) + "\n", encoding="utf-8")
            result = f.export_learning(source, out)
            written = [json.loads(line) for line in out.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(result, {"labels": {"done": 1, "look_again": 1, "act": 1, "stuck": 1},
                                  "skipped": 4, "written": 4})
        self.assertEqual({row["answer"] for row in written}, {"done", "look_again", "act", "stuck"})
        done = next(row for row in written if row["answer"] == "done")
        self.assertEqual(set(done), {"state", "answer", "meta"})
        self.assertEqual(set(done["meta"]), {"id", "family", "source", "check", "outcome", "variant"})
        state = json.loads(done["state"])
        self.assertEqual(set(state), set(f.LIMITS))
        self.assertEqual(state["goal"], "Save the note")
        self.assertEqual(state["last_step"], "click AXButton Save")

    def test_export_learning_uses_the_correct_episode_goal(self):
        rows = [
            {"kind": "step", "tool": "click", "done_when": "verified", "run_id": "shared", "episode_id": "one"},
            {"kind": "step", "tool": "click", "done_when": "verified", "run_id": "shared", "episode_id": "two"},
            {"kind": "episode", "goal": "First goal", "run_id": "shared", "episode_id": "one"},
            {"kind": "episode", "goal": "Second goal", "run_id": "shared", "episode_id": "two"},
            {"kind": "step", "tool": "click", "done_when": "verified", "run_id": "legacy"},
            {"kind": "episode", "goal": "First legacy goal", "run_id": "legacy"},
            {"kind": "episode", "goal": "Second legacy goal", "run_id": "legacy"},
        ]
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "learning-2026-11-20.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
            output = source / "out.jsonl"
            result = f.export_learning(source, output)
            found = [json.loads(json.loads(line)["state"])["goal"] for line in output.read_text().splitlines()]
        self.assertEqual(result["written"], 2)
        self.assertEqual(found, ["First goal", "Second goal"])

    def test_export_learning_refuses_live_outputs_and_bad_rows(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "learning-2026-11-20.jsonl").write_text("not json\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                f.export_learning(source, Path(temporary) / "out.jsonl")
            (source / "learning-2026-11-20.jsonl").write_text("", encoding="utf-8")
            with self.assertRaises(ValueError):
                f.export_learning(source, Path.home() / ".godspeed" / "out.jsonl")
            self.assertFalse((Path(temporary) / "out.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
