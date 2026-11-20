import importlib.util
import json
from collections import Counter
from pathlib import Path
import unittest

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("generate", HERE / "generate.py")
generate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generate)

class GenerateTests(unittest.TestCase):
    def test_seed_determinism(self):
        self.assertEqual(generate.generate(1, 20), generate.generate(1, 20))
        self.assertNotEqual(generate.generate(1, 20), generate.generate(2, 20))

    def test_schema_heldout_and_unique(self):
        fly = (HERE.parent / "flywheel.py").read_text()
        self.assertIn('"state", "answer", "meta"', fly)
        held = {row["meta"]["family"] for row in map(json.loads, (HERE.parent / "heldout.jsonl").read_text().splitlines())}
        rows = generate.generate(1, 50)
        self.assertFalse(held & set(generate.FAMILIES))
        keys = set()
        for row in rows:
            self.assertEqual(set(row), {"state", "answer", "meta"})
            self.assertTrue(row["meta"]["synthetic"])
            self.assertNotIn(json.dumps(row, sort_keys=True), keys)
            keys.add(json.dumps(row, sort_keys=True))
            self.assertEqual(set(json.loads(row["state"])), {"goal", "last_step", "result", "view"})

    def test_label_balance(self):
        rows = generate.generate(8, 200)
        for family in generate.FAMILIES:
            counts = Counter(r["answer"] for r in rows if r["meta"]["family"] == family)
            self.assertLessEqual(max(counts.values()) - min(counts.values()), 20)

if __name__ == "__main__": unittest.main()
