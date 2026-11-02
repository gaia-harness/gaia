#!/usr/bin/env bats
# Doc pins for Quality Gate step 7 (the dev smoke test): it passes only on
# exit 0, every other exit reports `Dev server` as not run or failed, and a
# held port asks with Hold the commit recommended. Each pin has a red twin
# that runs the same check on a mutated scratch copy of the page.
#
# GAIA_QUALITY_GATE_PAGE overrides the page path so a scratch copy can be
# driven through the same cases.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned sentences carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="${GAIA_QUALITY_GATE_PAGE:-$ROOT/wiki/decisions/Quality Gate.md}"
  SMOKE="$ROOT/.gaia/scripts/dev-smoke.sh"
  HELD_PORT_MARKER='is already in use'
}

# Step 7 through the line before step 8, whitespace collapsed.
step_seven() {
  awk '/^7\. \*\*Dev smoke test\*\*/{on=1} /^8\. /{on=0} on' "$1" | tr '\n' ' ' | tr -s ' '
}

# Writes a scratch copy of the page with one string replaced; prints its path.
mutated_page() {
  local scratch="$BATS_TEST_TMPDIR/Quality Gate.md"
  PAGE_FROM="$1" PAGE_TO="$2" python3 -c '
import os, sys
text = open(sys.argv[1]).read()
needle = os.environ["PAGE_FROM"]
assert needle in text, needle
open(sys.argv[2], "w").write(text.replace(needle, os.environ["PAGE_TO"]))
' "$PAGE" "$scratch"
  printf '%s' "$scratch"
}

pins_present() {
  local text needle
  text="$(step_seven "$1")"
  for needle in \
    'it passes only on exit 0' \
    '`Hold the commit` (Recommended)' \
    '`Stop it`' \
    'reruns the step' \
    'no later step or commit proceeds' \
    'Unattended, the workflow halts naming the reason' \
    'reports `Dev server` as not run or failed' \
    'No `react-router.config.*` package' \
    'No resolvable port' \
    'No process backend' \
    'install `lsof`' \
    "$HELD_PORT_MARKER"; do
    case "$text" in
      *"$needle"*) ;;
      *)
        printf 'missing: %s\n' "$needle" >&2
        return 1
        ;;
    esac
  done
}

@test "step 7 states every pass-only-on-exit-0 pin" {
  pins_present "$PAGE"
}

@test "red twin: step 7 without the exit 0 sentence fails the pin" {
  scratch="$(mutated_page 'it passes only on exit 0' 'it passes')"
  run pins_present "$scratch"
  [ "$status" -eq 1 ]
}

@test "red twin: step 7 without the unattended halt fails the pin" {
  scratch="$(mutated_page 'Unattended, the workflow halts naming the reason.' '')"
  run pins_present "$scratch"
  [ "$status" -eq 1 ]
}

@test "red twin: step 7 without the process backend reason fails the pin" {
  scratch="$(mutated_page '**No process backend**' '**Other**')"
  run pins_present "$scratch"
  [ "$status" -eq 1 ]
}

# bats test_tags=whole-tree
@test "no tracked file under wiki or the claude folders offers Leave it running" {
  run git -C "$ROOT" grep -n 'Leave it running' -- wiki .claude apps/web/.claude
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "red twin: a page offering the old option fails the absence check" {
  scratch="$(mutated_page '`Hold the commit` (Recommended)' '`Leave it running` (Recommended)')"
  run grep -c 'Leave it running' "$scratch"
  [ "$output" -ge 1 ]
}

@test "the held-port discriminator occurs in dev-smoke.sh and in step 7" {
  grep -qF "$HELD_PORT_MARKER" "$SMOKE"
  [[ "$(step_seven "$PAGE")" == *"$HELD_PORT_MARKER"* ]]
}

@test "red twin: a reworded discriminator is absent from dev-smoke.sh" {
  scratch="$(mutated_page "$HELD_PORT_MARKER" 'is taken')"
  [[ "$(step_seven "$scratch")" == *'is taken'* ]]
  run grep -qF 'is taken' "$SMOKE"
  [ "$status" -eq 1 ]
}
