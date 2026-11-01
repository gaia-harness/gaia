#!/usr/bin/env bats
#
# End-to-end proof of the reopened round through the real
# .claude/hooks/audit-loop-bound.sh. Each unit has coverage of its own; this
# suite drives the seam between them: a default stop, then a veto or a gate
# failure, with the tree unmoved. It plays the audit loop unit's and the main
# thread's file writes itself (dispositions, fixer results, vetoes, sidecars,
# commits) since no agent runs, and calls the real hook, the real dispositions
# check and the real owed-gate writer. No case calls the evaluator to decide
# an outcome: it reads state and run-folder files.
#
# Every fixture lives under $BATS_TEST_TMPDIR. pnpm is stubbed on PATH, and the
# dev smoke test by a script under the fixture root.
#
# GAIA_LOOP_BOUND_HOOK points the suite at a scratch copy of the hook, which is
# how a mutant is run against it without touching the working file.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-loop-reopen-e2e.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  HOOK="${GAIA_LOOP_BOUND_HOOK:-$REPO_ROOT/.claude/hooks/audit-loop-bound.sh}"
  BOUND_HOOK="$HOOK"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS GAIA_AUDIT_LOOP_DEADLINE_SECONDS
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/loop
  FRONTEND_MEMBER=code-audit-frontend
  SID=0a1b2c3d-1111-4222-8333-444455556666
  IN_UNIT='{"agent_id":"a0b1c2d3e4f5a6b7c","agent_type":"audit-loop-unit"}'
  STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
  GH_STUB_STATE_DIRECTORY="$BATS_TEST_TMPDIR/gh"
  RUN_FOLDER="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  STATE_DIRECTORY="${ALF_STATE%.json}.d"
  mkdir -p "$STUB_BIN" "$GH_STUB_STATE_DIRECTORY" "$RUN_FOLDER"
  # The owed steps: pnpm fails the Playwright step, and the dev smoke test is
  # a script under the fixture root that passes.
  cat >"$STUB_BIN/pnpm" <<'STUB'
#!/bin/bash
case "$*" in *" pw") exit 1 ;; esac
exit 0
STUB
  mkdir -p "$ALF_ROOT/.gaia/scripts"
  printf '#!/bin/bash\nexit 0\n' >"$ALF_ROOT/.gaia/scripts/dev-smoke.sh"
  cat >"$STUB_BIN/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${GH_STUB_DIRECTORY:?}/calls.log"
case "$*" in
  *isCrossRepository*) [ -f "$GH_STUB_DIRECTORY/branch.json" ] || { echo "no pull requests found" >&2; exit 1; }; printf 'false\n'; exit 0 ;;
esac
exit 1
STUB
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/pnpm"
}

# --- payloads and invocation ------------------------------------------------------

# payload <member> <session> [extra-json]: a member dispatch at the fixture root.
payload() {
  local extra="${3-}"
  [ -n "$extra" ] || extra='{}'
  jq -n -c --arg member "$1" --arg session_id "$2" --arg root "$ALF_ROOT" --argjson extra "$extra" \
    '{session_id: $session_id, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: $member, prompt: ("Audit the change. Working root: " + $root + ", base main")}} + $extra'
}

unit_payload() {
  jq -n -c --arg session_id "$1" --arg root "$ALF_ROOT" \
    '{session_id: $session_id, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: "audit-loop-unit",
        prompt: ("Run one audit unit.\nWorking root: " + $root + "\nUnit: 1\nStart round: 1")}}'
}

run_payload() {
  run env PATH="$STUB_BIN:$PATH" GH_STUB_DIRECTORY="$GH_STUB_STATE_DIRECTORY" \
    bash -c 'printf %s "$1" | "${GAIA_TEST_HOOK_BASH:-bash}" "$2"' _ "$1" "$HOOK"
}

# unit_dispatch: an audit-loop-unit dispatch from the main thread.
unit_dispatch() {
  run_payload "$(unit_payload "$SID")"
}

# nested: a member dispatch made from inside a unit.
nested() {
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$IN_UNIT")"
}

# below: a fresh reading one token under the default context line.
below() {
  gaia_context_write "$ALF_ROOT" "$SID" "$((GAIA_CONTEXT_ASK_TOKENS_DEFAULT * 100 / 1000000))" "$((GAIA_CONTEXT_ASK_TOKENS_DEFAULT - 1))" 1000000 "$(date +%s)"
}

assert_allowed() {
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  [ -z "$output" ] || { printf 'unexpected output: %s\n' "$output" >&2; return 1; }
}

# reason: the decoded deny reason of the last run.
reason() {
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" ||
    { printf 'raw output: %s\n' "$output" >&2; return 1; }
}

# deny_prefix <prefix>: the last run denied with a reason starting <prefix>.
deny_prefix() {
  [ "$status" -eq 0 ] || return 1
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || { printf 'not denied: %s\n' "$output" >&2; return 1; }
  case "$(reason)" in "$1"*) ;; *) printf 'want prefix %s, got: %s\n' "$1" "$(reason)" >&2; return 1 ;; esac
}

state_field() {
  jq -r "$1" "$ALF_STATE"
}

nrounds() {
  state_field '.history.rounds | length'
}

checkpoints() {
  state_field '.history.checkpoints | length'
}

# --- the shared stop ------------------------------------------------------------------

# earn_markers <member>...: give each member's sidecars a member-clearance review
# base and the member an earned marker at HEAD's tree.
earn_markers() {
  local sidecar_file member digest
  for sidecar_file in "$ALF_ROOT"/.gaia/local/audit/*.findings.json; do
    jq -c '.review_base = {sha: ("c" * 40), reason: "member-clearance"}' "$sidecar_file" >"$sidecar_file.edited"
    touch -r "$sidecar_file" "$sidecar_file.edited" && mv "$sidecar_file.edited" "$sidecar_file"
  done
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/audit-clearance.sh"
  for member in "$@"; do
    digest="$(bash "$SCRIPTS/audit-member-digest.sh" --root "$ALF_ROOT" --member "$member" --ref "$ALF_TREE")" || return 1
    jq -n -c --arg digest "$digest" --arg member "$member" '{digest: $digest, member: $member, provenance: "earned"}' \
      >"$(clearance_earned_path "$ALF_ROOT" "$digest" "$member")"
  done
}

# stop_case <all|one>: rounds 1 to 3 of one member, round 3 enriching (a new
# Minor on a line the round's commit repaired) with an incremental review base
# and an earned marker at round 3's tree, so the hook evaluates a real default
# stop over the Minors on f.txt:1, f.txt:2 and f.txt:8 (the Minor on
# base.txt:3 sits outside the branch and is uncounted). `all` accepts all four
# as residuals; `one` accepts only f.txt:1, waives f.txt:2 and f.txt:8 on the
# triage threshold, and fixes the uncounted one, which leaves a single residual.
stop_case() {
  local round entries
  entries='[{"path":"f.txt","line":1,"finding_class":"rule/x","severity":"minor","security":false},
    {"path":"f.txt","line":2,"finding_class":"rule/x","severity":"minor","security":false},
    {"path":"base.txt","line":3,"finding_class":"rule/q","severity":"minor","security":false}]'
  printf 'auditors:\n  - name: code-audit-frontend\n    globs:\n      - "**"\n    audience: adopter\n    default: true\n' >"$ALF_ROOT/.gaia/audit-ci.yml"
  alf_fill f.txt 12 feature
  for round in 1 2 3; do
    alf_set_line other.txt "$round" "round $round"
    if [ "$round" -eq 3 ]; then
      alf_set_line f.txt 8 repaired
      entries="$(jq -c '. + [{"path":"f.txt","line":8,"finding_class":"rule/y","severity":"minor","security":false}]' <<<"$entries")"
    fi
    alf_commit "round $round"
    alf_round "$round" "$FRONTEND_MEMBER" "$entries"
  done
  earn_markers "$FRONTEND_MEMBER"
  if [ "$1" = all ]; then
    alf_dispositions 3 "$(jq -n -c --arg member "$FRONTEND_MEMBER" \
      'def entry($class; $path; $line): {member: $member, finding_class: $class, path: $path, line: $line, disposition: "accept-residual", reason: "minor tail"};
       [entry("rule/x"; "f.txt"; 1), entry("rule/x"; "f.txt"; 2), entry("rule/y"; "f.txt"; 8), entry("rule/q"; "base.txt"; 3)]')"
  else
    alf_dispositions 3 "$(jq -n -c --arg member "$FRONTEND_MEMBER" --arg stop_key "$([ "$1" = fixed ] && echo fix || echo accept-residual)" \
      --arg uncounted "$([ "$1" = fixed ] && echo waive-out-of-scope || echo fix)" \
      'def entry($class; $path; $line; $disposition): {member: $member, finding_class: $class, path: $path, line: $line, disposition: $disposition, reason: "minor tail"}
         + (if $disposition == "waive-out-of-scope" then {basis: "triage-threshold"} else {} end);
       [entry("rule/x"; "f.txt"; 1; $stop_key), entry("rule/x"; "f.txt"; 2; "waive-out-of-scope"),
        entry("rule/y"; "f.txt"; 8; "waive-out-of-scope"), entry("rule/q"; "base.txt"; 3; $uncounted)]')"
  fi
}

# --- run folder writes the unit and the main thread make ----------------------------------

# veto_key <effective-from-round>: veto f.txt:1 (rule/x).
veto_key() {
  jq -n -c --argjson round "$1" \
    '{version: 1, keys: [{member: "code-audit-frontend", finding_class: "rule/x", path: "f.txt", line: 1,
       vetoed_at: "2026-01-01T00:00:00Z", unit: 1, effective_from_round: $round}]}' >"$RUN_FOLDER/vetoes.json"
}

# play_fix <round>: the reopened round's fix as the unit leaves it: a synthetic
# fix entry for the vetoed key no member re-reported, the fixer's `fixed`
# result, and the commit that carries it.
play_fix() {
  alf_dispositions "$1" '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"fix","reason":"vetoed"}]'
  jq -n -c --argjson round "$1" '{schema: 1, round: $round, attempt: 1,
    results: [{member: "code-audit-frontend", finding_class: "rule/x", path: "f.txt", line: 1, disposition: "fixed", reason: "done", changed_paths: ["f.txt"]}],
    changed_paths: ["f.txt"], reverted_paths: []}' >"$RUN_FOLDER/fixer-$1-audit.json"
  alf_set_line f.txt 1 "fixed"
  alf_commit "fix the vetoed key"
}

# round_shape <index>: round <index>'s reopened flag, members, closing flag,
# snapshot and whether its tree is HEAD's.
round_shape() {
  jq -c --argjson index "$1" --arg tree "$ALF_TREE" \
    '.history.rounds[$index] | [.reopened // false, .members, .closing, .snapshot, .tree == $tree]' "$ALF_STATE"
}

# assert_reopened <round>: the latest round is <round>, reopened on HEAD's tree
# with no members, its stamp written, and the latest unit starts there.
assert_reopened() {
  [ "$(nrounds)" -eq "$1" ] || { printf 'rounds: %s, want %s\n' "$(nrounds)" "$1" >&2; return 1; }
  [ "$(round_shape $(($1 - 1)))" = '[true,[],false,null,true]' ] || { printf 'round %s: %s\n' "$1" "$(round_shape $(($1 - 1)))" >&2; return 1; }
  [ -f "$STATE_DIRECTORY/round-$1.stamp" ] || return 1
  [ "$(state_field '.history.units | last | .start_round')" -eq "$1" ]
}

# --- reading the dispositions check -----------------------------------------------------

check_all_read_only() {
  run bash "$SCRIPTS/audit-dispositions-check.sh" check-all --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
}

# residual_count: the one run-wide read the main thread makes, as `total ask`.
residual_count() {
  local counted
  counted="$(bash "$SCRIPTS/audit-dispositions-check.sh" residual-count --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --snapshot-dir "$STATE_DIRECTORY")" || return 1
  jq -r '"\(.total) \(.ask)"' <<<"$counted"
}

# rendered_sections: the pull request sections the merge report carries.
rendered_sections() {
  bash "$SCRIPTS/audit-dispositions-check.sh" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --snapshot-dir "$STATE_DIRECTORY"
}

# heading_lines: the accepted-residual lines under the pr-sections heading,
# withheld ones included.
heading_lines() {
  local rendered shown withheld
  rendered="$(rendered_sections)" || return 1
  shown="$(awk '/^## Accepted residuals/ { reading = 1; next } /^## / { reading = 0 } reading && /^- `/' <<<"$rendered" | wc -l | tr -d ' ')"
  withheld="$(sed -n 's/^- \([0-9]*\) accepted residual(s) withheld.*/\1/p' <<<"$rendered")"
  printf '%s\n' "$((shown + ${withheld:-0}))"
}

# scratch_hook_no_reopen: a copy of the hook that never reopens a round.
scratch_hook_no_reopen() {
  local scratch_directory="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$scratch_directory/.claude/hooks"
  ln -sfn "$REPO_ROOT/.gaia" "$scratch_directory/.gaia"
  ln -sfn "$REPO_ROOT/.claude/hooks/lib" "$scratch_directory/.claude/hooks/lib"
  sed 's/\[ "\$reopen" = true \]/[ "$reopen" = never ]/' "$BOUND_HOOK" >"$scratch_directory/.claude/hooks/audit-loop-bound.sh"
  cmp -s "$BOUND_HOOK" "$scratch_directory/.claude/hooks/audit-loop-bound.sh" && return 1
  HOOK="$scratch_directory/.claude/hooks/audit-loop-bound.sh"
}

# veto_flow <all|one>: the stop, a veto effective at the next round, the reopening
# unit, the fix, a member on the fixed tree (round 5) writing a sidecar without
# the vetoed key, and a second unit dispatch whose dispositions check runs over
# the whole run folder. Leaves the run at round 5.
veto_flow() {
  below
  stop_case "$1"
  veto_key 4
  unit_dispatch
  assert_allowed || return 1
  assert_reopened 4 || return 1
  play_fix 4
  nested
  assert_allowed || return 1
  [ "$(nrounds)" -eq 5 ] || return 1
  alf_stamp 5 50
  alf_sidecar "$FRONTEND_MEMBER" '[{"path":"f.txt","line":2,"finding_class":"rule/x","severity":"minor","security":false},
    {"path":"base.txt","line":3,"finding_class":"rule/q","severity":"minor","security":false}]' 51
  unit_dispatch
  assert_allowed
}

# unit_report <n>: play the unit's report file, whose count is the run-wide
# total at the moment the unit ends.
unit_report() {
  local total
  total="$(residual_count)" || return 1
  jq -n -c --argjson unit "$1" --argjson total "${total%% *}" '{version: 1, unit: $unit, accepted_residual_count: $total}' >"$RUN_FOLDER/unit-$1.json"
}

# summed_unit_counts: what a main thread summing the unit files would report.
summed_unit_counts() {
  jq -s 'map(.accepted_residual_count) | add' "$RUN_FOLDER"/unit-*.json
}

# accepted_keys: the keys the rendered accepted-residual section lists.
accepted_keys() {
  rendered_sections | awk '/^## Accepted residuals/ { reading = 1; next } /^## / { reading = 0 } reading && /^- `/' | sed 's/^- `\([^`]*\)`.*/\1/'
}

@test "veto after a stop: the reopened round takes the fix, the key leaves the accepted residuals and the others stay" {
  local accepted_before
  below
  stop_case all
  [ "$(residual_count)" = "4 4" ] || return 1
  [ "$(heading_lines)" -eq 4 ] || return 1
  unit_report 1 || return 1
  veto_key 4
  unit_dispatch
  assert_allowed || return 1
  assert_reopened 4 || return 1
  [ "$(checkpoints)" -eq 0 ] || return 1
  # The vetoed key is pending: the hook's snapshot call passed it, the read-only call names it.
  check_all_read_only
  [ "$status" -eq 1 ] || return 1
  grep -qxF -- 'violation: undisposed {"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1}' <<<"$output" || return 1
  play_fix 4
  nested
  assert_allowed || return 1
  [ "$(nrounds)" -eq 5 ] || return 1
  [ "$(state_field '.history.rounds[3].snapshot.verdict')" = quiet ] || return 1
  alf_stamp 5 50
  alf_sidecar "$FRONTEND_MEMBER" '[{"path":"f.txt","line":2,"finding_class":"rule/x","severity":"minor","security":false},
    {"path":"base.txt","line":3,"finding_class":"rule/q","severity":"minor","security":false}]' 51
  unit_dispatch
  assert_allowed || return 1
  [ -f "$STATE_DIRECTORY/dispositions-4.checked.json" ] || return 1
  [ "$(jq -r '.entries[0] | [.finding_class, .path, .line, .disposition] | join(" ")' "$RUN_FOLDER/dispositions-4.json")" = "rule/x f.txt 1 fix" ] || return 1
  check_all_read_only
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  accepted_before="$(accepted_keys)"
  grep -qF -- 'f.txt:1' <<<"$accepted_before" && return 1
  for key in f.txt:2 f.txt:8 base.txt:3; do
    grep -qF -- "$key" <<<"$accepted_before" || { printf 'missing %s in: %s\n' "$key" "$accepted_before" >&2; return 1; }
  done
  [ "$(residual_count | cut -d' ' -f1)" -eq 3 ] || return 1
  [ "$(heading_lines)" -eq 3 ] || return 1
  unit_report 2 || return 1
  # The run-wide total is read once. Summing the unit files counts the key the
  # veto removed, so the sum no longer equals the lines under the heading.
  [ "$(summed_unit_counts)" -eq 7 ] || return 1
  [ "$(summed_unit_counts)" -ne "$(heading_lines)" ]
}

@test "veto after a stop with a single residual: the veto fixes it, so the total and the ask are 0 and the section is empty" {
  below
  stop_case one
  [ "$(residual_count)" = "1 1" ] || return 1
  [ "$(heading_lines)" -eq 1 ] || return 1
  veto_key 4
  unit_dispatch
  assert_allowed || return 1
  assert_reopened 4 || return 1
  play_fix 4
  nested
  assert_allowed || return 1
  alf_stamp 5 50
  alf_sidecar "$FRONTEND_MEMBER" '[]' 51
  unit_dispatch
  assert_allowed || return 1
  check_all_read_only
  [ "$status" -eq 0 ] || return 1
  [ "$(residual_count)" = "0 0" ] || return 1
  [ "$(heading_lines)" -eq 0 ] || return 1
  [ -z "$(accepted_keys)" ]
}

@test "veto after a stop: with the reopen disabled in a scratch hook no round holds the veto, the hook's call passes and the read-only check-all fails" {
  below
  stop_case one
  veto_key 4
  scratch_hook_no_reopen || return 1
  unit_dispatch
  assert_allowed || return 1
  [ "$(nrounds)" -eq 3 ] || return 1
  [ "$(state_field '.history.rounds | map(.reopened // false) | any')" = false ] || return 1
  unit_dispatch
  assert_allowed || return 1
  check_all_read_only
  [ "$status" -eq 1 ] || return 1
  grep -qxF -- 'violation: undisposed {"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1}' <<<"$output"
}

# closing_flow: the veto flow's run at round 5 (the vetoed key fixed and absent),
# then a recorded human accept and the closing round 6 on a new commit. Round 6
# reports the findings given as $1; its dispositions are the caller's.
closing_flow() {
  veto_flow one || return 1
  alf_add_checkpoint 5 stalled
  alf_add_answer 1 accept
  alf_set_line other.txt 60 "closing"
  alf_commit "closing round"
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID")"
  assert_allowed || return 1
  [ "$(state_field '.history.rounds[5].closing')" = true ] || return 1
  alf_stamp 6 60
  alf_sidecar "$FRONTEND_MEMBER" "$1" 61
}

X1_ROW='{"path":"f.txt","line":1,"finding_class":"rule/x","severity":"minor","security":false}'
X2_ROW='{"path":"f.txt","line":2,"finding_class":"rule/x","severity":"minor","security":false}'

accept_x2() {
  alf_dispositions 6 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":2,"disposition":"accept-residual","reason":"left for later"}]'
}

run_check() {
  run bash "$SCRIPTS/audit-dispositions-check.sh" check --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --round "$1" --snapshot-dir "$STATE_DIRECTORY"
}

run_check_all_snapshot() {
  run bash "$SCRIPTS/audit-dispositions-check.sh" check-all --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --snapshot-dir "$STATE_DIRECTORY"
}

@test "closing round on a satisfied veto: the key needs no entry through the check, the snapshot call, the read-only call and a later round" {
  closing_flow "[$X2_ROW]" || return 1
  accept_x2
  run_check 6
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(jq -c '.satisfied_vetoes' "$STATE_DIRECTORY/dispositions-6.checked.json")" = '[["code-audit-frontend","rule/x","f.txt",1]]' ] || return 1
  run_check_all_snapshot
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  check_all_read_only
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(jq '[.entries[] | select(.line == 1)] | length' "$RUN_FOLDER/dispositions-6.json")" -eq 0 ] || return 1
  # One later round: the hook stores round 6's snapshot, then round 7 omits the key as well.
  alf_set_line other.txt 70 "later"
  alf_commit "later round"
  alf_store_snapshot 6 || return 1
  alf_add_round "[\"$FRONTEND_MEMBER\"]" || return 1
  alf_stamp 7 70
  alf_sidecar "$FRONTEND_MEMBER" '[]' 71
  alf_dispositions 7 '[]'
  run_check 7
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  run_check_all_snapshot
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  check_all_read_only
  [ "$status" -eq 0 ]
}

@test "closing round on a satisfied veto: a member that reports the key in the closing round fails vetoed-not-fix or undisposed" {
  local key_line='violation: undisposed {"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1}'
  closing_flow "[$X1_ROW, $X2_ROW]" || return 1
  accept_x2
  run_check 6
  [ "$status" -eq 1 ] || return 1
  grep -qxF -- "$key_line" <<<"$output" || { printf '%s\n' "$output" >&2; return 1; }
  alf_dispositions 6 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"accept-residual","reason":"left for later"},
    {"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":2,"disposition":"accept-residual","reason":"left for later"}]'
  run_check 6
  [ "$status" -eq 1 ] || return 1
  grep -qxF -- "${key_line/undisposed/vetoed-not-fix}" <<<"$output"
}

# fail_owed_gate: the real owed-gate writer with a Playwright step that fails.
fail_owed_gate() {
  run env PATH="$STUB_BIN:$PATH" bash "$SCRIPTS/audit-gate-owed.sh" run --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  [ "$status" -eq 1 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  [ "$(jq -r '.step' "$RUN_FOLDER/gate-failure.json")" = pw ] || return 1
  [ "$(jq -r '.tree' "$RUN_FOLDER/gate-failure.json")" = "$(alf_git rev-parse 'HEAD^{tree}')" ]
}

@test "gate failure after a stop: the writer's record reopens a round, the repair carries no entries and the next wave can stop by default" {
  below
  stop_case all
  fail_owed_gate || return 1
  [ "$(jq -r '.after_round' "$RUN_FOLDER/gate-failure.json")" -eq 3 ] || return 1
  unit_dispatch
  assert_allowed || return 1
  assert_reopened 4 || return 1
  alf_dispositions 4 '[]'
  alf_set_line other.txt 4 "gate repair"
  alf_commit "gate repair"
  nested
  assert_allowed || return 1
  [ "$(nrounds)" -eq 5 ] || return 1
  [ "$(state_field '.history.rounds[4].reopened // false')" = false ] || return 1
  [ "$(state_field '.history.rounds[4].members | join(",")')" = "$FRONTEND_MEMBER" ] || return 1
  alf_stamp 5 50
  alf_sidecar "$FRONTEND_MEMBER" '[{"path":"f.txt","line":1,"finding_class":"rule/x","severity":"minor","security":false},
    {"path":"f.txt","line":2,"finding_class":"rule/x","severity":"minor","security":false},
    {"path":"f.txt","line":6,"finding_class":"rule/x","severity":"minor","security":false}]' 51
  earn_markers "$FRONTEND_MEMBER"
  unit_dispatch
  assert_allowed || return 1
  [ "$(state_field '.history.rounds[4].snapshot.default_stop')" = true ] || return 1
  [ "$(checkpoints)" -eq 0 ]
}

@test "gate failure after a closing round reopens nothing and leaves the owed gate refusing the status post" {
  closing_gate_case || return 1
  fail_owed_gate || return 1
  [ "$(jq -r '.after_round' "$RUN_FOLDER/gate-failure.json")" -eq 4 ] || return 1
  unit_dispatch
  [ "$(nrounds)" -eq 4 ] || return 1
  [ "$(state_field '.history.rounds | map(.reopened // false) | any')" = false ] || return 1
  run bash "$SCRIPTS/audit-gate-owed.sh" status --root "$ALF_ROOT"
  [ "$status" -eq 1 ]
}

# closing_gate_case: the stop, then a human accept and a closing round 4 on a
# commit that touches a source file, with the owed gate marked for round 3.
closing_gate_case() {
  below
  stop_case all
  alf_add_checkpoint 3 stalled
  alf_add_answer 1 accept
  alf_set_line app.ts 1 "const closing = 1"
  alf_commit "closing round"
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID")"
  assert_allowed || return 1
  [ "$(state_field '.history.rounds[3].closing')" = true ] || return 1
  bash "$SCRIPTS/audit-gate-owed.sh" mark --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --round 3
}

@test "gate failure on a tree no round recorded: a quick clear and then a late-pass commit each reopen on HEAD's tree and the repair is followed by a normal round" {
  below
  stop_case all
  alf_set_line other.txt 30 "quick clear"
  alf_commit "quick clear"
  fail_owed_gate || return 1
  unit_dispatch
  assert_allowed || return 1
  assert_reopened 4 || return 1
  alf_dispositions 4 '[]'
  alf_set_line other.txt 31 "repair"
  alf_commit "repair"
  nested
  assert_allowed || return 1
  [ "$(nrounds)" -eq 5 ] || return 1
  [ "$(state_field '.history.rounds[4].reopened // false')" = false ] || return 1
  alf_stamp 5 50
  alf_sidecar "$FRONTEND_MEMBER" '[]' 51
  alf_set_line other.txt 32 "late pass"
  alf_commit "late pass"
  fail_owed_gate || return 1
  [ "$(jq -r '.after_round' "$RUN_FOLDER/gate-failure.json")" -eq 5 ] || return 1
  unit_dispatch
  assert_allowed || return 1
  assert_reopened 6 || return 1
  alf_dispositions 6 '[]'
  alf_set_line other.txt 33 "second repair"
  alf_commit "second repair"
  nested
  assert_allowed || return 1
  [ "$(nrounds)" -eq 7 ] || return 1
  [ "$(state_field '.history.rounds[6].reopened // false')" = false ]
}

# assert_rubric_checkpoint: the last run denied with a checkpoint on the
# enriching rubric, and no round was reopened.
assert_rubric_checkpoint() {
  deny_prefix "BLOCKED: audit checkpoint" || return 1
  [ "$(state_field '.history.checkpoints | last | .trigger')" = "rubric:enriching" ] || return 1
  [ "$(nrounds)" -eq 3 ]
}

@test "no checkpoint on a stop's follow-up: the reopening unit is admitted on a round holding enriching" {
  below
  stop_case all
  veto_key 4
  unit_dispatch
  assert_allowed || return 1
  [ "$(checkpoints)" -eq 0 ] || return 1
  [ "$(state_field '.history.rounds[2].snapshot | [.signals.enriching, .default_stop] | tojson')" = '[true,true]' ] || return 1
  assert_reopened 4
}

@test "no checkpoint on a stop's follow-up: the same dispatch with default_stop false in the stored snapshot records a checkpoint" {
  below
  stop_case all
  unit_dispatch
  assert_allowed || return 1
  alf_state_edit '.history.rounds[2].snapshot.default_stop = false'
  veto_key 4
  unit_dispatch
  assert_rubric_checkpoint
}

@test "no checkpoint on a stop's follow-up: a threshold fix on a stop key records a checkpoint with default_stop still true in the stored snapshot" {
  below
  stop_case fixed
  veto_key 4
  unit_dispatch
  assert_rubric_checkpoint || return 1
  [ "$(state_field '.history.rounds[2].snapshot.default_stop')" = true ]
}
