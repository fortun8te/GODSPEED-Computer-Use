"""Exercise setup argument routing with an inert existing helper."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "setup-godspeed-chrome.sh"


class ChromeSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "calls.jsonl"
        self.helper = self.root / "existing helper"
        self.helper.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "with open(os.environ['GODSPEED_SETUP_TEST_LOG'], 'a') as f:\n"
            "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "if sys.argv[1:] == ['setup', 'beta', '--help']:\n"
            "    print(os.environ.get('GODSPEED_SETUP_TEST_HELP', '--zip PATH --no-open'))\n"
            "    sys.exit(0)\n"
            "sys.exit(int(os.environ.get('GODSPEED_SETUP_TEST_STATUS', '0')))\n"
        )
        self.helper.chmod(0o700)
        self.archive = self.root / "Godspeed workspace.zip"
        self.archive.write_bytes(b"fixture: helper owns archive validation")
        self.env = dict(os.environ, OPEN_COMPUTER_USE_OBU_BIN=str(self.helper),
                        GODSPEED_SETUP_TEST_LOG=str(self.log))

    def run_setup(self, *args):
        return subprocess.run(["bash", str(SCRIPT), *map(str, args)], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_workspace_reuses_helper_and_preserves_arguments(self):
        before = self.helper.read_bytes()
        result = self.run_setup("--no-open", "--workspace-zip", self.archive)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["setup", "beta", "--help"],
                                       ["setup", "beta", "--zip", str(self.archive), "--no-open"]])
        self.assertEqual(self.helper.read_bytes(), before)
        self.assertIn("Approve this extension", result.stdout)

    def test_workspace_can_open_setup_and_ping_uses_selected_helper(self):
        self.assertEqual(self.run_setup("--workspace-zip", self.archive).returncode, 0)
        self.assertEqual(self.calls()[-1], ["setup", "beta", "--zip", str(self.archive)])
        self.assertEqual(self.run_setup("--check").returncode, 0)
        self.assertEqual(self.calls()[-1], ["ping"])

    def test_existing_helper_is_not_reinstalled_in_standard_setup(self):
        result = self.run_setup("--no-open")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["setup", "--no-open"]])

    def test_missing_archive_or_helper_stops_before_setup(self):
        self.assertNotEqual(self.run_setup("--workspace-zip", self.root / "missing.zip").returncode, 0)
        self.assertEqual(self.calls(), [])
        self.helper.unlink()
        self.assertNotEqual(self.run_setup("--workspace-zip", self.archive).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_unsupported_or_failed_setup_is_not_reported_as_prepared(self):
        self.env["GODSPEED_SETUP_TEST_HELP"] = "old setup command"
        result = self.run_setup("--workspace-zip", self.archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [["setup", "beta", "--help"]])
        self.assertNotIn("Workspace prepared", result.stdout)
        self.env["GODSPEED_SETUP_TEST_HELP"] = "--zip PATH --no-open"
        self.env["GODSPEED_SETUP_TEST_STATUS"] = "1"
        result = self.run_setup("--workspace-zip", self.archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls()[-1], ["setup", "beta", "--zip", str(self.archive)])
        self.assertNotIn("Workspace prepared", result.stdout)

    def test_invalid_combinations_do_not_invoke_helper(self):
        for args in [("--workspace-zip",), ("--check", "--no-open"),
                     ("--check", "--workspace-zip", self.archive),
                     ("--workspace-zip", self.archive, "--workspace-zip", self.archive),
                     ("--no-open", "--no-open"), ("--unknown",)]:
            with self.subTest(args=args):
                self.assertEqual(self.run_setup(*args).returncode, 2)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
