#!/bin/bash
# Check an installed Godspeed and its MCP connection without sending UI actions.
set -euo pipefail

app="${GODSPEED_APP:-$HOME/Applications/GODSPEED.app}"
launcher="$HOME/.local/bin/godspeed-mcp"
if [[ -z "${GODSPEED_APP:-}" && ! -d "$app" ]]; then
  app="/Applications/GODSPEED.app"
fi

fail() { printf 'Godspeed check: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) [[ $# -ge 2 ]] || fail "--app needs a bundle path."; app="$2"; shift 2 ;;
    --launcher) [[ $# -ge 2 ]] || fail "--launcher needs a file path."; launcher="$2"; shift 2 ;;
    --help|-h)
      printf 'Usage: %s [--app PATH] [--launcher PATH]\n' "$0"
      exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || fail "Godspeed requires macOS."

binary="$app/Contents/MacOS/OpenComputerUse"
[[ -x "$binary" ]] || fail "App missing at $app. Run the release installer first."
[[ -x "$launcher" ]] || fail "MCP launcher missing at $launcher. Run the release installer first."
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
arch="$(lipo -archs "$binary")"
codesign --verify --strict --deep "$app" || fail "The app signature could not be verified."
printf 'App OK: Godspeed %s (%s)\n' "$version" "$arch"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/godspeed-doctor.XXXXXX")"
pid=""
cleanup() {
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
mkfifo "$scratch/request" "$scratch/reply"

GODSPEED_APP="$app" OPEN_COMPUTER_USE_TRAJECTORY_LOG=0 "$launcher" \
  < "$scratch/request" > "$scratch/reply" 2>"$scratch/launcher.log" &
pid=$!
exec 3>"$scratch/request"
exec 4<"$scratch/reply"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"Godspeed Doctor","version":"1"}}}' >&3
IFS= read -r -t 15 line <&4 || fail "The launcher did not initialize MCP. Open Godspeed, then reconnect."
printf '%s\n' "$line" > "$scratch/initialize.json"
name="$(plutil -extract result.serverInfo.name raw -o - "$scratch/initialize.json")" || fail "Invalid MCP initialization response."
server_version="$(plutil -extract result.serverInfo.version raw -o - "$scratch/initialize.json")" || fail "MCP server version missing."
[[ "$name" == godspeed && "$server_version" == "$version" ]] \
  || fail "The launcher connected to $name $server_version. Close old Godspeed sessions and reconnect."
printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' >&3
IFS= read -r -t 15 line <&4 || fail "MCP initialized but did not list its tools."
printf '%s\n' "$line" > "$scratch/tools.json"
plutil -extract result.tools json -o /dev/null "$scratch/tools.json" || fail "Invalid MCP tool list."
: > "$scratch/tool-names"
i=0
while tool="$(plutil -extract "result.tools.$i.name" raw -o - "$scratch/tools.json" 2>/dev/null)"; do
  printf '%s\n' "$tool" >> "$scratch/tool-names"
  i=$((i + 1))
done
for tool in get_app_state query batch; do
  grep -Fx "$tool" "$scratch/tool-names" >/dev/null || fail "The tool list is missing $tool."
done
printf 'MCP OK: initialized and listed tools with %s.\n' "$launcher"
if grep -Fx browser "$scratch/tool-names" >/dev/null; then
  printf 'Chrome tool listed. Run obu ping in the Chrome profile you want to use.\n'
else
  printf 'Chrome is optional. Follow Chrome setup to add its helper and extension.\n'
fi
if grep -Fx local_decision "$scratch/tool-names" >/dev/null; then
  printf 'GSD1 tool listed. Models load when requested.\n'
fi
exec 3>&- 4<&-
