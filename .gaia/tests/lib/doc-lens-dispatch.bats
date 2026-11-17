#!/usr/bin/env bats
#
# Doc-conformance suite for the shared adversarial-audit lens-dispatch contract
# (.claude/skills/gaia/references/spec/lens-dispatch.md), read by the spec
# audit and the plan decomposition audit.
#
# THE PROBLEM. A dispatched lens that no-ops writes nothing, and a caller that
# never classifies the file reads the absence as "the lens found nothing". The
# contract prescribes one classify command; this suite EXECUTES that command
# (extracted from the file's own fenced block, not a retyped copy) against
# fixtures, then runs every prose check against a mutated scratch copy to prove
# each one can fail.
#
# Every check is a function taking the contract file, so a red twin hands it a
# mutated copy under BATS_TEST_TMPDIR.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CONTRACT="$REPO_ROOT/.claude/skills/gaia/references/spec/lens-dispatch.md"
}

# Print the classify command from the file's fenced block, with the script
# path made absolute, the findings-file placeholder replaced by $2 and the
# brief-file placeholder by $3.
classify_command() {
  local file="$1" findings="$2" brief="$3" line
  line="$(grep -E '^[[:space:]]*node \.gaia/scripts/spec/lens-brief\.mjs classify ' "$file" | head -n 1)"
  [ -n "$line" ] || return 1
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line/node .gaia\/scripts\//node $REPO_ROOT/.gaia/scripts/}"
  line="${line/<findings file>/$findings}"
  printf '%s\n' "${line/<brief file>/$brief}"
}

BRIEF_TOKEN_FIXTURE="0123456789abcdef0123456789abcdef"

# Run the extracted command against a fixture body ($2); "-" means no file.
# The brief carries BRIEF_TOKEN_FIXTURE; a body naming another token is the
# caller's to write. Prints the exit code.
classify_exit() {
  local file="$1" body="$2" fixture="$BATS_TEST_TMPDIR/fixture.json" brief="$BATS_TEST_TMPDIR/brief.md" cmd
  rm -f "$fixture"
  printf 'Write "brief_token": "%s" at the top level.\n' "$BRIEF_TOKEN_FIXTURE" >"$brief"
  if [ "$body" != "-" ]; then printf '%s' "$body" >"$fixture"; fi
  cmd="$(classify_command "$file" "$fixture" "$brief")" || { echo "no-command"; return 0; }
  local rc=0
  (cd "$REPO_ROOT" && bash -c "$cmd" >/dev/null 2>&1) || rc=$?
  echo "$rc"
}

check_section_order() {
  local file="$1" got want
  got="$(grep -E '^## ' "$file" | tr '\n' '|')"
  want='## Caller slots|## Shared preamble|## Write and return|## Findings file schema|## Pre-clear, classify, re-dispatch|'
  [ "$got" = "$want" ]
}

check_under_500_lines() {
  [ "$(wc -l <"$1")" -lt 500 ]
}

check_redispatch_once() {
  grep -qF 're-dispatch that lens exactly once' "$1"
}

check_inline_fallback() {
  grep -qF 'run that lens inline on the main thread' "$1"
}

check_completion_notification() {
  grep -qF "completion notification, never at the moment the dispatch call returns" "$1"
}

check_repo_relative_preclear() {
  local file="$1"
  grep -qF 'rm -f .gaia/local/cache/audit-<spec_id>/findings/<LENS>.json' "$file" || return 1
  grep -qF 'rm -rf .notebook/plans/<PLAN-NNN>/audit' "$file" || return 1
  grep -qF 'mkdir -p .notebook/plans/<PLAN-NNN>/audit' "$file"
}

check_plan_bash_write_note() {
  local file="$1"
  grep -qF 'write the findings file with `Bash` at the main-checkout path' "$file" || return 1
  grep -qF 'read it back to confirm both its content and its location' "$file"
}

# Scratch copy of the contract with one fixed string deleted.
mutate_delete() {
  local out="$BATS_TEST_TMPDIR/mutated.md"
  sed "s|$1||" "$CONTRACT" >"$out"
  printf '%s\n' "$out"
}

# Scratch copy of the contract with one fixed string swapped for another.
mutate_replace() {
  local out="$BATS_TEST_TMPDIR/mutated.md"
  sed "s|$1|$2|" "$CONTRACT" >"$out"
  printf '%s\n' "$out"
}

@test "contract has the five sections in order and stays small" {
  check_section_order "$CONTRACT"
  check_under_500_lines "$CONTRACT"
}

@test "red twin: a reordered section list fails the order check" {
  local mutated="$BATS_TEST_TMPDIR/reordered.md"
  sed 's|^## Shared preamble|## Preamble first|' "$CONTRACT" >"$mutated"
  check_section_order "$mutated" && return 1
  true
}

@test "classify command: an empty findings array is real (exit 0)" {
  [ "$(classify_exit "$CONTRACT" '{"dimension":"FG","brief_token":"0123456789abcdef0123456789abcdef","findings":[]}')" = "0" ]
}

@test "classify command: a missing file is a no-op (exit 1)" {
  [ "$(classify_exit "$CONTRACT" '-')" = "1" ]
}

@test "classify command: a file with no findings key is a no-op (exit 1)" {
  [ "$(classify_exit "$CONTRACT" '{"dimension":"FG","brief_token":"0123456789abcdef0123456789abcdef"}')" = "1" ]
}

@test "red twin: a fence that lost --brief reads a wrong-token empty array as real" {
  local mutated body='{"dimension":"FG","brief_token":"ffffffffffffffffffffffffffffffff","findings":[]}'
  [ "$(classify_exit "$CONTRACT" "$body")" = "1" ] || return 1
  mutated="$(mutate_delete ' --brief <brief file>')"
  [ "$(classify_exit "$mutated" "$body")" = "0" ]
}

@test "contract states the once-only re-dispatch" {
  check_redispatch_once "$CONTRACT"
}

@test "red twin: a copy without the re-dispatch sentence fails" {
  local mutated
  mutated="$(mutate_replace 'exactly once' 'twice')"
  check_redispatch_once "$mutated" && return 1
  true
}

@test "contract states the inline fallback after a second no-op" {
  check_inline_fallback "$CONTRACT"
}

@test "red twin: a copy without the inline fallback fails" {
  local mutated
  mutated="$(mutate_replace 'inline on the main thread' 'in a fresh subagent')"
  check_inline_fallback "$mutated" && return 1
  true
}

@test "contract names the completion notification as the classification point" {
  check_completion_notification "$CONTRACT"
}

@test "red twin: a copy that classifies at dispatch return fails" {
  local mutated
  mutated="$(mutate_replace ', never at the moment' ', or at the moment')"
  check_completion_notification "$mutated" && return 1
  true
}

@test "pre-clear commands are spelled repo-relative for both callers" {
  check_repo_relative_preclear "$CONTRACT"
}

@test "red twin: an absolute plan pre-clear spelling fails" {
  local mutated="$BATS_TEST_TMPDIR/absolute.md"
  sed 's|rm -rf .notebook/plans/<PLAN-NNN>/audit|rm -rf <PLAN_DIR>/audit|' "$CONTRACT" >"$mutated"
  check_repo_relative_preclear "$mutated" && return 1
  true
}

@test "plan column carries the Bash-at-main-path write note with read-back" {
  check_plan_bash_write_note "$CONTRACT"
}

@test "red twin: a copy without the read-back fails" {
  local mutated
  mutated="$(mutate_delete 'read it back to confirm both its content and its location')"
  check_plan_bash_write_note "$mutated" && return 1
  true
}

# defined_once <dispatch> <audit> <decomposition>: each optional findings field
# is a JSON key exactly once, in the schema block of the findings file schema
# section, and a JSON key nowhere else in the three audit docs.
FINDINGS_FIELDS="brief_token proposed_disposition directive row_patches replacements"

defined_once() {
  local dispatch="$1" audit="$2" decomposition="$3" field block count
  block="$(awk '
    /^## Findings file schema/ { inside = 1; next }
    inside && /^## / { exit }
    inside && /"dimension":/ { grab = 1 }
    inside && grab && /^$/ { exit }
    inside && grab { print }
  ' "$dispatch")"
  [ -n "$block" ] || return 1
  for field in $FINDINGS_FIELDS; do
    count="$(printf '%s\n' "$block" | grep -oF "\"$field\":" | wc -l | tr -d " ")"
    [ "$count" -eq 1 ] || { printf '%s appears %s times in the schema block\n' "$field" "$count" >&2; return 1; }
    count="$(awk -v key="\"$field\":" '
      /^## / { inside = ($0 ~ /^## Findings file schema/) }
      !inside && index($0, key) { n++ }
      END { print n + 0 }
    ' "$dispatch")"
    [ "$count" -eq 0 ] || { printf '%s is a key outside the schema section of the dispatch doc\n' "$field" >&2; return 1; }
    grep -qF "\"$field\":" "$audit" "$decomposition" && { printf '%s is a key in another doc\n' "$field" >&2; return 1; }
  done
  true
}

@test "optional findings fields are defined once in the findings file schema section" {
  local audit="$REPO_ROOT/.claude/skills/gaia/references/spec/audit.md"
  local decomposition="$REPO_ROOT/.claude/skills/gaia/references/plan/decomposition-audit.md"
  local mutated="$BATS_TEST_TMPDIR/twice.md" extra="$BATS_TEST_TMPDIR/other.md"
  defined_once "$CONTRACT" "$audit" "$decomposition" || return 1

  sed 's|^          "directive": |          "directive": "x", "directive": |' "$CONTRACT" >"$mutated"
  defined_once "$mutated" "$audit" "$decomposition" && return 1
  { cat "$decomposition"; printf '    "row_patches": []\n'; } >"$extra"
  defined_once "$CONTRACT" "$audit" "$extra" && return 1
  true
}
