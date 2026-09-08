#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

require_command jq

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$TEST_ROOT/config"
export XDG_STATE_HOME="$TEST_ROOT/state"
export OMARCHY_PATH="$TEST_ROOT/stock omarchy"
PLUGIN_BIN="$TEST_ROOT/plugin with spaces/bin"
usage_dir="$XDG_STATE_HOME/omarchy/agents/usage"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/omarchy" "$OMARCHY_PATH/bin" "$PLUGIN_BIN"
cp "$ROOT/bin/omarchy-agent-usage-update" "$PLUGIN_BIN/"

# Each mock records invocation and flags independently, including concurrent runs.
mock_collector() {
  local path="$1" name="$2" origin="$3"
  printf '%s\n' '#!/bin/bash' \
    "printf '%s\\n' \"\$*\" >>\"\$HOME/$origin.calls\"" \
    "printf '%s\\n' '{\"id\":\"$name\",\"name\":\"$origin\"}'" >"$path"
  chmod +x "$path"
}

run_update() {
  bash "$PLUGIN_BIN/omarchy-agent-usage-update" "$@"
}

assert_name() {
  local agent="$1" expected="$2"
  [[ -f $usage_dir/$agent.json ]] || fail "$agent record exists"
  [[ $(jq -r '.name' "$usage_dir/$agent.json") == "$expected" ]] ||
    fail "$agent uses $expected"
}

mock_collector "$PLUGIN_BIN/omarchy-agent-usage-hermes" hermes bundled-hermes
mock_collector "$OMARCHY_PATH/bin/omarchy-agent-usage-claude" claude stock-claude
mock_collector "$OMARCHY_PATH/bin/omarchy-agent-usage-codex" codex stock-codex
# A core updater has the collector prefix but must never be executed.
mock_collector "$OMARCHY_PATH/bin/omarchy-agent-usage-update" update core-updater

run_update || fail "standalone update succeeds against upstream without Hermes"
assert_name hermes bundled-hermes
assert_name claude stock-claude
assert_name codex stock-codex
[[ ! -e $HOME/core-updater.calls && ! -e $usage_dir/update.json ]] ||
  fail "core updater is never invoked as a collector"
[[ ! -e $HOME/.local/state/omarchy/agents/usage ]] ||
  fail "records use the existing XDG state directory"
pass "bundled Hermes and stock collectors work without upstream Hermes or recursion"

mock_collector "$OMARCHY_PATH/bin/omarchy-agent-usage-hermes" hermes stock-hermes
run_update hermes || fail "bundled Hermes works alongside upstream Hermes"
[[ ! -e $HOME/stock-hermes.calls ]] || fail "stock Hermes never competes with bundled Hermes"
assert_name hermes bundled-hermes
pass "bundled Hermes takes precedence over stock Hermes"

meter_config="$XDG_CONFIG_HOME/omarchy/agent-meter.json"
printf '%s\n' '{"sources":{"hermes":{"type":"test"},"claude":{"type":"test"}}}' >"$meter_config"
printf '%s\n' '#!/bin/bash' '
[[ $1 == "--config" && $2 == "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/agent-meter.json" && $3 == "collect" && $# == 4 ]] || exit 2
printf "%s\n" "$4" >>"$HOME/meter.calls"
[[ ! -f $HOME/meter-fail ]] || exit 1
usage_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage"
mkdir -p "$usage_dir"
jq -n --arg id "$4" "{id: \$id, name: (\"remote-\" + \$id)}" >"$usage_dir/$4.json"
' >"$PLUGIN_BIN/omarchy-agent-meter"
chmod +x "$PLUGIN_BIN/omarchy-agent-meter"
# A stock meter must not be used, even when it is present.
mock_collector "$OMARCHY_PATH/bin/omarchy-agent-meter" meter stock-meter
rm -f "$HOME/bundled-hermes.calls" "$HOME/stock-claude.calls"
run_update hermes claude || fail "bundled meter collects configured remote sources"
assert_name hermes remote-hermes
assert_name claude remote-claude
[[ ! -e $HOME/bundled-hermes.calls && ! -e $HOME/stock-claude.calls && ! -e $HOME/stock-meter.calls ]] ||
  fail "remote records are not overwritten by local collectors or a stock meter"
pass "bundled meter remote collection takes precedence over local collectors"

touch "$HOME/meter-fail"
run_update --force --limits-only hermes claude || fail "meter failure falls back to local collectors"
assert_name hermes bundled-hermes
assert_name claude stock-claude
for origin in bundled-hermes stock-claude; do
  [[ $(<"$HOME/$origin.calls") == "--force --limits-only" ]] ||
    fail "fallback forwards both flags unchanged to $origin"
done
[[ ! -e $HOME/stock-hermes.calls ]] || fail "fallback must use bundled Hermes"
pass "meter failure falls back to bundled Hermes and stock collectors with flags"
rm -f "$HOME/meter-fail" "$HOME/meter.calls"

printf '%s\n' '{"sources":{"hermes":{"type":"test","enabled":false},"claude":{"type":"test","enabled":false}}}' >"$meter_config"
run_update hermes claude || fail "disabled remote sources select local collectors"
assert_name hermes bundled-hermes
assert_name claude stock-claude
[[ ! -e $HOME/meter.calls ]] || fail "local selection must not contact remote sources"
pass "local selection disables remote collection"

rm -f "$HOME/bundled-hermes.calls" "$HOME/stock-claude.calls" "$HOME/stock-codex.calls"
run_update --force --limits-only --except claude hermes claude || fail "local selection accepts flags and exclusions"
[[ $(<"$HOME/bundled-hermes.calls") == "--force --limits-only" ]] || fail "local Hermes receives flags"
[[ ! -e $HOME/stock-claude.calls && ! -e $HOME/stock-codex.calls ]] ||
  fail "only named, nonexcluded local collectors run"
pass "flags, multiple agent arguments and exclusions apply to local collectors"

printf '%s\n' '{"sources":{"hermes":{"type":"test"},"claude":{"type":"test"},"codex":{"type":"test"}}}' >"$meter_config"
rm -f "$HOME/bundled-hermes.calls"
run_update --force --limits-only --except hermes hermes claude || fail "remote selection accepts flags and exclusions"
[[ $(<"$HOME/meter.calls") == "claude" ]] || fail "only named, nonexcluded remote sources run"
[[ ! -e $HOME/bundled-hermes.calls && ! -e $HOME/stock-claude.calls && ! -e $HOME/stock-codex.calls ]] ||
  fail "remote selection does not invoke excluded or managed local collectors"
assert_name claude remote-claude
pass "agent arguments and exclusions apply equally to remote sources"

rm -f "$meter_config" "$HOME/meter.calls"
run_update --except hermes --except codex || fail "repeated exclusions work without an explicit selection"
[[ ! -e $HOME/bundled-hermes.calls && ! -e $HOME/stock-codex.calls && ! -e $HOME/meter.calls ]] ||
  fail "repeated exclusions and absent config avoid unwanted collectors"
assert_name claude stock-claude
pass "repeated exclusions apply to default discovery and absent config stays local"

printf '%s\n' '{"sources":{"hermes":{"type":"test"}}}' >"$meter_config"
chmod -x "$PLUGIN_BIN/omarchy-agent-meter"
run_update hermes || fail "unavailable bundled meter falls back locally"
assert_name hermes bundled-hermes
[[ ! -e $HOME/stock-meter.calls && ! -e $HOME/meter.calls ]] || fail "missing bundled meter never substitutes stock meter"
pass "unavailable bundled meter preserves local fallback"
chmod +x "$PLUGIN_BIN/omarchy-agent-meter"
rm -f "$meter_config"

# A hard link retains the old inode: success must replace, not truncate it.
printf '%s\n' '{"id":"claude","name":"previous"}' >"$usage_dir/claude.json"
ln "$usage_dir/claude.json" "$TEST_ROOT/previous.json"
run_update claude || fail "valid local record replaces existing state"
assert_name claude stock-claude
[[ $(jq -r '.name' "$TEST_ROOT/previous.json") == "previous" ]] || fail "writes must atomically replace the existing inode"
pass "valid records are atomically replaced rather than written in place"

cp "$usage_dir/claude.json" "$TEST_ROOT/valid.json"
for failure in invalid empty nonzero; do
  case "$failure" in
  invalid) body='printf "%s\n" "{broken"' ;;
  empty) body='exit 0' ;;
  nonzero) body='printf "%s\n" "{\"id\":\"claude\"}"; exit 1' ;;
  esac
  printf '%s\n' '#!/bin/bash' "$body" >"$OMARCHY_PATH/bin/omarchy-agent-usage-claude"
  if run_update claude codex >"$TEST_ROOT/stdout" 2>"$TEST_ROOT/stderr"; then
    fail "$failure collector must return failure"
  fi
  [[ $(<"$TEST_ROOT/stderr") == "omarchy-agent-usage-update: claude collector failed" ]] ||
    fail "$failure collector reports its failure"
  cmp -s "$usage_dir/claude.json" "$TEST_ROOT/valid.json" || fail "$failure collector corrupts the previous valid record"
  assert_name codex stock-codex
  pass "$failure collector fails without corrupting existing state or blocking other collectors"
done

printf '%s\n' '#!/bin/bash' 'printf "%s\n" "not json"' >"$OMARCHY_PATH/bin/omarchy-agent-usage-noisy"
chmod +x "$OMARCHY_PATH/bin/omarchy-agent-usage-noisy"
if run_update noisy 2>"$TEST_ROOT/stderr"; then
  fail "invalid new collector must return failure"
fi
[[ ! -e $usage_dir/noisy.json ]] || fail "invalid new collector writes no record"
shopt -s nullglob
temporary_records=("$usage_dir"/.*.??????)
(( ${#temporary_records[@]} == 0 )) || fail "no partial temporary records remain"
[[ ! -e $HOME/core-updater.calls && ! -e $usage_dir/update.json ]] || fail "no invocation recursively calls core updater"
pass "invalid new records leave no output or temporary files and core updater is never invoked"

# Empty XDG variables still use the user's conventional config/state locations.
mkdir -p "$HOME/.config/omarchy"
printf '%s\n' '{"sources":{"hermes":{"type":"test"}}}' >"$HOME/.config/omarchy/agent-meter.json"
XDG_CONFIG_HOME="" XDG_STATE_HOME="" run_update hermes || fail "default XDG locations work"
[[ $(jq -r '.name' "$HOME/.local/state/omarchy/agents/usage/hermes.json") == "remote-hermes" ]] ||
  fail "empty XDG state variable writes below isolated HOME"
pass "empty XDG variables preserve conventional user config and state paths"
