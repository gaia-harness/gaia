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

# Print the classify command from the file's fenced bash block, with the script
# path made absolute and the findings-file placeholder replaced by $2.
classify_command() {
  local file="$1" findings="$2" line
  line="$(grep -E '^[[:space:]]*bash \.gaia/scripts/audit-noop-detect\.sh ' "$file" | head -n 1)"
  [ -n "$line" ] || return 1
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line/bash .gaia\/scripts\//bash $REPO_ROOT/.gaia/scripts/}"
  printf '%s\n' "${line/<findings file>/$findings}"
}

# Run the extracted command against a fixture body ($2); "-" means no file.
# Prints the exit code.
classify_exit() {
  local file="$1" body="$2" fixture="$BATS_TEST_TMPDIR/fixture.json" cmd
  rm -f "$fixture"
  if [ "$body" != "-" ]; then printf '%s' "$body" >"$fixture"; fi
  cmd="$(classify_command "$file" "$fixture")" || { echo "no-command"; return 0; }
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

# The retry count, the inline ending and when to classify are the subagent
# dispatch rule's, always loaded, so the contract does not restate them; it
# owns only what is specific to a lens.
check_lens_noop_specifics() {
  local file="$1"
  grep -qF "re-clear that lens's file before the re-dispatch" "$file" || return 1
  grep -qF 'say in one line which lens ran inline' "$file"
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
  [ "$(classify_exit "$CONTRACT" '{"dimension":"FG","findings":[]}')" = "0" ]
}

@test "classify command: a missing file is a no-op (exit 1)" {
  [ "$(classify_exit "$CONTRACT" '-')" = "1" ]
}

@test "classify command: a file with no findings key is a no-op (exit 1)" {
  [ "$(classify_exit "$CONTRACT" '{"dimension":"FG"}')" = "1" ]
}

@test "red twin: a fence that lost --report-key reads the empty-array fixture as a no-op" {
  local mutated
  mutated="$(mutate_delete ' --report-key findings')"
  [ "$(classify_exit "$mutated" '{"dimension":"FG","findings":[]}')" = "1" ]
}

@test "contract states the lens-specific no-op steps: re-clear the lens's file, announce an inline lens" {
  check_lens_noop_specifics "$CONTRACT"
}

@test "red twin: a copy that drops the re-clear fails" {
  local mutated
  mutated="$(mutate_replace "re-clear that lens's file before the re-dispatch" 're-dispatch')"
  check_lens_noop_specifics "$mutated" && return 1
  true
}

@test "red twin: a copy that drops the inline announcement fails" {
  local mutated
  mutated="$(mutate_replace 'say in one line which lens ran inline' 'continue')"
  check_lens_noop_specifics "$mutated" && return 1
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
