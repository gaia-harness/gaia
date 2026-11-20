#!/usr/bin/env bats
# Doc pin for Quality Gate step 7 (the dev smoke test): the held-port
# discriminator dev-smoke.sh prints must stay the text step 7 branches on.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="$ROOT/wiki/decisions/Quality Gate.md"
  SMOKE="$ROOT/.gaia/scripts/dev-smoke.sh"
  HELD_PORT_MARKER='is already in use'
}

# Step 7 through the line before step 8, whitespace collapsed.
step_seven() {
  awk '/^7\. \*\*Dev smoke test\*\*/{on=1} /^8\. /{on=0} on' "$1" | tr '\n' ' ' | tr -s ' '
}

@test "the held-port discriminator occurs in dev-smoke.sh and in step 7" {
  grep -qF "$HELD_PORT_MARKER" "$SMOKE"
  [[ "$(step_seven "$PAGE")" == *"$HELD_PORT_MARKER"* ]]
}
