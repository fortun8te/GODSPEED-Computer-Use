#!/usr/bin/env python3
"""Portable runner/protocol tests, not native GUI or model performance evidence."""

from copy import deepcopy
import importlib.util
import io
import errno
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "godspeed-hillclimb.py"
FIXTURES = SCRIPT.parent / "fixtures"
SPEC = importlib.util.spec_from_file_location("godspeed_hillclimb", SCRIPT)
HC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HC)


def manifest():
    value = json.loads((FIXTURES / "hillclimb-demo.json").read_text())
    value["adapter"] = [sys.executable, str(FIXTURES / "hillclimb-demo.py")]
    value["artifacts"] = [str(FIXTURES / "hillclimb-demo.py")]
    value["train"] = value["train"][:1]
    value["holdout"] = value["holdout"][:1]
    return value


def result(request, cost=100):
    return HC.validate_result({
        "schema": 1, "case_id": request["case"]["id"], "completed": True,
        "checker_pass": True, "checks": {check: True for check in request["case"]["checks"]},
        "safety": dict.fromkeys(HC.SAFETY, 0),
        "metrics": {"duration_ms": 100, "observation_bytes": cost, "agent_calls": 0, "helper_calls": 0},
        "token_source": None,
    }, request)


def rows_for(value, costs=(100, 70, 100)):
    rows = []
    for case in value["train"]:
        for seed in value["seeds"]:
            for repeat in range(value["repeats"]):
                for arm, cost in zip(HC.ARMS, costs):
                    request = {"case": case}
                    rows.append({"case_id": case["id"], "seed": seed, "repeat": repeat, "arm": arm,
                                 "status": "ok", "result": result(request, cost), "quality_failures": []})
    return rows


class HillclimbTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.value = manifest()

    def write_manifest(self, value=None):
        path = self.root / "manifest.json"
        path.write_text(json.dumps(value or self.value))
        return path

    def run_cli(self, command="run", output=None):
        argv = [sys.executable, SCRIPT, command, self.write_manifest()]
        if command == "run":
            argv.extend(["--output", output or self.root / "run"])
        return subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False)

    def test_real_demo_rejects_information_loss_then_qualifies_compact(self):
        completed = self.run_cli()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads((self.root / "run/report.json").read_text())
        self.assertEqual(report["status"], "qualified")
        self.assertEqual(report["recommended_profile"], {"encoding": "compact"})
        self.assertFalse(report["applied"])
        self.assertEqual(report["holdout_evaluations"], 1)
        self.assertEqual(report["trials"], 27)
        self.assertEqual(len(report["comparisons"]), 3)
        self.assertFalse(report["comparisons"][0]["accepted"])
        self.assertIn("quality", " ".join(report["comparisons"][0]["reasons"]))
        coverage = report["comparisons"][-1]["coverage"]
        self.assertEqual(coverage["observation_bytes"]["paired_trials"], 3)
        self.assertEqual(coverage["input_tokens"]["measured"], dict.fromkeys(HC.ARMS, 0))
        self.assertEqual(json.loads((self.root / "run/rollback-profile.json").read_text()), self.value["baseline"])
        events = [json.loads(line) for line in (self.root / "run/ledger.jsonl").read_text().splitlines()]
        trial_events = [event for event in events if event["event"] == "trial"]
        self.assertEqual(len(trial_events), report["trials"])
        self.assertEqual([event["arm"] for event in trial_events[:6]], list(HC.ARMS) * 2)
        frozen = next(index for index, event in enumerate(events) if event["event"] == "candidate_frozen")
        heldout = next(index for index, event in enumerate(events) if event.get("comparison") == "holdout-1")
        self.assertGreater(heldout, frozen)
        self.assertEqual((self.root / "run").stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root / "run/report.json").stat().st_mode & 0o777, 0o600)

    def test_plan_does_not_launch_adapter_or_create_results(self):
        self.value["adapter"] = ["nonexistent-adapter"]
        completed = self.run_cli("plan")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["bounds"]["max_trials"], 36)
        self.assertFalse((self.root / "run").exists())

    def test_existing_directory_is_never_overwritten(self):
        output = self.root / "run"
        output.mkdir()
        (output / "sentinel").write_text("keep")
        completed = self.run_cli(output=output)
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(sorted(path.name for path in output.iterdir()), ["sentinel"])

    def test_missing_metrics_and_unknown_safety_cannot_win(self):
        rows = rows_for(self.value)
        rows[1]["result"]["metrics"]["observation_bytes"] = None
        evaluation = HC.evaluate(rows, self.value, self.value["train"])
        self.assertFalse(evaluation["accepted"])
        self.assertEqual(evaluation["coverage"]["observation_bytes"]["paired_trials"], 2)
        request = {"case": self.value["train"][0]}
        measured = result(request)
        measured["safety"]["user_disturbances"] = None
        self.assertTrue(HC.quality_failures(measured, request["case"], self.value))

    def test_fast_aborted_run_and_missing_receipt_do_not_count_as_success(self):
        request = {"case": self.value["train"][0]}
        measured = result(request, 1)
        for field in ("completed", "checker_pass"):
            broken = deepcopy(measured)
            broken[field] = False
            self.assertTrue(HC.quality_failures(broken, request["case"], self.value))
        measured["checks"].pop("target_retained")
        self.assertTrue(HC.quality_failures(measured, request["case"], self.value))
        rows = rows_for(self.value, (100, 1, 100))
        rows[1]["quality_failures"] = ["incomplete task"]
        self.assertFalse(HC.evaluate(rows, self.value, self.value["train"])["accepted"])

    def test_drift_and_per_case_regressions_are_not_hidden_in_averages(self):
        rows = rows_for(self.value, (100, 70, 80))
        evaluation = HC.evaluate(rows, self.value, self.value["train"])
        self.assertIn("control drift exceeds limit: observation_bytes", evaluation["reasons"])
        second = deepcopy(self.value["train"][0])
        second["id"] = "second"
        self.value["train"].append(second)
        rows = rows_for(self.value)
        for row in rows:
            if row["case_id"] == "second" and row["arm"] == "candidate":
                row["result"]["metrics"]["observation_bytes"] = 101
        evaluation = HC.evaluate(rows, self.value, self.value["train"])
        self.assertIn("case regression exceeds limit: observation_bytes", evaluation["reasons"])

    def test_repeats_use_medians_and_both_neighbouring_controls(self):
        rows = rows_for(self.value)
        rows[1]["result"]["metrics"]["observation_bytes"] = 10000
        evaluation = HC.evaluate(rows, self.value, self.value["train"])
        self.assertTrue(evaluation["accepted"])
        self.assertEqual(evaluation["metrics"]["observation_bytes"]["cells"][0]["medians"]["candidate"], 70)
        self.value["objective"]["max_control_drift"] = 1
        rows = rows_for(self.value, (100, 70, 69))
        self.assertFalse(HC.evaluate(rows, self.value, self.value["train"])["accepted"])

    def test_missing_or_duplicate_trials_fail_even_when_counts_match(self):
        rows = rows_for(self.value)
        rows[-1] = deepcopy(rows[0])
        evaluation = HC.evaluate(rows, self.value, self.value["train"])
        self.assertIn("incomplete or duplicate matched schedule", evaluation["reasons"])
        self.assertFalse(evaluation["accepted"])

    def test_zero_baselines_are_not_infinite_wins_or_json_nan(self):
        for costs in ((0, 0, 0), (0, 1, 0)):
            evaluation = HC.evaluate(rows_for(self.value, costs), self.value, self.value["train"])
            self.assertFalse(evaluation["accepted"])
            json.dumps(evaluation, allow_nan=False)

    def test_context_and_memory_limits_require_actual_measurements(self):
        self.value.update(context_limit_tokens=16384, memory_limit_bytes=4096)
        request = {"case": self.value["train"][0]}
        measured = result(request)
        self.assertEqual(len(HC.quality_failures(measured, request["case"], self.value)), 2)
        measured["metrics"].update(peak_context_tokens=16000, peak_memory_bytes=4000)
        self.assertFalse(HC.quality_failures(measured, request["case"], self.value))
        measured["metrics"]["peak_context_tokens"] = 16385
        self.assertTrue(HC.quality_failures(measured, request["case"], self.value))

    def test_malformed_numeric_and_token_receipts_are_rejected(self):
        request = {"case": self.value["train"][0]}
        for metric, value in (("duration_ms", True), ("observation_bytes", -1),
                              ("duration_ms", float("nan")), ("input_tokens", 1.5),
                              ("input_tokens", 10**400)):
            measured = result(request)
            measured["metrics"][metric] = value
            with self.subTest(metric=metric, value=str(value)[:20]), self.assertRaises(HC.Invalid):
                HC.validate_result(measured, request)
        measured = result(request)
        measured["metrics"].update(input_tokens=100, cached_input_tokens=101)
        measured["token_source"] = "fixture usage receipt"
        with self.assertRaisesRegex(HC.Invalid, "cached_input_tokens"):
            HC.validate_result(measured, request)
        measured["metrics"].update(cached_input_tokens=80, uncached_input_tokens=21)
        with self.assertRaisesRegex(HC.Invalid, "uncached_input_tokens"):
            HC.validate_result(measured, request)
        measured["metrics"].update(uncached_input_tokens=20, output_tokens=5, reasoning_output_tokens=6)
        with self.assertRaisesRegex(HC.Invalid, "reasoning_output_tokens"):
            HC.validate_result(measured, request)
        measured["metrics"].update(reasoning_output_tokens=3)
        self.assertEqual(HC.validate_result(measured, request)["metrics"]["uncached_input_tokens"], 20)
        measured["token_source"] = None
        with self.assertRaisesRegex(HC.Invalid, "token_source"):
            HC.validate_result(measured, request)

    def test_duplicate_json_keys_nonfinite_and_case_mismatch_are_errors(self):
        for encoded in ('{"schema":1,"schema":1}', '{"metric":NaN}', '{"metric":Infinity}'):
            with self.assertRaises(HC.Invalid):
                HC.parse_json(encoded)
        request = {"case": self.value["train"][0]}
        measured = result(request)
        measured["case_id"] = "other"
        with self.assertRaisesRegex(HC.Invalid, "case mismatch"):
            HC.validate_result(measured, request)

    def test_cache_writes_require_total_and_fit_within_uncached_input(self):
        request = {"case": self.value["train"][0]}
        invalid = [
            {"input_tokens": 1, "cached_input_tokens": 1, "uncached_input_tokens": 0, "cache_write_input_tokens": 2},
            {"input_tokens": 10, "cached_input_tokens": 9, "cache_write_input_tokens": 2},
            {"input_tokens": 3, "cache_write_input_tokens": 4},
            {"cache_write_input_tokens": 0},
        ]
        for metrics in invalid:
            measured = result(request)
            measured["metrics"].update(metrics)
            measured["token_source"] = "normalized fixture usage receipt"
            with self.subTest(metrics=metrics), self.assertRaisesRegex(HC.Invalid, "cache_write_input_tokens"):
                HC.validate_result(measured, request)
        for metrics in (
            {"input_tokens": 10, "cached_input_tokens": 8, "uncached_input_tokens": 2, "cache_write_input_tokens": 2},
            {"input_tokens": 10, "cache_write_input_tokens": 2},
            {"input_tokens": 0, "cached_input_tokens": 0, "cache_write_input_tokens": 0},
        ):
            measured = result(request)
            measured["metrics"].update(metrics)
            measured["token_source"] = "normalized fixture usage receipt"
            validated = HC.validate_result(measured, request)
            if "cached_input_tokens" not in metrics:
                self.assertIsNone(validated["metrics"]["cached_input_tokens"])
                self.assertIsNone(validated["metrics"]["uncached_input_tokens"])

    def test_manifest_bounds_and_separation_are_enforced(self):
        for change in ({"repeats": 2}, {"seeds": [True]}, {"max_candidates": 1001},
                       {"holdout": self.value["train"]}, {"seeds": [1, 1]}):
            with self.subTest(change=change), self.assertRaises(HC.Invalid):
                HC.load_manifest(self.write_manifest({**self.value, **change}))

    def mock_adapter(self, command, cwd, request, timeout):
        compact = request["profile"]["encoding"] == "compact"
        measured = result(request, 70 if compact else 100)
        return {"status": "ok", "runner_wall_ms": 1, "exit_code": 0, "stderr": "", "result": measured}

    def test_failed_holdout_does_not_try_runner_up_or_write_profile(self):
        self.value["parameters"]["encoding"] = ["verbose", "compact", "another"]
        heldout_id = self.value["holdout"][0]["id"]

        def adapter(*args):
            row = self.mock_adapter(*args)
            request = args[2]
            if request["case"]["id"] == heldout_id and request["profile"]["encoding"] == "compact":
                row["result"]["checker_pass"] = False
            return row

        with patch.object(HC, "run_adapter", side_effect=adapter):
            report = HC.Search(self.value, self.root, self.root / "run").run()
        self.assertEqual(report["status"], "qualification_failed")
        self.assertEqual(report["holdout_evaluations"], 1)
        self.assertIsNone(report["recommended_profile"])
        self.assertFalse((self.root / "run/recommended-profile.json").exists())
        self.assertEqual(report["comparisons"][-1]["phase"], "holdout")
        self.assertEqual(sum(item["phase"] == "holdout" for item in report["comparisons"]), 1)

    def test_changed_pinned_artifact_blocks_qualification(self):
        tracked = self.root / "evaluated-implementation.txt"
        tracked.write_text("original")
        self.value["artifacts"].append(str(tracked))
        self.value["parameters"]["encoding"] = ["verbose", "compact"]

        def adapter(*args):
            tracked.write_text("changed during evaluation")
            return self.mock_adapter(*args)

        with patch.object(HC, "run_adapter", side_effect=adapter):
            report = HC.Search(self.value, self.root, self.root / "run").run()
        self.assertEqual(report["status"], "artifacts_changed")
        self.assertIsNone(report["recommended_profile"])
        self.assertFalse((self.root / "run/recommended-profile.json").exists())

    def test_budget_exhaustion_preserves_failure_ledger_and_never_promotes(self):
        self.value["max_total_seconds"] = 0.1
        self.value["adapter"] = [sys.executable, "-c", "import time; time.sleep(30)"]
        report = HC.Search(self.value, self.root, self.root / "run").run()
        self.assertEqual(report["status"], "budget_exhausted")
        events = [json.loads(line) for line in (self.root / "run/ledger.jsonl").read_text().splitlines()]
        self.assertTrue(any(event.get("status") == "timeout" for event in events))
        self.assertIsNone(report["recommended_profile"])
        self.assertLess(report["elapsed_seconds"], 3)

    def test_initial_and_final_artifact_hashing_share_the_total_budget(self):
        self.value["parameters"]["encoding"] = ["verbose", "compact"]
        self.value["max_total_seconds"] = 0.15
        original = HC.fingerprints
        for delayed_call in (1, 2):
            clock, calls = [0.0], [0]
            output = self.root / f"hash-{delayed_call}"

            def delayed_hash(*args, **kwargs):
                pins = original(*args, **kwargs)
                calls[0] += 1
                if calls[0] == delayed_call:
                    clock[0] += 0.25
                return pins

            with self.subTest(delayed_call=delayed_call), \
                    patch.object(HC.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(HC, "fingerprints", side_effect=delayed_hash), \
                    patch.object(HC, "run_adapter", side_effect=self.mock_adapter):
                report = HC.Search(self.value, self.root, output).run()
            self.assertEqual(report["status"], "budget_exhausted")
            self.assertEqual(report["elapsed_seconds"], 0.25)
            self.assertEqual(report["trials"], 0 if delayed_call == 1 else 18)
            self.assertIsNone(report["recommended_profile"])
            self.assertFalse((output / "recommended-profile.json").exists())
            self.assertEqual(json.loads((output / "report.json").read_text())["status"], "budget_exhausted")

    def test_artifact_hash_checks_deadline_between_bounded_chunks(self):
        clock = [0.0]

        class SlowStream(io.BytesIO):
            reads = 0

            def read(self, size):
                self.reads += 1
                if size > 1024 * 1024:
                    raise AssertionError("unbounded artifact read")
                clock[0] += 0.1
                return super().read(size)

        stream = SlowStream(b"x" * (3 * 1024 * 1024))
        with patch.object(HC.time, "monotonic", side_effect=lambda: clock[0]):
            with self.assertRaises(HC.BudgetExhausted):
                HC._hash_stream(stream, deadline=0.15)
        self.assertEqual(stream.reads, 2)
        self.assertLess(stream.tell(), len(stream.getbuffer()))

    def test_profile_write_cannot_publish_after_deadline(self):
        original_sync, original_replace = HC.os.fsync, HC.os.replace
        for delayed_operation in ("fsync", "replace"):
            clock = [0.0]
            path = self.root / f"late-{delayed_operation}.json"
            original = original_sync if delayed_operation == "fsync" else original_replace

            def delayed(*args):
                result = original(*args)
                clock[0] += 0.25
                return result

            with self.subTest(operation=delayed_operation), \
                    patch.object(HC.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(HC.os, delayed_operation, side_effect=delayed):
                with self.assertRaises(HC.BudgetExhausted):
                    HC.write_json(path, {"encoding": "compact"}, deadline=0.15)
            self.assertFalse(path.exists())
            self.assertFalse(path.with_suffix(".json.tmp").exists())

    def test_process_reaping_is_bounded_after_both_termination_signals(self):
        process = Mock(pid=987654321)
        process.wait.side_effect = subprocess.TimeoutExpired("fixture", 0.2)
        with patch.object(HC.os, "killpg") as kill:
            self.assertFalse(HC.stop_group(process))
        self.assertEqual([call.args for call in kill.call_args_list],
                         [(process.pid, HC.signal.SIGTERM), (process.pid, HC.signal.SIGKILL)])
        self.assertEqual([call.kwargs for call in process.wait.call_args_list],
                         [{"timeout": 0.2}, {"timeout": 1.0}])

    def test_signal_denial_is_unconfirmed_even_when_the_leader_has_reaped(self):
        for denied in (HC.signal.SIGTERM, HC.signal.SIGKILL):
            process = Mock(pid=987654321)
            process.wait.return_value = 0
            diagnostics = []

            def signal_owned_group(group, value):
                self.assertEqual(group, process.pid)
                if value == denied:
                    raise PermissionError(errno.EPERM, "Operation not permitted")

            with self.subTest(signal=denied), patch.object(HC.os, "killpg", side_effect=signal_owned_group) as kill:
                self.assertFalse(HC.stop_group(process, diagnostics))
            expected = [(process.pid, HC.signal.SIGTERM)]
            if denied == HC.signal.SIGKILL:
                expected.append((process.pid, HC.signal.SIGKILL))
            self.assertEqual([call.args for call in kill.call_args_list], expected)
            self.assertTrue(any("PermissionError" in error for error in diagnostics))
            self.assertTrue(all(0 < call.kwargs["timeout"] <= 1 for call in process.wait.call_args_list))

    def test_disappeared_group_is_not_signalled_again_after_leader_wait(self):
        process = Mock(pid=987654321)
        process.wait.return_value = 0
        with patch.object(HC.os, "killpg", side_effect=ProcessLookupError(errno.ESRCH, "No such process")) as kill:
            self.assertTrue(HC.stop_group(process))
        kill.assert_called_once_with(process.pid, HC.signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=0.2)

    def test_signal_denial_preserves_timeout_and_closes_both_pipes(self):
        created = []
        spawn = HC.subprocess.Popen

        def capture_process(*args, **kwargs):
            process = spawn(*args, **kwargs)
            created.append(process)
            return process

        def denied_kill(group, value):
            self.assertEqual(group, created[0].pid)
            if value == HC.signal.SIGKILL:
                raise PermissionError(errno.EPERM, "Operation not permitted")
            # The short-lived child exits naturally during the bounded TERM wait.
            # No test process remains alive when this mocked signal is not delivered.

        with patch.object(HC.subprocess, "Popen", side_effect=capture_process), \
                patch.object(HC.os, "killpg", side_effect=denied_kill):
            row = HC.run_adapter([sys.executable, "-c", "import time; time.sleep(0.15)"], self.root, {}, 0.02)
        self.assertEqual(row["status"], "timeout")
        self.assertFalse(row["cleanup_complete"])
        self.assertTrue(any("SIGKILL: PermissionError" in error for error in row["cleanup_errors"]))
        self.assertEqual(created[0].returncode, 0)
        self.assertTrue(created[0].stdout.closed)
        self.assertTrue(created[0].stderr.closed)
        with patch.object(HC, "run_adapter", return_value=row) as adapter:
            report = HC.Search(self.value, self.root, self.root / "denied-cleanup").run()
        self.assertEqual(adapter.call_count, 1)
        self.assertEqual(report["status"], "error")
        self.assertIsNone(report["recommended_profile"])
        self.assertFalse((self.root / "denied-cleanup/recommended-profile.json").exists())

    def test_unconfirmed_cleanup_cannot_return_a_successful_adapter_receipt(self):
        request = {"case": self.value["train"][0]}
        code = "print(" + repr(json.dumps(result(request))) + ")"
        with patch.object(HC, "stop_group", return_value=False):
            row = HC.run_adapter([sys.executable, "-c", code], self.root, request, 5)
        self.assertEqual(row["status"], "cleanup_incomplete")
        self.assertFalse(row["cleanup_complete"])
        with patch.object(HC, "run_adapter", return_value=row) as adapter:
            report = HC.Search(self.value, self.root, self.root / "run").run()
        self.assertEqual(adapter.call_count, 1)
        self.assertEqual(report["status"], "error")
        self.assertIsNone(report["recommended_profile"])

    def test_interrupt_is_logged_and_never_promotes(self):
        with patch.object(HC, "run_adapter", side_effect=KeyboardInterrupt):
            report = HC.Search(self.value, self.root, self.root / "run").run()
        self.assertEqual(report["status"], "interrupted")
        self.assertEqual(report["trials"], 1)
        events = [json.loads(line) for line in (self.root / "run/ledger.jsonl").read_text().splitlines()]
        self.assertTrue(any(event.get("status") == "interrupted" for event in events))
        self.assertIsNone(report["recommended_profile"])

    def test_timeout_also_bounds_descendants_that_keep_pipes_open(self):
        command = [sys.executable, "-c", "import subprocess,sys; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])"]
        started = time.monotonic()
        row = HC.run_adapter(command, self.root, {}, 0.15)
        self.assertEqual(row["status"], "timeout")
        self.assertLess(time.monotonic() - started, 3)

    def test_output_limit_and_invalid_output_are_bounded_failures(self):
        row = HC.run_adapter([sys.executable, "-c", "import sys; sys.stdout.write('x' * 2000000)"], self.root, {}, 5)
        self.assertEqual(row["status"], "output_limit")
        self.assertLessEqual(len(row["stdout_excerpt"]), 4096)
        row = HC.run_adapter([sys.executable, "-c", "print('not a receipt')"], self.root, {}, 5)
        self.assertEqual(row["status"], "invalid_result")

    def test_parent_api_secrets_are_not_forwarded_to_adapter(self):
        request = {"case": self.value["train"][0]}
        receipt = result(request)
        code = "import json,os; value=json.loads(" + repr(json.dumps(receipt)) + "); value['checker_pass']='HILLCLIMB_TEST_SECRET' not in os.environ; print(json.dumps(value))"
        with patch.dict(os.environ, {"HILLCLIMB_TEST_SECRET": "private-test-value"}):
            row = HC.run_adapter([sys.executable, "-c", code], self.root, request, 5)
        self.assertEqual(row["status"], "ok")
        self.assertTrue(row["result"]["checker_pass"])


if __name__ == "__main__":
    unittest.main()
