#!/usr/bin/env python3
"""Report call-level reliability, local routes, timing and reply size from metadata."""

import argparse
from collections import Counter
import json
import math
from pathlib import Path

DELIVERY_STATES = ("not_sent", "outcome_unknown", "acknowledged", "verified")
# helper_image_requests overlaps these routes; it is not an additional request.
HELPER_ROUTES = ("decide", "choose", "locate", "gsd1_action", "gsd1_read", "gsd1_recover")
VISUAL_ROUTES = ("ocr_fast", "ocr_accurate", "vision", "ambiguous")


def nonnegative_number(value):
    if type(value) not in (int, float) or value < 0:
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def record_label(totals, value):
    # Retain new receipt codes from newer drivers instead of silently dropping them.
    if isinstance(value, str) and value:
        totals[value] += 1


def percentiles(out, values, sample_key, metric):
    out[sample_key] = len(values)
    if values:
        values.sort()
        for percentile in (50, 95):
            out[f"p{percentile}_{metric}"] = values[math.ceil(len(values) * percentile / 100) - 1]


def summarize(directory, run_id=None, driver_build=None):
    counts = Counter()
    failures = Counter()
    tools = Counter()
    delivery_states = Counter()
    telemetry = Counter()
    handoffs = Counter()
    batch_stops = Counter()
    step_observations = Counter()
    step_deliveries = Counter()
    step_failures = Counter()
    batch_observations = Counter()
    done_checks = Counter()
    helper_requests = Counter()
    handoff_routes = Counter()
    durations = []
    admissions = []
    queue_inclusive = []
    reply_sizes = []
    for path in sorted(directory.glob("*.jsonl")):
        with path.open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                    if not isinstance(row, dict):
                        raise ValueError("expected a record")
                except ValueError:
                    counts["malformed_rows"] += 1
                    continue
                if row.get("event") != "tool_call":
                    continue
                if run_id is not None and row.get("run_id") != run_id:
                    continue
                if driver_build is not None and row.get("driver_build") != driver_build:
                    continue
                counts["calls"] += 1
                if isinstance(row.get("tool"), str):
                    tools[row["tool"]] += 1
                delivery = row.get("delivery_state")
                record_label(delivery_states, delivery)
                counts["delivery_state_samples"] += delivery in DELIVERY_STATES
                for field, totals in (("telemetry", telemetry), ("handoff_metrics", handoffs)):
                    metrics = row.get(field)
                    if isinstance(metrics, dict):
                        counts[f"{field}_calls"] += 1
                        for key, value in metrics.items():
                            if nonnegative_number(value):
                                totals[key] += value
                metrics = row.get("telemetry")
                if isinstance(metrics, dict):
                    requests = 0
                    for route in HELPER_ROUTES:
                        value = metrics.get(f"{route}_requests")
                        if nonnegative_number(value):
                            helper_requests[route] += value
                            requests += value
                    counts["calls_with_helper_requests"] += requests > 0
                metrics = row.get("handoff_metrics")
                if isinstance(metrics, dict) and all(nonnegative_number(metrics.get(key)) for key in ("rules", "model")):
                    counts["handoff_routing_calls"] += 1
                    for key in ("rules", "model"):
                        handoff_routes[key] += metrics[key]
                counts["error_flag_samples"] += type(row.get("is_error")) is bool
                counts["tool_errors"] += row.get("is_error") is True
                counts["screenshots_returned"] += row.get("screenshot_returned") is True
                if row.get("schema_version") == 2:
                    counts["calls_v2"] += 1
                    counts["batch_failures_v2"] += row.get("batch_failed") is True
                    counts["decision_hints_v2"] += row.get("decision_hint") is True
                    counts["vision_clicks_v2"] += row.get("vision_click") is True
                elif row.get("schema_version") == 3:
                    counts["calls_v3"] += 1
                    counts["batch_failures_v3"] += row.get("batch_failed") is True
                    counts["decision_hints_v3"] += row.get("decision_hint") is True
                    counts["vision_clicks_v3"] += row.get("vision_click") is True
                    record_label(failures, row.get("failure_code"))
                    record_label(batch_stops, row.get("batch_stop_code"))
                    record_label(batch_observations, row.get("batch_observation"))
                    record_label(done_checks, row.get("batch_done_check"))
                    not_run = row.get("batch_not_run")
                    if type(not_run) is int and not_run >= 0:
                        counts["batch_not_run_samples"] += 1
                        counts["batch_not_run_total"] += not_run
                    steps = row.get("batch_step_receipts")
                    if isinstance(steps, list):
                        for step in steps:
                            if isinstance(step, dict):
                                counts["batch_step_samples"] += 1
                                record_label(step_observations, step.get("observation"))
                                record_label(step_deliveries, step.get("delivery_state"))
                                record_label(step_failures, step.get("failure_code"))
                else:
                    counts["legacy_calls"] += 1
                counts["admission_timeouts"] += row.get("admission_timed_out") is True
                admission = row.get("admission_ms")
                if nonnegative_number(admission):
                    admissions.append(admission)
                value = row.get("duration_ms")
                timed_out = row.get("admission_timed_out") is True
                if not timed_out and nonnegative_number(value):
                    durations.append(value)
                # Timeout records have a dummy execution duration: only admission ran.
                # Missing admission is unknown, not a zero-length queue wait.
                if nonnegative_number(admission) and (timed_out or nonnegative_number(value)):
                    total = admission if timed_out else admission + value
                    if nonnegative_number(total):
                        queue_inclusive.append(total)
                        counts["queue_inclusive_timeout_samples"] += timed_out
                reply_size = row.get("reply_text_bytes")
                if type(reply_size) is int and reply_size >= 0:
                    reply_sizes.append(reply_size)
    out = {key: counts[key] for key in (
        "calls", "legacy_calls", "tool_errors", "screenshots_returned", "batch_failures_v2",
        "calls_v2", "decision_hints_v2", "vision_clicks_v2", "calls_v3", "batch_failures_v3",
        "decision_hints_v3", "vision_clicks_v3", "malformed_rows", "admission_timeouts",
        "error_flag_samples", "delivery_state_samples", "batch_step_samples",
        "batch_not_run_samples", "batch_not_run_total", "queue_inclusive_timeout_samples",
    )}
    out["tool_counts"] = dict(sorted(tools.items()))
    out["delivery_states"] = dict(sorted(delivery_states.items()))
    out["telemetry_totals"] = dict(sorted(telemetry.items()))
    out["handoff_totals"] = dict(sorted(handoffs.items()))
    requests = sum(helper_requests.values())
    out["helper_activity"] = {
        "telemetry_calls": counts["telemetry_calls"],
        "calls_without_telemetry": counts["calls"] - counts["telemetry_calls"],
        "calls_with_helper_requests": counts["calls_with_helper_requests"],
        "requests_by_route": dict(sorted(helper_requests.items())),
        "requests_total": requests,
        "requests_per_telemetry_call": requests / counts["telemetry_calls"] if counts["telemetry_calls"] else None,
    }
    actions = sum(handoff_routes.values())
    out["local_routing"] = {
        "handoff_metric_calls": counts["handoff_metrics_calls"],
        "handoff_routing_calls": counts["handoff_routing_calls"],
        "rule_actions": handoff_routes["rules"],
        "model_actions": handoff_routes["model"],
        "rule_action_fraction": handoff_routes["rules"] / actions if actions else None,
        "visual_search_routes": {route: telemetry[f"visual_search_{route}"] for route in VISUAL_ROUTES
                                 if f"visual_search_{route}" in telemetry},
    }
    out["failure_codes"] = dict(sorted(failures.items()))
    out["batch_stops"] = dict(sorted(batch_stops.items()))
    out["step_observations"] = dict(sorted(step_observations.items()))
    out["step_delivery_states"] = dict(sorted(step_deliveries.items()))
    out["step_failure_codes"] = dict(sorted(step_failures.items()))
    out["batch_observations"] = dict(sorted(batch_observations.items()))
    out["done_checks"] = dict(sorted(done_checks.items()))
    out["done_check_samples"] = sum(done_checks.values())
    percentiles(out, durations, "duration_samples", "duration_ms")
    percentiles(out, admissions, "admission_samples", "admission_ms")
    percentiles(out, queue_inclusive, "queue_inclusive_samples", "queue_inclusive_ms")
    percentiles(out, reply_sizes, "reply_size_samples", "reply_text_bytes")
    if reply_sizes:
        out["reply_text_bytes_total"] = sum(reply_sizes)
    return out


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path, default=Path.home() / ".godspeed" / "trajectories")
    parser.add_argument("--run-id", help="only count calls from this run")
    parser.add_argument("--driver-build", help="only count calls from this driver build")
    args = parser.parse_args()
    if not args.directory.is_dir():
        parser.error("trajectory directory does not exist")
    print(json.dumps(summarize(args.directory, args.run_id, args.driver_build), indent=2))
