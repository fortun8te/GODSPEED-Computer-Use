#!/bin/bash
# Install the optional Chrome bridge for the current macOS user.
set -euo pipefail

usage() {
  echo "Usage: $0 [--no-open] [--workspace-zip PATH] | --check" >&2
  exit 2
}

check_only=false
no_open=false
workspace_zip=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) [[ "$check_only" == false ]] || usage; check_only=true; shift ;;
    --no-open) [[ "$no_open" == false ]] || usage; no_open=true; shift ;;
    --workspace-zip)
      [[ $# -ge 2 && -n "$2" && "$2" != --* && -z "$workspace_zip" ]] || usage
      workspace_zip="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
if [[ "$check_only" == true && ( "$no_open" == true || -n "$workspace_zip" ) ]]; then
  usage
fi

check_bridge() {
  if [[ ! -x "$bridge" ]]; then
    echo "Chrome helper missing. Run this script without --check to set it up." >&2
    return 1
  fi
  if ! "$bridge" ping; then
    echo "Open Chrome in the intended profile and enable your browser extension, then rerun with --check." >&2
    return 1
  fi
  echo "Chrome bridge connected. Reconnect your Godspeed MCP client to pick up the browser tool."
}

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
bridge="${OPEN_COMPUTER_USE_OBU_BIN:-}"
if [[ -z "$bridge" ]]; then
  bridge="$(command -v obu || command -v open-browser-use || true)"
  bridge="${bridge:-$HOME/.local/bin/obu}"
fi
if [[ "$check_only" == true ]]; then
  check_bridge
  exit
fi

if [[ -n "$workspace_zip" ]]; then
  [[ -f "$workspace_zip" ]] || { echo "Workspace ZIP not found: $workspace_zip" >&2; exit 1; }
  [[ -x "$bridge" ]] || {
    echo "A compatible Chrome helper is required. Install it first, or set OPEN_COMPUTER_USE_OBU_BIN to its absolute path." >&2
    exit 1
  }
  # Reuse the selected helper, including an authenticated Godspeed host. This
  # path must never install a different CLI over the existing executable.
  if ! setup_help="$("$bridge" setup beta --help 2>&1)" || [[ "$setup_help" != *--zip* || "$setup_help" != *--no-open* ]]; then
    echo "This helper does not advertise setup beta --zip and --no-open. Use a compatible helper before preparing the workspace." >&2
    exit 1
  fi
  setup_args=(setup beta --zip "$workspace_zip")
  [[ "$no_open" == false ]] || setup_args+=(--no-open)
  "$bridge" "${setup_args[@]}"
  echo "Godspeed Browser Workspace prepared. Approve this extension in your intended Chrome profile, then rerun with --check."
  exit
fi

if [[ ! -x "$bridge" ]]; then
  if [[ -n "${OPEN_COMPUTER_USE_OBU_BIN:-}" ]]; then
    echo "The selected Chrome helper is not executable: $bridge" >&2
    exit 1
  fi
  if ! command -v npm >/dev/null || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) < 18 ? 1 : 0)' 2>/dev/null; then
    echo "Install Node.js 18 or newer with npm from https://nodejs.org/, then rerun this script." >&2
    exit 1
  fi
  npm install --global --prefix "$HOME/.local" open-browser-use@1.1.0
fi
if [[ "$no_open" == true ]]; then
  "$bridge" setup --no-open
else
  "$bridge" setup
fi
echo "Open Browser Use: https://chromewebstore.google.com/detail/bgjoihaepiejlfjinojjfgokghnodnhd"
echo "Approve the extension in the Chrome profile you plan to use, then rerun this script with --check."
