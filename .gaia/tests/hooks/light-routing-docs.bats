#!/usr/bin/env bats
# Reproducing test for the first wait step of the audit-loop unit's "Waiting
# for a dispatch" subsection: it prints the time before it sleeps, on one line.
#
# GAIA_LIGHT_ROUTING_UNIT overrides the unit path so a scratch copy can be
# driven through the same predicate; it defaults to the real file.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  UNIT="${GAIA_LIGHT_ROUTING_UNIT:-$ROOT/.claude/agents/audit-loop-unit.md}"
}

# first_wait_step_prints_time_first <file>: rc 0 when, inside "Waiting for a
# dispatch", exactly one line holds both the date capture and the 5 s sleep and
# the date capture comes first on it (a capture after the sleep would understate
# the reviewer's latency by the sleep).
first_wait_step_prints_time_first() {
  local date_command='date -u +%Y-%m-%dT%H:%M:%SZ'
  local sleep_command="perl -e 'select(undef,undef,undef,5)'"
  local matching_lines line prefix
  matching_lines="$(awk '/^### Waiting for a dispatch$/ {inside_wait_section=1; next} /^##+ / {inside_wait_section=0} inside_wait_section' "$1" \
    | grep -F -- "$date_command" | grep -F -- "$sleep_command" || true)"
  [ -n "$matching_lines" ] || return 1
  [ "$(printf '%s\n' "$matching_lines" | wc -l | tr -d ' ')" = 1 ] || return 1
  line="$matching_lines"
  prefix="${line%%"$date_command"*}"
  case "$prefix" in
    *"$sleep_command"*) return 1 ;;
  esac
  true
}

@test "first wait step prints the time before it sleeps, on one line" {
  first_wait_step_prints_time_first "$UNIT"
}
