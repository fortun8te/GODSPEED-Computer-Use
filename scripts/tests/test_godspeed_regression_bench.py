import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "regression_bench", Path(__file__).resolve().parents[1] / "godspeed-regression-bench.py"
)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class RegressionBenchmarkTests(unittest.TestCase):
    def test_grades_fixture_side_effects_and_transitions(self):
        before = {"pid": 123, "tabCount": 2, "windows": ["Original", "Moved fixture tab"], "moved": True}
        final = {"pid": 124, "generation": 2, "windows": ["Relaunched"], "events": bench.EXPECTED}
        self.assertTrue(bench.grade(before, final)["fixture_pass"])
        result = bench.grade(before, {**final, "events": bench.EXPECTED + ["Wrong window/Mark 1", "Original/Mark 1"]})
        self.assertFalse(result["fixture_pass"])
        self.assertEqual(result["wrong_targets"], 1)
        self.assertEqual(result["duplicate_actions"], 1)
        self.assertFalse(bench.grade({**before, "moved": False}, final)["fixture_pass"])

    def test_nearest_rank_includes_aborted_trials(self):
        runs = [
            {"wall_seconds": i, "fixture_pass": i != 19, "wrong_targets": 0, "duplicate_actions": 0}
            for i in range(1, 21)
        ]
        self.assertEqual(bench.summarize(runs)["p95_wall_seconds"], 19)
        self.assertEqual(bench.summarize(runs)["fixture_pass_rate"], 0.95)

    def test_workload_only_observes_after_dropped_reply(self):
        class Driver:
            phase = 0

            def call(self, tool, args, *, drop_reply):
                reply = ""
                if tool == "get_app_state":
                    title = bench.PHASES[self.phase]
                    reply = f'Window: "{title}", App: Fixture.\nWindow ID: {self.phase + 1}\nRecorded Mark 4'
                if args.get("label") in ("Open fixture tab", "Move fixture window"):
                    self.phase += 1
                return {"tool": tool, "reply": reply, "reply_dropped": drop_reply}

            def restart(self):
                self.phase += 1

        driver = Driver()
        steps = []
        bench.run_workload(driver, "fixture", driver.restart, steps)
        self.assertEqual(len(steps), bench.STEP_COUNT)
        lost = [i for i, step in enumerate(steps) if step.get("reply_dropped")]
        self.assertEqual(len(lost), 1)
        self.assertEqual(steps[lost[0] + 1]["tool"], "get_app_state")


if __name__ == "__main__":
    unittest.main()
