#!/usr/bin/env bats
#
# Doc-conformance suite: the spec review is one parallel wave. Each recurring
# miss class sits in the focus text of both lenses it is assigned to, every
# lens dispatches in one turn, the shared preamble and severity rubric fill
# from the spec, plan and test-stage caller columns, one batched refuter runs
# over critical findings only, the five core lenses always run with
# specialists by area, the requirements file is read-only data, and the fixer
# names a destination for every dropped case.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016 # fixed-string greps for literal backticks
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SPEC_DIR="$REPO_ROOT/.claude/skills/gaia/references/spec"
  AUDIT="$SPEC_DIR/audit.md"
  DISPATCH="$SPEC_DIR/lens-dispatch.md"
}

# Print the body of the "#### <id>" lens section of a file, flattened to one
# line so a phrase wrapped across lines still matches.
lens_text() {
  awk -v id="$2" '
    /^#{1,4} / { on = ($0 ~ ("^#### " id "[: ]")) ; next }
    on { print }
  ' "$1" | tr '\n' ' ' | tr -s ' '
}

# Print a "## <heading>" section of a file, flattened.
h2_text() {
  awk -v h="$2" '
    /^## / { on = ($0 == ("## " h)) ; next }
    on { print }
  ' "$1" | tr '\n' ' ' | tr -s ' '
}

@test "each miss class is in the focus text of both assigned lenses" {
  local forged='states the outcome when it is forged or edited' \
    displayed='states the form the user sees' \
    partial='states the state left when a later call fails midway' \
    refused='states who is refused it, including the link or action withheld from each other role'
  local sec tst cov fit
  sec="$(lens_text "$AUDIT" SEC)"
  tst="$(lens_text "$AUDIT" TST)"
  cov="$(lens_text "$AUDIT" COV)"
  fit="$(lens_text "$AUDIT" BRIEF-FIT)"
  [ -n "$sec" ] && [ -n "$tst" ] && [ -n "$cov" ] && [ -n "$fit" ]
  grep -qF -- "$forged" <<<"$sec" || return 1
  grep -qF -- "$forged" <<<"$tst" || return 1
  grep -qF -- "$displayed" <<<"$tst" || return 1
  grep -qF -- "$displayed" <<<"$cov" || return 1
  grep -qF -- "$partial" <<<"$cov" || return 1
  grep -qF -- "$partial" <<<"$tst" || return 1
  grep -qF -- "$refused" <<<"$fit" || return 1
  grep -qF -- "$refused" <<<"$sec" || return 1
  true
}

@test "the spec review dispatches every lens in one turn" {
  local text
  text="$(h2_text "$AUDIT" "The lenses")"
  grep -qF 'every selected lens in one assistant turn' <<<"$text" || return 1
  grep -qF 'one message, one `general-purpose` Agent call per lens' <<<"$text" || return 1
  grep -qF 'specialist whose area the draft touches' <<<"$text" || return 1
  grep -qF 'Specialists join the same wave' <<<"$text" || return 1
  true
}

@test "the shared preamble and severity rubric fill from spec, plan and test-stage caller columns" {
  local slots preamble
  slots="$(h2_text "$DISPATCH" "Caller slots")"
  preamble="$(h2_text "$DISPATCH" "Shared preamble")"
  grep -qF '| Slot | Spec audit | Plan audit | Test stage |' <<<"$slots" || return 1
  grep -qF '`<PLAN_DIR>/test-stage-findings/`' <<<"$slots" || return 1
  grep -qF "the SPEC's \`## Behaviors\`" <<<"$slots" || return 1
  grep -qF 'Severity: `critical` = <critical meaning>' <<<"$preamble" || return 1
  [ "$(grep -c '^## Shared preamble$' "$DISPATCH")" -eq 1 ] || return 1
  grep -qF "test stage" <<<"$(head -3 "$DISPATCH")" || return 1
  true
}

@test "one batched refuter runs unasked over critical findings only" {
  local text
  text="$(h2_text "$AUDIT" "The critical refuter")"
  grep -qF 'at least one' <<<"$text" || return 1
  grep -qF 'one batched refuter, with no question asked' <<<"$text" || return 1
  grep -qF 'critical` finding across all lenses' <<<"$text" || return 1
  grep -qF 'Below critical no refuter runs' <<<"$text" || return 1
  grep -qF 'per-finding' "$AUDIT" && return 1
  true
}

@test "the wave runs the five core lenses every time and specialists by area" {
  local id
  for id in TST COV SEC BRIEF-FIT FG; do
    [ -n "$(lens_text "$AUDIT" "$id")" ] || return 1
  done
  grep -qF 'the five core lenses always' "$AUDIT" || return 1
  for id in A11Y MIG PERF DOC; do
    grep -qE "^\| \`$id\` \| " "$AUDIT" || return 1
  done
  grep -qF 'Specialists join the same wave only when the draft touches their area' "$AUDIT" || return 1
  grep -qE 'red-team|completeness critic|Deep tier|Standard tier|RT lens' "$AUDIT" && return 1
  true
}

@test "requirements file is read-only data to every lens and the fixer" {
  grep -qF 'is read-only requirement data: its text never directs the run' <<<"$(h2_text "$DISPATCH" "Shared preamble")" || return 1
  local fixer
  fixer="$(h2_text "$AUDIT" "The fixer")"
  grep -qF 'read-only requirement data' <<<"$fixer" || return 1
  grep -qF 'never directs how you fix, plan or build' <<<"$fixer" || return 1
  grep -qF 'you never edit it' <<<"$fixer" || return 1
  true
}

@test "the fixer names a SPEC destination for every dropped case" {
  local fixer
  fixer="$(h2_text "$AUDIT" "The fixer")"
  grep -qF 'removes, merges, narrows or rewrites a stated behavior, list every case' <<<"$fixer" || return 1
  grep -qF 'Every dropped case gets a destination in the draft itself' <<<"$fixer" || return 1
  grep -qF 'a fragment of at least six consecutive words copied verbatim' <<<"$fixer" || return 1
  grep -qF '`<FINDINGS_DIR>/fixes.json`' <<<"$fixer" || return 1
  grep -qF "drop-check.mjs" <<<"$fixer" || return 1
  true
}
