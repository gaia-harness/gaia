#!/usr/bin/env bats
# End-to-end proof that the light-routing pieces compose: the router, the
# light-marker script, the clearance writer, the merge gate, the base
# resolver, the rounds record, the loop-bound hook and the telemetry, all
# driven from one sandbox repository's own copies of the scripts. The reviewer
# agent cannot be dispatched from a suite, so canned verdict replies built from
# the route record stand in for it. Markers come only from the real writer or
# the light-marker script; the legacy and stripped cases say so where they
# differ.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  FRONTEND="code-audit-frontend"
  REPLY_FILE="$BATS_TEST_TMPDIR/reply.json"
}

teardown() {
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

audit_directory() {
  printf '%s/.gaia/local/audit' "$LSB_ROOT"
}

light_directory() {
  printf '%s/.gaia/local/audit/light' "$LSB_ROOT"
}

# marker_path: the earned marker the frontend member would have for the
# current digest.
marker_path() {
  printf '%s/%s.ok' "$(audit_directory)" "$(lsb_member_digest "$FRONTEND")"
}

route_input_path() {
  printf '%s/%s.%s.input.md' "$(light_directory)" "$(lsb_member_digest "$FRONTEND")" "$FRONTEND"
}

telemetry_log() {
  printf '%s/.gaia/local/telemetry/audit-light-routing.jsonl' "$LSB_ROOT"
}

telemetry_script() {
  printf '%s/.gaia/scripts/audit-light-telemetry.sh' "$LSB_ROOT"
}

expect_line() {
  [ "$status" -eq 0 ] || { printf 'status %s, output: %s\n' "$status" "$output" >&2; return 1; }
  [ "$output" = "$1" ] || { printf 'want %s, got: %s\n' "$1" "$output" >&2; return 1; }
}

expect_full() {
  expect_line "$(printf 'full\t%s' "$1")"
}

expect_light_eligible() {
  expect_line "$(printf 'light\tlight-eligible')"
}

assert_no_marker() {
  [ ! -e "$(marker_path)" ] || { printf 'unexpected marker %s\n' "$(marker_path)" >&2; return 1; }
}

# assert_gate_allows / assert_gate_denies: the merge gate's verdict for the
# sandbox's current tree.
assert_gate_allows() {
  lsb_run_merge_hook 41
  [ "$status" -eq 0 ] || { printf 'gate status %s: %s\n' "$status" "$output" >&2; return 1; }
  grep -qF '"permissionDecision": "deny"' <<<"$output" && { printf 'gate denied: %s\n' "$output" >&2; return 1; }
  true
}

assert_gate_denies() {
  lsb_run_merge_hook 41
  [ "$status" -eq 0 ] || { printf 'gate status %s: %s\n' "$status" "$output" >&2; return 1; }
  grep -qF '"permissionDecision": "deny"' <<<"$output" || { printf 'gate did not deny: %s\n' "$output" >&2; return 1; }
}

# prepare_light [--maintainer]: a full clearance, then an owned Markdown-only
# commit inside the cap, routed light.
prepare_light() {
  lsb_init "$@"
  lsb_full_clearance "$FRONTEND"
  lsb_commit frontend/app/notes.md "$(printf 'one\ntwo\nthree')"
  lsb_route "$FRONTEND"
  expect_light_eligible
}

# clear_through_light: the canned clear reply fed through the light-marker
# script, the way the unit feeds the real reviewer's reply.
clear_through_light() {
  lsb_clear_reply "$FRONTEND" >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
}

escalate_through_light() {
  lsb_escalate_reply "$FRONTEND" >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
}

# --- routing outcomes ------------------------------------------------------------

@test "on a first dispatch whose route is full no reviewer input is written, and a member that has no quick route gets none either" {
  lsb_init
  lsb_commit frontend/app/notes.md "one line"
  lsb_route "$FRONTEND"
  expect_full quick-path
  local merge_base record
  merge_base="$(lsb_git merge-base refs/remotes/origin/main HEAD)" || return 1
  record="$(light_directory)/$(lsb_member_digest "$FRONTEND").$FRONTEND.route.json"
  [ "$(jq -r '.anchor_kind + " " + .anchor_sha' "$record")" = "merge-base $merge_base" ] \
    || { jq -c . "$record" >&2; return 1; }
  [ ! -e "$(route_input_path)" ]
  find "$(light_directory)" -name '*.input.md' 2>/dev/null | grep -q . && return 1
  lsb_route code-audit-maintainer-shell
  expect_full no-full-clearance
  find "$(light_directory)" -name '*.input.md' 2>/dev/null | grep -q . && return 1
  true
}

# --- the first-dispatch quick route, end to end ------------------------------------

QUICK_ENGLISH="frontend/app/languages/en/common.ts"
QUICK_JAPANESE="frontend/app/languages/ja/common.ts"
QUICK_DIALOG="frontend/app/components/ui/dialog.tsx"
QUICK_CONSUMER="frontend/app/components/confirm-dialog/index.tsx"
QUICK_STORY="frontend/app/components/confirm-dialog/tests/index.stories.tsx"

# quick_locale_text <title>: a one-key language file.
quick_locale_text() {
  printf 'export default {\n  title: '"'"'%s'"'"',\n};' "$1"
}

quick_dialog_text() {
  cat <<'EOF'
import {cn} from 'cn';

const DialogContent = ({className}: {className?: string}) => (
  <div className={cn('fixed', className)} />
);

const DialogHeader = ({className}: {className?: string}) => (
  <div className={cn('flex', className)} />
);

export {DialogContent, DialogHeader};
EOF
}

# quick_consumer_text <content-tokens> <header-tokens> <span-token>
quick_consumer_text() {
  cat <<EOF
import {cn} from 'cn';
import {DialogContent, DialogHeader} from '../ui/dialog';

const ConfirmDialog = () => (
  <DialogContent
    className="$1"
  >
    <DialogHeader
      className="$2"
    >
      Confirm
    </DialogHeader>
    <span className={cn('$3', 'py-1')}>Body</span>
  </DialogContent>
);

export default ConfirmDialog;
EOF
}

# quick_story_text <label>
quick_story_text() {
  cat <<EOF
import type {Meta, StoryObj} from '@storybook/react-vite';
import ConfirmDialog from '..';

const meta: Meta<typeof ConfirmDialog> = {
  component: ConfirmDialog,
  title: 'Components/ConfirmDialog',
};

export default meta;

type Story = StoryObj<typeof ConfirmDialog>;

export const Default: Story = {
  args: {
    label: '$1',
  },
};
EOF
}

record_for_frontend() {
  printf '%s/%s.%s.route.json' "$(light_directory)" "$(lsb_member_digest "$FRONTEND")" "$FRONTEND"
}

@test "the landing-page string change routes light quick-eligible on a first dispatch, a clean reply clears it and the merge gate passes on that marker alone" {
  lsb_init
  lsb_main_base_begin
  lsb_commit "$QUICK_ENGLISH" "$(quick_locale_text Hello)"
  lsb_commit "$QUICK_JAPANESE" "$(quick_locale_text こんにちは)"
  lsb_main_base_end
  lsb_commit "$QUICK_ENGLISH" "$(quick_locale_text Welcome)"
  lsb_commit "$QUICK_JAPANESE" "$(quick_locale_text ようこそ)"
  assert_gate_denies
  lsb_route "$FRONTEND"
  expect_line "$(printf 'light\tquick-eligible')"
  grep -qxF 'anchor_kind: merge-base' "$(route_input_path)"
  [ "$(jq -r .anchor_kind "$(record_for_frontend)")" = "merge-base" ]
  clear_through_light
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review] | join(" ")' "$(marker_path)")" = "earned light" ]
  [ "$(find "$(audit_directory)" -maxdepth 1 -name '*.ok' | wc -l | tr -d ' ')" = "1" ]
  assert_gate_allows
}

@test "a dialog-wrapper change with its own story routes light quick-eligible, clears on a clean reply and the story did not trip the test floor" {
  lsb_init
  lsb_main_base_begin
  lsb_commit "$QUICK_DIALOG" "$(quick_dialog_text)"
  lsb_commit "$QUICK_CONSUMER" "$(quick_consumer_text 'max-w-md p-4' 'gap-2 text-left' px-2)"
  lsb_commit "$QUICK_STORY" "$(quick_story_text Save)"
  lsb_main_base_end
  lsb_commit "$QUICK_CONSUMER" "$(quick_consumer_text 'max-w-lg p-6' 'gap-3 text-left' px-3)"
  lsb_commit "$QUICK_STORY" "$(quick_story_text Confirm)"
  [ "$(lsb_git diff --numstat refs/remotes/origin/main HEAD | awk '{ total += $1 + $2 } END { print (total <= 40) }')" = "1" ]
  assert_gate_denies
  lsb_route "$FRONTEND"
  expect_line "$(printf 'light\tquick-eligible')"
  [ "$(jq -c '[.hard_full_rule, .anchor_kind]' "$(record_for_frontend)")" = '[null,"merge-base"]' ]
  grep -qF "$QUICK_STORY" "$(route_input_path)"
  clear_through_light
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review] | join(" ")' "$(marker_path)")" = "earned light" ]
  [ "$(find "$(audit_directory)" -maxdepth 1 -name '*.ok' | wc -l | tr -d ' ')" = "1" ]
  assert_gate_allows
}

# bats test_tags=whole-tree
@test "the corpus dialog layout and copy change routes light quick-eligible and a clean reply marked with the reviewer dispatch time clears it" {
  local corpus="$REPO_ROOT/.gaia/scripts/tests/fixtures/audit-quick-corpus.json" file_path index file_count
  file_count="$(jq '[.entries[] | select(.id == "dialog-layout-and-copy")][0].files | length' "$corpus")"
  [ "$file_count" -gt 0 ]
  lsb_init
  lsb_main_base_begin
  index=0
  while [ "$index" -lt "$file_count" ]; do
    file_path="$(jq -r --argjson index "$index" '[.entries[] | select(.id == "dialog-layout-and-copy")][0].files[$index].path' "$corpus")"
    lsb_commit "$file_path" "$(jq -r --argjson index "$index" '[.entries[] | select(.id == "dialog-layout-and-copy")][0].files[$index].before' "$corpus")"
    index=$((index + 1))
  done
  lsb_main_base_end
  index=0
  while [ "$index" -lt "$file_count" ]; do
    file_path="$(jq -r --argjson index "$index" '[.entries[] | select(.id == "dialog-layout-and-copy")][0].files[$index].path' "$corpus")"
    lsb_commit "$file_path" "$(jq -r --argjson index "$index" '[.entries[] | select(.id == "dialog-layout-and-copy")][0].files[$index].after' "$corpus")"
    index=$((index + 1))
  done
  assert_gate_denies
  lsb_route "$FRONTEND"
  expect_line "$(printf 'light\tquick-eligible')"
  [ "$(jq -r .anchor_kind "$(record_for_frontend)")" = "merge-base" ]
  lsb_clear_reply "$FRONTEND" >"$REPLY_FILE"
  run bash "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" --root "$LSB_ROOT" --member "$FRONTEND" --verdict "$REPLY_FILE" \
    --reviewer-dispatched-at 2020-01-01T00:00:00Z </dev/null
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review] | join(" ")' "$(marker_path)")" = "earned light" ]
  local ledger_line
  ledger_line="$(tail -n 1 "$(light_directory)/$LSB_SLUG.reviews.jsonl")"
  jq -e '.reviewer_dispatched_at == "2020-01-01T00:00:00Z"
    and (.marked_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .anchor_kind == "merge-base"' <<<"$ledger_line" >/dev/null
  assert_gate_allows
}

@test "a quick route whose reply carries a minor note is refused, the router still sends the delta to the reviewer, and the merge gate keeps denying" {
  lsb_init
  lsb_main_base_begin
  lsb_commit "$QUICK_ENGLISH" "$(quick_locale_text Hello)"
  lsb_commit "$QUICK_JAPANESE" "$(quick_locale_text こんにちは)"
  lsb_main_base_end
  lsb_commit "$QUICK_ENGLISH" "$(quick_locale_text Welcome)"
  lsb_commit "$QUICK_JAPANESE" "$(quick_locale_text ようこそ)"
  lsb_route "$FRONTEND"
  expect_line "$(printf 'light\tquick-eligible')"
  lsb_clear_reply "$FRONTEND" | jq -c '.files[0].note = "Minor: wording"' >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-malformed
  assert_no_marker
  lsb_route "$FRONTEND" --check
  expect_line "$(printf 'light\tquick-eligible')"
  assert_gate_denies
  clear_through_light
  expect_line "light-cleared"
  assert_gate_allows
}

@test "a clear reply after a full clearance and a small owned Markdown commit clears light, and the merge gate allows it" {
  lsb_init
  lsb_full_clearance "$FRONTEND"
  [ "$(jq -r .review "$(marker_path)")" = "full" ]
  lsb_commit frontend/app/notes.md "$(printf 'one\ntwo\nthree')"
  assert_gate_denies
  lsb_route "$FRONTEND"
  expect_light_eligible
  [ -f "$(route_input_path)" ]
  clear_through_light
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review, .tree] | join(" ")' "$(marker_path)")" = "earned light $LSB_TREE" ]
  local light_sidecars
  light_sidecars="$(find "$(audit_directory)" -maxdepth 1 -name "*.$FRONTEND.light.findings.json")"
  [ "$(printf '%s\n' "$light_sidecars" | grep -c .)" = "1" ]
  [ "$(jq -r .review "$light_sidecars")" = "light" ]
  assert_gate_allows
}

@test "a refused branch repaired by a small delta clears light against the refusal's findings, and the merge gate allows it" {
  lsb_init
  lsb_commit_lines frontend/app/notes.md 5 line
  lsb_refuse_with_findings "$FRONTEND" "[$(lsb_finding frontend/app/notes.md 2 major false)]"
  assert_gate_denies
  lsb_commit_lines frontend/app/notes.md 5 fixed
  assert_gate_denies
  lsb_route "$FRONTEND"
  expect_line "$(printf 'light\trefusal-anchored')"
  grep -qxF 'open_findings: 1' "$(route_input_path)"
  clear_through_light
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review] | join(" ")' "$(marker_path)")" = "earned light" ]
  assert_gate_allows
}

@test "the same repair with the cited line left as it was is refused and the merge gate keeps denying" {
  lsb_init
  lsb_commit_lines frontend/app/notes.md 5 line
  lsb_refuse_with_findings "$FRONTEND" "[$(lsb_finding frontend/app/notes.md 2 major false)]"
  lsb_commit frontend/app/notes.md "$(printf 'line 1\nline 2\nline 3\nline 4\nchanged 5')"
  lsb_route "$FRONTEND"
  expect_line "$(printf 'light\trefusal-anchored')"
  clear_through_light
  expect_full checklist-unchanged
  assert_no_marker
  assert_gate_denies
}

@test "an escalate reply leaves no marker for the current digest and the merge gate denies" {
  prepare_light
  escalate_through_light
  expect_full escalate
  assert_no_marker
  assert_gate_denies
}

@test "an empty reply and a non-JSON reply each route full verdict-noop; the gate allows only after the real writer clears the member" {
  prepare_light
  lsb_mark "$FRONTEND" ""
  expect_full verdict-noop
  assert_no_marker
  printf 'The change looks fine to me.\n' >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-noop
  assert_no_marker
  assert_gate_denies
  lsb_full_clearance "$FRONTEND"
  [ "$(jq -r .review "$(marker_path)")" = "full" ]
  assert_gate_allows
}

@test "a reply that is JSON but not a verdict never earns a marker and leaves the gate denying" {
  prepare_light
  printf '{"schema":1,"verdict":"clear"}\n' >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  [ "$status" -eq 0 ]
  case "$output" in
    "$(printf 'full\t')"*) ;;
    *) printf 'want a full route, got: %s\n' "$output" >&2; return 1 ;;
  esac
  assert_no_marker
  assert_gate_denies
}

# --- anchoring ---------------------------------------------------------------------

@test "after a full clearance at one tree and a light clear at the next, a full-routed commit resolves its base at the full tree" {
  lsb_init
  lsb_full_clearance "$FRONTEND"
  local anchor_commit="$LSB_HEAD" anchor_tree="$LSB_TREE"
  lsb_commit frontend/app/notes.md "$(printf 'one\ntwo\nthree')"
  local light_commit="$LSB_HEAD"
  lsb_route "$FRONTEND"
  expect_light_eligible
  clear_through_light
  expect_line "light-cleared"
  [ "$(jq -r .tree "$(marker_path)")" != "$anchor_tree" ]
  lsb_commit frontend/app/feature.test.ts "export const covered = true;"
  lsb_route "$FRONTEND"
  expect_full hard-full
  run bash -c 'cd "$1" && bash .github/audit/resolve-audit-base.sh --member "$2" 2>/dev/null' _ "$LSB_ROOT" "$FRONTEND"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$first_line" = "$anchor_commit" ] || { printf 'want %s, got: %s\n' "$anchor_commit" "$output" >&2; return 1; }
  [ "$first_line" != "$light_commit" ]
  [ "$(lsb_git rev-parse "$first_line^{tree}")" = "$anchor_tree" ]
}

# --- rounds record -------------------------------------------------------------------

@test "after one light clear and one escalate the rounds record names the light reviews and leaves the total at the recorded rounds" {
  local values_file="$BATS_TEST_TMPDIR/values.json" body_in="$BATS_TEST_TMPDIR/body-in.md" body_out="$BATS_TEST_TMPDIR/body-out.md"
  lsb_init
  lsb_full_clearance "$FRONTEND"
  lsb_seed_loop_state "$FRONTEND"
  # Before any light review the state alone carries no light key.
  run bash "$LSB_ROOT/.gaia/scripts/audit-loop-eval.sh" record-values --root "$LSB_ROOT"
  [ "$status" -eq 0 ]
  [ "$(jq -c 'has("light")' <<<"$output")" = "false" ]
  local total_before
  total_before="$(jq -r .total <<<"$output")"
  [ "$total_before" = "1" ]

  lsb_commit frontend/app/notes.md "$(printf 'one\ntwo\nthree')"
  lsb_route "$FRONTEND"
  expect_light_eligible
  clear_through_light
  expect_line "light-cleared"
  lsb_commit frontend/app/more.md "more"
  lsb_route "$FRONTEND"
  expect_light_eligible
  escalate_through_light
  expect_full escalate

  run bash "$LSB_ROOT/.gaia/scripts/audit-loop-eval.sh" record-values --root "$LSB_ROOT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$values_file"
  [ "$(jq -r '.light["code-audit-frontend"]' "$values_file")" = "2" ]
  [ "$(jq -r .total "$values_file")" = "$total_before" ]
  printf 'Body text.\n' >"$body_in"
  run bash "$LSB_ROOT/.gaia/scripts/audit-loop-record.sh" --pr 1 --values-json - --body-in "$body_in" --body-out "$body_out" <"$values_file"
  [ "$status" -eq 0 ] || { printf 'record: %s\n' "$output" >&2; return 1; }
  grep -qF 'light reviews: code-audit-frontend 2' "$body_out"
  grep -qF "Total rounds: $total_before;" "$body_out"
}

# --- telemetry ---------------------------------------------------------------------------

@test "in a maintainer sandbox the light-clear chain leaves a route event and a self-contained light_outcome event with equal values" {
  prepare_light --maintainer
  clear_through_light
  expect_line "light-cleared"
  [ "$(jq -r 'select(.event == "route") | .event' "$(telemetry_log)" | grep -c .)" = "1" ]
  [ "$(jq -r 'select(.event == "light_outcome") | .event' "$(telemetry_log)" | grep -c .)" = "1" ]
  local route_event outcome_event field
  route_event="$(jq -c 'select(.event == "route")' "$(telemetry_log)")"
  outcome_event="$(jq -c 'select(.event == "light_outcome")' "$(telemetry_log)")"
  for field in member digest route reason lines files; do
    [ "$(jq -c ".$field" <<<"$outcome_event")" != "null" ] || { printf 'outcome %s is null: %s\n' "$field" "$outcome_event" >&2; return 1; }
    [ "$(jq -c ".$field" <<<"$outcome_event")" = "$(jq -c ".$field" <<<"$route_event")" ] ||
      { printf 'outcome and route disagree on %s\n' "$field" >&2; return 1; }
  done
  [ "$(jq -r .verdict <<<"$outcome_event")" = "clear" ]
  [ "$(jq -r .member <<<"$outcome_event")" = "$FRONTEND" ]
  [ "$(jq -r .digest <<<"$outcome_event")" = "$(lsb_member_digest "$FRONTEND")" ]
  [ "$(jq -r .route <<<"$outcome_event")" = "light" ]
  [ "$(jq -r .reason <<<"$outcome_event")" = "light-eligible" ]
  [ "$(jq -r .files <<<"$outcome_event")" = "1" ]
}

@test "an escalation followed by a refusal and two findings from the member counts toward escalation precision" {
  prepare_light --maintainer
  escalate_through_light
  expect_full escalate
  local findings_base
  findings_base="$(cd "$LSB_ROOT" && bash .github/audit/resolve-audit-base.sh --member "$FRONTEND" 2>/dev/null | sed -n '3p')"
  findings_base="$(lsb_git merge-base "$findings_base" HEAD)"
  bash "$LSB_ROOT/.gaia/scripts/audit-write-clearance.sh" --root "$LSB_ROOT" --member "$FRONTEND" --provenance refused >/dev/null
  jq -n -c '[range(1; 3) | {finding_class: "holistic/example", severity: "major", path: "frontend/app/notes.md", line: .,
    title: "a defect", failure_mode: "input and state give a wrong outcome", verified_by: "ran it", suggested_fix: "repair it"}]' |
    bash "$LSB_ROOT/.gaia/scripts/audit-write-findings.sh" --root "$LSB_ROOT" --member "$FRONTEND" --base "$findings_base" --findings - >/dev/null
  run bash "$(telemetry_script)" member-result --root "$LSB_ROOT" --member "$FRONTEND"
  [ "$status" -eq 0 ]
  local followup_event
  followup_event="$(jq -c 'select(.event == "escalation_followup")' "$(telemetry_log)")"
  [ -n "$followup_event" ]
  [ "$(jq -r .result <<<"$followup_event")" = "refused" ]
  [ "$(jq -r .findings <<<"$followup_event")" = "2" ]
  [ "$(jq -r .route_digest <<<"$followup_event")" = "$(lsb_member_digest "$FRONTEND")" ]
  run bash "$(telemetry_script)" tally --root "$LSB_ROOT"
  [ "$status" -eq 0 ]
  [ "$(awk -F': ' '$1 == "escalation_precision" { print $2 }' <<<"$output")" = "1.00" ]
}

@test "an escalation followed by a cleared member records a followup that tally does not count as precise" {
  prepare_light --maintainer
  escalate_through_light
  lsb_full_clearance "$FRONTEND"
  run bash "$(telemetry_script)" member-result --root "$LSB_ROOT" --member "$FRONTEND"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event == "escalation_followup") | .result' "$(telemetry_log)")" = "cleared" ]
  run bash "$(telemetry_script)" tally --root "$LSB_ROOT"
  [ "$(awk -F': ' '$1 == "escalation_precision" { print $2 }' <<<"$output")" = "0.00" ]
}

# --- the release shape --------------------------------------------------------------------

@test "an adopter sandbox built as a release ships no reference to the telemetry script and still completes the chain" {
  lsb_init
  # Driven red: the unstripped copy names the telemetry script in the router.
  grep -qF 'audit-light-telemetry.sh' "$LSB_ROOT/.gaia/scripts/audit-light-route.sh"
  [ -n "$(grep -rl 'audit-light-telemetry.sh' "$LSB_ROOT/.gaia/scripts" "$LSB_ROOT/.claude" "$LSB_ROOT/.github" 2>/dev/null)" ]
  [ ! -e "$LSB_ROOT/.claude/rules/maintainers/harness-triage-threshold.md" ]

  lsb_strip_maintainer_only
  [ ! -e "$(telemetry_script)" ]
  local leftovers
  leftovers="$(grep -rl 'audit-light-telemetry.sh' "$LSB_ROOT/.gaia/scripts" "$LSB_ROOT/.claude" "$LSB_ROOT/.github" 2>/dev/null || true)"
  [ -z "$leftovers" ] || { printf 'shipped files still name the telemetry script: %s\n' "$leftovers" >&2; return 1; }
  bash -n "$LSB_ROOT/.gaia/scripts/audit-light-route.sh"
  bash -n "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh"

  lsb_full_clearance "$FRONTEND"
  lsb_commit frontend/app/notes.md "$(printf 'one\ntwo\nthree')"
  lsb_route "$FRONTEND"
  expect_light_eligible
  clear_through_light
  expect_line "light-cleared"
  [ "$(jq -r .review "$(marker_path)")" = "light" ]
  [ ! -e "$(telemetry_log)" ]
}

@test "a telemetry directory that cannot be written still routes light and clears" {
  lsb_init --maintainer
  lsb_full_clearance "$FRONTEND"
  mkdir -p "$(dirname "$(telemetry_log)")"
  chmod 0555 "$(dirname "$(telemetry_log)")"
  [ ! -w "$(dirname "$(telemetry_log)")" ] || skip "the directory stays writable for this user"
  lsb_commit frontend/app/notes.md "$(printf 'one\ntwo\nthree')"
  lsb_route "$FRONTEND"
  expect_light_eligible
  clear_through_light
  expect_line "light-cleared"
  [ "$(jq -r .review "$(marker_path)")" = "light" ]
  [ ! -e "$(telemetry_log)" ]
}

# --- the loop-bound hook ------------------------------------------------------------------

# hook_dispatch <subagent-type>: an Agent dispatch for the sandbox through the
# sandbox's bound hook, with a gh that reports a same-repository pull request.
hook_dispatch() {
  local stub_directory="$BATS_TEST_TMPDIR/hook-gh-bin" payload
  mkdir -p "$stub_directory"
  cat >"$stub_directory/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *isCrossRepository*) printf 'false\n'; exit 0 ;; esac
exit 1
EOF
  chmod +x "$stub_directory/gh"
  payload="$(jq -n -c --arg member "$1" --arg root "$LSB_ROOT" \
    '{session_id: "e2e", hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: $member, prompt: ("Audit the change. Working root: " + $root + ", base main")}}')"
  run env PATH="$stub_directory:$PATH" bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$LSB_ROOT/.claude/hooks/audit-loop-bound.sh"
}

recorded_rounds() {
  jq -r '.history.rounds | length' "$ALF_STATE"
}

@test "a light reviewer dispatch leaves the recorded round count unchanged and the escalated member dispatch on the same tree records one" {
  lsb_init
  lsb_full_clearance "$FRONTEND"
  lsb_seed_loop_state "$FRONTEND"
  [ "$(recorded_rounds)" = "1" ]
  # The seeded round sits at the full clearance's tree; the light delta is a new one.
  lsb_commit frontend/app/notes.md "$(printf 'one\ntwo\nthree')"
  lsb_route "$FRONTEND"
  expect_light_eligible
  hook_dispatch audit-light-reviewer
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf 'light dispatch was not allowed: %s\n' "$output" >&2; return 1; }
  [ "$(recorded_rounds)" = "1" ]
  escalate_through_light
  expect_full escalate
  hook_dispatch "$FRONTEND"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf 'member dispatch was not allowed: %s\n' "$output" >&2; return 1; }
  [ "$(recorded_rounds)" = "2" ]
  [ "$(jq -r '.history.rounds[1].members | join(",")' "$ALF_STATE")" = "$FRONTEND" ]
}

@test "after a clean catch-up the base's content is trusted and the small branch commit clears light and passes the gate" {
  lsb_init
  lsb_catchup_init
  lsb_full_clearance "$FRONTEND"
  lsb_catchup_base_commit frontend/public/sw.js "self.x = 1"
  lsb_catch_up
  assert_gate_allows
  lsb_catchup_branch_commit frontend/app/notes.md "$(printf 'one\ntwo\nthree')"
  assert_gate_denies
  lsb_route "$FRONTEND"
  expect_light_eligible
  grep -qF 'frontend/public/sw.js' "$(route_input_path)" && return 1
  clear_through_light
  expect_line "light-cleared"
  assert_gate_allows
}
