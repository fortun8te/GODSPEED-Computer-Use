import hashlib
import difflib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch as mock_patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "package-godspeed-browser.py"
SPEC = importlib.util.spec_from_file_location("godspeed_browser_package", SCRIPT)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


@unittest.skipUnless(shutil.which("git") and shutil.which("node"), "git and node are needed for the package contract")
class BrowserPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="godspeed-browser-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.integration = self.root / "integration"
        self.integration.mkdir()
        self.output = self.root / "output"
        extension = self.source / "apps" / "chrome-extension"
        self.background = 'const original = "before";\n'
        for relative in PACKAGE.FILES:
            path = extension / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture")
            if path.suffix in {".js", ".mjs"}:
                path.write_text('const fixture = true;\n')
        (extension / "background.js").write_text(self.background)
        (extension / "manifest.json").write_text(json.dumps({
            "manifest_version": 3, "version": "1.1.0", "action": {"default_title": "Upstream"},
            "permissions": ["tabs", "tabGroups", "nativeMessaging"],
        }) + "\n")
        (self.source / "LICENSE").write_text("Fixture license\n")
        self.git("init", "--quiet")
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--quiet", "-m", "Pinned fixture")
        commit = self.git("rev-parse", "HEAD").strip()
        self.pin = {
            "repository": "https://github.com/iFurySt/open-browser-use.git", "commit": commit,
            "version": "1.1.0", "workspace_version": "1.1.0.1",
            "background_sha256": hashlib.sha256(self.background.encode()).hexdigest(),
            "extension_public_key": PACKAGE.load_pin()["extension_public_key"],
        }
        self.save_pin()
        (self.integration / "background.patch").write_text(
            'diff --git a/background.js b/background.js\n--- a/background.js\n+++ b/background.js\n'
            '@@ -1 +1,2 @@\n+import "./godspeed-workspace.mjs";\n const original = "before";\n')
        (self.integration / "godspeed-workspace.mjs").write_text('export const workspace = "ready";\n')

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.source), *args], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout

    def save_pin(self):
        (self.integration / "upstream.json").write_text(json.dumps(self.pin))

    def build(self):
        return PACKAGE.build(self.source, self.output, integration=self.integration)

    def test_pinned_build_ignores_working_edits_and_preserves_license_and_permissions(self):
        (self.source / "apps/chrome-extension/background.js").write_text("unreviewed invalid JavaScript")
        artifact = self.build()
        with zipfile.ZipFile(artifact) as archive:
            self.assertIn(b'const original = "before";', archive.read("background.js"))
            self.assertIn(b'godspeed-workspace.mjs', archive.read("background.js"))
            self.assertEqual(archive.read("UPSTREAM-LICENSE.txt"), b"Fixture license\n")
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["permissions"], ["tabs", "tabGroups", "nativeMessaging"])
            self.assertEqual(manifest["key"], self.pin["extension_public_key"])
            self.assertEqual(manifest["name"], "Godspeed Browser Workspace")
            provenance = json.loads(archive.read("PROVENANCE.json"))
            self.assertEqual(provenance["extension_id"], "ljonkdmghgnpenfkbmpijhadclblikja")
            self.assertEqual(provenance["source_sha256"]["LICENSE"], hashlib.sha256(b"Fixture license\n").hexdigest())
            self.assertEqual(set(archive.namelist()), PACKAGE.STAGED_FILES | {"PROVENANCE.json"})
            for path, digest in provenance["files_sha256"].items():
                self.assertEqual(hashlib.sha256(archive.read(path)).hexdigest(), digest)

    def check_replacement_is_ignored(self, kind):
        manifest_path = "apps/chrome-extension/manifest.json"
        original_manifest = (self.source / manifest_path).read_bytes()
        object_expression = {"commit": "", "tree": "^{tree}", "blob": ":" + manifest_path}[kind]
        original = self.git("rev-parse", self.pin["commit"] + object_expression).strip()
        manifest = json.loads(original_manifest)
        manifest["permissions"].append("debugger")
        (self.source / manifest_path).write_text(json.dumps(manifest))
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--quiet", "-m", "Replacement object fixture")
        replacement = self.git("rev-parse", "HEAD" + object_expression).strip()
        self.git("replace", original, replacement)
        # Demonstrate that a normal Git read is redirected, so this covers the actual
        # replacement mechanism rather than just placing an unused ref in the checkout.
        self.assertIn("debugger", self.git("show", self.pin["commit"] + ":" + manifest_path))
        artifact = self.build()
        with zipfile.ZipFile(artifact) as archive:
            self.assertEqual(json.loads(archive.read("manifest.json"))["permissions"],
                             ["tabs", "tabGroups", "nativeMessaging"])
            provenance = json.loads(archive.read("PROVENANCE.json"))
            self.assertEqual(provenance["commit"], self.pin["commit"])
            self.assertEqual(provenance["source_sha256"]["manifest.json"], hashlib.sha256(original_manifest).hexdigest())

    def test_replacement_commit_cannot_redirect_pinned_source(self):
        self.check_replacement_is_ignored("commit")

    def test_replacement_tree_cannot_redirect_pinned_source(self):
        self.check_replacement_is_ignored("tree")

    def test_replacement_blob_cannot_redirect_pinned_source(self):
        self.check_replacement_is_ignored("blob")

    def patch_text(self, relative, before, after):
        return "".join(difflib.unified_diff(before.splitlines(keepends=True), after.splitlines(keepends=True),
                                            fromfile="a/" + relative, tofile="b/" + relative))

    def test_allowed_popup_modifications_are_packaged(self):
        patch = self.integration / "background.patch"
        patch.write_text(patch.read_text() + self.patch_text("popup.js", "const fixture = true;\n", "const popup = 'Godspeed';\n"))
        with zipfile.ZipFile(self.build()) as archive:
            self.assertEqual(archive.read("popup.js"), b"const popup = 'Godspeed';\n")

    def test_patch_validation_application_and_provenance_use_one_frozen_copy(self):
        path = self.integration / "background.patch"
        original = path.read_bytes()
        execute = PACKAGE.run

        def changing_editor(command, **kwargs):
            if "apply" in command and "--check" in command:
                path.write_text("unrelated edit made while packaging\n")
            return execute(command, **kwargs)

        with mock_patch.object(PACKAGE, "run", side_effect=changing_editor):
            artifact = self.build()
        with zipfile.ZipFile(artifact) as archive:
            self.assertIn(b'import "./godspeed-workspace.mjs";', archive.read("background.js"))
            self.assertEqual(json.loads(archive.read("PROVENANCE.json"))["patch_sha256"], hashlib.sha256(original).hexdigest())

    def test_patch_cannot_change_manifest_permissions_license_or_other_files(self):
        artifact = self.build()
        prior = artifact.read_bytes()
        patch = self.integration / "background.patch"
        original = patch.read_text()
        manifest = (self.source / "apps/chrome-extension/manifest.json").read_text()
        changed = json.loads(manifest); changed["permissions"].append("debugger")
        cases = [self.patch_text("manifest.json", manifest, json.dumps(changed) + "\n"),
                 self.patch_text("UPSTREAM-LICENSE.txt", "Fixture license\n", "License removed\n"),
                 self.patch_text("content-cursor.js", "const fixture = true;\n", "const cursor = false;\n")]
        for forbidden in cases:
            with self.subTest(patch=forbidden):
                patch.write_text(original + forbidden)
                with self.assertRaises(ValueError):
                    self.build()
                self.assertEqual(artifact.read_bytes(), prior)

    def test_patch_rejects_add_delete_rename_mode_and_traversal(self):
        forbidden = [
            "diff --git a/extra.js b/extra.js\nnew file mode 100644\n--- /dev/null\n+++ b/extra.js\n@@ -0,0 +1 @@\n+const extra = true;\n",
            "diff --git a/background.js b/background.js\ndeleted file mode 100644\n--- a/background.js\n+++ /dev/null\n@@ -1 +0,0 @@\n-const original = \"before\";\n",
            "diff --git a/background.js b/popup.js\nsimilarity index 100%\nrename from background.js\nrename to popup.js\n",
            "diff --git a/background.js b/background.js\nold mode 100644\nnew mode 100755\n",
            "diff --git a/background.js b/background.js\nold mode 100644\nnew mode 120000\n",
            self.patch_text("../outside.js", "const original = true;\n", "const replacement = true;\n"),
        ]
        for contents in forbidden:
            with self.subTest(patch=contents):
                (self.integration / "background.patch").write_text(contents)
                with self.assertRaises(ValueError):
                    self.build()
                self.assertFalse(list(self.output.glob("*.zip")))

    def test_final_allowlist_rejects_extra_files_and_symlinks(self):
        stage = self.root / "stage"
        stage.mkdir()
        for relative in PACKAGE.STAGED_FILES:
            path = stage / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b"fixture")
        self.assertEqual(len(PACKAGE.staged_files(stage)), len(PACKAGE.STAGED_FILES))
        extra = stage / "extra.txt"; extra.write_text("extra")
        with self.assertRaisesRegex(ValueError, "exact allowlist"):
            PACKAGE.staged_files(stage)
        extra.unlink()
        target = stage / "background.js"; target.unlink(); target.symlink_to(self.source / "LICENSE")
        with self.assertRaisesRegex(ValueError, "ordinary files"):
            PACKAGE.staged_files(stage)

    def test_invalid_public_identity_does_not_promote(self):
        artifact = self.build()
        prior = artifact.read_bytes()
        for key in ("fixture-public-identity", "YWJj", ""):
            with self.subTest(key=key):
                self.pin["extension_public_key"] = key; self.save_pin()
                with self.assertRaises(ValueError):
                    self.build()
                self.assertEqual(artifact.read_bytes(), prior)

    def test_output_is_reproducible_without_clock_or_checkout_path(self):
        first = self.build().read_bytes()
        second = self.build().read_bytes()
        self.assertEqual(first, second)

    def test_failed_patch_does_not_replace_previous_artifact(self):
        artifact = self.build()
        prior = artifact.read_bytes()
        (self.integration / "background.patch").write_text("not a patch\n")
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual(artifact.read_bytes(), prior)

    def test_invalid_script_or_source_digest_never_promotes_a_package(self):
        (self.integration / "godspeed-workspace.mjs").write_text("export invalid !!!\n")
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(list(self.output.glob("*.zip")))
        self.pin["background_sha256"] = "0" * 64
        self.save_pin()
        with self.assertRaisesRegex(ValueError, "reviewed digest"):
            self.build()
        self.assertFalse(list(self.output.glob("*.zip")))

    def test_source_reader_rejects_traversal_and_symlinks(self):
        with self.assertRaises(ValueError):
            PACKAGE.pinned_file(self.source, self.pin["commit"], "../LICENSE")
        link = self.source / "linked"
        link.symlink_to("LICENSE")
        self.git("add", "linked")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--quiet", "-m", "Symlink fixture")
        with self.assertRaisesRegex(ValueError, "ordinary file"):
            PACKAGE.pinned_file(self.source, self.git("rev-parse", "HEAD").strip(), "linked")


if __name__ == "__main__":
    unittest.main()
