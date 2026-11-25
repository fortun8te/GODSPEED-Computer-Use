#!/usr/bin/env python3
"""Bounded, local, offline-by-default profile search. Never applies a profile.

Adapters are explicitly supplied local programs, not a sandbox. See
docs/local-evaluation.md for the protocol and the limits of the evidence.
"""

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import selectors
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time


SCHEMA = 1
ARMS = ("control_before", "candidate", "control_after")
TOKEN_METRICS = (
    "input_tokens", "output_tokens", "reasoning_output_tokens",
    "cached_input_tokens", "cache_write_input_tokens", "uncached_input_tokens",
    "peak_context_tokens",
)
METRICS = ("duration_ms", "observation_bytes", "agent_calls", "helper_calls",
           "peak_memory_bytes", *TOKEN_METRICS)
OBJECTIVES = set(METRICS) - {"cached_input_tokens", "cache_write_input_tokens"}
SAFETY = ("wrong_targets", "duplicate_actions", "user_disturbances")
MAX_JSON_BYTES = 1024 * 1024
MAX_OUTPUT_BYTES = 256 * 1024
MAX_TRIALS = 100_000


class Invalid(ValueError):
    pass


class BudgetExhausted(Exception):
    pass


def remaining_budget(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise BudgetExhausted("total wall-time budget exhausted")
    return remaining


def check_deadline(deadline):
    if deadline is not None:
        remaining_budget(deadline)


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Invalid(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json(raw):
    try:
        return json.loads(raw, object_pairs_hook=no_duplicates,
                          parse_constant=lambda value: (_ for _ in ()).throw(
                              Invalid(f"non-finite JSON number: {value}")))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Invalid(f"invalid JSON: {error}") from error


def canonical(value):
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"),
                          ensure_ascii=False, allow_nan=False).encode("utf-8")
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Invalid(f"value is not finite UTF-8 JSON: {error}") from error


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def require(condition, message):
    if not condition:
        raise Invalid(message)


def number(value, name, minimum=0, maximum=None, integer=False):
    require(type(value) in ((int,) if integer else (int, float))
            and (type(value) is int or math.isfinite(value)) and value >= minimum
            and (maximum is None or value <= maximum), f"invalid {name}")
    return value


def nonempty(value, name):
    require(isinstance(value, str) and bool(value.strip()), f"invalid {name}")
    return value


def exact_keys(value, allowed, required, name):
    require(isinstance(value, dict), f"{name} must be an object")
    require(not (set(value) - set(allowed)), f"unknown {name} fields: {sorted(set(value) - set(allowed))}")
    require(set(required) <= set(value), f"missing {name} fields: {sorted(set(required) - set(value))}")


def load_manifest(path):
    with path.open("rb") as stream:
        raw = stream.read(MAX_JSON_BYTES + 1)
    require(len(raw) <= MAX_JSON_BYTES, "manifest exceeds 1 MiB")
    manifest = parse_json(raw)
    fields = ("schema", "experiment", "identity", "adapter", "artifacts", "baseline",
              "parameters", "train", "holdout", "seeds", "repeats", "max_candidates",
              "max_rounds", "timeout_seconds", "max_total_seconds", "objective",
              "context_limit_tokens", "memory_limit_bytes")
    exact_keys(manifest, fields, set(fields) - {"context_limit_tokens", "memory_limit_bytes"}, "manifest")
    require(type(manifest["schema"]) is int and manifest["schema"] == SCHEMA, "unsupported manifest schema")
    nonempty(manifest["experiment"], "experiment")
    identity = manifest["identity"]
    exact_keys(identity, ("suite_revision", "host", "model", "harness_revision"),
               ("suite_revision", "host", "model", "harness_revision"), "identity")
    for key, value in identity.items():
        nonempty(value, f"identity.{key}")
    command = manifest["adapter"]
    require(isinstance(command, list) and 0 < len(command) <= 64, "adapter must be an argv list")
    for arg in command:
        nonempty(arg, "adapter argument")
        require("\0" not in arg, "NUL in adapter argument")
    require(isinstance(manifest["artifacts"], list) and manifest["artifacts"],
            "artifacts must name the adapter and evaluated implementation files")
    for artifact in manifest["artifacts"]:
        nonempty(artifact, "artifact")
        require((path.parent / artifact).is_file(), f"artifact is not a file: {artifact}")
    baseline, parameters = manifest["baseline"], manifest["parameters"]
    require(isinstance(baseline, dict) and baseline, "baseline must be a nonempty profile")
    require(isinstance(parameters, dict) and parameters, "parameters must be a nonempty object")
    for name, value in baseline.items():
        nonempty(name, "profile key")
        require(value is None or type(value) in (str, int, float, bool), "profile values must be JSON scalars")
        if type(value) in (int, float):
            require(type(value) is int or math.isfinite(value), "non-finite profile value")
    for name, values in parameters.items():
        require(name in baseline, f"parameter missing from baseline: {name}")
        require(isinstance(values, list) and 1 < len(values) <= 64, f"invalid parameter grid: {name}")
        for value in values:
            require(value is None or type(value) in (str, int, float, bool), "parameter values must be JSON scalars")
            if type(value) in (int, float):
                require(type(value) is int or math.isfinite(value), "non-finite parameter value")
        require(len({canonical(value) for value in values}) == len(values), f"duplicate grid values: {name}")
        require(canonical(baseline[name]) in {canonical(value) for value in values},
                f"baseline value absent from grid: {name}")
    ids = set()
    for split in ("train", "holdout"):
        cases = manifest[split]
        require(isinstance(cases, list) and cases, f"{split} cases must be nonempty")
        for case in cases:
            exact_keys(case, ("id", "input", "checks"), ("id", "input", "checks"), "case")
            nonempty(case["id"], "case id")
            require(case["id"] not in ids, f"duplicate or overlapping case id: {case['id']}")
            ids.add(case["id"])
            require(isinstance(case["input"], dict), "case input must be an object")
            checks = case["checks"]
            require(isinstance(checks, list) and checks, "each case needs independent checks")
            for check in checks:
                nonempty(check, "check name")
            require(len(set(checks)) == len(checks), "duplicate check names")
    seeds = manifest["seeds"]
    require(isinstance(seeds, list) and seeds, "seeds must be nonempty")
    for seed in seeds:
        number(seed, "seed", 0, 2**32 - 1, integer=True)
    require(len(set(seeds)) == len(seeds), "duplicate seeds")
    number(manifest["repeats"], "repeats", 3, 100, integer=True)
    number(manifest["max_candidates"], "max_candidates", 1, 1000, integer=True)
    number(manifest["max_rounds"], "max_rounds", 1, 1000, integer=True)
    number(manifest["timeout_seconds"], "timeout_seconds", 0.01, 86400)
    number(manifest["max_total_seconds"], "max_total_seconds", 0.01, 604800)
    for key in ("context_limit_tokens", "memory_limit_bytes"):
        if key in manifest:
            number(manifest[key], key, 1, integer=True)
    objective = manifest["objective"]
    fields = ("metric", "minimum_improvement", "max_control_drift", "max_case_regression", "guardrails")
    exact_keys(objective, fields, fields, "objective")
    require(isinstance(objective["metric"], str) and objective["metric"] in OBJECTIVES,
            "unknown or non-minimizing objective metric")
    number(objective["minimum_improvement"], "minimum_improvement", 0.000001, 0.99)
    number(objective["max_control_drift"], "max_control_drift", 0, 1)
    number(objective["max_case_regression"], "max_case_regression", 0, 1)
    require(isinstance(objective["guardrails"], dict), "guardrails must be an object")
    for key, value in objective["guardrails"].items():
        require(key in OBJECTIVES and key != objective["metric"], "invalid guardrail metric")
        number(value, f"guardrail {key}", 0, 1)
    require(schedule_bounds(manifest)["max_trials"] <= MAX_TRIALS, "schedule exceeds 100,000 trials")
    return manifest


def schedule_bounds(manifest):
    multiplier = 3 * len(manifest["seeds"]) * manifest["repeats"]
    return {"max_candidates": manifest["max_candidates"],
            "train_trials_per_candidate": multiplier * len(manifest["train"]),
            "holdout_trials_once": multiplier * len(manifest["holdout"]),
            "max_trials": multiplier * (len(manifest["train"]) * manifest["max_candidates"] + len(manifest["holdout"])),
            "max_total_seconds": manifest["max_total_seconds"]}


def validate_result(result, request):
    fields = ("schema", "case_id", "completed", "checker_pass", "checks", "safety", "metrics", "token_source")
    exact_keys(result, fields, fields, "adapter result")
    require(type(result["schema"]) is int and result["schema"] == SCHEMA, "unsupported adapter schema")
    require(result["case_id"] == request["case"]["id"], "adapter case mismatch")
    for key in ("completed", "checker_pass"):
        require(type(result[key]) is bool, f"{key} must be boolean")
    require(isinstance(result["checks"], dict), "checks must be an object")
    for key, value in result["checks"].items():
        nonempty(key, "check name")
        require(type(value) is bool, "check result must be boolean")
    exact_keys(result["safety"], SAFETY, SAFETY, "safety")
    for key, value in result["safety"].items():
        if value is not None:
            number(value, f"safety.{key}", maximum=2**53 - 1, integer=True)
    exact_keys(result["metrics"], METRICS, (), "metrics")
    result["metrics"] = {key: result["metrics"].get(key) for key in METRICS}
    for key, value in result["metrics"].items():
        if value is not None:
            number(value, key, maximum=2**53 - 1, integer=(key != "duration_ms"))
    measured_tokens = any(result["metrics"][key] is not None for key in TOKEN_METRICS)
    if measured_tokens:
        nonempty(result["token_source"], "token_source for measured tokens")
    else:
        require(result["token_source"] is None, "token_source must be null when tokens are unmeasured")
    metrics = result["metrics"]
    for component, total in (("reasoning_output_tokens", "output_tokens"), ("cached_input_tokens", "input_tokens")):
        if metrics[component] is not None:
            require(metrics[total] is not None and metrics[component] <= metrics[total],
                    f"{component} exceeds or lacks {total}")
    if metrics["uncached_input_tokens"] is not None:
        require(metrics["input_tokens"] is not None and metrics["cached_input_tokens"] is not None
                and metrics["uncached_input_tokens"] == metrics["input_tokens"] - metrics["cached_input_tokens"],
                "uncached_input_tokens must equal input_tokens minus cached_input_tokens")
    writes = metrics["cache_write_input_tokens"]
    if writes is not None:
        require(metrics["input_tokens"] is not None and writes <= metrics["input_tokens"],
                "cache_write_input_tokens exceeds or lacks input_tokens")
        if metrics["cached_input_tokens"] is not None:
            require(writes <= metrics["input_tokens"] - metrics["cached_input_tokens"],
                    "cache_write_input_tokens exceeds uncached input_tokens")
    return result


def quality_failures(result, case, manifest):
    failures = []
    if not result["completed"] or not result["checker_pass"]:
        failures.append("incomplete task or independent checker failed")
    if any(result["checks"].get(check) is not True for check in case["checks"]):
        failures.append("required case checks missing or failed")
    if any(value is False for value in result["checks"].values()):
        failures.append("adapter reported a failed check")
    if any(result["safety"][key] != 0 for key in SAFETY):
        failures.append("safety counters are nonzero or unmeasured")
    for limit, metric in (("context_limit_tokens", "peak_context_tokens"), ("memory_limit_bytes", "peak_memory_bytes")):
        if limit in manifest:
            value = result["metrics"][metric]
            if value is None or value > manifest[limit]:
                failures.append(f"{metric} is unmeasured or exceeds {limit}")
    return failures


def stop_group(process):
    # Only the session created for this adapter, never a process-name match.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1.0)
        return True
    except subprocess.TimeoutExpired:
        # A process stuck in kernel I/O may not reap promptly even after SIGKILL.
        # The kill has still been sent; do not hang the whole evaluation forever.
        return False


def run_adapter(command, cwd, request, timeout):
    """Cap time and combined pipe output, including descendants holding pipes open."""
    started = time.monotonic()
    stdout, stderr = bytearray(), bytearray()
    process = None
    status = "ok"
    cleanup_complete = True
    environment = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "TZ", "TMPDIR") if key in os.environ}
    environment["GODSPEED_EVALUATION"] = "1"
    encoded = canonical(request)
    require(len(encoded) <= MAX_JSON_BYTES, "adapter request exceeds 1 MiB")
    try:
        with tempfile.TemporaryFile() as stdin, selectors.DefaultSelector() as selector:
            stdin.write(encoded)
            stdin.seek(0)
            process = subprocess.Popen(command, cwd=cwd, env=environment, stdin=stdin,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            for stream, destination in ((process.stdout, stdout), (process.stderr, stderr)):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, destination)
            while selector.get_map() or process.poll() is None:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    status = "timeout"
                    break
                for key, _ in selector.select(min(remaining, 0.05)):
                    data = os.read(key.fd, 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    available = MAX_OUTPUT_BYTES - len(stdout) - len(stderr)
                    key.data.extend(data[:available])
                    if len(data) > available:
                        status = "output_limit"
                        break
                if status != "ok":
                    break
            if status == "ok" and process.wait() != 0:
                status = "adapter_error"
    except OSError as error:
        status = "adapter_error"
        stderr.extend(str(error).encode("utf-8")[:4096])
    finally:
        if process is not None:
            cleanup_complete = stop_group(process)
            if not cleanup_complete and status == "ok":
                status = "cleanup_timeout"
            process.stdout.close()
            process.stderr.close()
    row = {"status": status, "runner_wall_ms": round((time.monotonic() - started) * 1000, 3),
           "exit_code": process.returncode if process else None,
           "cleanup_complete": cleanup_complete,
           "stderr": stderr.decode("utf-8", errors="replace")}
    if status == "ok":
        try:
            row["result"] = validate_result(parse_json(stdout), request)
        except Invalid as error:
            row.update(status="invalid_result", error=str(error))
    else:
        row["error"] = f"adapter {status}"
    if row["status"] != "ok":
        row["stdout_excerpt"] = stdout[:4096].decode("utf-8", errors="replace")
    return row


def ratio(candidate, control):
    return candidate / control if control else (1.0 if candidate == 0 else math.inf)


def finite_or_none(value):
    return value if math.isfinite(value) else None


def evaluate(rows, manifest, cases):
    """Equal-weight case/seed medians; require every scheduled repeat in every arm."""
    expected = len(cases) * len(manifest["seeds"]) * manifest["repeats"]
    cells = defaultdict(lambda: defaultdict(list))
    triplets = defaultdict(list)
    reasons, coverage = [], {}
    scheduled = {(case["id"], seed, repeat, arm) for case in cases
                 for seed in manifest["seeds"] for repeat in range(manifest["repeats"]) for arm in ARMS}
    observed = [(row["case_id"], row["seed"], row["repeat"], row["arm"]) for row in rows]
    if len(observed) != len(set(observed)) or set(observed) != scheduled:
        reasons.append("incomplete or duplicate matched schedule")
    for row in rows:
        triplets[(row["case_id"], row["seed"], row["repeat"])].append(row)
        if row["status"] != "ok" or row.get("quality_failures"):
            reasons.append("adapter, completion, quality or safety gate failed")
        if row["status"] == "ok":
            cells[(row["case_id"], row["seed"])][row["arm"]].append(row["result"]["metrics"])
    comparisons = {}
    for metric in METRICS:
        counts = {arm: sum(item[metric] is not None for arms in cells.values()
                           for item in arms[arm]) for arm in ARMS}
        paired = sum(len(triplet) == 3 and {item["arm"] for item in triplet} == set(ARMS)
                     and all(item["status"] == "ok" and item["result"]["metrics"][metric] is not None
                             for item in triplet) for triplet in triplets.values())
        coverage[metric] = {"expected_per_arm": expected, "measured": counts, "paired_trials": paired}
        if any(count != expected for count in counts.values()) or len(observed) != len(scheduled):
            continue
        per_cell, before_ratios, after_ratios = [], [], []
        for (case_id, seed), arms in sorted(cells.items()):
            medians = {arm: statistics.median(item[metric] for item in arms[arm]) for arm in ARMS}
            before = ratio(medians["candidate"], medians["control_before"])
            after = ratio(medians["candidate"], medians["control_after"])
            drift = max(ratio(medians["control_before"], medians["control_after"]),
                        ratio(medians["control_after"], medians["control_before"])) - 1
            before_ratios.append(before)
            after_ratios.append(after)
            per_cell.append({"case_id": case_id, "seed": seed, "medians": medians,
                             "control_drift": finite_or_none(drift), "unbounded_drift": not math.isfinite(drift),
                             "worst_ratio": finite_or_none(max(before, after)),
                             "unbounded_regression": not math.isfinite(max(before, after))})
        if not per_cell:
            continue
        before, after = statistics.mean(before_ratios), statistics.mean(after_ratios)
        comparisons[metric] = {"mean_ratio_to_control_before": finite_or_none(before),
                               "mean_ratio_to_control_after": finite_or_none(after),
                               "unbounded_regression": not math.isfinite(max(before, after)), "cells": per_cell}
    objective = manifest["objective"]
    gates = {objective["metric"]: objective["max_case_regression"], **objective["guardrails"]}
    for metric, regression in gates.items():
        values = comparisons.get(metric)
        if values is None:
            reasons.append(f"incomplete metric coverage: {metric}")
            continue
        for cell in values["cells"]:
            if cell["unbounded_drift"] or cell["control_drift"] > objective["max_control_drift"]:
                reasons.append(f"control drift exceeds limit: {metric}")
            if cell["unbounded_regression"] or cell["worst_ratio"] > 1 + regression:
                reasons.append(f"case regression exceeds limit: {metric}")
    objective_values = comparisons.get(objective["metric"])
    if objective_values and (objective_values["unbounded_regression"] or any(
        objective_values[key] > 1 - objective["minimum_improvement"]
        for key in ("mean_ratio_to_control_before", "mean_ratio_to_control_after")
    )):
        reasons.append("objective did not improve enough against both controls")
    return {"accepted": not reasons, "reasons": sorted(set(reasons)),
            "coverage": coverage, "metrics": comparisons}


def neighbours(profile, parameters):
    for key in sorted(parameters):
        for value in parameters[key]:
            if canonical(value) != canonical(profile[key]):
                yield {**profile, key: value}


def file_hash(path, deadline=None):
    check_deadline(deadline)
    with path.open("rb") as stream:
        return _hash_stream(stream, deadline)


def _hash_stream(stream, deadline=None):
    hasher = hashlib.sha256()
    while True:
        check_deadline(deadline)
        block = stream.read(1024 * 1024)
        check_deadline(deadline)
        if not block:
            return hasher.hexdigest()
        hasher.update(block)


def fingerprints(manifest, directory, command, deadline=None):
    check_deadline(deadline)
    paths = {Path(__file__).resolve(), Path(command[0]).resolve()}
    paths.update((directory / artifact).resolve() for artifact in manifest["artifacts"])
    return {str(path): file_hash(path, deadline) for path in sorted(paths)}


def write_json(path, value, deadline=None):
    check_deadline(deadline)
    temp = path.with_suffix(path.suffix + ".tmp")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical(value) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        check_deadline(deadline)
        os.replace(temp, path)
        try:
            check_deadline(deadline)
        except BudgetExhausted:
            path.unlink(missing_ok=True)
            raise
    finally:
        temp.unlink(missing_ok=True)


class Search:
    def __init__(self, manifest, directory, output):
        self.started = time.monotonic()
        self.deadline = self.started + manifest["max_total_seconds"]
        self.manifest, self.directory, self.output = manifest, directory, output
        self.command = list(manifest["adapter"])
        executable = self.command[0]
        resolved = (directory / executable).resolve() if "/" in executable else shutil.which(executable)
        require(resolved is not None and Path(resolved).is_file(), "adapter executable not found")
        self.command[0] = str(resolved)
        self.pins = {}
        self.trials = 0
        self.report = {"schema": SCHEMA, "experiment": manifest["experiment"], "manifest_sha256": digest(manifest),
                       "identity": manifest["identity"], "files_sha256": self.pins,
                       "runtime": {"python": sys.version, "platform": platform.platform()},
                       "started_at": datetime.now(timezone.utc).isoformat(), "bounds": schedule_bounds(manifest),
                       "baseline": manifest["baseline"], "search_incumbent": manifest["baseline"],
                       "comparisons": [], "history": [], "recommended_profile": None, "applied": False,
                       "holdout_sha256": digest(manifest["holdout"]), "holdout_evaluations": 0}
        self.ledger = None

    def event(self, value):
        value = {"at": datetime.now(timezone.utc).isoformat(), **value}
        self.ledger.write(canonical(value) + b"\n")
        self.ledger.flush()
        os.fsync(self.ledger.fileno())

    def compare(self, control, candidate, cases, phase, index):
        rows = []
        trial_id = f"{phase}-{index}"
        self.event({"event": "comparison_started", "id": trial_id, "control": control, "candidate": candidate})
        for case in cases:
            for seed in self.manifest["seeds"]:
                for repeat in range(self.manifest["repeats"]):
                    for arm in ARMS:
                        remaining_budget(self.deadline)
                        profile = candidate if arm == "candidate" else control
                        request = {"schema": SCHEMA, "profile": profile, "case": case, "seed": seed, "repeat": repeat}
                        self.trials += 1
                        self.event({"event": "trial_started", "comparison": trial_id, "case_id": case["id"],
                                    "seed": seed, "repeat": repeat, "arm": arm, "profile_sha256": digest(profile),
                                    "request_sha256": digest(request)})
                        try:
                            row = run_adapter(self.command, self.directory, request,
                                              min(self.manifest["timeout_seconds"], remaining_budget(self.deadline)))
                        except KeyboardInterrupt:
                            self.event({"event": "trial", "comparison": trial_id, "case_id": case["id"],
                                        "seed": seed, "repeat": repeat, "arm": arm, "status": "interrupted"})
                            raise
                        row.update(comparison=trial_id, case_id=case["id"], seed=seed, repeat=repeat, arm=arm,
                                   profile_sha256=digest(profile))
                        if row["status"] == "ok":
                            row["quality_failures"] = quality_failures(row["result"], case, self.manifest)
                        self.event({"event": "trial", **row})
                        # Persist diagnostics once; retain only scoring data in memory.
                        # A noisy long-running adapter must not multiply its stderr
                        # or arbitrary checker labels by the number of repeats.
                        score_row = {key: row[key] for key in ("case_id", "seed", "repeat", "arm", "status")}
                        if row["status"] == "ok":
                            score_row.update(result={"metrics": row["result"]["metrics"]},
                                             quality_failures=row["quality_failures"])
                        rows.append(score_row)
                        if row.get("cleanup_complete") is False:
                            raise Invalid("Adapter process did not exit after SIGKILL; evaluation stopped without a recommendation")
                        remaining_budget(self.deadline)
        evaluation = {"id": trial_id, "phase": phase, "control": control, "candidate": candidate,
                      **evaluate(rows, self.manifest, cases)}
        self.report["comparisons"].append(evaluation)
        self.event({"event": "comparison_finished", **evaluation})
        write_json(self.output / "report.json", self.report)
        remaining_budget(self.deadline)
        return evaluation["accepted"]

    def run(self):
        # A fresh, private directory prevents stale evidence from being reused.
        self.output.mkdir(mode=0o700, parents=False, exist_ok=False)
        write_json(self.output / "manifest.json", self.manifest)
        write_json(self.output / "rollback-profile.json", self.manifest["baseline"])
        fd = os.open(self.output / "ledger.jsonl", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as self.ledger:
            self.event({"event": "started", "manifest_sha256": self.report["manifest_sha256"],
                        "files_sha256": self.pins, "holdout_sha256": self.report["holdout_sha256"]})
            incumbent = self.manifest["baseline"]
            seen, count = {digest(incumbent)}, 0
            try:
                self.pins = fingerprints(self.manifest, self.directory, self.command, self.deadline)
                remaining_budget(self.deadline)
                self.report["files_sha256"] = self.pins
                self.event({"event": "artifacts_pinned", "files_sha256": self.pins})
                for round_index in range(self.manifest["max_rounds"]):
                    changed = False
                    for candidate in neighbours(incumbent, self.manifest["parameters"]):
                        if digest(candidate) in seen:
                            continue
                        if count >= self.manifest["max_candidates"]:
                            break
                        seen.add(digest(candidate))
                        count += 1
                        if self.compare(incumbent, candidate, self.manifest["train"], "train", count):
                            incumbent = candidate
                            changed = True
                            change = {"round": round_index, "comparison": f"train-{count}", "profile": incumbent}
                            self.report["history"].append(change)
                            self.event({"event": "incumbent_changed", **change})
                            break  # Recompute one-parameter neighbours of this incumbent.
                    if not changed or count >= self.manifest["max_candidates"]:
                        break
                self.report["search_incumbent"] = incumbent
                if digest(incumbent) == digest(self.manifest["baseline"]):
                    self.report["status"] = "no_improvement"
                else:
                    # Freeze before any holdout execution; no fallback selection after failure.
                    self.event({"event": "candidate_frozen", "profile": incumbent})
                    self.report["holdout_evaluations"] = 1
                    qualified = self.compare(self.manifest["baseline"], incumbent, self.manifest["holdout"], "holdout", 1)
                    self.report["status"] = "qualified" if qualified else "qualification_failed"
                    if qualified:
                        self.report["recommended_profile"] = incumbent
                final_pins = fingerprints(self.manifest, self.directory, self.command, self.deadline)
                remaining_budget(self.deadline)
                if final_pins != self.pins:
                    self.report.update(status="artifacts_changed", recommended_profile=None)
                if self.report["recommended_profile"] is not None:
                    write_json(self.output / "recommended-profile.json", self.report["recommended_profile"], self.deadline)
            except BudgetExhausted as error:
                self.report.update(status="budget_exhausted", error=str(error), recommended_profile=None)
            except KeyboardInterrupt:
                self.report.update(status="interrupted", recommended_profile=None)
            except (OSError, Invalid) as error:
                self.report.update(status="error", error=str(error), recommended_profile=None)
            except Exception as error:
                self.report.update(status="error", error=f"{type(error).__name__}: {error}", recommended_profile=None)
            if self.report["recommended_profile"] is None:
                (self.output / "recommended-profile.json").unlink(missing_ok=True)
            self.report.update(trials=self.trials, elapsed_seconds=round(time.monotonic() - self.started, 3))
            self.event({"event": "finished", "status": self.report["status"], "trials": self.trials,
                        "recommended_profile": self.report["recommended_profile"],
                        "error": self.report.get("error"), "applied": False})
            write_json(self.output / "report.json", self.report)
        return self.report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "run"):
        subparser = subcommands.add_parser(name)
        subparser.add_argument("manifest", type=Path)
        if name == "run":
            subparser.add_argument("--output", type=Path, required=True, help="new directory; never reused")
    args = parser.parse_args(argv)
    try:
        path = args.manifest.resolve()
        manifest = load_manifest(path)
        if args.command == "plan":
            print(json.dumps({"schema": SCHEMA, "experiment": manifest["experiment"],
                              "manifest_sha256": digest(manifest), "bounds": schedule_bounds(manifest),
                              "objective": manifest["objective"], "holdout_sha256": digest(manifest["holdout"]),
                              "applies_settings": False}, indent=2))
            return 0
        report = Search(manifest, path.parent, args.output.resolve()).run()
        print(json.dumps({"status": report["status"], "trials": report["trials"],
                          "recommended_profile": report["recommended_profile"],
                          "report": str(args.output.resolve() / "report.json"), "applied": False}, indent=2))
        return 0 if report["status"] in ("qualified", "no_improvement") else 2
    except (Invalid, OSError) as error:
        print(f"hillclimb: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
