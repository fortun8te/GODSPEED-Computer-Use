"""Run with python3 -I scripts/flywheel/test_calibration.py. Synthetic data only; no models, no network."""
import argparse
import importlib.util
import json
import random
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("flywheel", Path(__file__).with_name("flywheel.py"))
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)
LABELS = sorted(f.LABELS)


def overconfident_rows(seed, count):
    """Accuracy about 70 percent, but every top-label confidence is 0.95."""
    rng = random.Random(seed)
    rows = []
    for index in range(count):
        gold = rng.choice(LABELS)
        if rng.random() < 0.7:
            predicted = gold
        else:
            predicted = rng.choice([label for label in LABELS if label != gold])
        probs = {label: 0.05 / 3 for label in LABELS}
        probs[predicted] = 0.95
        rows.append({"id": f"v{index}", "gold": gold, "question": "decision", "probs": probs})
    return rows


def validation_file(rows, directory, name="validation.jsonl"):
    path = Path(directory) / name
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
    return path


def peaked(label, peak, rest=None):
    others = [item for item in LABELS if item != label]
    rest = (1 - peak) / len(others) if rest is None else rest
    return {item: (peak if item == label else rest) for item in LABELS}


class CalibrationTests(unittest.TestCase):
    def test_temperature_scaling_lowers_ece_on_miscalibrated_fixture(self):
        rows = overconfident_rows(7, 600)
        params, report = f.fit_calibration(rows, isotonic=False)
        self.assertGreater(report["ece"]["before"], 0.2)
        self.assertLess(report["ece"]["after"], report["ece"]["before"])
        self.assertLess(report["ece"]["after"], 0.1)
        self.assertGreater(params["groups"]["decision"]["temperature"], 1.0)
        self.assertEqual(len(report["reliability"]["after"]), f.CALIBRATION_BINS)

    def test_isotonic_option_is_fitted_and_monotone(self):
        rows = overconfident_rows(11, 600)
        params, report = f.fit_calibration(rows, isotonic=True)
        knots = params["groups"]["decision"]["isotonic"]
        values = [value for _, value in knots]
        self.assertEqual(values, sorted(values))
        self.assertLess(report["ece"]["after"], report["ece"]["before"])

    def test_done_threshold_keeps_zero_false_done_and_reports_recall(self):
        rng = random.Random(3)
        rows = []
        for index in range(300):
            gold = rng.choice(LABELS)
            top = gold if rng.random() < 0.8 else rng.choice(LABELS)
            probs = {label: rng.uniform(0.01, 0.2) for label in LABELS}
            probs[top] += 1.5
            rows.append({"id": f"t{index}", "gold": gold, "question": "decision", "probs": f.normalize_probs(probs)})
        params, report = f.fit_calibration(rows, isotonic=False)
        threshold = params["done_threshold"]
        group = params["groups"]["decision"]
        false_done = done_hits = done_total = 0
        for row in rows:
            p_done = f.temper(row["probs"], group["temperature"])["done"]
            predicted_done = p_done > threshold
            if row["gold"] == "done":
                done_total += 1
                done_hits += predicted_done
            elif predicted_done:
                false_done += 1
        self.assertEqual(false_done, 0)
        self.assertEqual(report["done"]["false_done"], 0)
        self.assertEqual(report["done"]["validation_done_rows"], done_total)
        self.assertAlmostEqual(report["done"]["done_recall"], done_hits / done_total, places=5)
        self.assertAlmostEqual(report["done"]["recall_cost"], 1 - done_hits / done_total, places=5)

    def test_calibrate_command_writes_params_and_is_deterministic(self):
        rows = overconfident_rows(5, 200)
        with tempfile.TemporaryDirectory() as directory:
            source = validation_file(rows, directory)
            outputs = []
            for name in ("first.json", "second.json"):
                params = Path(directory) / name
                f.calibrate_command(argparse.Namespace(validation=source, params=params, isotonic=True))
                outputs.append(params.read_bytes())
            self.assertEqual(outputs[0], outputs[1])
            self.assertIn("done_threshold", json.loads(outputs[0]))

    def test_selection_respects_family_cap_and_prefers_uncertain_rows(self):
        pool = []
        for index in range(30):
            pool.append({"id": f"a{index:02d}", "family": "A", "probs": peaked(LABELS[index % 4], 0.3 + index * 0.01)})
        for family in ("B", "C", "D"):
            for index in range(10):
                pool.append({"id": f"{family}{index:02d}", "family": family, "probs": peaked("act", 0.97)})
        scored = f.labeling_candidates([{**row, "probs": f.normalize_probs(row["probs"])} for row in pool])
        picked = f.select_for_labeling(scored, 10, 40)
        self.assertEqual(len(picked), 10)
        counts = Counter(row["family"] for row in picked)
        self.assertLessEqual(counts["A"] * 100, 40 * len(picked))
        for family, count in counts.items():
            self.assertLessEqual(count * 100, 40 * len(picked), family)
        most_uncertain_a = sorted((row for row in scored if row["family"] == "A"),
                                  key=lambda row: (-row["score"], row["id"]))[:counts["A"]]
        self.assertEqual({row["id"] for row in picked if row["family"] == "A"},
                         {row["id"] for row in most_uncertain_a})
        top = max(scored, key=lambda row: (row["score"], row["id"]))
        self.assertEqual(picked[0]["id"], top["id"])
        self.assertTrue(all("uncertain" in row["reason"] for row in picked))

    def test_cap_holds_when_the_pool_is_short_of_families(self):
        pool = [{"id": f"a{i}", "family": "A", "probs": f.normalize_probs(peaked("act", 0.4))} for i in range(5)]
        pool.append({"id": "b0", "family": "B", "probs": f.normalize_probs(peaked("act", 0.95))})
        picked = f.select_for_labeling(f.labeling_candidates(pool), 6, 40)
        total = len(picked)
        for family, count in Counter(row["family"] for row in picked).items():
            self.assertLessEqual(count * 100, 40 * total, family)

    def test_two_models_disagreement_ranks_first_with_reason(self):
        agree = [{"id": f"s{i}", "family": ["A", "B", "C", "D"][i % 4], "probs": f.normalize_probs(peaked("act", 0.9))}
                 for i in range(8)]
        first = [{**row} for row in agree]
        second = [{**row, "probs": f.normalize_probs(peaked("act", 0.9))} for row in agree]
        first.append({"id": "x", "family": "E", "probs": f.normalize_probs(peaked("act", 0.9))})
        second.append({"id": "x", "family": "E", "probs": f.normalize_probs(peaked("done", 0.9))})
        scored = f.labeling_candidates(first, second)
        top = max(scored, key=lambda row: (row["score"], row["id"]))
        self.assertEqual(top["id"], "x")
        self.assertIn("models disagree", top["reason"])

    def test_select_command_output_is_deterministic(self):
        pool = [{"id": f"p{i:03d}", "family": "ABCD"[i % 4], "probs": peaked(LABELS[i % 4], 0.25 + (i % 7) * 0.1)}
                for i in range(80)]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "pool.jsonl"
            source.write_text("".join(json.dumps(row) + "\n" for row in pool), encoding="utf-8")
            outputs = []
            for name in ("one.jsonl", "two.jsonl"):
                out = Path(directory) / name
                f.select_command(argparse.Namespace(pool=source, other_probs=None, n=12, out=out,
                                                    family_cap_percent=40))
                outputs.append(out.read_bytes())
            self.assertEqual(outputs[0], outputs[1])
            lines = [json.loads(line) for line in outputs[0].decode().splitlines()]
            self.assertEqual(len(lines), 12)
            self.assertTrue(all(line["reason"] for line in lines))

    def test_command_line_runs_isolated(self):
        rows = overconfident_rows(9, 120)
        script = str(Path(__file__).with_name("flywheel.py"))
        with tempfile.TemporaryDirectory() as directory:
            source = validation_file(rows, directory)
            result = subprocess.run([sys.executable, "-I", script, "calibrate", str(source),
                                     "--params", str(Path(directory) / "params.json")],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"ece"', result.stdout)


if __name__ == "__main__":
    unittest.main()
