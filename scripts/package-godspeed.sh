#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Godspeed builds on macOS." >&2
  exit 1
fi
out="${1:-$repo_root/dist/godspeed}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/godspeed-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

OPEN_COMPUTER_USE_APP_VARIANT=dev \
OPEN_COMPUTER_USE_PACKAGE_VERSION="$(cat "$repo_root/VERSION")" \
OPEN_COMPUTER_USE_INCLUDE_LOCKED_USE=0 \
OPEN_COMPUTER_USE_CODESIGN_MODE="${OPEN_COMPUTER_USE_CODESIGN_MODE:-adhoc}" \
OPEN_COMPUTER_USE_APP_OUTPUT_DIR="$stage" \
  "$repo_root/scripts/build-open-computer-use-app.sh" --configuration release --arch "${GODSPEED_ARCH:-native}"

app="$stage/GODSPEED.app"
test -x "$app/Contents/MacOS/OpenComputerUse"
codesign --verify --strict "$app"
name="Godspeed-macOS-$([[ "${GODSPEED_ARCH:-native}" == native ]] && uname -m || printf '%s' "$GODSPEED_ARCH").zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$name"
mv -f "$stage/$name" "$out/$name"
(cd "$out" && shasum -a 256 "$name" > "$name.sha256")
printf '%s\n' "$out/$name"
