#!/usr/bin/env bats
#
# Flow test: a `fix` finding of the PR review on an owned file reaches the next
# audit unit as a veto. After a clean audit unit, route-fix writes the veto key
# and names the owner, the bound hook then admits the next unit although every
# clearance holds and reopens a round for the repair, the owner's clean review
# of the repaired tree satisfies the key, and only then does `fixed` record the
# finding. The suite plays the unit's and the main thread's run-folder writes
# and commits, since no agent runs, and calls the real record script, the real
# bound hook and the real evaluator.
#
# Maintainer-only. `.gaia/tests` is release-excluded, so this never reaches an
# adopter.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/pr-review-handover.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  HOOK="$REPO_ROOT/.claude/hooks/audit-loop-bound.sh"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS GAIA_AUDIT_LOOP_DEADLINE_SECONDS
  export CLAUDE_CODE_ENTRYPOINT=cli
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/loop
  MEMBER=code-audit-frontend
  OWNED=src/a.sh
  SID=0a1b2c3d-1111-4222-8333-444455556666
  IN_UNIT='{"agent_id":"a0b1c2d3e4f5a6b7c","agent_type":"audit-loop-unit"}'
  STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
  RUN_FOLDER="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  mkdir -p "$STUB_BIN" "$RUN_FOLDER"
  # The bound hook looks the pull request up; none exists.
  printf '#!/bin/bash\necho "no pull requests found" >&2\nexit 1\n' >"$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  printf 'auditors:\n  - name: %s\n    globs:\n      - "src/**"\n    audience: adopter\n' "$MEMBER" >"$ALF_ROOT/.gaia/audit-ci.yml"
  alf_fill "$OWNED" 6 feature
  alf_commit "feature"
  HEAD_SHA="$ALF_COMMIT"
  BUNDLE="$BATS_TEST_TMPDIR/bundle"
  mkdir -p "$BUNDLE"
  printf '%s\n' "$OWNED" >"$BUNDLE/changed-files.txt"
  jq -n -c --arg head "$HEAD_SHA" '{pr: 7, reviewed_head: $head, base: "main", spec: "present",
    spec_author_not_collaborator: false, changelog_present: true, template_present: false}' >"$BUNDLE/meta.json"
  FINDINGS="$BATS_TEST_TMPDIR/findings.json"
  gaia_context_write "$ALF_ROOT" "$SID" "$((GAIA_CONTEXT_ASK_TOKENS_DEFAULT * 100 / 1000000))" "$((GAIA_CONTEXT_ASK_TOKENS_DEFAULT - 1))" 1000000 "$(date +%s)"
}

# record <subcommand> [args...]: the record script on the run folder.
record() {
  run bash "$SCRIPTS/pr-review-record.sh" "$@" --run-folder "$RUN_FOLDER"
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

@test "a fix finding on an owned file is vetoed, reopens the next audit unit's round, is satisfied by the owner's clean review, and only then is recorded fixed" {
  # A clean audit unit: one round, the owner reported nothing, nothing disposed.
  alf_round 1 "$MEMBER" '[]' || return 1
  alf_dispositions 1 '[]'
  # The review opens, ingests one Major finding on the owned script, and it is disposed fix.
  record open --root "$ALF_ROOT" --pr 7 --head "$HEAD_SHA" --bundle "$BUNDLE"
  [ "$status" -eq 0 ] || return 1
  record attempt-open
  [ "$status" -eq 0 ] || return 1
  jq -n -c --arg file "$OWNED" '[{file: $file, line: 3, severity: "Major", summary: "the guard is inverted",
    failure_scenario: "the failing input", verified: true, security: false}]' >"$FINDINGS"
  record outcome --findings "$FINDINGS"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  record dispose --id pr-1 --disposition fix
  [ "$status" -eq 0 ] || return 1
  [ "$(rounds)" -eq 1 ] || return 1
  [ "$(bash "$SCRIPTS/audit-loop-eval.sh" next-unit --root "$ALF_ROOT")" = "1 2" ] || return 1
  # The route names the owner and writes one key, effective from the next round.
  record route-fix --root "$ALF_ROOT" --id pr-1
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "veto $MEMBER" ] || return 1
  [ "$(jq -c '.keys | map([.member, .finding_class, .path, .line, .effective_from_round])' "$RUN_FOLDER/vetoes.json")" = \
    "[[\"pr-reviewer\",\"pr-review/pr-1\",\"$OWNED\",3,2]]" ] || return 1
  # The finding is not fixed while its veto is unsatisfied.
  record fixed --root "$ALF_ROOT" --id pr-1
  [ "$status" -eq 1 ] || return 1
  # The next unit is admitted although every clearance holds, and the veto reopens a round on the unmoved tree.
  dispatch audit-loop-unit
  allowed || return 1
  [ "$(rounds)" -eq 2 ] || return 1
  [ "$(jq -r '.history.rounds[1].reopened' "$ALF_STATE")" = true ] || return 1
  [ "$(bash "$SCRIPTS/audit-loop-eval.sh" reopened-round --root "$ALF_ROOT")" = 2 ] || return 1
  veto unsatisfied 2 || return 1
  # The unit's fixer repairs the line and the repair is committed.
  alf_dispositions 2 "[{\"member\":\"pr-reviewer\",\"finding_class\":\"pr-review/pr-1\",\"path\":\"$OWNED\",\"line\":3,\"disposition\":\"fix\",\"reason\":\"vetoed\"}]"
  jq -n -c --arg path "$OWNED" '{schema: 1, round: 2, attempt: 1,
    results: [{member: "pr-reviewer", finding_class: "pr-review/pr-1", path: $path, line: 3, disposition: "fixed", reason: "done", changed_paths: [$path]}],
    changed_paths: [$path], reverted_paths: []}' >"$RUN_FOLDER/fixer-2-audit.json"
  alf_set_line "$OWNED" 3 repaired
  alf_commit "repair the guard"
  record fixed --root "$ALF_ROOT" --id pr-1
  [ "$status" -eq 1 ] || return 1
  # The owner reviews the repaired tree as round 3 and reports nothing: the key is satisfied.
  dispatch "$MEMBER" "$IN_UNIT"
  allowed || return 1
  [ "$(rounds)" -eq 3 ] || return 1
  alf_stamp 3 30
  alf_sidecar "$MEMBER" '[]' 31
  alf_dispositions 3 '[]'
  veto satisfied 3 || return 1
  record fixed --root "$ALF_ROOT" --id pr-1
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(jq -r '.findings[0].fix_state' "$RUN_FOLDER/pr-review.json")" = fixed ]
}
