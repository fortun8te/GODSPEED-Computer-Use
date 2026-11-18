#!/usr/bin/env python3
"""Report tool counts and timing from local Godspeed JSONL without exporting UI content."""

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
DONE_CHECKS = ("not_requested", "skipped", "verified", "unmet")


def summarize(directory):
    counts = Counter()
    failures = Counter()
    batch_stops = Counter()
    step_observations = Counter()
    batch_observations = Counter()
    done_checks = Counter()
    durations = []
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
                counts["calls"] += 1
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
                value = row.get("duration_ms")
                if type(value) in (int, float) and math.isfinite(value) and value >= 0:
                    durations.append(value)
    durations.sort()
    out = {key: counts[key] for key in (
        "calls", "legacy_calls", "tool_errors", "screenshots_returned", "batch_failures_v2",
        "decision_hints_v2", "vision_clicks_v2", "calls_v3", "batch_failures_v3",
        "decision_hints_v3", "vision_clicks_v3", "malformed_rows",
    )}
    out["failure_codes"] = dict(sorted(failures.items()))
    out["batch_stops"] = dict(sorted(batch_stops.items()))
    out["step_observations"] = dict(sorted(step_observations.items()))
    out["batch_observations"] = dict(sorted(batch_observations.items()))
    out["done_checks"] = dict(sorted(done_checks.items()))
    if durations:
        for percentile in (50, 95):
            out[f"p{percentile}_duration_ms"] = durations[math.ceil(len(durations) * percentile / 100) - 1]
    return out


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path, default=Path.home() / ".godspeed" / "trajectories")
    args = parser.parse_args()
    if not args.directory.is_dir():
        parser.error("trajectory directory does not exist")
    print(json.dumps(summarize(args.directory), indent=2))
