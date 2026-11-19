#!/usr/bin/env bats

# The worthiness evaluator must never propose deleting the only lower-layer test
# that drives a guard into its failing state. The prompt is prose, so the
# carve-out is pinned by grep.

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  PROMPT="$HOME_ROOT/.claude/agents/worthiness-evaluator.md"
}

# Whitespace-collapsed prompt text, so a pin survives the prompt's hard wrapping.
normalized_prompt() {
  tr '\n' ' ' < "$1" | tr -s ' '
}

# Fails with the first needle of the list the prompt lacks.
prompt_carries_every() {
  local prompt_file="$1"
  shift
  local needle text
  text=$(normalized_prompt "$prompt_file")
  for needle in "$@"; do
    grep -qF -- "$needle" <<<"$text" || {
      printf 'missing needle: %s\n' "$needle" >&2
      return 1
    }
  done
  return 0
}

# shellcheck disable=SC2016
sole_driver_needles() {
  SOLE_DRIVER_NEEDLES=(
    'only test below the browser layer (`.claude/doctrine/testing.md`, `## Guards and security rows`) driving a guard, refusal or validation into its failing state is `keep` or `fix`, never `delete`'
    'A browser test or a flow test never counts as the covering sibling'
    'neither does a sibling also proposed for `delete`'
  )
}

@test "the evaluator prompt never proposes deleting the only lower-layer test driving a guard, and never counts a browser test as its sibling" {
  sole_driver_needles
  prompt_carries_every "$PROMPT" "${SOLE_DRIVER_NEEDLES[@]}"
}
