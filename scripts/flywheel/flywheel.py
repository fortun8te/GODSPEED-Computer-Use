"""Fixture dataset packaging and paired local model evaluation."""
import argparse
import base64
import gc
import hashlib
import http.client
import importlib.util
import json
import math
import os
import re
from collections import Counter
from pathlib import Path
import statistics
import sys
import time
import zipfile

HERE = Path(__file__).resolve().parent
HELPER = Path.home() / ".ocu-referee"
FAMILIES = {
    "train": {"contact", "appearance", "queue", "timer"},
    "val": {"playlist", "bookmark"},
    "test": {"rename", "reservation"},
    "holdout": {"export", "schedule", "library", "accessibility"},
}
LABELS = {"act", "look_again", "done", "stuck"}
LIMITS = {"goal": 500, "last_step": 300, "result": 500, "view": 1200}
VARIANTS = {
    "success": "done_verified", "disabled": "click_no_effect", "ignored": "click_no_effect",
    "lookalike": "wrong_target_changed", "other_window": "wrong_target_changed",
    "staged": "partial_completion", "repeat": "stuck", "next_step": "partial_completion",
}
DONE_CONFIDENCE = 0.86
HINT_CONFIDENCE = 0.60
CALL_LIMIT = 300


def jsonl(rows):
    return "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows).encode()


def digest(content):
    return hashlib.sha256(content).hexdigest()


def read_rows(content):
    return [json.loads(line) for line in content.splitlines() if line.strip()]


def validate_rows(rows, families):
    expected = {
        f"{family}/{seed}/{variant}/{check}"
        for family in families for seed in (0, 1) for variant in VARIANTS for check in ("decision", "click")
    }
    for row in rows:
        if set(row) != {"state", "answer", "meta"} or row["answer"] not in LABELS:
            raise ValueError("Invalid d1 row")
        meta = row["meta"]
        if (set(meta) != {"id", "family", "source", "check", "outcome", "variant"}
                or meta["source"] != "synthetic_headless" or meta["family"] not in families
                or meta["check"] not in {"decision", "click"} or meta["variant"] not in VARIANTS
                or meta["outcome"] != VARIANTS[meta["variant"]]):
            raise ValueError("Invalid fixture provenance")
        row_id = meta["id"]
        ids = {f"{meta['family']}/{seed}/{meta['variant']}/{meta['check']}" for seed in (0, 1)}
        if row_id not in expected or row_id not in ids:
            raise ValueError("Duplicate or unexpected fixture ID")
        expected.remove(row_id)
        state = json.loads(row["state"])
        if set(state) != set(LIMITS) or any(
            not isinstance(value, str) or not value or len(value) > LIMITS[key] for key, value in state.items()
        ):
            raise ValueError("Invalid d1 state")
    if expected:
        raise ValueError("Incomplete fixture families")


def frozen(name):
    content = (HERE / name).read_bytes()
    expected = (HERE / f"{name}.sha256").read_text().strip()
    if digest(content) != expected:
        raise ValueError(f"Frozen file changed: {name}")
    return content


def heldout():
    rows = read_rows(frozen("heldout.jsonl"))
    validate_rows(rows, FAMILIES["holdout"])
    return rows


def writable(path):
    path = path.resolve()
    if any(path.is_relative_to(root.resolve()) for root in (HELPER, Path.home() / ".godspeed")):
        raise ValueError("Choose an output outside the live Godspeed folders")
    return path


def package(fixtures, destination):
    bench = heldout()
    rows = read_rows(writable(fixtures).read_bytes())
    validate_rows(rows, set.union(*FAMILIES.values()))
    # Refuse to package changed fixtures under a stale holdout manifest.
    current_holdout = [row for row in rows if row["meta"]["family"] in FAMILIES["holdout"]]
    if jsonl(current_holdout) != jsonl(bench):
        raise ValueError("Generated holdout disagrees with the frozen bench")
    if digest(jsonl(rows)) != (HERE / "fixture-input.sha256").read_text().strip():
        raise ValueError("Fixture input does not match the reviewed generator output")
    states = {json.dumps(json.loads(row["state"]), sort_keys=True) for row in bench}
    data = {}
    config = {
        "D1_DATA": "flywheel-v1", "D1_OUT": "flywheel-d1-v1", "epochs": 3,
        "D1_LORA_TARGETS": "q_proj,k_proj,v_proj,out_proj,in_proj,w1,w2,w3",
        "splits": {},
    }
    for split in ("train", "val", "test"):
        selected = [row for row in rows if row["meta"]["family"] in FAMILIES[split]]
        current = {json.dumps(json.loads(row["state"]), sort_keys=True) for row in selected}
        if states & current:
            raise ValueError("Duplicate state across splits")
        states |= current
        if set(row["answer"] for row in selected) != LABELS:
            raise ValueError(f"Missing d1 answer class in {split}")
        payload = jsonl(selected)
        data[f"data/{config['D1_DATA']}/{split}.jsonl"] = payload
        config["splits"][split] = {
            "families": sorted(FAMILIES[split]), "rows": len(selected),
            "labels": dict(Counter(row["answer"] for row in selected)), "sha256": digest(payload),
        }
    with zipfile.ZipFile(writable(destination), "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, payload in data.items():
            archive.writestr(name, payload)
        archive.writestr("train-config.json", json.dumps(config, indent=2) + "\n")
    return config["splits"]


def metadata_counts(entries):
    """Summarize already-reviewed metadata without learning labels from incomplete receipts."""
    counts = Counter()
    for entry in entries:
        if entry.get("event") in {"session_end", "log_capped"}:
            continue
        if (entry.get("event") != "tool_call" or entry.get("capture_mode") != "metadata"
                or any(key in entry for key in ("result_text", "arguments", "failure_detail", "steps", "check"))):
            raise ValueError("Expected outcome-only trajectory metadata")
        if entry.get("tool") != "batch":
            continue
        # The v3 telemetry has no step tool name or target identity. Unchanged is not necessarily a click.
        for step in entry.get("batch_step_receipts", []):
            observed = step.get("observation")
            if observed in ("no_effect_seen", "not_sent", "outcome_unknown"):
                counts[observed] += 1
        if entry.get("batch_stop_code") == "window_changed":
            counts["window_changed"] += 1
        if entry.get("batch_done_check") == "verified":
            counts["batch_done_verified"] += 1
        if entry.get("batch_done_check") == "unmet" and entry.get("batch_not_run", 0) > 0:
            counts["batch_unmet_with_unrun_steps"] += 1
    return dict(counts)


def number(value, min_value, max_value):
    if type(value) not in (int, float) or not math.isfinite(value) or not min_value <= value <= max_value:
        raise ValueError("Invalid number in helper reply")
    return value


def decision_reply(reply, done_threshold, hint_threshold):
    label = reply["label"]
    if label not in LABELS:
        raise ValueError("Invalid decision label")
    confidence = number(reply["confidence"], 0, 1)
    threshold = max(done_threshold, hint_threshold) if label == "done" else hint_threshold
    return {"raw": label, "prediction": label if confidence >= threshold else "abstain",
            "model_ms": number(reply["ms"], 0, math.inf)}


def live_artifact(track):
    # A single read-only request identifies the champion. Inference below never calls the live service.
    connection = http.client.HTTPConnection("127.0.0.1", 8765, timeout=3)
    try:
        connection.request("GET", "/health")
        response = connection.getresponse()
        if response.status != 200:
            raise ValueError("Live helper health unavailable")
        body = json.loads(response.read(65536))
    finally:
        connection.close()
    if body.get("ok") is not True or body.get("runtime") != "mlx":
        raise ValueError("Expected live MLX helper")
    return Path(body[track]).resolve(strict=True)


def load_runtime(mode, max_view, zoom):
    # Match the installed runtime without invoking its HTTP server, janitor or trajectory logging.
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1",
                      OCU_REFEREE_LOG="0", OCU_REFEREE_MODE=mode, OCU_REFEREE_MAX_VIEW_CHARS=str(max_view),
                      OCU_LOCATE_ZOOM=str(int(zoom)))
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("_flywheel_helper", HELPER / "server_mlx.py")
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    return runtime


def inventory(path):
    # Include model weights and support files, including symlink targets in HF snapshots.
    entries = {}
    for file in sorted(path.iterdir()):
        if file.is_file():
            with file.open("rb") as handle:
                entries[file.name] = hashlib.file_digest(handle, "sha256").hexdigest()
    if not any(name.endswith(".safetensors") for name in entries):
        raise ValueError("Missing local model weights")
    return digest(json.dumps(entries, sort_keys=True).encode())


def samples(rows, infer, parse, limit):
    if len(rows) > limit:
        raise ValueError("Evaluation call budget exceeded")
    output = {}
    failed = False
    for row in rows:
        start = time.perf_counter()
        try:
            record = parse(row, infer(row)) if not failed else {"error": "not_run_after_error"}
        except Exception as error:
            record = {"error": type(error).__name__}
            failed = True
        record["wall_ms"] = None if record.get("error") == "not_run_after_error" else (time.perf_counter() - start) * 1000
        output[row["meta"]["id"]] = record
    return output


def local_infer(runtime, track, path, rows, parse):
    if track == "d1":
        runtime.D1_PATH = str(path)

        def infer(row):
            return runtime.decide(json.loads(row["state"]), log=False)
    else:
        runtime.LFM_PATH = str(path)

        def infer(row):
            status, reply = runtime.locate({"query": row["query"], "image_base64": row["image_base64"]})
            if status != 200:
                raise ValueError("Grounding request failed")
            return reply
    try:
        return samples(rows, infer, parse, CALL_LIMIT // 2)
    finally:
        runtime.models.clear()
        runtime.last_used.clear()
        gc.collect()
        runtime.clear_cache()


def ratio(numerator, denominator):
    return numerator / denominator if denominator else None


def precision_recall(pairs, label):
    tp = sum(gold == pred == label for gold, pred in pairs)
    return ratio(tp, sum(pred == label for _, pred in pairs)), ratio(tp, sum(gold == label for gold, _ in pairs))


def latency(records, key):
    values = sorted(record[key] for record in records if not record.get("error"))
    return (statistics.median(values), values[math.ceil(.95 * len(values)) - 1]) if values else (None, None)


def score(rows, results):
    pairs = {"decision": [], "click": [], "grounding": []}
    false_done, false_click, raw_false_done, raw_false_click, wrong_point = set(), set(), set(), set(), set()
    records = []
    for row in rows:
        row_id, check = row["meta"]["id"], row["meta"]["check"]
        record = results[row_id]
        records.append(record)
        prediction = record.get("prediction", "error")
        gold = row["answer"]
        pairs[check].append((gold, prediction))
        if check == "decision" and gold != "done":
            if prediction == "done":
                false_done.add(row_id)
            if record.get("raw") == "done":
                raw_false_done.add(row_id)
        if check == "click" and gold != "done":
            if prediction == "done":
                false_click.add(row_id)
            if record.get("raw") == "done":
                raw_false_click.add(row_id)
        if check == "grounding" and prediction == "wrong_point":
            wrong_point.add(row_id)

    decision, click, grounding = (pairs[key] for key in ("decision", "click", "grounding"))
    return {
        "n": len(rows),
        "errors": sum("error" in record for record in records),
        "abstentions": sum(pred == "abstain" for group in pairs.values() for _, pred in group),
        "accuracy": ratio(sum(gold == pred for gold, pred in decision or grounding), len(decision or grounding)),
        "raw_accuracy": ratio(sum(row["answer"] == results[row["meta"]["id"]].get("raw")
                                  for row in rows if row["meta"]["check"] == "decision"), len(decision)),
        "done": precision_recall(decision, "done"),
        "stuck": precision_recall(decision, "stuck"),
        "click": precision_recall(click, "done"),
        "false_done": false_done,
        "false_click": false_click,
        "raw_false_done": raw_false_done,
        "raw_false_click": raw_false_click,
        "wrong_point": wrong_point,
        "false_pass_rate": ratio(len(false_click), sum(gold != "done" for gold, _ in click)),
        "model_ms": latency(records, "model_ms"),
        "wall_ms": latency(records, "wall_ms"),
    }


def gate(live, candidate, dry_run, track):
    reasons = []
    if dry_run:
        reasons.append("Dry run with scripted replies")
    if live["errors"] or candidate["errors"]:
        reasons.append("An evaluation arm is incomplete")
    if candidate["accuracy"] <= live["accuracy"]:
        reasons.append("Held-out accuracy did not improve")
    if track == "d1":
        for label in ("done", "stuck", "click"):
            if candidate[label][1] < live[label][1]:
                reasons.append(f"{label} recall fell")
        for key in ("false_done", "false_click", "raw_false_done", "raw_false_click"):
            if candidate[key] - live[key]:
                reasons.append(f"New {key.replace('_', ' ')} on held-out rows")
    elif candidate["wrong_point"] - live["wrong_point"]:
        reasons.append("New wrong grounding point on held-out rows")
    return reasons


def fmt(value, percent=False):
    if value is None:
        return "n/a"
    return f"{value:.1%}" if percent else f"{value:.1f}"


def report(rows, arms, identities, settings, dry_run, track):
    live, candidate = [score(rows, arm) for arm in arms]
    reasons = gate(live, candidate, dry_run, track)
    heading = "Dry run" if dry_run else "Held-out evaluation"
    lines = [f"# Godspeed {heading.lower()}", "", f"Track `{track}`. {settings}", "",
             f"- Live arm `{identities[0]}`", f"- Candidate arm `{identities[1]}`", ""]
    lines += ["**Recommendation for manual review**" if not reasons else "**Hold candidate**", ""]
    lines += [f"- {reason}" for reason in reasons] + ([""] if reasons else [])
    lines += ["| Metric | Live | Candidate |", "|---|---:|---:|"]
    for label, key in (("Held-out rows", "n"), ("Errors or unrun", "errors"), ("Abstentions", "abstentions"),
                       ("Accuracy", "accuracy"), ("Raw decision accuracy", "raw_accuracy"),
                       ("Click verifier false-pass rate", "false_pass_rate"), ("False done", "false_done"),
                       ("False click worked", "false_click"), ("Raw false done", "raw_false_done"),
                       ("Raw false click worked", "raw_false_click"), ("Wrong grounding points", "wrong_point"),
                       ("Model median / p95 ms", "model_ms"), ("Wall median / p95 ms", "wall_ms")):
        cells = []
        for arm in (live, candidate):
            value = arm[key]
            if isinstance(value, set):
                cells.append(str(len(value)))
            elif isinstance(value, tuple):
                cells.append(" / ".join(fmt(part) for part in value))
            elif isinstance(value, int):
                cells.append(str(value))
            else:
                cells.append(fmt(value, percent=True))
        lines.append(f"| {label} | {cells[0]} | {cells[1]} |")
    if track == "d1":
        for key in ("done", "stuck", "click"):
            cells = [" / ".join(fmt(part, percent=True) for part in arm[key]) for arm in (live, candidate)]
            lines.append(f"| {key.capitalize()} precision / recall | {cells[0]} | {cells[1]} |")
    lines += ["", "| Family | Rows | Live accuracy | Candidate accuracy | Live / candidate errors |",
              "|---|---:|---:|---:|---:|"]
    for family in sorted({row["meta"]["family"] for row in rows}):
        subset = [row for row in rows if row["meta"]["family"] == family]
        a, b = (score(subset, arm) for arm in arms)
        lines.append(f"| {family} | {len(subset)} | {fmt(a['accuracy'], True)} | {fmt(b['accuracy'], True)}"
                     f" | {a['errors']} / {b['errors']} |")
    for key in ("false_done", "false_click", "raw_false_done", "raw_false_click", "wrong_point"):
        new = candidate[key] - live[key]
        if new:
            lines += ["", f"New {key.replace('_', ' ')} rows: " + ", ".join(sorted(new))]
    return "\n".join(lines) + "\n"


def grounding_rows():
    manifest = json.loads(frozen("grounding.json"))
    rows = []
    for case in manifest:
        image = (HERE / "grounding" / f"{case['image']}.png").read_bytes()
        if digest(image) != case["sha256"]:
            raise ValueError("Frozen grounding image changed")
        rows.append({**case, "image_base64": base64.b64encode(image).decode("ascii"),
                     "answer": "miss" if case["box"] is None else "hit",
                     "meta": {"id": case["id"], "family": case["family"], "check": "grounding"}})
    return rows


def ground_reply(reply, box):
    found = reply["found"]
    if type(found) is not bool:
        raise ValueError("Invalid grounding reply")
    prediction = "miss"
    if found:
        x, y = (number(reply[key], 0, 1) for key in ("x", "y"))
        prediction = "hit" if box and box[0] <= x <= box[2] and box[1] <= y <= box[3] else "wrong_point"
    return {"prediction": prediction, "model_ms": number(reply["ms"], 0, math.inf)}


def scripted_reply(row, track, missed_id):
    label = row["answer"]
    if row["meta"]["id"] == missed_id:
        label = "act" if track == "d1" else "miss"
    if track == "d1":
        return {"label": label, "confidence": 1, "ms": 0}
    if label != "hit":
        return {"found": False, "ms": 0}
    left, top, right, bottom = row["box"]
    return {"found": True, "x": (left + right) / 2, "y": (top + bottom) / 2, "ms": 0}


def evaluate(args):
    destination = writable(args.report)
    if destination.exists():
        raise ValueError("Report already exists")
    rows = heldout() if args.track == "d1" else grounding_rows()
    if args.dry_run:
        # A complete single-family slice with all positive and negative classes represented.
        rows = [row for row in rows if row["meta"]["family"] == rows[0]["meta"]["family"]]
    if 2 * len(rows) + 1 > CALL_LIMIT:
        raise ValueError("Both arms and health discovery exceed the call budget")
    if args.track == "d1":
        parse = lambda row, reply: decision_reply(reply, args.done_confidence, args.hint_confidence)
    else:
        parse = lambda row, reply: ground_reply(reply, row["box"])
    if args.dry_run:
        arms = [
            samples(rows, lambda row: scripted_reply(row, args.track, missed_id), parse, CALL_LIMIT // 2)
            for missed_id in (rows[0]["meta"]["id"], None)
        ]
        identities = ["scripted baseline", "scripted candidate"]
        settings = "Synthetic replies. Latency is a placeholder. No models were loaded."
    else:
        candidate = args.candidate.resolve(strict=True)
        live = live_artifact(args.track)
        if not all((path / "config.json").is_file() for path in (live, candidate)):
            raise ValueError("Both model directories need local config.json files")
        signatures = [inventory(path) for path in (live, candidate)]
        if signatures[0] == signatures[1]:
            raise ValueError("Candidate and champion have identical model files")
        runtime = load_runtime(args.mode, args.max_view, args.zoom)
        arms = [local_infer(runtime, args.track, path, rows, parse) for path in (live, candidate)]
        identities = [f"{path.name} (SHA256 {sig})" for path, sig in zip((live, candidate), signatures)]
        bench = "heldout.jsonl" if args.track == "d1" else "grounding.json"
        settings = (
            f"Bench SHA256 {digest(frozen(bench))}. "
            f"MLX helper source {digest((HELPER / 'server_mlx.py').read_bytes())}. "
            f"Mode {args.mode}, max view {args.max_view}, done threshold {args.done_confidence}, "
            f"hint threshold {args.hint_confidence}, zoom {args.zoom}. One model loaded at a time. Wall time includes cold load."
        )
    with destination.open("x", encoding="utf-8") as handle:
        handle.write(report(rows, arms, identities, settings, args.dry_run, args.track))
    print(destination)


# Offline calibration and labeling selection. These read probability files only; no model is loaded.
# Probability row (validation): {"id", "gold", "probs": {label: p}, "question"?}  ("question" defaults to "default")
# Probability row (pool):       {"id", "family", "probs": {label: p}}
CALIBRATION_BINS = 15
TEMPERATURE_GRID = [0.05 * (400 ** (i / 199)) for i in range(200)]  # 0.05 to 20, log-spaced, deterministic


def read_probability_file(path, need_gold):
    rows, seen = [], set()
    for raw in read_rows(path.read_bytes()):
        probs = raw.get("probs") if isinstance(raw, dict) else None
        row_id = raw.get("id") if isinstance(raw, dict) else None
        if (not isinstance(row_id, str) or not row_id or row_id in seen
                or not isinstance(probs, dict) or set(probs) != LABELS):
            raise ValueError("Invalid probability row")
        seen.add(row_id)
        row = {"id": row_id, "probs": normalize_probs(probs)}
        if need_gold:
            if raw.get("gold") not in LABELS:
                raise ValueError("Invalid gold label")
            question = raw.get("question", "default")
            if not isinstance(question, str) or not question:
                raise ValueError("Invalid question name")
            row.update(gold=raw["gold"], question=question)
        else:
            family = raw.get("family")
            if not isinstance(family, str) or not family:
                raise ValueError("Pool row needs a family")
            row["family"] = family
        rows.append(row)
    if not rows:
        raise ValueError("No probability rows")
    return rows


def normalize_probs(probs):
    clean = {}
    for label in sorted(probs):
        value = probs[label]
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            raise ValueError("Invalid probability")
        clean[label] = max(float(value), 1e-12)
    total = sum(clean.values())
    return {label: value / total for label, value in clean.items()}


def argmax(probs):
    return max(sorted(probs), key=lambda label: (probs[label], label))


def temper(probs, temperature):
    logits = {label: math.log(p) / temperature for label, p in probs.items()}
    top = max(logits.values())
    weights = {label: math.exp(value - top) for label, value in logits.items()}
    total = sum(weights.values())
    return {label: weight / total for label, weight in weights.items()}


def nll(rows, temperature):
    return -sum(math.log(temper(row["probs"], temperature)[row["gold"]]) for row in rows) / len(rows)


def fit_temperature(rows):
    return min(TEMPERATURE_GRID, key=lambda value: (nll(rows, value), value))


def fit_isotonic(xs, ys):
    """Pool-adjacent-violators on distinct x values. Returns [(upper_x, value)] knots."""
    grouped = {}
    for x, y in zip(xs, ys):
        total, count = grouped.get(x, (0.0, 0))
        grouped[x] = (total + y, count + 1)
    blocks = []  # [sum_y, count, upper_x]
    for x in sorted(grouped):
        total, count = grouped[x]
        blocks.append([total, count, x])
        while len(blocks) > 1 and blocks[-2][0] / blocks[-2][1] > blocks[-1][0] / blocks[-1][1]:
            total, count, upper = blocks.pop()
            blocks[-1][0] += total
            blocks[-1][1] += count
            blocks[-1][2] = upper
    return [(upper, total / count) for total, count, upper in blocks]


def apply_isotonic(knots, x):
    for upper, value in knots:
        if x <= upper:
            return value
    return knots[-1][1]


def reliability_bins(pairs):
    buckets = [[] for _ in range(CALIBRATION_BINS)]
    for confidence, correct in pairs:
        buckets[min(int(confidence * CALIBRATION_BINS), CALIBRATION_BINS - 1)].append((confidence, correct))
    table = []
    for index, bucket in enumerate(buckets):
        row = {"lo": round(index / CALIBRATION_BINS, 4), "hi": round((index + 1) / CALIBRATION_BINS, 4),
               "count": len(bucket), "confidence": None, "accuracy": None}
        if bucket:
            row["confidence"] = round(sum(c for c, _ in bucket) / len(bucket), 4)
            row["accuracy"] = round(sum(int(ok) for _, ok in bucket) / len(bucket), 4)
        table.append(row)
    return table


def expected_calibration_error(table):
    total = sum(row["count"] for row in table)
    return round(sum(row["count"] / total * abs(row["accuracy"] - row["confidence"])
                     for row in table if row["count"]), 6)


def fit_calibration(rows, isotonic):
    groups, scaled = {}, {}
    for question in sorted({row["question"] for row in rows}):
        group = [row for row in rows if row["question"] == question]
        temperature = fit_temperature(group)
        knots = None
        for row in group:
            scaled[row["id"]] = temper(row["probs"], temperature)
        if isotonic:
            knots = fit_isotonic([max(scaled[row["id"]].values()) for row in group],
                                 [int(argmax(scaled[row["id"]]) == row["gold"]) for row in group])
        groups[question] = {"temperature": temperature, "isotonic": knots, "rows": len(group)}

    def calibrated_confidence(row):
        confidence = max(scaled[row["id"]].values())
        knots = groups[row["question"]]["isotonic"]
        return apply_isotonic(knots, confidence) if knots else confidence

    before = [(max(row["probs"].values()), argmax(row["probs"]) == row["gold"]) for row in rows]
    after = [(calibrated_confidence(row), argmax(scaled[row["id"]]) == row["gold"]) for row in rows]
    before_table, after_table = reliability_bins(before), reliability_bins(after)

    done = [(scaled[row["id"]]["done"], row["gold"] == "done") for row in rows]
    # Strict rule: predict done only when P(done) is above the highest P(done) any non-done row received.
    threshold = max((p for p, is_done in done if not is_done), default=0.0)
    false_done = sum(1 for p, is_done in done if not is_done and p > threshold)
    done_total = sum(1 for _, is_done in done if is_done)
    recall = sum(1 for p, is_done in done if is_done and p > threshold) / done_total if done_total else None
    params = {
        "method": "temperature scaling" + (" plus isotonic on top-label confidence" if isotonic else ""),
        "done_rule": "predict done when calibrated P(done) > done_threshold",
        "done_threshold": threshold,
        "groups": groups,
        "fit_rows": len(rows),
    }
    report = {
        "rows": len(rows),
        "in_sample": "Fitted and scored on the same validation rows. Use a separate file to check generalization.",
        "ece": {"before": expected_calibration_error(before_table), "after": expected_calibration_error(after_table)},
        "reliability": {"before": before_table, "after": after_table},
        "temperatures": {question: group["temperature"] for question, group in groups.items()},
        "done": {"validation_done_rows": done_total, "done_threshold": threshold, "false_done": false_done,
                 "done_recall": None if recall is None else round(recall, 6),
                 "recall_cost": None if recall is None else round(1 - recall, 6)},
    }
    return params, report


def calibrate_command(args):
    rows = read_probability_file(args.validation, need_gold=True)
    params, report = fit_calibration(rows, args.isotonic)
    destination = writable(args.params)
    with destination.open("x", encoding="utf-8") as handle:
        handle.write(json.dumps(params, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))


def entropy_norm(probs):
    return -sum(p * math.log(p) for p in probs.values()) / math.log(len(probs))


def total_variation(a, b):
    return 0.5 * sum(abs(a[label] - b[label]) for label in LABELS)


def labeling_candidates(pool, other=None):
    other_by_id = {}
    if other is not None:
        other_by_id = {row["id"]: row for row in other}
        if set(other_by_id) != {row["id"] for row in pool}:
            raise ValueError("Both probability files must cover the same ids")
    scored = []
    for row in pool:
        partner = other_by_id[row["id"]]["probs"] if other is not None else None
        if partner is not None and other_by_id[row["id"]]["family"] != row["family"]:
            raise ValueError("Family differs between probability files")
        mean = {label: (row["probs"][label] + partner[label]) / 2 for label in LABELS} if partner else row["probs"]
        ordered = sorted(mean.values(), reverse=True)
        margin = ordered[0] - ordered[1]
        entropy = entropy_norm(mean)
        uncertainty = 0.5 * entropy + 0.5 * (1 - margin)
        reasons = [f"uncertain: margin {margin:.2f}, entropy {entropy:.2f}"]
        disagreement = 0.0
        if partner:
            disagreement = total_variation(row["probs"], partner)
            if argmax(row["probs"]) != argmax(partner):
                reasons.append(f"models disagree: {argmax(row['probs'])} vs {argmax(partner)}")
            else:
                reasons.append(f"models differ by {disagreement:.2f}")
        scored.append({"id": row["id"], "family": row["family"],
                       "score": round(uncertainty + disagreement, 6), "reason": "; ".join(reasons)})
    return scored


def select_for_labeling(pool, count, cap_percent):
    """Greedy by score, skipping any family that would pass cap_percent of the requested count.

    The final check runs on the picks actually returned, so no family exceeds the cap share of them.
    """
    cap = count * cap_percent // 100
    if cap < 1:
        raise ValueError("N is too small for the family cap")
    ranked = sorted(pool, key=lambda row: (-row["score"], row["id"]))
    picked, taken = [], Counter()
    for row in ranked:
        if len(picked) == count:
            break
        if taken[row["family"]] < cap:
            picked.append(row)
            taken[row["family"]] += 1
    while picked:
        counts = Counter(row["family"] for row in picked)
        over = max(counts, key=lambda family: (counts[family], family))
        if counts[over] * 100 <= cap_percent * len(picked):
            break
        # Drop the lowest-ranked pick from the over-share family; the pool may not hold enough other families.
        index = max(i for i, row in enumerate(picked) if row["family"] == over)
        del picked[index]
    return picked


def select_command(args):
    pool = read_probability_file(args.pool, need_gold=False)
    other = read_probability_file(args.other_probs, need_gold=False) if args.other_probs else None
    scored = labeling_candidates(pool, other)
    picked = select_for_labeling(scored, args.n, args.family_cap_percent)
    destination = writable(args.out)
    lines = [{"rank": rank, **row} for rank, row in enumerate(picked, start=1)]
    with destination.open("x", encoding="utf-8") as handle:
        handle.write(jsonl(lines).decode())
    summary = {"requested": args.n, "selected": len(picked),
               "families": dict(sorted(Counter(row["family"] for row in picked).items())),
               "family_cap_percent": args.family_cap_percent, "two_models": other is not None}
    if len(picked) < args.n:
        summary["note"] = "Fewer picks than requested: the cap would otherwise be breached with this pool."
    print(json.dumps(summary, indent=2, sort_keys=True))

def learning_label(row):
    """Label only from an observed step outcome. Model decisions and probabilities never label a row."""
    if row.get("kind") != "step":
        return None
    if row.get("failure_code") == "stuck":
        return "stuck"
    if row.get("done_when") == "verified":
        return "done"
    if row.get("done_when") == "unmet":
        return "look_again"
    if row.get("done_when") is None and row.get("delivery_state") == "delivered":
        return "act"
    return None


def export_learning(source, destination):
    """Turn LearningLog JSONL files into labelled rows shaped like the d1 rows (state, answer, meta)."""
    folder = Path(source)
    if not folder.is_dir():
        raise ValueError("Learning folder not found")
    output_path = writable(destination)
    rows, goals = [], {}
    for file in sorted(folder.glob("learning-*.jsonl")):
        for index, line in enumerate(file.read_text(encoding="utf-8").splitlines()):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                raise ValueError("Invalid learning row")
            if not isinstance(row, dict):
                raise ValueError("Invalid learning row")
            rows.append((f"{file.name}/{index}", row))
            if row.get("kind") == "episode" and row.get("goal"):
                goals[row.get("run_id")] = row["goal"]
    counts, skipped, out = Counter(), 0, []
    for ident, row in rows:
        label = learning_label(row)
        if label is None:
            skipped += 1
            continue
        last_step = " ".join(str(row.get(key) or "") for key in ("tool", "target_role", "target_label")).strip()
        state = {
            "goal": goals.get(row.get("run_id")) or row.get("tool") or "unknown",
            "last_step": last_step or "unknown",
            "result": (f"delivery {row.get('delivery_state') or 'unknown'}; "
                       f"verification {row.get('verification') or 'none'}; "
                       f"failure {row.get('failure_code') or 'none'}"),
            "view": row.get("after") or row.get("before") or last_step or "unknown",
        }
        state = {key: str(value)[:LIMITS[key]] for key, value in state.items()}
        counts[label] += 1
        out.append({
            "state": json.dumps(state, sort_keys=True, ensure_ascii=False),
            "answer": label,
            "meta": {"id": ident, "family": "learning", "source": "local_observed", "check": "step",
                     "outcome": row.get("done_when") or row.get("delivery_state") or "unknown", "variant": "observed"},
        })
    with output_path.open("x", encoding="utf-8") as handle:
        handle.write(jsonl(out).decode())
    return {"labels": dict(counts), "skipped": skipped, "written": len(out)}


SECURE_MARKERS = ("password", "passcode", "wachtwoord", "secure")
REDACTED = "[redacted]"
TYPING_TOOLS = {"type_text": "text", "set_value": "value"}


def words(text):
    return re.findall(r"[a-z0-9]+", (text or "").lower())


def secure_text(text):
    """True for secure-field markers and for values the scrubber already redacted. Matching is loose on purpose."""
    lower = (text or "").lower()
    return REDACTED in lower or any(marker in lower for marker in SECURE_MARKERS)


def learning_episodes(folder):
    """Group LearningLog step rows into episodes. BatchTool.learn writes an episode row after its steps, so each
    episode row closes the steps before it. Steps left open by a crash (a new batch starts before the old one closed)
    are counted as incomplete and dropped."""
    if not folder.is_dir():
        raise ValueError("Learning folder not found")
    episodes, dropped = [], Counter()
    for file in sorted(folder.glob("learning-*.jsonl")):
        pending = []
        for line in file.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                raise ValueError("Invalid learning row")
            if not isinstance(row, dict):
                raise ValueError("Invalid learning row")
            if row.get("kind") == "step":
                if pending and (row.get("n") == 1 or pending[-1].get("run_id") != row.get("run_id")):
                    dropped["incomplete"] += 1
                    pending = []
                pending.append(row)
            elif row.get("kind") == "episode":
                episodes.append({"file": file.name, "run_id": row.get("run_id"), "ts": row.get("ts"),
                                 "goal": row.get("goal") or "", "app": row.get("app") or "", "steps": pending,
                                 "done_when": row.get("done_when"), "done": row.get("done"),
                                 "window": row.get("window")})
                pending = []
        if pending:
            dropped["incomplete"] += 1
    return episodes, dropped

CONFIRM_WORDS = {"send", "pay", "payment", "purchase", "buy", "checkout", "delete", "remove", "trash", "erase", "transfer"}
SLOT_WORDS = (("recipient", {"recipient", "to", "cc", "bcc"}), ("email", {"email", "mail"}),
              ("path", {"path", "folder", "directory"}), ("number", {"number", "quantity", "amount"}))
GOAL_SLOTS = (
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "{{email}}"),
    (re.compile(r'"[^"]*"|“[^”]*”'), "{{text}}"),
    (re.compile(r"\b\d+(?:[.,:/]\d+)*\b"), "{{number}}"),
)
EXAMPLES = 3


def slot_kind(label):
    """A slot's kind from its field label only. Typed values are never logged, so they cannot be inspected."""
    found = set(words(label))
    for kind, marks in SLOT_WORDS:
        if found & marks:
            return kind
    return "text"


def goal_template(goal):
    text = goal or ""
    for pattern, slot in GOAL_SLOTS:
        text = pattern.sub(slot, text)
    return text.strip()


def episode_problem(episode):
    """Why an episode can never become a candidate, or None. Secure and redacted fields exclude the whole episode."""
    steps = episode["steps"]
    if not steps:
        return "no_steps"
    if len({row.get("app") for row in steps if row.get("app")}) > 1:
        return "mixed_app"
    if secure_text(episode["goal"]):
        return "secure_or_redacted"
    for condition in episode.get("done_when") or []:
        if any(secure_text(value) for value in condition.values() if isinstance(value, str)):
            return "secure_or_redacted"
    for row in steps:
        if secure_text(row.get("target_role")) or secure_text(row.get("target_label")):
            return "secure_or_redacted"
        if row.get("tool") in TYPING_TOOLS and not row.get("target_label"):
            return "unlabelled_typing"
    return None


def step_signature(row):
    """Tool plus target role and label. Typed values are not part of it, so they never split a sequence."""
    return (row.get("tool") or "", row.get("target_role") or "", row.get("target_label") or "")


def verified_episode(episode):
    return episode["steps"][-1].get("done_when") == "verified"


def generalized_conditions(conditions):
    """done_when in its JSON form, with the same slot generalization as goal text. None when the row has none."""
    if not isinstance(conditions, list) or not conditions:
        return None
    if not all(isinstance(condition, dict) for condition in conditions):
        return None
    return [{key: goal_template(value) if isinstance(value, str) else value for key, value in condition.items()}
            for condition in conditions]


def shared_identity(verified):
    """(done_when, window, reason). Every supporting episode must share the same generalized done_when and the same
    window. A candidate with a reason stays unverified; the reason says what was missing or different."""
    checks = {json.dumps(generalized_conditions(e.get("done_when")), sort_keys=True) for e in verified}
    if checks == {"null"}:
        return None, None, "done_when missing"
    if len(checks) > 1 or "null" in checks:
        return None, None, "done_when differs"
    windows = {json.dumps(e.get("window"), sort_keys=True) for e in verified}
    if windows == {"null"}:
        return None, None, "window missing"
    if len(windows) > 1 or "null" in windows:
        return None, None, "window differs"
    done_when = generalized_conditions(verified[0].get("done_when"))
    if "{{" in json.dumps(done_when):
        # A placeholder in a condition has nothing to bind to on replay, so it cannot be verified yet.
        return None, None, "done_when has slots"
    return done_when, verified[0].get("window"), None


def recipe_candidate(members, verified, app, template, signatures):
    """A BatchRecipes-shaped recipe. It is verified only when the supporting episodes share done_when and window;
    otherwise it stays unverified and says why."""
    sample = verified[0]
    done_when, window, reason = shared_identity(verified)
    steps, params, kinds = [], {}, {}
    sensitive = False
    for (tool, _role, label) in signatures:
        item = {"tool": tool}
        if label:
            item["label"] = label
        if tool in TYPING_TOOLS:
            name = "_".join(words(label)[:3]) or "text"
            unique, number = name, 2
            while unique in params:
                unique, number = f"{name}_{number}", number + 1
            params[unique] = ""
            kinds[unique] = slot_kind(label)
            item[TYPING_TOOLS[tool]] = "{{" + unique + "}}"
        if set(words(label)) & CONFIRM_WORDS:
            item["requiresConfirmation"] = True
            sensitive = True
        steps.append(item)
    examples = [{"file": e["file"], "run_id": e["run_id"], "ts": e["ts"]} for e in verified[:EXAMPLES]]
    return {
        "app": app, "goal": template, "steps": steps, "uses": 0, "failures": 0,
        "params": params, "slot_kinds": kinds, "done_when": done_when or [], "done_when_missing": done_when is None,
        "window": window, "verified": reason is None, "champion": False, "version": None,
        "status": "unverified" if reason else "verified", "reason": reason,
        "requiresConfirmation": sensitive, "support": len(verified), "episodes_total": len(members),
        "examples": examples,
    }


def mine_recipes(folder, min_support=3):
    """Repeated step sequences (same app, goal template and steps) that ended in a verified done_when.

    A sequence is kept only when it verified at least min_support times and every time it ran. A sequence that
    verified only sometimes is dropped. Typed values are never read: the log does not hold them."""
    if min_support < 1:
        raise ValueError("min_support must be at least 1")
    episodes, dropped = learning_episodes(Path(folder))
    groups = {}
    for episode in episodes:
        reason = episode_problem(episode)
        if reason:
            dropped[reason] += 1
            continue
        app = next((row.get("app") for row in episode["steps"] if row.get("app")), episode["app"])
        template = goal_template(episode["goal"])
        key = (app.lower(), " ".join(words(template)), tuple(step_signature(row) for row in episode["steps"]))
        groups.setdefault(key, []).append((app, template, episode))
    candidates = []
    for key, members in sorted(groups.items()):
        verified = [item[2] for item in members if verified_episode(item[2])]
        if len(verified) < min_support:
            dropped["groups_low_support"] += 1
        elif len(verified) < len(members):
            dropped["groups_sometimes_verified"] += 1
        else:
            app, template, _ = members[0]
            candidates.append(recipe_candidate(members, verified, app, template, key[2]))
    candidates.sort(key=lambda item: (-item["support"], item["goal"], item["app"]))
    return candidates, dict(sorted(dropped.items()))


def mine_command(args):
    candidates, dropped = mine_recipes(args.learning_dir, args.min_support)
    destination = writable(args.out)
    with destination.open("x", encoding="utf-8") as handle:
        handle.write(json.dumps(candidates, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    print(json.dumps({"candidates": len(candidates), "min_support": args.min_support, "dropped": dropped,
                      "all_unverified": True}, indent=2, sort_keys=True))


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("package", help="Package generated synthetic d1 rows for the PC")
    pack.add_argument("fixtures", type=Path)
    pack.add_argument("output", type=Path)
    learning = commands.add_parser("export-learning", help="Label LearningLog rows from observed outcomes only")
    learning.add_argument("dir", type=Path)
    learning.add_argument("out", type=Path)
    counts = commands.add_parser("counts", help="Count outcomes in a separately reviewed v3 metadata-only file")
    counts.add_argument("metadata", type=Path)
    run = commands.add_parser("eval", help="Score a candidate against the live model artifact")
    run.add_argument("--track", choices=("d1", "lfm"), default="d1")
    run.add_argument("--report", required=True, type=Path)
    arm = run.add_mutually_exclusive_group(required=True)
    arm.add_argument("--dry-run", action="store_true")
    arm.add_argument("--candidate", type=Path)
    run.add_argument("--mode", choices=("single", "two"), default="single")
    run.add_argument("--max-view", type=int, default=1200)
    run.add_argument("--done-confidence", type=float, default=DONE_CONFIDENCE)
    run.add_argument("--hint-confidence", type=float, default=HINT_CONFIDENCE)
    run.add_argument("--zoom", action="store_true")
    cal = commands.add_parser("calibrate", help="Fit per-question temperature (optional isotonic) and a done threshold")
    cal.add_argument("validation", type=Path, help="Validation probability JSONL")
    cal.add_argument("--params", required=True, type=Path, help="Output JSON of fitted parameters (new file)")
    cal.add_argument("--isotonic", action="store_true")
    pick = commands.add_parser("select-for-labeling", help="Pick the most informative unlabeled rows")
    pick.add_argument("--pool", required=True, type=Path, help="Unlabeled pool probability JSONL")
    pick.add_argument("--other-probs", type=Path, help="Second model's probability JSONL over the same ids")
    pick.add_argument("--n", required=True, type=int)
    pick.add_argument("--out", required=True, type=Path, help="Output JSONL with a reason per row (new file)")
    pick.add_argument("--family-cap-percent", type=int, default=40)
    mine = commands.add_parser("mine-recipes", help="Propose unverified recipe candidates from repeated verified LearningLog sequences")
    mine.add_argument("learning_dir", type=Path)
    mine.add_argument("--min-support", type=int, default=3)
    mine.add_argument("--out", required=True, type=Path, help="Output candidates JSON (new file)")
    args = cli.parse_args()
    try:
        if args.command == "package":
            print(json.dumps(package(args.fixtures, args.output), indent=2))
        elif args.command == "export-learning":
            print(json.dumps(export_learning(args.dir, args.out), sort_keys=True))
        elif args.command == "mine-recipes":
            mine_command(args)
        elif args.command == "counts":
            print(json.dumps(metadata_counts(read_rows(args.metadata.read_bytes())), sort_keys=True))
        elif args.command == "calibrate":
            calibrate_command(args)
        elif args.command == "select-for-labeling":
            if args.n < 1 or not 1 <= args.family_cap_percent <= 100:
                cli.exit(1, "flywheel: invalid --n or --family-cap-percent\n")
            select_command(args)
        else:
            number(args.done_confidence, 0, 1)
            number(args.hint_confidence, 0, 1)
            number(args.max_view, 1, LIMITS["view"])
            evaluate(args)
    except (KeyError, ValueError, TypeError, RuntimeError, OSError, ImportError) as error:
        cli.exit(1, f"flywheel: {error}\n")


if __name__ == "__main__":
    main()
