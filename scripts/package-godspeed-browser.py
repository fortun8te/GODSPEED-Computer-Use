#!/usr/bin/env python3
"""Build the Godspeed workspace extension from pinned OBU Git objects.

No source-checkout scripts are executed and no browser/helper is installed.
The output contains the upstream license and a digest of every packaged file.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = ROOT / "integrations" / "chrome-workspace"
FILES = (
    "manifest.json", "background.js", "content-cursor.js", "content-webmcp-main.js",
    "content-webmcp-bridge.js", "icons/icon-16.png", "icons/icon-32.png", "icons/icon-48.png",
    "icons/icon-128.png", "images/cursor-chat.png", "popup.css", "popup.html", "popup.js",
)
MAX_SOURCE_BYTES = 2 * 1024 * 1024
PATCH_FILES = frozenset(("background.js", "popup.css", "popup.html", "popup.js"))
STAGED_FILES = frozenset(FILES) | {"UPSTREAM-LICENSE.txt", "godspeed-workspace.mjs"}
GIT = ("git", "--no-replace-objects", "--no-pager")


def run(command: list[str], *, cwd: Path | None = None, timeout: float = 45) -> bytes:
    result = subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
    if result.returncode:
        error = result.stderr.decode("utf-8", errors="replace")[-2000:].strip()
        raise ValueError(f"{command[0]} failed: {error}")
    return result.stdout


def pinned_file(source: Path, commit: str, path: str) -> bytes:
    relative = PurePosixPath(path)
    if relative.is_absolute() or ".." in relative.parts or str(relative) != path:
        raise ValueError("Invalid pinned source path")
    # Replacement refs can redirect a commit, a tree or an individual blob while
    # rev-parse still reports the original commit name. All Git reads must disable them.
    listing = run([*GIT, "-C", str(source), "ls-tree", commit, "--", path]).decode("utf-8")
    fields = listing.rstrip("\n").split("\t")
    if len(fields) != 2 or fields[1] != path or not fields[0].startswith("100644 blob "):
        raise ValueError(f"Pinned source must be an ordinary file: {path}")
    object_id = fields[0].split()[-1]
    size = int(run([*GIT, "-C", str(source), "cat-file", "-s", object_id]).decode("ascii"))
    if size > MAX_SOURCE_BYTES:
        raise ValueError(f"Pinned source is too large: {path}")
    data = run([*GIT, "-C", str(source), "cat-file", "blob", object_id])
    if len(data) > MAX_SOURCE_BYTES:
        raise ValueError(f"Pinned source is too large: {path}")
    return data


def validate_patch(patch: Path, stage: Path) -> None:
    """Only ordinary text modifications of the four reviewed integration surfaces."""
    summary = run([*GIT, "apply", "--summary", str(patch)], cwd=stage)
    if summary.strip():
        raise ValueError("Workspace patch cannot add, delete, rename, copy or change file modes")
    entries = run([*GIT, "apply", "--numstat", "-z", str(patch)], cwd=stage).split(b"\0")
    if not entries[-1] == b"" or not entries[:-1]:
        raise ValueError("Workspace patch must modify an allowed existing file")
    for entry in entries[:-1]:
        fields = entry.split(b"\t")
        if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
            raise ValueError("Workspace patch must contain ordinary text modifications")
        if fields[2].decode("utf-8") not in PATCH_FILES:
            raise ValueError("Workspace patch changes a path outside the approved integration files")


def staged_files(stage: Path) -> list[Path]:
    files = []
    for path in stage.rglob("*"):
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise ValueError("Packaged workspace entries must be ordinary files")
        files.append(path)
    if {path.relative_to(stage).as_posix() for path in files} != STAGED_FILES:
        raise ValueError("Packaged workspace files do not match the exact allowlist")
    return sorted(files)


def extension_identity(public_key: str) -> tuple[str, str]:
    try:
        raw = base64.b64decode(public_key, validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("Extension identity must be a valid base64 public key") from error
    if not raw or len(raw) > 8192 or base64.b64encode(raw).decode("ascii") != public_key:
        raise ValueError("Extension identity must be a canonical public key")
    # Parse as a public key, never execute extension code. A copied placeholder or
    # malformed DER must not produce a ZIP which Chrome cannot load with its stable ID.
    run(["node", "-e", "const {createPublicKey}=require('node:crypto');"
         "const raw=Buffer.from(process.argv[1],'base64');"
         "const key=createPublicKey({key:raw,format:'der',type:'spki'});"
         "if(!key.export({format:'der',type:'spki'}).equals(raw)) process.exit(2);", public_key])
    digest = hashlib.sha256(raw).hexdigest()
    identity = "".join(chr(ord("a") + int(nibble, 16)) for nibble in digest[:32])
    return identity, digest


def load_pin(integration: Path = INTEGRATION) -> dict:
    pin = json.loads((integration / "upstream.json").read_text(encoding="utf-8"))
    if not re.fullmatch(r"[0-9a-f]{40}", pin.get("commit", "")):
        raise ValueError("Upstream commit must be an exact Git SHA")
    if pin.get("repository") != "https://github.com/iFurySt/open-browser-use.git":
        raise ValueError("Unexpected upstream repository")
    if not re.fullmatch(r"[0-9a-f]{64}", pin.get("background_sha256", "")):
        raise ValueError("Missing pinned background digest")
    for key in ("version", "workspace_version"):
        if not re.fullmatch(r"\d+\.\d+\.\d+(?:\.\d+)?", pin.get(key, "")):
            raise ValueError("Invalid pinned extension version")
    return pin


def build(source: Path, output: Path, *, integration: Path = INTEGRATION) -> Path:
    integration = integration.resolve()
    pin = load_pin(integration)
    commit = pin["commit"]
    verified = run([*GIT, "-C", str(source), "rev-parse", "--verify", commit + "^{commit}"]).decode().strip()
    if verified != commit:
        raise ValueError("Source checkout does not contain the pinned commit")
    if not shutil.which("node"):
        raise ValueError("Node.js is required to validate the extension before packaging")
    extension_id, key_digest = extension_identity(pin["extension_public_key"])
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="godspeed-browser-build-") as temporary:
        build_root = Path(temporary)
        stage = build_root / "extension"
        stage.mkdir()
        # Scope checking, application and provenance must refer to the same bytes,
        # even while another checkout/editor updates the integration source files.
        patch_bytes = (integration / "background.patch").read_bytes()
        patch = build_root / "reviewed-background.patch"
        patch.write_bytes(patch_bytes)
        source_digests: dict[str, str] = {}
        for path in FILES:
            data = pinned_file(source, commit, "apps/chrome-extension/" + path)
            source_digests[path] = hashlib.sha256(data).hexdigest()
            target = stage / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        if source_digests["background.js"] != pin["background_sha256"]:
            raise ValueError("The pinned background source does not match its reviewed digest")
        license_data = pinned_file(source, commit, "LICENSE")
        (stage / "UPSTREAM-LICENSE.txt").write_bytes(license_data)
        source_digests["LICENSE"] = hashlib.sha256(license_data).hexdigest()
        validate_patch(patch, stage)
        run([*GIT, "apply", "--check", "--whitespace=error-all", str(patch)], cwd=stage)
        run([*GIT, "apply", "--whitespace=error-all", str(patch)], cwd=stage)
        (stage / "godspeed-workspace.mjs").write_bytes((integration / "godspeed-workspace.mjs").read_bytes())
        manifest_path = stage / "manifest.json"
        if hashlib.sha256(manifest_path.read_bytes()).hexdigest() != source_digests["manifest.json"]:
            raise ValueError("Workspace patch changed the pinned manifest")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("version") != pin["version"] or manifest.get("manifest_version") != 3:
            raise ValueError("Unexpected upstream extension version or manifest")
        # A separate stable identity prevents an unpacked workspace build from
        # silently replacing the user's Web Store or upstream beta extension.
        manifest.update(name="Godspeed Browser Workspace", version=pin["workspace_version"],
                        version_name="Godspeed workspace · OBU " + pin["version"],
                        description="A quiet, organized Chrome workspace for Godspeed.", key=pin["extension_public_key"])
        manifest["action"]["default_title"] = "Godspeed Browser Workspace"
        manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        packaged = staged_files(stage)
        # Parse all shipped scripts, including the patch and the new module.
        for script in packaged:
            if script.suffix in {".js", ".mjs"}:
                run(["node", "--check", str(script)], cwd=stage)
        provenance = {
            "repository": pin["repository"], "commit": commit,
            "upstream_version": pin["version"], "workspace_version": pin["workspace_version"],
            "extension_id": extension_id, "extension_public_key_sha256": key_digest,
            "source_sha256": source_digests,
            "files_sha256": {path.relative_to(stage).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in packaged},
            "patch_sha256": hashlib.sha256(patch_bytes).hexdigest(),
        }
        metadata = stage / "PROVENANCE.json"
        metadata.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        packaged.append(metadata)
        destination = output / ("Godspeed-Chrome-Workspace-" + pin["workspace_version"] + ".zip")
        fd, temporary_zip = tempfile.mkstemp(prefix=".godspeed-browser-", suffix=".zip", dir=output)
        try:
            os.close(fd)
            with zipfile.ZipFile(temporary_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
                for path in sorted(packaged):
                    info = zipfile.ZipInfo(path.relative_to(stage).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
                    info.create_system = 3
                    info.external_attr = 0o100644 << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, path.read_bytes(), compresslevel=9)
            os.replace(temporary_zip, destination)
        finally:
            Path(temporary_zip).unlink(missing_ok=True)
    return destination


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--source", type=Path, help="Existing OBU checkout containing the pinned commit; working files are not used")
    source.add_argument("--fetch", action="store_true", help="Fetch the pinned source into a temporary checkout")
    parser.add_argument("--output", type=Path, default=ROOT / "dist" / "chrome-workspace")
    args = parser.parse_args(argv)
    try:
        if args.fetch:
            pin = load_pin()
            with tempfile.TemporaryDirectory(prefix="godspeed-browser-source-") as temporary:
                checkout = Path(temporary)
                run([*GIT, "init", "--quiet", str(checkout)])
                run([*GIT, "-C", str(checkout), "fetch", "--quiet", "--depth=1", pin["repository"], pin["commit"]])
                artifact = build(checkout, args.output.resolve())
        else:
            artifact = build(args.source.resolve(), args.output.resolve())
        print(json.dumps({"artifact": str(artifact), "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
                          "installed": False}, sort_keys=True))
        return 0
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"Browser workspace package was not produced: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
