#!/usr/bin/env python3
"""Compare paired GODSPEED requests using only the existing loopback helper."""
import argparse
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time
from urllib import error, request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
HOST = "http://127.0.0.1:8765"
VARIANTS = ("legacy", "focused")
CALL_LIMIT = 300
DEFAULT_CHOOSE = (0.6, 0.2)
DEFAULT_HINT = {"done": 0.86, "stuck": 0.6, "look_again": 0.6}


class NoRedirects(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


HTTP = request.build_opener(request.ProxyHandler({}), NoRedirects())


def call(route, body=None, timeout=8):
    payload = json.dumps(body).encode() if body is not None else None
    req = request.Request(HOST + "/" + route, data=payload, headers={"Content-Type": "application/json"})
    started = time.perf_counter()
    try:
        with HTTP.open(req, timeout=timeout) as stream:
            reply = json.load(stream)
        if not isinstance(reply, dict):
            return None, (time.perf_counter() - started) * 1000, "response was not an object"
        return reply, (time.perf_counter() - started) * 1000, None
    except (OSError, ValueError, error.URLError) as exc:
        return None, (time.perf_counter() - started) * 1000, str(exc)


def export_fixtures(skip_build):
    with tempfile.TemporaryDirectory(prefix="godspeed-helper-eval-") as tmp:
        file = Path(tmp) / "requests.json"
        command = ["swift", "test", "-j", "3"]
        if skip_build:
            command += ["--skip-build"]
        command += ["--filter", "LocalHelperEvalFixturesTests/testExportLocalHelperEval"]
        subprocess.run(
            command, cwd=ROOT, env={**os.environ, "GODSPEED_LOCAL_EVAL_OUTPUT": str(file)}, check=True,
        )
        return json.loads(file.read_text())


def top_two(row):
    reply = row["reply"] or {}
    probs = reply.get("probs")
    if not isinstance(probs, dict) or "none" not in probs:
        return "none", 0, 0
    values = [(k, v) for k, v in probs.items() if type(v) in (int, float) and 0 <= v <= 1]
    if len(values) != len(probs) or len(values) < 2:
        return "none", 0, 0
    values.sort(key=lambda kv: kv[1], reverse=True)
    (best, confidence), (_, second) = values[:2]
    return best, confidence, confidence - second


def choose(row, cutoff, margin):
    best, confidence, lead = top_two(row)
    return best if confidence >= cutoff and lead >= margin else "none"


def hint(row, thresholds):
    reply = row["reply"] or {}
    label = reply.get("label")
    confidence = reply.get("confidence", 0)
    if label in thresholds and type(confidence) in (int, float) and confidence >= thresholds[label]:
        return label
    return None


def calibrate(dev):
    """Pick exploratory thresholds only on the dev families."""
    calibration = {}
    for variant in VARIANTS:
        rows = [r for r in dev if r["variant"] == variant and r["route"] == "choose"]
        grid = [(cutoff, margin) for cutoff in (0.6, 0.7, 0.8, 0.9) for margin in (0.2, 0.25, 0.35)]
        admissible = []
        for cutoff, margin in grid:
            pairs = [(choose(row, cutoff, margin), row["expected"]) for row in rows]
            if any(got != want and got != "none" for got, want in pairs):
                continue
            correct_actions = sum(got == want and got != "none" for got, want in pairs)
            if correct_actions >= 3:
                admissible.append((correct_actions, cutoff, margin))
        fit = max(admissible, default=None)
        rows = [r for r in dev if r["variant"] == variant and r["route"] == "decide"]
        done_cutoff = None
        for cutoff in (0.86, 0.90, 0.95, 0.99):
            predictions = [r for r in rows if hint(r, {"done": cutoff}) == "done"]
            if len(predictions) >= 3 and all(r["expected"] == "done" for r in predictions):
                done_cutoff = cutoff
                break
        calibration[variant] = {
            "choose": [fit[1], fit[2]] if fit else None,
            "dev_correct_actions": fit[0] if fit else None,
            "done_confidence": done_cutoff,
        }
    return calibration


def timing(values):
    return {
        "median_ms": round(statistics.median(values), 1) if values else None,
        "p90_ms": round(sorted(values)[math.ceil(0.9 * len(values)) - 1], 1) if values else None,
    }


def summarize(rows, calibration):
    summary = {}
    for split in ("dev", "heldout"):
        for route in ("choose", "decide"):
            for variant in VARIANTS:
                subset = [r for r in rows if (r["split"], r["route"], r["variant"]) == (split, route, variant)]
                n = len(subset)
                if not n:
                    continue
                key = f"{split}/{route}/{variant}"
                metrics = {"n": n, "errors": sum(bool(r["error"]) for r in subset),
                           **timing([r["wall_ms"] for r in subset if not r["error"]])}
                if route == "choose":
                    metrics["top1_correct"] = sum(
                        bool(r["reply"]) and top_two(r)[0] == r["expected"] for r in subset
                    )
                    settings = {"defaults": DEFAULT_CHOOSE, "dev_fit": calibration[variant]["choose"]}
                    for name, fit in settings.items():
                        if fit is None:
                            continue
                        pairs = [(choose(r, *fit), r["expected"]) for r in subset]
                        metrics[name] = {
                            "correct": sum(a == b for a, b in pairs),
                            "abstain": sum(a == "none" for a, _ in pairs),
                            "wrong_actions": sum(a != b and a != "none" for a, b in pairs),
                        }
                else:
                    metrics["top1_correct"] = sum((r["reply"] or {}).get("label") == r["expected"] for r in subset)
                    settings = {"defaults": DEFAULT_HINT}
                    cutoff = calibration[variant]["done_confidence"]
                    if cutoff is not None:
                        settings["dev_fit"] = {**DEFAULT_HINT, "done": cutoff}
                    for name, thresholds in settings.items():
                        pairs = [(hint(r, thresholds), r["expected"]) for r in subset]
                        metrics[name] = {
                            "abstain": sum(a is None for a, _ in pairs),
                            "correct_hints": sum(a == b for a, b in pairs),
                            "done_correct": sum(a == b == "done" for a, b in pairs),
                            "done_hints": sum(a == "done" for a, _ in pairs),
                        }
                summary[key] = metrics
    return summary


def ground(row, variant):
    point = row.get("ocr_point") if variant == "focused" else None
    elapsed = row["ocr_ms"] if variant == "focused" else 0
    source = "ocr" if point is not None else "abstain"
    failure = None
    lfm_called = point is None and not (variant == "focused" and row["ambiguous"])
    if lfm_called:
        image = row["crop"] if variant == "focused" else row["legacy"]
        reply, wall, failure = call("locate", {"query": row["query"], "image_base64": image}, timeout=15)
        elapsed += wall
        if reply and reply.get("found") is True and all(type(reply.get(c)) in (float, int) for c in ("x", "y")):
            point = [reply["x"], reply["y"]]
            source = "lfm"
    box = row.get("box")
    valid = bool(point and all(0 <= x < 1 for x in point))
    correct = (not valid if box is None else
               valid and box[0] <= point[0] <= box[2] and box[1] <= point[1] <= box[3])
    return {"id": row["id"], "variant": variant, "source": source, "correct": correct,
            "abstain": not valid, "lfm_called": lfm_called, "point": point, "wall_ms": elapsed, "error": failure}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="reuse an existing Swift test build")
    parser.add_argument("--output", type=Path, help="write the report and keep incremental samples next to it")
    args = parser.parse_args()
    health, _, failure = call("health", timeout=2)
    if not health or health.get("ok") is not True:
        print("SKIP: the existing local helper is unavailable.", failure or "")
        return
    print("Helper:", json.dumps(health), flush=True)
    fixtures = export_fixtures(args.skip_build)
    decisions = fixtures["decisions"]
    screenshots = fixtures["screenshots"]
    if 2 * (len(decisions) + len(screenshots)) + 1 > CALL_LIMIT:
        raise SystemExit("Fixture count would exceed the sequential call cap.")
    samples = None
    if args.output:
        samples = args.output.with_suffix(".samples.jsonl").open("w")

    def save_sample(row):
        if samples:
            samples.write(json.dumps(row) + "\n")
            samples.flush()

    rows = []
    visual = []
    try:
        calibration = {}
        for split in ("dev", "heldout"):
            for index, row in enumerate(r for r in decisions if r["split"] == split):
                order = VARIANTS if index % 2 == 0 else VARIANTS[::-1]
                for variant in order:
                    reply, wall_ms, err = call(row["route"], row[variant])
                    result = {k: row[k] for k in ("id", "split", "route", "expected")}
                    result.update(variant=variant, reply=reply, wall_ms=wall_ms, error=err)
                    rows.append(result)
                    save_sample(result)
            if split == "dev":
                calibration = calibrate(rows)
            print(f"Finished {split} ({len(rows)} cumulative decision requests).", flush=True)
        for index, row in enumerate(screenshots):
            order = VARIANTS if index % 2 == 0 else VARIANTS[::-1]
            for variant in order:
                result = ground(row, variant)
                visual.append(result)
                save_sample(result)
    finally:
        if samples:
            samples.close()
    report = {
        "helper": health, "calibration_from_dev_only": calibration,
        "decisions": summarize(rows, calibration),
        "grounding": {
            variant: {
                "n": len(subset),
                "correct": sum(r["correct"] for r in subset),
                "abstain": sum(r["abstain"] for r in subset),
                "lfm_calls": sum(r["lfm_called"] for r in subset),
                **timing([r["wall_ms"] for r in subset]),
            }
            for variant in VARIANTS if (subset := [r for r in visual if r["variant"] == variant])
        },
        "grounding_samples": visual,
    }
    output = json.dumps(report, indent=2) + "\n"
    print(output, end="")
    if args.output:
        args.output.write_text(output)


if __name__ == "__main__":
    main()
