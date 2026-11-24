import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "godspeed_observation_capture.py"
spec = importlib.util.spec_from_file_location("godspeed_observation_capture", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CaptureTests(unittest.TestCase):
    def test_links_observations_while_redacting_typed_and_field_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            capture = module.ObservationCapture(tmp)
            before = {"result": {"content": [{"type": "text", "text": "App=private.app\nWindow: secret document\n0 standard window secret\n  1 button Alice's bank\n  2 text field private message"}]}}
            after = {"result": {"content": [{"type": "text", "text": "App=private.app\nWindow: secret document\n0 standard window secret\n  1 button Alice's bank\n  2 text field changed value"}]}}
            ack = {"result": {"content": [{"type": "text", "text": "ok"}]}}
            capture.record("get_app_state", {"app": "private.app"}, before, 1)
            capture.record("set_value", {"app": "private.app", "label": "field", "value": "hunter2"}, ack, 2)
            capture.record("get_app_state", {"app": "private.app"}, after, 3)
            file = next(Path(tmp).glob("*.jsonl"))
            contents = file.read_text()
            for secret in ("hunter2", "private message", "changed value"):
                self.assertNotIn(secret, contents)
            rows = [json.loads(line) for line in contents.splitlines()]
            self.assertIn("Alice's bank", rows[0]["visible_state"])
            self.assertEqual(rows[1]["prior_observation"], 1)
            self.assertEqual(rows[2]["after_action"], 2)
            self.assertTrue(rows[2]["view_changed"])
            self.assertEqual(rows[0]["roles"], {"button": 1, "standard_window": 1, "text_field": 1})
            self.assertTrue(all(row["task_verification"] == "not_checked" for row in rows))
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_secure_window_and_clipboard_never_record_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            capture = module.ObservationCapture(tmp)
            state = {"result": {"content": [{"type": "text", "text": "App=x\nWindow: test\n0 secure text field secret"}]}}
            capture.record("get_app_state", {"app": "x"}, state, 1)
            capture.record("clipboard", {"text": "my secret"}, {"result": {}}, 1)
            state["result"]["content"][0]["text"] = "App=x\nWindow: test\n0 text my secret"
            capture.record("get_app_state", {"app": "x"}, state, 1)
            rows = [json.loads(line) for line in next(Path(tmp).glob("*.jsonl")).read_text().splitlines()]
            self.assertTrue(rows[0]["content_omitted"])
            self.assertTrue(rows[2]["content_omitted"])
            self.assertNotIn("my secret", json.dumps(rows))

    def test_batch_input_echoes_and_image_payloads_are_not_saved(self):
        with tempfile.TemporaryDirectory() as tmp:
            capture = module.ObservationCapture(tmp)
            capture.record("batch", {"app": "x", "steps": [{"tool": "type_text", "text": "a typed secret"}]}, {"result": {}}, 1)
            state = {"result": {"content": [{"type": "text", "text": "App=x\nWindow: test\n0 text a typed secret"}, {"type": "image", "data": "image_payload"}]}}
            capture.record("get_app_state", {"app": "x"}, state, 1)
            text = next(Path(tmp).glob("*.jsonl")).read_text()
            self.assertNotIn("a typed secret", text)
            self.assertNotIn("image_payload", text)
            self.assertTrue(json.loads(text.splitlines()[-1])["content_omitted"])

    def test_full_capture_directory_preserves_existing_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = Path(tmp) / "existing.jsonl"
            old.write_text("already recorded\n")
            capture = module.ObservationCapture(tmp, directory_max_bytes=1)
            self.assertFalse(capture.record("click", {"app": "x"}, {"result": {}}, 1))
            self.assertFalse(capture.record("click", {"app": "x"}, {"result": {}}, 1))
            self.assertEqual(old.read_text(), "already recorded\n")
            self.assertEqual(len(list(Path(tmp).glob("*.jsonl"))), 1)

    def test_failed_and_unobserved_actions_are_not_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            capture = module.ObservationCapture(tmp)
            capture.record("click", {"app": "example", "label": "private"}, {"result": {"isError": True}}, 4)
            rows = [json.loads(line) for line in next(Path(tmp).glob("*.jsonl")).read_text().splitlines()]
            self.assertEqual(rows[0]["response"], "error")
            self.assertEqual(rows[0]["task_verification"], "not_checked")
            self.assertIsNone(rows[0]["prior_observation"])


if __name__ == "__main__":
    unittest.main()
