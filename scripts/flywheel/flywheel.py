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


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("package", help="Package generated synthetic d1 rows for the PC")
    pack.add_argument("fixtures", type=Path)
    pack.add_argument("output", type=Path)
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
    args = cli.parse_args()
    try:
        if args.command == "package":
            print(json.dumps(package(args.fixtures, args.output), indent=2))
        elif args.command == "counts":
            print(json.dumps(metadata_counts(read_rows(args.metadata.read_bytes())), sort_keys=True))
        else:
            number(args.done_confidence, 0, 1)
            number(args.hint_confidence, 0, 1)
            number(args.max_view, 1, LIMITS["view"])
            evaluate(args)
    except (KeyError, ValueError, TypeError, RuntimeError, OSError, ImportError) as error:
        cli.exit(1, f"flywheel: {error}\n")


if __name__ == "__main__":
    main()
