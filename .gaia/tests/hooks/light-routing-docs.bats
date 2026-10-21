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

# long_waits <file>: prints every wait of a minute or more the unit definition
# could prescribe: any select(undef,undef,undef,<n>) or sleep <n> in the file,
# and any <n> s or <n> seconds inside the "Waiting for a dispatch" subsection
# only. Prints "none-found-input" when nothing at all was extracted, so an
# empty extraction fails loudly instead of passing.
long_waits() {
  local wait_values
  wait_values="$(
    {
      grep -oE 'select\(undef,undef,undef,[0-9.]+\)' "$1" | grep -oE '[0-9.]+\)$' | tr -d ')'
      grep -oE 'sleep [0-9.]+' "$1" | grep -oE '[0-9.]+$'
      awk '/^### Waiting for a dispatch$/ {inside_wait_section=1; next} /^##+ / {inside_wait_section=0} inside_wait_section' "$1" \
        | grep -oE '[0-9.]+ (s|seconds)\b' | grep -oE '^[0-9.]+'
    } || true
  )"
  [ -n "$wait_values" ] || { echo none-found-input; return 0; }
  local wait_value
  while IFS= read -r wait_value; do
    awk -v v="$wait_value" 'BEGIN { exit !(v+0 >= 60) }' && echo "long wait: $wait_value"
  done <<<"$wait_values"
  true
}

# bats test_tags=whole-tree
@test "unit names the first-dispatch anchor and the bounded wait wording" {
  assert_pinned "$UNIT" '(the reason says `quick-eligible`)'
  local waiting
  waiting="$(awk '/^### Waiting for a dispatch$/ {inside_wait_section=1; next} /^##+ / {inside_wait_section=0} inside_wait_section' "$UNIT")"
  [ -n "$waiting" ]
  local needle
  for needle in '(5 s)' 'at most 30 s' 'No single wait reaches a minute.' '24 steps'; do
    grep -qF -- "$needle" <<<"$waiting" || { echo "not under Waiting for a dispatch: $needle" >&2; return 1; }
  done
}

# bats test_tags=whole-tree
@test "unit forbids a fix round on a light-cleared member" {
  assert_pinned "$UNIT" 'A member that light-cleared in a round is never dispatched to a fixer and never the subject of a fix round'
}

# bats test_tags=whole-tree
@test "quick-clear path writes an unopened clean round and skips unit-window" {
  local quick
  quick="$(awk '/^### Quick-clear path$/ {inside_quick_section=1; next} /^##+ / {inside_quick_section=0} inside_quick_section' "$UNIT")"
  [ -n "$quick" ]
  local needle
  for needle in '"opened":false' 'stop_reason: "clean"' 'Skip `unit-window`'; do
    grep -qF -- "$needle" <<<"$quick" || { echo "not under Quick-clear path: $needle" >&2; return 1; }
  done
}

# bats test_tags=whole-tree
@test "unit prescribes no wait of a minute or more" {
  local out
  out="$(long_waits "$UNIT")"
  [ "$out" != none-found-input ]
  [ -z "$out" ]
  # The 600-second limit sentence sits outside the guarded subsection.
  grep -qF -- '600-second limit' "$UNIT"
}

@test "no-long-wait guard fails on an appended 60 s select" {
  { cat "$UNIT"; printf '%s\n' "perl -e 'select(undef,undef,undef,60)'"; } >"$BATS_TEST_TMPDIR/long-select.md"
  local out
  out="$(long_waits "$BATS_TEST_TMPDIR/long-select.md")"
  [ "$out" = "long wait: 60" ]
}

@test "no-long-wait guard fails on a 90 s wait inside the subsection" {
  awk '{print} /^### Waiting for a dispatch$/ {print "\nOn a quiet run, wait 90 s."}' "$UNIT" >"$BATS_TEST_TMPDIR/long-section.md"
  local out
  out="$(long_waits "$BATS_TEST_TMPDIR/long-section.md")"
  [ "$out" = "long wait: 90" ]
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

@test "capture-order guard fails when the date and sleep commands are swapped" {
  awk '/^### Waiting for a dispatch$/ {inside_wait_section=1} /^##+ / && !/^### Waiting for a dispatch$/ {inside_wait_section=0}
    inside_wait_section && index($0, "date -u +%Y-%m-%dT%H:%M:%SZ; perl -e '"'"'select(undef,undef,undef,5)'"'"'") {
      sub(/date -u \+%Y-%m-%dT%H:%M:%SZ; perl -e '"'"'select\(undef,undef,undef,5\)'"'"'/, "perl -e '"'"'select(undef,undef,undef,5)'"'"'; date -u +%Y-%m-%dT%H:%M:%SZ")
    } {print}' "$UNIT" >"$BATS_TEST_TMPDIR/swapped.md"
  cmp -s "$UNIT" "$BATS_TEST_TMPDIR/swapped.md" && return 1
  first_wait_step_prints_time_first "$BATS_TEST_TMPDIR/swapped.md" && return 1
  true
}

@test "capture-order guard fails when the date command sits on its own line" {
  awk '/^### Waiting for a dispatch$/ {inside_wait_section=1} /^##+ / && !/^### Waiting for a dispatch$/ {inside_wait_section=0}
    inside_wait_section && index($0, "date -u +%Y-%m-%dT%H:%M:%SZ; perl") {
      sub(/date -u \+%Y-%m-%dT%H:%M:%SZ; /, "date -u +%Y-%m-%dT%H:%M:%SZ\n")
    } {print}' "$UNIT" >"$BATS_TEST_TMPDIR/split.md"
  cmp -s "$UNIT" "$BATS_TEST_TMPDIR/split.md" && return 1
  first_wait_step_prints_time_first "$BATS_TEST_TMPDIR/split.md" && return 1
  true
}

# light_routing_section <file>: prints the "#### Light routing" section of the
# page (heading line to the next heading), nothing when the heading is absent.
light_routing_section() {
  awk '/^#### Light routing$/ {inside_light_section=1; next} /^##+ / {inside_light_section=0} inside_light_section' "$1"
}

# bats test_tags=whole-tree
@test "page light-routing section names the classifier and the merge-base anchor" {
  local section
  section="$(light_routing_section "$PAGE")"
  [ -n "$section" ]
  local needle
  for needle in '.claude/hooks/lib/audit-quick-classify-lib.sh' 'anchor_kind: merge-base'; do
    grep -qF -- "$needle" <<<"$section" || { echo "not under Light routing: $needle" >&2; return 1; }
  done
}

# bats test_tags=whole-tree
@test "page light-routing section does not enumerate the hiding and focus tokens" {
  local section
  section="$(light_routing_section "$PAGE")"
  [ -n "$section" ]
  local token
  for token in 'sr-only' 'outline-none'; do
    if grep -qF -- "$token" <<<"$section"; then
      echo "enumerated: $token" >&2
      return 1
    fi
  done
}

@test "token-enumeration guard fails on a scratch page that adds one" {
  awk '{print} /^#### Light routing$/ {print "\nHidden tokens include sr-only."}' "$PAGE" >"$BATS_TEST_TMPDIR/enumerated-page.md"
  local section
  section="$(light_routing_section "$BATS_TEST_TMPDIR/enumerated-page.md")"
  grep -qF -- 'sr-only' <<<"$section"
}

# bats test_tags=whole-tree
@test "kill-rule section names the quick-route telemetry lines" {
  local team_page="${GAIA_LIGHT_ROUTING_TEAM_PAGE:-$ROOT/wiki/decisions/Code Audit Team.md}"
  local section
  section="$(awk '/^### Light routing: the kill rule$/ {inside_kill_section=1; next} /^##+ / {inside_kill_section=0} inside_kill_section' "$team_page")"
  [ -n "$section" ]
  grep -qF -- 'quick_routes' <<<"$section"
  grep -qF -- 'quick_cleared' <<<"$section"
}
