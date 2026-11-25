import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "trace_summary", Path(__file__).resolve().parents[1] / "godspeed-trace-summary.py"
)
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


def call(**fields):
    return {"event": "tool_call", "schema_version": 3, "tool": "click",
            "is_error": False, "delivery_state": "acknowledged", **fields}


class TraceSummaryTests(unittest.TestCase):
    def summarize(self, rows, **filters):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "trace.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
            )
            return trace.summarize(directory, **filters)

    def test_current_and_new_receipt_codes_are_not_silently_lost(self):
        codes = ("BACKGROUND_UNSUPPORTED", "APPROVAL_REQUIRED", "ACTION_DENIED",
                 "STALE_REF", "WINDOW_CHANGED", "new_driver_failure")
        rows = [call(is_error=True, failure_code=code) for code in codes]
        rows.append(call(
            tool="batch", batch_stop_code="cancelled", batch_done_check="weak_evidence",
            batch_not_run=2, batch_observation="failed", delivery_state="outcome_unknown",
            batch_step_receipts=[
                {"delivery_state": "outcome_unknown", "failure_code": "STALE_REF",
                 "observation": "outcome_unknown"},
                {"delivery_state": "not_sent", "failure_code": "cancelled",
                 "observation": "not_sent"},
            ],
        ))
        result = self.summarize(rows)
        self.assertEqual(result["failure_codes"], dict.fromkeys(codes, 1))
        self.assertEqual(result["batch_stops"], {"cancelled": 1})
        self.assertEqual(result["done_checks"], {"weak_evidence": 1})
        self.assertEqual(result["batch_not_run_total"], 2)
        self.assertEqual(result["batch_not_run_samples"], 1)
        self.assertEqual(result["batch_step_samples"], 2)
        self.assertEqual(result["step_failure_codes"], {"STALE_REF": 1, "cancelled": 1})
        self.assertEqual(result["step_delivery_states"], {"outcome_unknown": 1, "not_sent": 1})

    def test_queue_inclusive_latency_pairs_each_call_and_includes_timeouts(self):
        result = self.summarize([
            call(duration_ms=1, admission_ms=1000),
            call(duration_ms=1000, admission_ms=1, is_error=True, failure_code="tool_error"),
            call(duration_ms=0, admission_ms=2000, admission_timed_out=True,
                 is_error=True, failure_code="timeout", delivery_state="not_sent"),
            call(duration_ms=99),
        ])
        self.assertEqual(result["duration_samples"], 3)
        self.assertEqual(result["p50_duration_ms"], 99)
        self.assertEqual(result["p95_duration_ms"], 1000)
        self.assertEqual(result["admission_samples"], 3)
        self.assertEqual(result["queue_inclusive_samples"], 3)
        self.assertEqual(result["queue_inclusive_timeout_samples"], 1)
        self.assertEqual(result["p50_queue_inclusive_ms"], 1001)
        self.assertEqual(result["p95_queue_inclusive_ms"], 2000)
        self.assertNotEqual(result["p50_queue_inclusive_ms"],
                            result["p50_duration_ms"] + result["p50_admission_ms"])

    def test_helper_routes_do_not_double_count_image_requests_or_missing_rows(self):
        result = self.summarize([
            call(telemetry={"choose_requests": 2, "helper_image_requests": 2,
                            "helper_busy_responses": 1, "gsd1_read_requests": 1}),
            call(telemetry={"visual_search_ocr_fast": 2}),
            call(telemetry={}),
            call(),
            call(telemetry=None),
        ])
        activity = result["helper_activity"]
        self.assertEqual(activity["telemetry_calls"], 3)
        self.assertEqual(activity["calls_without_telemetry"], 2)
        self.assertEqual(activity["calls_with_helper_requests"], 1)
        self.assertEqual(activity["requests_by_route"], {"choose": 2, "gsd1_read": 1})
        self.assertEqual(activity["requests_total"], 3)
        self.assertEqual(activity["requests_per_telemetry_call"], 1)
        missing = self.summarize([call(), call(telemetry=None)])["helper_activity"]
        self.assertIsNone(missing["requests_per_telemetry_call"])
        self.assertEqual(missing["calls_without_telemetry"], 2)

    def test_local_routing_fraction_requires_both_action_counters(self):
        result = self.summarize([
            call(tool="handoff", handoff_metrics={"rules": 2, "model": 1, "verified": 1},
                 telemetry={"visual_search_ocr_fast": 2, "visual_search_ocr_accurate": 1,
                            "visual_search_vision": 1, "visual_search_ambiguous": 1}),
            call(tool="handoff", handoff_metrics={"rules": 8}),
            call(),
        ])
        routing = result["local_routing"]
        self.assertEqual(routing["handoff_metric_calls"], 2)
        self.assertEqual(routing["handoff_routing_calls"], 1)
        self.assertEqual(routing["rule_actions"], 2)
        self.assertEqual(routing["model_actions"], 1)
        self.assertEqual(routing["rule_action_fraction"], 2 / 3)
        self.assertEqual(result["handoff_totals"]["rules"], 10)
        self.assertEqual(routing["visual_search_routes"],
                         {"ocr_fast": 2, "ocr_accurate": 1, "vision": 1, "ambiguous": 1})

    def test_filters_use_both_run_and_driver_and_ignore_non_calls(self):
        result = self.summarize([
            call(run_id="trial", driver_build="new", duration_ms=5),
            call(run_id="trial", driver_build="old", duration_ms=100),
            call(run_id="other", driver_build="new", duration_ms=200),
            call(event="session_end", run_id="trial", driver_build="new"),
        ], run_id="trial", driver_build="new")
        self.assertEqual(result["calls"], 1)
        self.assertEqual(result["p95_duration_ms"], 5)

    def test_invalid_numeric_samples_are_not_zero_duration_or_free_helpers(self):
        result = self.summarize([
            call(duration_ms=True, admission_ms=-1, reply_text_bytes=False,
                 telemetry={"choose_requests": float("nan"), "locate_requests": True}),
            call(duration_ms=float("inf"), admission_ms="5", reply_text_bytes=-1),
            call(duration_ms=10 ** 400, admission_ms=None),
            [],
        ])
        self.assertEqual(result["calls"], 3)
        self.assertEqual(result["malformed_rows"], 1)
        self.assertEqual(result["duration_samples"], 0)
        self.assertEqual(result["admission_samples"], 0)
        self.assertEqual(result["reply_size_samples"], 0)
        self.assertEqual(result["queue_inclusive_samples"], 0)
        self.assertNotIn("p50_duration_ms", result)
        self.assertEqual(result["helper_activity"]["requests_by_route"], {})
        json.dumps(result, allow_nan=False)

    def test_non_error_and_acknowledged_calls_do_not_become_verified_checks(self):
        result = self.summarize([
            call(batch_done_check="weak_evidence"),
            call(batch_done_check="skipped"),
            call(batch_done_check="unmet"),
            call(batch_done_check="verified", delivery_state="verified"),
            call(delivery_state="outcome_unknown"),
            call(delivery_state=None, is_error=None),
        ])
        self.assertEqual(result["calls"], 6)
        self.assertEqual(result["tool_errors"], 0)
        self.assertEqual(result["error_flag_samples"], 5)
        self.assertEqual(result["delivery_state_samples"], 5)
        self.assertEqual(result["delivery_states"]["verified"], 1)
        self.assertEqual(result["done_check_samples"], 4)
        self.assertEqual(result["done_checks"],
                         {"weak_evidence": 1, "skipped": 1, "unmet": 1, "verified": 1})

    def test_mixed_schema_counts_and_reply_size_denominators(self):
        result = self.summarize([
            call(schema_version=1, reply_text_bytes=0),
            call(schema_version=2, batch_failed=True, reply_text_bytes=200),
            call(schema_version=3),
        ])
        self.assertEqual(result["calls"], 3)
        self.assertEqual(result["legacy_calls"], 1)
        self.assertEqual(result["calls_v2"], 1)
        self.assertEqual(result["calls_v3"], 1)
        self.assertEqual(result["batch_failures_v2"], 1)
        self.assertEqual(result["reply_size_samples"], 2)
        self.assertEqual(result["reply_text_bytes_total"], 200)


if __name__ == "__main__":
    unittest.main()
