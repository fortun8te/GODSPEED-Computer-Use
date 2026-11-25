"""Exercise guest transport command construction and MCP probes without SSH or GUI input."""
import importlib.util
from pathlib import Path
import sys
import unittest


SPEC = importlib.util.spec_from_file_location("godspeed_guest_mcp", Path(__file__).resolve().parents[1] / "godspeed-guest-mcp.py")
guest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guest)


FAKE_SERVER = r'''
import json
import sys
mode = sys.argv[1]
for line in sys.stdin:
    event = json.loads(line)
    method = event["method"]
    if method == "initialize":
        result = {"serverInfo": {"name": "godspeed", "version": "test-build"}}
    elif method == "notifications/initialized":
        assert "id" not in event
        continue
    elif method == "tools/list":
        names = ["get_app_state", "query", "batch", "handoff"]
        if mode == "missing-tool":
            names.pop()
        result = {"tools": [{"name": name} for name in names]}
    elif method == "tools/call":
        assert mode != "no-window"
        assert event["params"]["name"] == "get_app_state"
        args = event["params"]["arguments"]
        assert args["app"] == "Calculator"
        assert args["window_id"] == 42
        assert args["include_screenshot"] is False
        assert args["include_ax"] is True
        result = {"isError": mode == "window-error", "content": [
            {"type": "text", "text": "Window ID: " + ("43" if mode == "wrong-window" else "42")},
        ]}
    else:
        raise AssertionError("Unexpected method")
    if mode == "bad-output":
        print("not JSON", flush=True)
        break
    print(json.dumps({"jsonrpc": "2.0", "id": event["id"], "result": result}), flush=True)
'''


class GuestTransportTests(unittest.TestCase):
    def server(self, mode):
        return [sys.executable, "-u", "-c", FAKE_SERVER, mode]

    def test_command_is_fixed_and_requires_verified_host_key(self):
        command = guest.ssh_command("godspeed-guest")
        self.assertEqual(command[:2], ["/usr/bin/ssh", "-T"])
        self.assertIn("StrictHostKeyChecking=yes", command)
        self.assertIn("BatchMode=yes", command)
        self.assertIn("ForwardAgent=no", command)
        self.assertIn("ClearAllForwardings=yes", command)
        self.assertIn("ControlPath=none", command)
        self.assertEqual(command[-2:], ["godspeed-guest", guest.REMOTE_COMMAND])

    def test_rejects_unsafe_or_ambiguous_aliases(self):
        for invalid in ["", "-oProxyCommand=x", "user@host", "ssh://guest", "guest;touch x", "guest\nother", "a" * 129]:
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    guest.ssh_command(invalid)

    def test_reachability_only_does_not_read_app(self):
        result = guest.check_guest(self.server("no-window"), "test-build", timeout=3)
        self.assertEqual(result, {"version": "test-build", "tools": 4, "window_read": False})

    def test_disposable_window_read(self):
        result = guest.check_guest(self.server("normal"), "test-build", "Calculator", 42, timeout=3)
        self.assertTrue(result["window_read"])

    def test_rejects_wrong_version_and_missing_tools(self):
        with self.assertRaisesRegex(RuntimeError, "version"):
            guest.check_guest(self.server("normal"), "different", timeout=3)
        with self.assertRaisesRegex(RuntimeError, "missing required"):
            guest.check_guest(self.server("missing-tool"), timeout=3)

    def test_rejects_wrong_window_and_error_reply(self):
        for mode in ["wrong-window", "window-error"]:
            with self.subTest(mode=mode), self.assertRaises(RuntimeError):
                guest.check_guest(self.server(mode), "test-build", "Calculator", 42, timeout=3)

    def test_rejects_non_mcp_output(self):
        with self.assertRaisesRegex(RuntimeError, "non-MCP"):
            guest.check_guest(self.server("bad-output"), timeout=3)

    def test_timeout_is_bounded(self):
        command = [sys.executable, "-u", "-c", "import sys; sys.stdin.read()"]
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            guest.check_guest(command, timeout=0.1)


if __name__ == "__main__":
    unittest.main()
