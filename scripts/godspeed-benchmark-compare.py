#!/usr/bin/env python3
"""Compare two complete, matched computer-use benchmark arms offline."""

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
from statistics import median
import sys


SCHEMA = 1
SUITE_TASKS = {
    "CDB-G02", "CDB-G03", "CDB-G04", "MB-09", "MB-10", "MB-11",
    "IR-01", "IR-02", "IR-03", "IR-04",
}
CRITERIA = {
    "key_focus", "window_order", "user_input", "pointer", "clipboard",
    "space", "user_dialog", "app_activation",
}
COMMON = {
    "suite_revision", "scenario", "model", "harness", "host", "config",
}
DRIVER = {"name", "version", "config"}
METRICS = {"duration_ms", "agent_calls", "input_tokens", "output_tokens"}
ROW_FIELDS = {
    "schema", "suite", "task", "seed", "mode", "identity", "driver", "status",
    "checker_pass", "gui_only", "undisturbed", "metrics",
}


class Invalid(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


def keys(value, expected, label):
    require(isinstance(value, dict) and value.keys() == expected,
            f"{label} has unexpected or missing fields")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "repeated JSON field")
        result[key] = value
    return result


def read_json(text):
    return json.loads(text, object_pairs_hook=unique_object)


def validate_labels(value, expected, label):
    keys(value, expected, label)
    require(all(isinstance(item, str) and item.strip() for item in value.values()),
            f"{label} fields need nonempty labels or fingerprints")


def trial_key(row):
    require(isinstance(row["task"], str) and row["task"].strip(), "invalid task")
    require(type(row["seed"]) is int and row["seed"] >= 0, "invalid seed")
    require(row["mode"] in ("foreground", "background"), "invalid mode")
    return row["task"], row["seed"], row["mode"]


def scale_schedule():
    return {
        (
            task,
            int(hashlib.sha256(f"{task}:{run_index}".encode()).hexdigest()[:8], 16) % 1_000_000,
            mode,
        )
        for task in SUITE_TASKS
        for run_index in range(5)
        for mode in ("foreground", "background")
        if mode == "foreground" or task not in {"MB-10", "MB-11"}
    }


def load_schedule(suite, schedule_path):
    if suite == "scale-bench-v2":
        require(schedule_path is None, "the Scale profile uses its built-in 90-trial schedule")
        return scale_schedule()
    require(schedule_path is not None, "the Aside internal profile requires --schedule")
    schedule = read_json(schedule_path.read_text(encoding="utf-8"))
    keys(schedule, {"schema", "suite", "trials"}, "schedule")
    require(type(schedule["schema"]) is int and schedule["schema"] == SCHEMA and schedule["suite"] == suite,
            "schedule schema or suite mismatch")
    require(isinstance(schedule["trials"], list), "schedule trials must be a list")
    trials = set()
    for row in schedule["trials"]:
        keys(row, {"task", "seed", "mode"}, "schedule trial")
        entry = trial_key(row)
        require(entry not in trials, "duplicate schedule trial")
        trials.add(entry)
    require(len({entry[0] for entry in trials}) == 4, "Aside internal profile requires exactly four distinct tasks")
    return trials


def validate_row(row, suite):
    keys(row, ROW_FIELDS, "trial")
    require(type(row["schema"]) is int and row["schema"] == SCHEMA, "unsupported trial schema")
    require(row["suite"] == suite, "trial suite mismatch")
    key = trial_key(row)
    validate_labels(row["identity"], COMMON, "identity")
    validate_labels(row["driver"], DRIVER, "driver")
    require(row["status"] in ("scored", "harness_error"), "invalid status")
    keys(row["metrics"], METRICS, "metrics")
    for metric, value in row["metrics"].items():
        require(value is None or (type(value) is int and value >= 0),
                f"{metric} must be null or a nonnegative integer")
    if row["status"] == "scored":
        require(type(row["checker_pass"]) is bool and type(row["gui_only"]) is bool,
                "scored trials need explicit checker and GUI-only outcomes")
        for metric in ("duration_ms", "agent_calls"):
            require(row["metrics"][metric] is not None, f"scored trials need {metric}")
        if row["mode"] == "background":
            keys(row["undisturbed"], CRITERIA, "undisturbed")
            require(all(value is None or type(value) is bool for value in row["undisturbed"].values()),
                    "undisturbed criteria must be true, false or null")
        else:
            require(row["undisturbed"] is None, "foreground trials have no undisturbed grade")
    else:
        require(all(row[field] is None for field in ("checker_pass", "gui_only", "undisturbed")),
                "harness errors cannot carry a grade")
    return key


def load_arm(path, suite):
    rows = {}
    identity = driver = None
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, start=1):
            try:
                row = read_json(line)
                key = validate_row(row, suite)
                require(key not in rows, "duplicate trial (resolve retries before comparison)")
                if identity is None:
                    identity, driver = row["identity"], row["driver"]
                require(row["identity"] == identity and row["driver"] == driver,
                        "mixed experiment identity or driver within an arm")
                rows[key] = row
            except ValueError as exc:
                message = str(exc) if isinstance(exc, Invalid) else "invalid JSON"
                raise Invalid(f"{path.name} line {line_number}: {message}") from exc
    require(bool(rows), f"{path.name} has no trials")
    return rows, identity, driver


def full_pass(row):
    return (
        row["checker_pass"] and row["gui_only"]
        and (row["mode"] == "foreground" or all(value is True for value in row["undisturbed"].values()))
    )


def arm_metrics(rows):
    outcomes = Counter()
    observed = {metric: [] for metric in METRICS}
    disturbances = Counter()
    unmeasured = Counter()
    for row in rows:
        outcomes["full_pass"] += full_pass(row)
        outcomes["checker_pass"] += row["checker_pass"]
        outcomes["gui_only"] += row["gui_only"]
        if row["mode"] == "background":
            for criterion, value in row["undisturbed"].items():
                disturbances[criterion] += value is False
                unmeasured[criterion] += value is None
        for metric, value in row["metrics"].items():
            if value is not None:
                observed[metric].append(value)
    return {
        **outcomes,
        "disturbances": dict(disturbances),
        "unmeasured_criteria": dict(unmeasured),
        "metrics": {
            metric: {"median": median(values) if values else None, "observed": len(values)}
            for metric, values in observed.items()
        },
    }


def summarize(mode, schedule, baseline, candidate):
    keys = sorted(key for key in schedule if key[2] == mode)
    if not keys:
        return None
    old = [baseline[key] for key in keys]
    new = [candidate[key] for key in keys]
    baseline_only = sum(full_pass(a) and not full_pass(b) for a, b in zip(old, new))
    candidate_only = sum(full_pass(b) and not full_pass(a) for a, b in zip(old, new))
    discordant = baseline_only + candidate_only
    p_value = min(1.0, 2 * sum(math.comb(discordant, i) for i in range(min(baseline_only, candidate_only) + 1))
                  / (2 ** discordant))
    metric_deltas = {}
    for metric in sorted(METRICS):
        pairs = [(a["metrics"][metric], b["metrics"][metric]) for a, b in zip(old, new)]
        deltas = [b - a for a, b in pairs if a is not None and b is not None]
        metric_deltas[metric] = {
            "median_candidate_minus_baseline": median(deltas) if len(deltas) == len(keys) else None,
            "matched_observations": len(deltas),
        }
    return {
        "scheduled": len(keys),
        "baseline": arm_metrics(old),
        "candidate": arm_metrics(new),
        "baseline_only_passes": baseline_only,
        "candidate_only_passes": candidate_only,
        "paired_metric_deltas": metric_deltas,
        "full_pass_delta_percentage_points": round(100 * (candidate_only - baseline_only) / len(keys), 3),
        "exact_paired_p_value_descriptive": round(p_value, 9),
    }


def checked_arm(rows, schedule, name):
    if set(rows) != schedule or any(row["status"] != "scored" for row in rows.values()):
        missing = len(schedule - rows.keys())
        unexpected = len(rows.keys() - schedule)
        harness_errors = sum(row["status"] == "harness_error" for row in rows.values())
        raise Invalid(f"{name} is incomplete or has unexpected trials "
                      f"(missing {missing}, unexpected {unexpected}, harness errors {harness_errors})")


def compare(suite, schedule_path, baseline_path, candidate_path):
    schedule = load_schedule(suite, schedule_path)
    baseline, baseline_identity, baseline_driver = load_arm(baseline_path, suite)
    candidate, candidate_identity, candidate_driver = load_arm(candidate_path, suite)
    checked_arm(baseline, schedule, "baseline")
    checked_arm(candidate, schedule, "candidate")
    mismatches = sorted(field for field in COMMON if baseline_identity[field] != candidate_identity[field])
    require(not mismatches, "unmatched experiment identity: " + ", ".join(mismatches))
    require(baseline_driver != candidate_driver, "both arms identify the same driver and configuration")
    return {
        "schema": SCHEMA,
        "suite": suite,
        "identity": baseline_identity,
        "baseline_driver": baseline_driver,
        "candidate_driver": candidate_driver,
        "conditions": {
            mode: result
            for mode in ("foreground", "background")
            if (result := summarize(mode, schedule, baseline, candidate)) is not None
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=("scale-bench-v2", "aside-internal"), required=True)
    parser.add_argument("--schedule", type=Path, help="predeclared Aside internal JSON schedule")
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    try:
        report = compare(args.suite, args.schedule, args.baseline, args.candidate)
    except (OSError, ValueError) as exc:
        print(f"Comparison blocked: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
