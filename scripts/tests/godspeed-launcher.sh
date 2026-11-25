#!/usr/bin/env bash
# Portable contract checks: the launcher must keep every argument intact, return the app's
# status, and pin MCP delivery to background operation. No installed app is required.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/godspeed-launcher.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
app="$fixture/Applications with spaces/GODSPEED.app"
mkdir -p "$app/Contents/MacOS"

cat > "$app/Contents/MacOS/OpenComputerUse" <<'APP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "$GODSPEED_TEST_ARGUMENTS"
printf '%s\n' "${OPEN_COMPUTER_USE_BACKGROUND_ONLY-unset}" \
  "${OPEN_COMPUTER_USE_FOCUS_BORROW-unset}" \
  "${OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS-unset}" > "$GODSPEED_TEST_ENVIRONMENT"
exit "${GODSPEED_TEST_EXIT_STATUS:-0}"
APP
chmod +x "$app/Contents/MacOS/OpenComputerUse"
export GODSPEED_APP="$app"
export GODSPEED_TEST_ARGUMENTS="$fixture/arguments"
export GODSPEED_TEST_ENVIRONMENT="$fixture/environment"
launcher="$root/scripts/godspeed"

test -x "$launcher"
"$launcher"
printf '%s\0' settings > "$fixture/expected"
cmp "$fixture/expected" "$GODSPEED_TEST_ARGUMENTS"

"$launcher" settings --show
printf '%s\0' settings --show > "$fixture/expected"
cmp "$fixture/expected" "$GODSPEED_TEST_ARGUMENTS"

# Quoted payloads, whitespace, empty arguments, and literal shell syntax are opaque to the wrapper.
"$launcher" call example 'value with spaces' '' '$literal `unchanged`' $'two\nlines'
printf '%s\0' call example 'value with spaces' '' '$literal `unchanged`' $'two\nlines' > "$fixture/expected"
cmp "$fixture/expected" "$GODSPEED_TEST_ARGUMENTS"

OPEN_COMPUTER_USE_BACKGROUND_ONLY=0 OPEN_COMPUTER_USE_FOCUS_BORROW=1 \
  OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 "$launcher" mcp
printf '%s\0' mcp > "$fixture/expected"
cmp "$fixture/expected" "$GODSPEED_TEST_ARGUMENTS"
printf '1\n0\n0\n' > "$fixture/expected"
cmp "$fixture/expected" "$GODSPEED_TEST_ENVIRONMENT"

# Editing preferences must not install the MCP launcher's overrides in the settings process.
OPEN_COMPUTER_USE_BACKGROUND_ONLY=0 OPEN_COMPUTER_USE_FOCUS_BORROW=1 \
  OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 "$launcher" settings --show
printf '0\n1\n1\n' > "$fixture/expected"
cmp "$fixture/expected" "$GODSPEED_TEST_ENVIRONMENT"

status=0
GODSPEED_TEST_EXIT_STATUS=42 "$launcher" settings --help || status=$?
test "$status" -eq 42

rm "$GODSPEED_TEST_ARGUMENTS"
status=0
GODSPEED_APP="$fixture/missing app" "$launcher" settings --show > "$fixture/missing.log" 2>&1 || status=$?
test "$status" -eq 1
test ! -e "$GODSPEED_TEST_ARGUMENTS"
grep -F 'Install GODSPEED.app or set GODSPEED_APP.' "$fixture/missing.log" > /dev/null

printf 'Godspeed launcher checks passed.\n'
