#!/usr/bin/env bats
#
# A refused-authored `file` row on an enforcement path, after its round
# closed. A human accept cannot clear it and a veto alone leaves the clean
# stop refused, so the route is the veto's drafted repair: the reopened round's
# fixer edits the path, the unit commits nothing, a human's commit lands it,
# and the next unit's member wave reviews it. The suite plays the unit's and
# the main thread's run-folder writes and commits, since no agent runs, and
# calls the real bound hook and the real dispositions check.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-enforcement-veto.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  HOOK="$REPO_ROOT/.claude/hooks/audit-loop-bound.sh"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS GAIA_AUDIT_LOOP_DEADLINE_SECONDS
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/loop
  MEMBER=code-audit-maintainer-shell
  ENFORCED=.gaia/scripts/audit-fix-verify.sh
  SID=0a1b2c3d-1111-4222-8333-444455556666
  IN_UNIT='{"agent_id":"a0b1c2d3e4f5a6b7c","agent_type":"audit-loop-unit"}'
  STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
  RUN_FOLDER="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  mkdir -p "$STUB_BIN" "$RUN_FOLDER"
  # The bound hook looks the pull request up; none exists.
  printf '#!/bin/bash\necho "no pull requests found" >&2\nexit 1\n' >"$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  printf 'auditors:\n  - name: %s\n    globs:\n      - "**"\n    audience: adopter\n    default: true\n' "$MEMBER" >"$ALF_ROOT/.gaia/audit-ci.yml"
  alf_fill "$ENFORCED" 160 branch
  # The fixture ignores .gaia/, so the enforcement path is force-added.
  alf_git add -f "$ENFORCED"
  alf_commit "edit the verifier"
  alf_round 1 "$MEMBER" "[{\"path\":\"$ENFORCED\",\"line\":140,\"finding_class\":\"holistic/unclassified\",\"severity\":\"major\",\"security\":false}]"
  alf_dispositions 1 "[{\"member\":\"$MEMBER\",\"finding_class\":\"holistic/unclassified\",\"path\":\"$ENFORCED\",\"line\":140,\"disposition\":\"file\",\"reason\":\"pre-existing\"}]"
  jq -n -c --arg member "$MEMBER" --arg path "$ENFORCED" \
    '{key: {member: $member, finding_class: "holistic/unclassified", path: $path, line: 140}, outcome: "refused-authored"}' \
    >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  jq -n -c --arg member "$MEMBER" --arg path "$ENFORCED" \
    '{member: $member, finding_class: "holistic/unclassified", path: $path, line: 140, severity: "major", security: false,
      failure_mode: "deadlock", reason: "human accepts"}' >"$BATS_TEST_TMPDIR/finding.json"
  gaia_context_write "$ALF_ROOT" "$SID" "$((GAIA_CONTEXT_ASK_TOKENS_DEFAULT * 100 / 1000000))" "$((GAIA_CONTEXT_ASK_TOKENS_DEFAULT - 1))" 1000000 "$(date +%s)"
}

check_all() {
  run bash "$SCRIPTS/audit-dispositions-check.sh" check-all --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
}

veto_key() {
  jq -n -c --arg member "$MEMBER" --arg path "$ENFORCED" \
    '{version: 1, keys: [{member: $member, finding_class: "holistic/unclassified", path: $path, line: 140,
       vetoed_at: "2026-01-01T00:00:00Z", unit: 1, effective_from_round: 2}]}' >"$RUN_FOLDER/vetoes.json"
}

# dispatch <subagent-type> [extra-json]: an Agent dispatch through the real bound hook.
dispatch() {
  local extra="${2-}" payload
  [ -n "$extra" ] || extra='{}'
  payload="$(jq -n -c --arg type "$1" --arg session_id "$SID" --arg root "$ALF_ROOT" --argjson extra "$extra" \
    '{session_id: $session_id, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: $type, prompt: ("Run it.\nWorking root: " + $root + "\nUnit: 1\nStart round: 1")}} + $extra')"
  run env PATH="$STUB_BIN:$PATH" bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$HOOK"
}

allowed() {
  [ "$status" -eq 0 ] && [ -z "$output" ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
}

rounds() {
  jq -r '.history.rounds | length' "$ALF_STATE"
}

# veto <satisfied|unsatisfied> <round>: the vetoed key is in that list at round r.
veto() {
  local state
  state="$(bash "$SCRIPTS/audit-loop-eval.sh" veto-state --root "$ALF_ROOT" --round "$2")" || return 1
  [ "$(jq -r --arg want "$1" '.[$want] | length' <<<"$state")" -eq 1 ] || { printf 'veto state at round %s: %s\n' "$2" "$state" >&2; return 1; }
}

# draft_repair: the reopened round 2 as the unit leaves it at its
# enforcement-draft stop: the drafted fix entry, the fixer's `fixed` result,
# and the edit uncommitted.
draft_repair() {
  alf_dispositions 2 "[{\"member\":\"$MEMBER\",\"finding_class\":\"holistic/unclassified\",\"path\":\"$ENFORCED\",\"line\":140,\"disposition\":\"fix\",\"reason\":\"vetoed\",\"enforcement_draft\":true}]"
  jq -n -c --arg member "$MEMBER" --arg path "$ENFORCED" '{schema: 1, round: 2, attempt: 1,
    results: [{member: $member, finding_class: "holistic/unclassified", path: $path, line: 140, disposition: "fixed", reason: "done", changed_paths: [$path]}],
    changed_paths: [$path], reverted_paths: []}' >"$RUN_FOLDER/fixer-2-audit.json"
  alf_set_line "$ENFORCED" 140 repaired
}

# review_round <entries-json>: the next unit's member wave on the committed tree,
# recorded as round 3 with the owner's findings.
review_round() {
  dispatch audit-loop-unit
  allowed || return 1
  [ "$(rounds)" -eq 2 ] || { printf 'the unit reopened another round: %s\n' "$(rounds)" >&2; return 1; }
  dispatch "$MEMBER" "$IN_UNIT"
  allowed || return 1
  [ "$(rounds)" -eq 3 ] || return 1
  alf_stamp 3 30
  alf_sidecar "$MEMBER" "$1" 31
  alf_dispositions 3 '[]'
}

@test "the closed round's refused-authored row fails check-all, and a human accept on it is refused" {
  check_all
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"violation: refused-authored"* ]] || return 1
  run bash "$SCRIPTS/audit-dispositions-check.sh" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" \
    --finding "$BATS_TEST_TMPDIR/finding.json" --decision accept
  [ "$status" -eq 3 ] || return 1
  check_all
  [[ "$output" == *"violation: refused-authored"* ]]
}

@test "drafted repair: the human's commit lands it, the next unit opens no second reopened round, and the owner's clean review clears check-all" {
  veto_key
  dispatch audit-loop-unit
  allowed || return 1
  [ "$(jq -r '.history.rounds[1].reopened' "$ALF_STATE")" = true ] || return 1
  draft_repair
  veto unsatisfied 2 || return 1
  alf_commit "fix(audit): commit the drafted enforcement repair"
  review_round '[]' || return 1
  veto satisfied 3 || return 1
  check_all
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

# bats test_tags=protected
@test "drafted repair in an enforcement repair path another member owns: the human's commit of the draft lands it, and the veto stays unsatisfied until the repair path's owner, not only the key's member, reviews it clean" {
  local settings=.claude/settings.json key_path=lib/notes.sh repair_owner=code-audit-shell
  # The veto is keyed on a file outside ENFORCEMENT_PATHS that MEMBER owns,
  # and its repair lands in an enforcement path repair_owner owns, so MEMBER's
  # clean review alone must not satisfy it.
  printf 'auditors:\n  - name: %s\n    globs:\n      - "%s"\n    audience: adopter\n  - name: %s\n    globs:\n      - "**"\n    audience: adopter\n    default: true\n' \
    "$repair_owner" "$settings" "$MEMBER" >"$ALF_ROOT/.gaia/audit-ci.yml"
  alf_fill "$key_path" 160 branch
  alf_fill "$settings" 4 settings
  alf_git add -f "$key_path" "$settings"
  alf_commit "add the key file and the settings file"
  alf_state_edit '.history.rounds[0].tree = $tree | .history.rounds[0].commit = $commit' --arg tree "$ALF_TREE" --arg commit "$ALF_COMMIT"
  alf_sidecar "$MEMBER" "[{\"path\":\"$key_path\",\"line\":140,\"finding_class\":\"holistic/unclassified\",\"severity\":\"major\",\"security\":false}]" 11
  alf_dispositions 1 "[{\"member\":\"$MEMBER\",\"finding_class\":\"holistic/unclassified\",\"path\":\"$key_path\",\"line\":140,\"disposition\":\"file\",\"reason\":\"pre-existing\"}]"
  jq -n -c --arg member "$MEMBER" --arg path "$key_path" \
    '{key: {member: $member, finding_class: "holistic/unclassified", path: $path, line: 140}, outcome: "refused-authored"}' \
    >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  jq -n -c --arg member "$MEMBER" --arg path "$key_path" --arg repair "$settings" \
    '{member: $member, finding_class: "holistic/unclassified", path: $path, line: 140, severity: "major", security: false,
      failure_mode: "deadlock", reason: "add the allow entry", repair_paths: [$repair]}' >"$BATS_TEST_TMPDIR/repair.json"
  run bash "$SCRIPTS/audit-dispositions-check.sh" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" \
    --finding "$BATS_TEST_TMPDIR/repair.json" --decision fix
  [ "$status" -eq 0 ] || { printf 'the enforcement repair path was refused: %s\n' "$output" >&2; return 1; }
  [ "$(jq -c '.keys | map(.repair_paths)' "$RUN_FOLDER/vetoes.json")" = "[[\"$settings\"]]" ] || return 1
  dispatch audit-loop-unit
  allowed || return 1
  alf_dispositions 2 "[{\"member\":\"$MEMBER\",\"finding_class\":\"holistic/unclassified\",\"path\":\"$key_path\",\"line\":140,\"disposition\":\"fix\",\"reason\":\"vetoed\",\"repair_paths\":[\"$settings\"],\"enforcement_draft\":true}]"
  alf_set_line "$settings" 2 allowed
  veto unsatisfied 2 || return 1
  alf_commit "fix(audit): commit the drafted settings repair"
  dispatch audit-loop-unit
  allowed || return 1
  dispatch "$MEMBER" "$IN_UNIT"
  allowed || return 1
  [ "$(rounds)" -eq 3 ] || return 1
  alf_stamp 3 30
  alf_sidecar "$MEMBER" '[]' 31
  # The key's reviewer reported nothing, but the repair path's owner was not dispatched.
  veto unsatisfied 3 || return 1
  dispatch "$repair_owner" "$IN_UNIT"
  allowed || return 1
  alf_sidecar "$repair_owner" '[]' 32
  veto satisfied 3 || return 1
  alf_dispositions 3 '[]'
  check_all
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "drafted repair red twin: with no human commit the member wave joins the reopened round and the veto stays unsatisfied" {
  veto_key
  dispatch audit-loop-unit
  allowed || return 1
  draft_repair
  dispatch audit-loop-unit
  allowed || return 1
  dispatch "$MEMBER" "$IN_UNIT"
  allowed || return 1
  [ "$(rounds)" -eq 2 ] || return 1
  alf_sidecar "$MEMBER" '[]' 21
  veto unsatisfied 2
}

@test "drafted repair red twin: an owner re-report of the repaired line leaves the veto unsatisfied and check-all failing" {
  veto_key
  dispatch audit-loop-unit
  allowed || return 1
  draft_repair
  alf_commit "fix(audit): commit the drafted enforcement repair"
  review_round "[{\"path\":\"$ENFORCED\",\"line\":140,\"finding_class\":\"holistic/unclassified\",\"severity\":\"major\",\"security\":false}]" || return 1
  veto unsatisfied 3 || return 1
  check_all
  [ "$status" -eq 1 ]
}
