#!/usr/bin/env bats
#
# Bats suite for which hooks the cost path registers. The `gh pr merge`
# PostToolUse registration in .claude/settings.json and
# frontend/.claude/settings.json names pr-merge-cost.sh, and that hook invokes
# no script beyond the libraries it loads and usage-merge.sh.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/cost-hook-registrations.bats

bats_require_minimum_version 1.5.0

setup() {
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SETTINGS_FILES=("$SOURCE_ROOT/.claude/settings.json" "$SOURCE_ROOT/frontend/.claude/settings.json")
}

# merge_commands <settings-file>: the commands of the PostToolUse registrations
# guarded by `if: Bash(gh pr merge *)`.
merge_commands() {
  jq -r '[.hooks.PostToolUse // [] | .[] | .hooks[]? | select((.if // "") == "Bash(gh pr merge *)") | .command] | .[]' "$1"
}

@test "the gh pr merge PostToolUse registration names pr-merge-cost.sh, in either settings file" {
  local settings_file
  for settings_file in "${SETTINGS_FILES[@]}"; do
    [ "$(merge_commands "$settings_file" | grep -c 'pr-merge-cost\.sh')" -eq 1 ]
  done
}

@test "pr-merge-cost.sh invokes only the libraries it loads and usage-merge.sh" {
  local hook="$SOURCE_ROOT/.claude/hooks/pr-merge-cost.sh" invoked expected
  invoked="$(grep -vE '^[[:space:]]*#' "$hook" | grep -oE '(^|[;&|[:space:]])(bash|\.)[[:space:]]+"[^"]+"' | grep -oE '[A-Za-z0-9_.-]+\.sh' | LC_ALL=C sort -u)"
  [ -n "$invoked" ]
  expected="$(printf '%s\n' hook-payload.sh usage-merge.sh verb-arming.sh)"
  [ "$invoked" = "$expected" ]
}

@test "guards-must-fail: a scratch settings copy whose merge registration names another hook is caught" {
  local scratch="$BATS_TEST_TMPDIR/settings.json"
  sed 's/pr-merge-cost\.sh/other-merge-hook.sh/' "$SOURCE_ROOT/.claude/settings.json" >"$scratch"
  [ -n "$(merge_commands "$scratch")" ]
  [ "$(merge_commands "$scratch" | grep -c 'pr-merge-cost\.sh' || true)" -eq 0 ]
}
