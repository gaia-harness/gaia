#!/usr/bin/env bats
# The zero-round unit path: a first-dispatch quick review clears with no full
# member round, so the audit loop unit that ran it leaves a state file holding
# one admitted unit and no rounds, or no state file at all. The rounds record,
# the unit window and the dispositions checks must behave on both, on real
# router, mark and loop-state output from one merge-base sandbox.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

QUICK_ENGLISH="frontend/app/languages/en/common.ts"
QUICK_JAPANESE="frontend/app/languages/ja/common.ts"

# quick_locale_text <title>: a one-key language file.
quick_locale_text() {
  printf 'export default {\n  title: '"'"'%s'"'"',\n};' "$1"
}

setup_file() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
  lsb_build_templates plain
  (
    BATS_TEST_TMPDIR="$LSB_TEMPLATE_ROOT/prepared-quick"
    mkdir -p "$BATS_TEST_TMPDIR"
    lsb_init
    lsb_main_base_begin
    lsb_commit "$QUICK_ENGLISH" "$(quick_locale_text Hello)"
    lsb_commit "$QUICK_JAPANESE" "$(quick_locale_text こんにちは)"
    lsb_main_base_end
    lsb_commit "$QUICK_ENGLISH" "$(quick_locale_text Welcome)"
    lsb_commit "$QUICK_JAPANESE" "$(quick_locale_text ようこそ)"
    routed="$(bash "$LSB_ROOT/.gaia/scripts/audit-light-route.sh" --root "$LSB_ROOT" --member code-audit-frontend)"
    [ "$routed" = "$(printf 'light\tquick-eligible')" ] || { printf 'template router: %s\n' "$routed" >&2; exit 1; }
    cp "$LSB_TEMPLATE_ROOT/plain/slug" "$BATS_TEST_TMPDIR/slug"
  ) || return 1
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  FRONTEND="code-audit-frontend"
  RUN_FOLDER="$BATS_TEST_TMPDIR/run"
  REPLY_FILE="$BATS_TEST_TMPDIR/reply.json"
}

teardown() {
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# prepare_cleared_quick: the routed two-locale string change, a clean reply
# marked, and an empty run folder.
prepare_cleared_quick() {
  lsb_from_template prepared-quick
  lsb_clear_reply "$FRONTEND" >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  [ "$status" -eq 0 ] && [ "$output" = "light-cleared" ] || { printf 'mark: %s\n' "$output" >&2; return 1; }
  mkdir -p "$RUN_FOLDER"
}

# seed_unit_without_rounds: loop state holding one admitted unit and no rounds,
# the entry shape the bound hook appends for an admitted unit.
# shellcheck disable=SC2034  # the sourced fixture helper reads ALF_ROOT, ALF_BRANCH and ALF_SLUG
seed_unit_without_rounds() {
  # shellcheck source=.gaia/tests/helpers/audit-loop-fixture.sh
  . "$LSB_REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh" || return 1
  ALF_ROOT="$LSB_ROOT"
  ALF_BRANCH="$LSB_BRANCH"
  ALF_NORMALIZED_BRANCH="${LSB_BRANCH#worktree-}"
  ALF_NORMALIZED_BRANCH="${ALF_NORMALIZED_BRANCH//+//}"
  ALF_SLUG="$(gaia_key_slug "$LSB_BRANCH")" || return 1
  ALF_STATE="$LSB_ROOT/.gaia/local/protected/audit-loop/$ALF_NORMALIZED_BRANCH.json"
  alf_seed_state '{}' || return 1
  alf_state_edit '.history.units = [{unit: 1, start_round: 1, k: 3, through_round: 3, admitted_on: "context",
    after_checkpoint: 0, recorded_at: "2026-01-01T00:00:00Z", session_id: "s1"}]'
  [ "$(jq -c '[.history.rounds, (.history.units | length)]' "$ALF_STATE")" = '[[],1]' ]
}

record_values() {
  run bash "$LSB_ROOT/.gaia/scripts/audit-loop-eval.sh" record-values --root "$LSB_ROOT"
}

check_all() {
  run bash "$LSB_ROOT/.gaia/scripts/audit-dispositions-check.sh" check-all --root "$LSB_ROOT" --run-folder "$RUN_FOLDER"
}

pr_sections() {
  run bash "$LSB_ROOT/.gaia/scripts/audit-dispositions-check.sh" pr-sections --root "$LSB_ROOT" --run-folder "$RUN_FOLDER"
}

# assert_zero_round_outputs: the record values carry the quick count and a zero
# total, the dispositions checks pass over an empty run folder, and the PR
# sections print nothing.
assert_zero_round_outputs() {
  record_values
  [ "$status" -eq 0 ] || return 1
  [ "$output" = '{"total":0,"members":{},"grants":0,"quick":{"code-audit-frontend":1}}' ] || { printf 'record-values: %s\n' "$output" >&2; return 1; }
  check_all
  [ "$status" -eq 0 ] || { printf 'check-all %s: %s\n' "$status" "$output" >&2; return 1; }
  [ -z "$output" ] || { printf 'check-all output: %s\n' "$output" >&2; return 1; }
  pr_sections
  [ "$status" -eq 0 ] || { printf 'pr-sections %s: %s\n' "$status" "$output" >&2; return 1; }
  [ -z "$output" ] || { printf 'pr-sections output: %s\n' "$output" >&2; return 1; }
}

@test "a quick clear then a state with one admitted unit and no rounds: record values, the unit window and the dispositions checks all work" {
  prepare_cleared_quick
  seed_unit_without_rounds
  assert_zero_round_outputs
  run bash "$LSB_ROOT/.gaia/scripts/audit-loop-eval.sh" unit-window --root "$LSB_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 3 false" ]
}

@test "a quick clear with no loop state file at all: the same record values and the same clean dispositions checks" {
  prepare_cleared_quick
  seed_unit_without_rounds
  rm -f "$ALF_STATE"
  [ ! -e "$ALF_STATE" ]
  assert_zero_round_outputs
}

@test "the quick clear in the ledger is what puts quick in the values: with the ledger removed the keys are gone" {
  prepare_cleared_quick
  seed_unit_without_rounds
  [ "$(jq -r .anchor_kind "$LSB_ROOT/.gaia/local/audit/light/$(lsb_member_digest "$FRONTEND").$FRONTEND.route.json")" = "merge-base" ]
  rm -f "$LSB_ROOT/.gaia/local/audit/light/$LSB_SLUG.reviews.jsonl"
  record_values
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":0,"members":{},"grants":0}' ]
}
