#!/bin/bash
# Install the optional Chrome bridge for the current macOS user.
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --check && "$1" != --no-open ) ]]; then
  echo "Usage: $0 [--no-open | --check]" >&2
  exit 2
fi

check_bridge() {
  if [[ ! -x "$bridge" ]]; then
    echo "Chrome helper missing. Run this script without --check to set it up." >&2
    return 1
  fi
  if ! "$bridge" ping; then
    echo "Open Chrome in the intended profile and enable Open Browser Use, then rerun with --check." >&2
    return 1
  fi
  echo "Chrome bridge connected. Reconnect your Godspeed MCP client to pick up the browser tool."
}

bridge="$HOME/.local/bin/obu"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [[ "${1:-}" == --check ]]; then
  check_bridge
  exit
fi

if ! command -v npm >/dev/null || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) < 18 ? 1 : 0)' 2>/dev/null; then
  echo "Install Node.js 18 or newer with npm from https://nodejs.org/, then rerun this script." >&2
  exit 1
fi
npm install --global --prefix "$HOME/.local" open-browser-use@1.1.0
if [[ "${1:-}" == --no-open ]]; then
  "$bridge" setup --no-open
else
  "$bridge" setup
fi
echo "Open Browser Use: https://chromewebstore.google.com/detail/bgjoihaepiejlfjinojjfgokghnodnhd"
echo "Approve the extension in the Chrome profile you plan to use, then rerun this script with --check."
