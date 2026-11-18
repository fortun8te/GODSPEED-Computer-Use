#!/usr/bin/env python3
"""Report tool counts and timing from local Godspeed JSONL without exporting UI content."""

import argparse
from collections import Counter
import json
import math
from pathlib import Path


def summarize(directory):
    counts = Counter()
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
                else:
                    counts["legacy_calls"] += 1
                value = row.get("duration_ms")
                if type(value) in (int, float) and math.isfinite(value) and value >= 0:
                    durations.append(value)
    durations.sort()
    out = {key: counts[key] for key in (
        "calls", "legacy_calls", "tool_errors", "screenshots_returned", "batch_failures_v2",
        "decision_hints_v2", "vision_clicks_v2", "malformed_rows",
    )}
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
