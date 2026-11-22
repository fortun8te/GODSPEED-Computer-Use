#!/bin/bash
# Download, verify, and install a GitHub Godspeed Apple Silicon development build.
set -euo pipefail

version=v1.1.12
archive=Godspeed-macOS-arm64.zip
app_dir="$HOME/Applications"
launcher_dir="$HOME/.local/bin"
release_url="https://github.com/fortun8te/godspeed/releases/download/$version"
verify_only=false
local_archive=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only) verify_only=true; shift ;;
    --archive) [[ $# -ge 2 ]] || exit 2; local_archive="$2"; shift 2 ;;
    --app-dir) [[ $# -ge 2 ]] || exit 2; app_dir="$2"; shift 2 ;;
    --launcher-dir) [[ $# -ge 2 ]] || exit 2; launcher_dir="$2"; shift 2 ;;
    *) printf 'Usage: %s [--archive ZIP] [--verify-only] [--app-dir DIR] [--launcher-dir DIR]\n' "$0" >&2; exit 2 ;;
  esac
done

fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]   || fail "This download requires an Apple Silicon Mac."
os_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$os_major" -ge 14 ]] || fail "Godspeed requires macOS 14 or later."
if ! $verify_only && ps -ax -o comm= | grep -F "$app_dir/GODSPEED.app/Contents/MacOS/OpenComputerUse" >/dev/null; then
  fail "Close active Godspeed sessions before installing. This keeps any in-flight actions safe."
fi

download_dir="$(mktemp -d "${TMPDIR:-/tmp}/godspeed-download.XXXXXX")"
staging=""
trap 'rm -rf "$download_dir"; if [[ -n "$staging" ]]; then rm -rf "$staging"; fi' EXIT
if [[ -n "$local_archive" ]]; then
  cp "$local_archive" "$download_dir/$archive"
  cp "$local_archive.sha256" "$download_dir/$archive.sha256"
else
  printf 'Downloading Godspeed %s for Apple Silicon…\n' "$version"
  curl -fL --retry 2 --progress-bar "$release_url/$archive" -o "$download_dir/$archive"
  curl -fsSL --retry 2 "$release_url/$archive.sha256" -o "$download_dir/$archive.sha256"
fi
read -r expected filename extra < "$download_dir/$archive.sha256"
[[ "$expected" =~ ^[[:xdigit:]]{64}$ && "$filename" == "$archive" && -z "$extra" ]]   || fail "The download checksum file is invalid."
actual="$(shasum -a 256 "$download_dir/$archive" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || fail "Godspeed download checksum mismatch."

if $verify_only; then
  staging="$(mktemp -d "$download_dir/verify.XXXXXX")"
else
  mkdir -p "$app_dir" "$launcher_dir"
  staging="$(mktemp -d "$app_dir/.godspeed-install.XXXXXX")"
fi
printf 'Verifying the application signature and architecture…\n'
ditto -x -k "$download_dir/$archive" "$staging"
app="$staging/GODSPEED.app"
binary="$app/Contents/MacOS/OpenComputerUse"
[[ -x "$binary" && -x "$staging/godspeed-mcp" ]] || fail "The package is missing the app or MCP launcher."
[[ "$(lipo -archs "$binary")" == arm64 ]] || fail "The package is not an arm64 build."
codesign --verify --strict --deep "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "${version#v}" ]]   || fail "The package version does not match the release."

if $verify_only; then
  printf 'Verified Godspeed %s, arm64, and MCP launcher.\n' "$version"
  exit 0
fi

target="$app_dir/GODSPEED.app"
backup=""
if [[ -e "$target" ]]; then
  backup="$(mktemp -d "$app_dir/.godspeed-previous.XXXXXX")"
  mv "$target" "$backup/GODSPEED.app"
fi
if ! mv "$app" "$target"; then
  if [[ -n "$backup" ]]; then mv "$backup/GODSPEED.app" "$target"; fi
  fail "Could not install Godspeed."
fi

launcher="$launcher_dir/godspeed-mcp"
if [[ -e "$launcher" ]] && ! cmp -s "$staging/godspeed-mcp" "$launcher"; then
  previous="$(mktemp "$launcher_dir/godspeed-mcp.previous.XXXXXX")"
  cp -p "$launcher" "$previous"
fi
install -m 755 "$staging/godspeed-mcp" "$launcher"
printf 'Installed %s\nMCP launcher %s\n' "$target" "$launcher"
if [[ -n "$backup" ]]; then printf 'Previous app saved under %s\n' "$backup"; fi
printf 'Open Godspeed and follow the macOS permissions prompts.\n'
