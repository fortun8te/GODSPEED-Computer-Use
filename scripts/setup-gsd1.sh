#!/bin/bash
# Optional Apple Silicon model setup. Run from a Godspeed release checkout.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
home="$HOME/.ocu-referee"
data="${XDG_DATA_HOME:-$HOME/.local/share}/godspeed/gsd1-v0.1.0"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/godspeed"
launcher="$home/run_gsd1.sh"
version=gsd1-v0.1.0
archive=gsd1-adapters-v0.1.0.zip
expected=ac05a1a794bf5077ceafef1521297435d3ff01388c4a1a5eaed40924e8d71077
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo "GSD1 needs native Apple Silicon Python on macOS."; exit 1;
}
python3 -c 'import platform,sys; sys.exit(sys.version_info < (3,10) or platform.machine()!="arm64")' || {
  echo "Install Python 3.10 or newer for arm64."; exit 1;
}
if [[ -e "$launcher" ]] && ! grep -Fx '# Godspeed public GSD1 setup' "$launcher" >/dev/null; then
  echo "Your existing GSD1 launcher was left in place at $launcher."; exit 1
fi
mkdir -p "$home" "$data" "$cache"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/godspeed-models.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
printf 'Downloading and verifying GSD1 adapters…\n'
if [[ ! -f "$cache/$archive" ]] || [[ "$(shasum -a 256 "$cache/$archive" | awk '{print $1}')" != "$expected" ]]; then
  curl -fL --progress-bar --retry 2     "https://github.com/fortun8te/godspeed/releases/download/$version/$archive" -o "$scratch/$archive"
  [[ "$(shasum -a 256 "$scratch/$archive" | awk '{print $1}')" == "$expected" ]] || {
    echo "Adapter archive checksum mismatch."; exit 1;
  }
  mv "$scratch/$archive" "$cache/$archive"
fi
ditto -x -k "$cache/$archive" "$scratch"
bundle="$scratch/$version"
printf 'Preparing the pinned Apple Silicon runtime…\n'
[[ -x "$data/venv/bin/python" ]] || python3 -m venv "$data/venv"
python="$data/venv/bin/python"
"$python" -m pip install --disable-pip-version-check 'mlx==0.32.4' 'mlx-vlm==0.7.12' 'huggingface-hub==2.4.0'
printf 'Downloading the two base checkpoints from Liquid AI. Allow about 14 GB of free disk space.\n'
"$python" - "$cache" <<'PY'
from huggingface_hub import snapshot_download
from pathlib import Path
import sys
root = Path(sys.argv[1])
for repository, name, revision in (
    ("LiquidAI/d1-2B-MLX-fp16", "d1-2B-mlxfp16", "f4e6e118bf850880e6f45a5b22085057778ac243"),
    ("LiquidAI/d1-2B-MLX-8bit", "d1-2B-mlx8bit", "3247d0483b11e5da31fa10e7979c23252fbe3580"),
):
    snapshot_download(repository, revision=revision, local_dir=root / name,
                      allow_patterns=["*.safetensors", "*.json", "*.jinja", "*LICENSE*", "NOTICE", "*.model"])
PY
printf 'Converting the saved adapters. No training is required.\n'
for role in action read recover; do
  if [[ ! -f "$data/models/$role/gsd1-export.json" ]]; then
    "$python" "$bundle/export_mlx.py" "$data/models" --candidates "$cache" --role "$role"
  fi
done
install -m 600 "$bundle/LICENSE" "$data/LICENSE"
install -m 600 "$bundle/NOTICE" "$data/NOTICE"
install -m 600 "$root/experiments/LocalHelper/gsd1_server.py" "$data/gsd1_server.py"
"$python" - "$data" "$launcher" <<'PY'
import json, os, shlex, sys, tempfile
from pathlib import Path
data, launcher = map(Path, sys.argv[1:])
settings = Path.home() / ".godspeed/settings.json"
current = json.loads(settings.read_text()) if settings.exists() else {}
if not isinstance(current, dict):
    raise ValueError("Godspeed settings must be a JSON object")
current["gsd1_url"] = "http://127.0.0.1:18765"
command = shlex.join([str(data / "venv/bin/python"), "-I", str(data / "gsd1_server.py"), str(data / "models")])
for path, text, mode in (
    (launcher, "#!/bin/sh\n# Godspeed public GSD1 setup\nexec /usr/bin/nice -n 10 " + command + "\n", 0o700),
    (settings, json.dumps(current, indent=2) + "\n", 0o600),
):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False, encoding="utf-8") as f:
        f.write(text)
    os.chmod(f.name, mode)
    os.replace(f.name, path)
PY
printf 'GSD1 installed. Open a fresh MCP session to see local_decision.\n'
