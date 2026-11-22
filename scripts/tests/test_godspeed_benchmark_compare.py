#!/usr/bin/env python3
"""Synthetic fixtures only. No driver, model, or GUI runs."""

from copy import deepcopy
import json
from pathlib import Path
import runpy
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "godspeed-benchmark-compare.py"
API = runpy.run_path(str(SCRIPT))


def make_rows(suite, schedule):
    return [
        {
            "schema": 1,
            "suite": suite,
            "task": task,
            "seed": seed,
            "mode": mode,
            "identity": {field: field + "-fixture" for field in API["COMMON"]},
            "driver": {"name": "reference", "version": "1", "config": "fixture"},
            "status": "scored",
            "checker_pass": True,
            "gui_only": True,
            "undisturbed": dict.fromkeys(API["CRITERIA"], True) if mode == "background" else None,
            "metrics": {"duration_ms": 12, "agent_calls": 3, "input_tokens": None, "output_tokens": 22},
        }
        for task, seed, mode in sorted(schedule)
    ]


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.schedule = API["scale_schedule"]()
        self.suite = "scale-bench-v2"
        self.baseline = make_rows(self.suite, self.schedule)
        self.candidate = deepcopy(self.baseline)
        for row in self.candidate:
            row["driver"]["name"] = "candidate"

    def run_comparison(self, *options):
        paths = []
        for name, rows in (("baseline", self.baseline), ("candidate", self.candidate)):
            path = self.directory / f"{name}.jsonl"
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))
            paths.append(path)
        return subprocess.run(
            [sys.executable, SCRIPT, "--suite", self.suite, *options, *paths],
            capture_output=True, text=True, check=False,
        )

    def assert_blocked(self, reason, *options):
        result = self.run_comparison(*options)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn(reason, result.stderr)

    def test_official_denominators_seed_and_outcomes(self):
        self.assertIn(("IR-02", 565606, "background"), self.schedule)
        self.assertEqual(len(self.schedule), 90)
        background = [row for row in self.candidate if row["mode"] == "background"]
        background[0]["undisturbed"]["pointer"] = None
        background[1]["gui_only"] = False
        background[2]["checker_pass"] = False
        background[3]["metrics"]["duration_ms"] = 3
        result = self.run_comparison()
        self.assertEqual(result.returncode, 0, result.stderr)
        conditions = json.loads(result.stdout)["conditions"]
        self.assertEqual(conditions["foreground"]["scheduled"], 50)
        measured = conditions["background"]
        self.assertEqual(measured["scheduled"], 40)
        self.assertEqual(measured["candidate"]["full_pass"], 37)
        self.assertEqual(measured["candidate"]["unmeasured_criteria"]["pointer"], 1)
        self.assertEqual(measured["full_pass_delta_percentage_points"], -7.5)
        self.assertIsNone(measured["paired_metric_deltas"]["input_tokens"]["median_candidate_minus_baseline"])

    def test_cached_tokens_are_reported_with_paired_coverage(self):
        for row in self.baseline:
            row["metrics"].update(input_tokens=100, cached_input_tokens=80, reasoning_output_tokens=5)
        for row in self.candidate:
            row["metrics"].update(input_tokens=90, cached_input_tokens=85, reasoning_output_tokens=3)
        result = self.run_comparison()
        self.assertEqual(result.returncode, 0, result.stderr)
        metrics = json.loads(result.stdout)["conditions"]["background"]["paired_metric_deltas"]
        self.assertEqual(metrics["uncached_input_tokens"]["median_candidate_minus_baseline"], -15)
        self.assertEqual(metrics["cached_input_tokens"]["median_candidate_minus_baseline"], 5)
        self.assertEqual(metrics["reasoning_output_tokens"]["median_candidate_minus_baseline"], -2)
        self.assertEqual(metrics["cache_write_input_tokens"]["matched_observations"], 0)

    def test_cached_tokens_cannot_exceed_input(self):
        self.candidate[0]["metrics"].update(input_tokens=100, cached_input_tokens=101)
        self.assert_blocked("cached input exceeds total input")

    def test_missing_both_arms_is_not_valid(self):
        self.baseline.pop()
        self.candidate.pop()
        self.assert_blocked("missing 1")

    def test_harness_error_requires_retry(self):
        self.candidate[0].update(status="harness_error", checker_pass=None, gui_only=None, undisturbed=None)
        self.assert_blocked("harness errors 1")

    def test_duplicate_does_not_replace_attempt(self):
        self.candidate.append(deepcopy(self.candidate[0]))
        self.assert_blocked("duplicate trial")

    def test_environment_mismatch_blocks_comparison(self):
        for row in self.candidate:
            row["identity"]["host"] = "different host"
        self.assert_blocked("unmatched experiment identity: host")

    def test_aside_profile_requires_external_schedule(self):
        self.suite = "aside-internal"
        self.assert_blocked("requires --schedule")
        self.schedule = {(task, 0, "foreground") for task in ("calculator", "textedit", "folder", "file")}
        self.baseline = make_rows(self.suite, self.schedule)
        self.candidate = deepcopy(self.baseline)
        for row in self.candidate:
            row["driver"]["name"] = "candidate"
        schedule_file = self.directory / "aside-schedule.json"
        schedule_file.write_text(json.dumps({
            "schema": 1, "suite": self.suite,
            "trials": [{"task": task, "seed": seed, "mode": mode} for task, seed, mode in sorted(self.schedule)],
        }))
        result = self.run_comparison("--schedule", schedule_file)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["conditions"]["foreground"]["scheduled"], 4)
        self.suite = "scale-bench-v2"
        self.assert_blocked("suite mismatch")


if __name__ == "__main__":
    unittest.main()
