#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

cat > "$fixture/swift" <<'SWIFT'
#!/usr/bin/env bash
if [[ "$*" == *"--show-bin-path"* ]]; then
  printf '%s\n' "$GODSPEED_TEST_BIN_DIR"
  exit 0
fi
exit 42
SWIFT
touch "$fixture/OpenComputerUse"
chmod +x "$fixture/swift" "$fixture/OpenComputerUse"
if env GODSPEED_TEST_BIN_DIR="$fixture" PATH="$fixture:$PATH" \
  "$root/scripts/package-godspeed.sh" "$fixture/output" >"$fixture/build.log" 2>&1; then
  echo "A failed Swift build must not package the stale executable." >&2
  exit 1
fi
test -d "$fixture/output"
test -z "$(find "$fixture/output" -name '*.zip' -print -quit)"
