import importlib.util
from pathlib import Path
import unittest

MODULE = Path(__file__).resolve().parents[2] / "experiments/LocalHelper/gsd1_server.py"
SPEC = importlib.util.spec_from_file_location("gsd1_server", MODULE)
GSD1 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GSD1)


class FakeModel:
    def system_one(self, state, questions):
        return {"answers": {"decision": {"probabilities": {"a": 0.9, "b": 0.1}}}}


class GSD1ServerTests(unittest.TestCase):
    def test_switching_roles_releases_previous_checkpoint(self):
        loaded = []
        cleared = []
        def load(path):
            loaded.append(Path(path).name)
            return FakeModel(), None
        scorer = GSD1.Scorer(Path("/fixture"), load, lambda: cleared.append(True))
        for role in ("action", "action", "recover", "read"):
            response = scorer.score(role, {}, {})
            self.assertEqual(response["model"], "gsd1-" + role)
            self.assertEqual(scorer.role, role)
        self.assertEqual(loaded, ["action", "recover", "read"])
        self.assertEqual(len(cleared), 3)
        scorer.last_use -= 181
        scorer.unload_if_idle()
        self.assertIsNone(scorer.role)
        self.assertIsNone(scorer.model)

    def test_requests_validate_role_and_option_shape(self):
        valid = {"role": "read", "state": {}, "question": {
            "type": "choice", "instructions": "Decide", "criteria": {"a": "Use read", "b": "Refresh"},
        }}
        self.assertEqual(GSD1.request(valid)[0], "read")
        with self.assertRaises(ValueError):
            GSD1.request({**valid, "role": "stock"})
        with self.assertRaises(ValueError):
            GSD1.request({**valid, "question": {**valid["question"], "criteria": {"a": "Only one"}}})


if __name__ == "__main__":
    unittest.main()
