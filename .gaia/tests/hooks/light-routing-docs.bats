#!/usr/bin/env bats
# Doc-grep pins for the light-routing prose the audit-loop unit executes and
# the audit round procedure page describes.
#
# Prose-to-prose checks: each literal below is something an orchestrator acts
# on or a named departure a reader would otherwise infer wrongly. Every
# presence check has a red twin: a scratch copy with the literal removed must
# fail the same predicate, so the predicate is proven able to fail.
#
# GAIA_LIGHT_ROUTING_PAGE and GAIA_LIGHT_ROUTING_UNIT override the page and
# unit paths so a scratch copy can be driven through the same cases; they
# default to the real files.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned literals carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="${GAIA_LIGHT_ROUTING_PAGE:-$ROOT/wiki/concepts/Audit Round Procedure.md}"
  UNIT="${GAIA_LIGHT_ROUTING_UNIT:-$ROOT/.claude/agents/audit-loop-unit.md}"
  DECISION="${GAIA_LIGHT_ROUTING_DECISION:-$ROOT/wiki/decisions/Code Audit Team.md}"
  # Assembled so this file never spells the forbidden flag contiguously.
  FORBIDDEN_FLAG="--review"" light"
}

# has_literal <file> <literal>: rc 0 when the fixed string is present.
has_literal() {
  grep -qF -- "$2" "$1"
}

# scratch_without <file> <literal>: writes a copy with every line carrying the
# literal removed and prints its path.
scratch_without() {
  local scratch_copy_path="$BATS_TEST_TMPDIR/without.md"
  grep -vF -- "$2" "$1" >"$scratch_copy_path"
  printf '%s\n' "$scratch_copy_path"
}

# assert_pinned <file> <literal>: present in the real file, absent in the
# scratch copy that drops it (the red twin).
assert_pinned() {
  has_literal "$1" "$2" || { echo "missing: $2" >&2; return 1; }
  local copy
  copy="$(scratch_without "$1" "$2")"
  has_literal "$copy" "$2" && { echo "red twin did not fail: $2" >&2; return 1; }
  true
}

@test "page and unit never spell the light write flag" {
  grep -qF -- "$FORBIDDEN_FLAG" "$PAGE" && return 1
  grep -qF -- "$FORBIDDEN_FLAG" "$UNIT" && return 1
  # Red twin: the predicate fires on a copy that spells it.
  { cat "$PAGE"; printf 'run %s now\n' "$FORBIDDEN_FLAG"; } >"$BATS_TEST_TMPDIR/spelled-page.md"
  grep -qF -- "$FORBIDDEN_FLAG" "$BATS_TEST_TMPDIR/spelled-page.md"
  { cat "$UNIT"; printf 'run %s now\n' "$FORBIDDEN_FLAG"; } >"$BATS_TEST_TMPDIR/spelled-unit.md"
  grep -qF -- "$FORBIDDEN_FLAG" "$BATS_TEST_TMPDIR/spelled-unit.md"
}

@test "unit names the router and the light-marker script in its routing section" {
  local routing
  routing="$(awk '/^## Routing each member$/ {inside_routing_section=1; next} /^## / {inside_routing_section=0} inside_routing_section' "$UNIT")"
  [ -n "$routing" ]
  local needle
  for needle in '.gaia/scripts/audit-light-route.sh' '.gaia/scripts/audit-light-mark.sh' 'audit-member-digest.sh' '`audit-light-reviewer`'; do
    grep -qF -- "$needle" <<<"$routing" || { echo "not under Routing each member: $needle" >&2; return 1; }
  done
  assert_pinned "$UNIT" 'The light-marker script is the only light writer.'
  assert_pinned "$UNIT" 'is not re-dispatched'
}

@test "unit hands the reply over as a scratchpad file, not as stdin through a heredoc" {
  assert_pinned "$UNIT" 'with the Write tool to a file in your session scratchpad directory'
  assert_pinned "$UNIT" '--verdict <that file'
  assert_pinned "$UNIT" '`--verdict -` and `< /dev/null`'
  assert_pinned "$UNIT" 'A heredoc or pipe carrying the reply is refused under worktree confinement'
  assert_pinned "$PAGE" 'names that file to `.gaia/scripts/audit-light-mark.sh`'
  # The old stdin-only spelling is gone from both.
  grep -qF -- 'on stdin through a quoted heredoc' "$UNIT" && return 1
  grep -qF -- 'pipes the reply' "$PAGE" && return 1
  true
}

@test "unit has no instruction to write a marker other than through the light-marker script" {
  # Any line telling the unit to write or create a marker must name the
  # light-marker script or be a prohibition.
  local offending
  offending="$(grep -iE '(write|create|hand-write|mint)[^.]{0,20} (a|the|an) (earned )?(marker|clearance|verdict)' "$UNIT" \
    | grep -viE 'never|no marker|light-marker|audit-light-mark' || true)"
  [ -z "$offending" ] || { printf 'unscripted marker write: %s\n' "$offending" >&2; return 1; }
  # Red twin: an instruction to write the marker is flagged by the same filter.
  { cat "$UNIT"; printf -- '- Then write the marker for the member.\n'; } >"$BATS_TEST_TMPDIR/bad-unit.md"
  offending="$(grep -iE '(write|create|hand-write|mint)[^.]{0,20} (a|the|an) (earned )?(marker|clearance|verdict)' "$BATS_TEST_TMPDIR/bad-unit.md" \
    | grep -viE 'never|no marker|light-marker|audit-light-mark' || true)"
  [ -n "$offending" ]
}
