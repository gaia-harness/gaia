#!/usr/bin/env bats
#
# The "## Decided unattended" PR-body section audit-dispositions-check.sh
# pr-sections renders from the autonomy decision log
# (.gaia/scripts/audit-decided-unattended-lib.sh). The fixture is a real repo
# on a feature branch whose main checkout holds the log.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-decided-unattended.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup_file() {
  # shellcheck source=/dev/null
  . "$BATS_TEST_DIRNAME/../../tests/helpers/audit-loop-fixture.sh"
  alf_build_template
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/disp
  alf_fill f.txt 3 feature
  alf_commit "feature"
  RUN_FOLDER="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  mkdir -p "$RUN_FOLDER" "$ALF_ROOT/.gaia/local/protected"
  LOG="$ALF_ROOT/.gaia/local/protected/autonomy-log.jsonl"
}

# decision <branch> <header> <option>: one log entry in the writer's shape.
decision() {
  jq -n -c --arg branch "$1" --arg header "$2" --arg option "$3" \
    '{time: "2026-01-01T00:00:00Z", session_id: "s", branch: $branch, header: $header, option: $option}' >>"$LOG"
}

run_sections() {
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
}

green() {
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
}

mutant_script() {
  local mutant_directory="$BATS_TEST_TMPDIR/mutant" target="$1"
  shift
  mkdir -p "$mutant_directory"
  cp "$SCRIPTS"/*.sh "$mutant_directory/"
  sed "$@" "$SCRIPTS/$target" >"$mutant_directory/$target"
  cmp -s "$SCRIPTS/$target" "$mutant_directory/$target" && return 1
  SCRIPT="$mutant_directory/audit-dispositions-check.sh"
}

@test "the section lists the branch's entries in log order, its pre-rename spelling included, and no other branch's" {
  local expected
  decision feat/disp 'Merge strategy' 'Squash (Recommended)'
  decision feat/other 'Elsewhere' 'Not this branch'
  decision worktree-feat+disp 'Before rename' 'Yes (Recommended)'
  run_sections
  green || return 1
  expected="$(printf '%s\n' '## Decided unattended' '' '- Merge strategy: Squash (Recommended)' '- Before rename: Yes (Recommended)')"
  [ "$output" = "$expected" ] || { printf 'got:\n%s\n' "$output"; return 1; }
  mutant_script audit-decided-unattended-lib.sh -e 's/"$(gaia_branch_normalize "$candidate")" = "$key"/"$candidate" = "$branch"/' || return 1
  run_sections
  green || return 1
  grep -qF -- 'Before rename' <<<"$output" && { echo "twin did not fail the case: $output"; return 1; }
  true
}

@test "a branch with no entries, or no log, gets no section" {
  run_sections
  green || return 1
  [ -z "$output" ] || { echo "no log: $output"; return 1; }
  decision feat/other 'Elsewhere' 'Not this branch'
  run_sections
  green || return 1
  [ -z "$output" ] || { echo "other branch only: $output"; return 1; }
}

@test "an entry failing the secret or machine-local reference screen is withheld and counted, the text absent" {
  local token expected
  token="$(printf '%s_%s' ghp "$(printf '%036d' 0)")"
  decision feat/disp 'Shown' 'Plain option'
  decision feat/disp 'Leaks' "token $token"
  decision feat/disp 'Local' 'see SPEC-042 first'
  run_sections
  green || return 1
  expected="$(printf '%s\n' '## Decided unattended' '' '- Shown: Plain option' '- 2 decision(s) withheld: text failed the secret or machine-local reference screen')"
  [ "$output" = "$expected" ] || { printf 'got:\n%s\n' "$output"; return 1; }
  mutant_script audit-decided-unattended-lib.sh -e 's/((. + 1) | IN($local_hits\[\]) | not)/true/' || return 1
  run_sections
  green || return 1
  grep -qF -- 'SPEC-042' <<<"$output" || { echo "twin did not fail the case: $output"; return 1; }
}

@test "the section sits directly after the accepted residuals" {
  jq -n -c '{source: "worthiness", member: "worthiness-evaluator", finding_class: "holistic/unclassified", path: "a.test.ts", line: 1, reason: "kept"}' \
    >>"$RUN_FOLDER/recorded-residuals.jsonl"
  decision feat/disp 'Merge strategy' 'Squash (Recommended)'
  run_sections
  green || return 1
  [ "$(grep -n '^## ' <<<"$output" | cut -d: -f2-)" = "$(printf '%s\n' '## Accepted residuals (recorded, not fixed)' '## Decided unattended')" ] || { echo "$output"; return 1; }
}

@test "an unreadable decision log fails the section instead of dropping it" {
  decision feat/disp 'Merge strategy' 'Squash (Recommended)'
  chmod 000 "$LOG"
  run_sections
  chmod 600 "$LOG"
  [ "$status" -ne 0 ] || { echo "unreadable log rendered: $output"; return 1; }
  grep -qF -- 'unreadable decision log' <<<"$output" || { echo "no error named: $output"; return 1; }
  mutant_script audit-decided-unattended-lib.sh -e '/\[ -r "\$log" \]/d' || return 1
  chmod 000 "$LOG"
  run_sections
  chmod 600 "$LOG"
  [ "$status" -eq 0 ] || { echo "twin did not drop the section: $status $output"; return 1; }
}
