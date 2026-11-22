#!/usr/bin/env python3
"""Report counts, timing and reply size from local Godspeed metadata."""

import argparse
from collections import Counter
import json
import math
from pathlib import Path

FAILURE_CODES = (
    "unsupported_tool", "invalid_arguments", "app_not_found", "permission_denied",
    "state_unavailable", "stale_state", "timeout", "cancelled", "recipe_verification",
    "tool_error", "internal_error",
)
BATCH_STOPS = ("step_failure", "time_budget", "window_changed", "recipe_verification")
STEP_OBSERVATIONS = ("not_sent", "no_effect_seen", "outcome_unknown")
BATCH_OBSERVATIONS = ("returned", "failed", "unavailable")
DELIVERY_STATES = ("not_sent", "outcome_unknown", "acknowledged", "verified")
DONE_CHECKS = ("not_requested", "skipped", "verified", "unmet")


def summarize(directory, run_id=None, driver_build=None):
    counts = Counter()
    failures = Counter()
    tools = Counter()
    delivery_states = Counter()
    telemetry = Counter()
    handoffs = Counter()
    batch_stops = Counter()
    step_observations = Counter()
    batch_observations = Counter()
    done_checks = Counter()
    durations = []
    admissions = []
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
                if delivery in DELIVERY_STATES:
                    delivery_states[delivery] += 1
                for field, totals in (("telemetry", telemetry), ("handoff_metrics", handoffs)):
                    metrics = row.get(field)
                    if isinstance(metrics, dict):
                        for key, value in metrics.items():
                            if type(value) in (int, float) and math.isfinite(value) and value >= 0:
                                totals[key] += value
                counts["tool_errors"] += row.get("is_error") is True
                counts["screenshots_returned"] += row.get("screenshot_returned") is True
                if row.get("schema_version") == 2:
                    counts["batch_failures_v2"] += row.get("batch_failed") is True
                    counts["decision_hints_v2"] += row.get("decision_hint") is True
                    counts["vision_clicks_v2"] += row.get("vision_click") is True
                elif row.get("schema_version") == 3:
                    counts["calls_v3"] += 1
                    counts["batch_failures_v3"] += row.get("batch_failed") is True
                    counts["decision_hints_v3"] += row.get("decision_hint") is True
                    counts["vision_clicks_v3"] += row.get("vision_click") is True
                    code = row.get("failure_code")
                    if code in FAILURE_CODES:
                        failures[code] += 1
                    stop = row.get("batch_stop_code")
                    if stop in BATCH_STOPS:
                        batch_stops[stop] += 1
                    observation = row.get("batch_observation")
                    if observation in BATCH_OBSERVATIONS:
                        batch_observations[observation] += 1
                    check = row.get("batch_done_check")
                    if check in DONE_CHECKS:
                        done_checks[check] += 1
                    steps = row.get("batch_step_receipts")
                    if isinstance(steps, list):
                        for step in steps:
                            observation = step.get("observation") if isinstance(step, dict) else None
                            if observation in STEP_OBSERVATIONS:
                                step_observations[observation] += 1
                else:
                    counts["legacy_calls"] += 1
                counts["admission_timeouts"] += row.get("admission_timed_out") is True
                admission = row.get("admission_ms")
                if type(admission) in (int, float) and math.isfinite(admission) and admission >= 0:
                    admissions.append(admission)
                value = row.get("duration_ms")
                if row.get("admission_timed_out") is not True and type(value) in (int, float) and math.isfinite(value) and value >= 0:
                    durations.append(value)
                reply_size = row.get("reply_text_bytes")
                if type(reply_size) is int and reply_size >= 0:
                    reply_sizes.append(reply_size)
    durations.sort()
    admissions.sort()
    out = {key: counts[key] for key in (
        "calls", "legacy_calls", "tool_errors", "screenshots_returned", "batch_failures_v2",
        "decision_hints_v2", "vision_clicks_v2", "calls_v3", "batch_failures_v3",
        "decision_hints_v3", "vision_clicks_v3", "malformed_rows", "admission_timeouts",
    )}
    out["tool_counts"] = dict(sorted(tools.items()))
    out["delivery_states"] = dict(sorted(delivery_states.items()))
    out["telemetry_totals"] = dict(sorted(telemetry.items()))
    out["handoff_totals"] = dict(sorted(handoffs.items()))
    out["failure_codes"] = dict(sorted(failures.items()))
    out["batch_stops"] = dict(sorted(batch_stops.items()))
    out["step_observations"] = dict(sorted(step_observations.items()))
    out["batch_observations"] = dict(sorted(batch_observations.items()))
    out["done_checks"] = dict(sorted(done_checks.items()))
    if durations:
        for percentile in (50, 95):
            out[f"p{percentile}_duration_ms"] = durations[math.ceil(len(durations) * percentile / 100) - 1]
    if admissions:
        out["admission_samples"] = len(admissions)
        for percentile in (50, 95):
            out[f"p{percentile}_admission_ms"] = admissions[math.ceil(len(admissions) * percentile / 100) - 1]
    if reply_sizes:
        reply_sizes.sort()
        out["reply_size_samples"] = len(reply_sizes)
        out["reply_text_bytes_total"] = sum(reply_sizes)
        for percentile in (50, 95):
            out[f"p{percentile}_reply_text_bytes"] = reply_sizes[math.ceil(len(reply_sizes) * percentile / 100) - 1]
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
