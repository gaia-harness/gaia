#!/usr/bin/env bats
#
# Suite for .gaia/scripts/audit-veto-lib.sh and audit-loop-stop-lib.sh: when
# a veto key counts as satisfied, the in-memory stop override the bound hook
# applies to a snapshot, and the reopened-round test's fail-loud reads. Pure
# state and run-folder fixtures, except the inline-fix cases: satisfaction by a
# commit made outside the fixer reads the diff between two round trees, so
# those cases commit real trees in a repository at MAIN.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-veto-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-eval.sh"
  MAIN="$BATS_TEST_TMPDIR/main"
  BRANCH_NAME=feat/loop
  RUN="$MAIN/.gaia/local/runs/$BRANCH_NAME"
  mkdir -p "$RUN"
  VETOED_IDENTITY='["code-audit-frontend","rule/x","f.txt",2]'
  OTHER_IDENTITY='["code-audit-frontend","rule/x","f.txt",9]'
  TREE_ONE="$(printf '1%.0s' $(seq 1 40))"
  TREE_TWO="$(printf '2%.0s' $(seq 1 40))"
}

# state_with <rounds-json>: a state whose rounds are the given
# [{tree, members, keys}] (keys null leaves the stored snapshot null).
state_with() {
  jq -n -c --argjson rounds "$1" '{schema: 1, branch: "feat/loop",
    history: {rounds: [$rounds | to_entries[] | {round: (.key + 1), tree: .value.tree, commit: .value.tree, members: .value.members,
      snapshot: (if .value.keys == null then null else {keys: .value.keys} end)}], checkpoints: []},
    allowance: {answers: []}}'
}

# veto <effective_from_round>: vetoes.json holding the vetoed identity.
veto() {
  jq -n -c --argjson identity "$VETOED_IDENTITY" --argjson effective_from_round "$1" \
    '{version: 1, keys: [{member: $identity[0], finding_class: $identity[1], path: $identity[2], line: $identity[3], effective_from_round: $effective_from_round}]}' >"$RUN/vetoes.json"
}

# fix_entry <round> <disposition> [identity]: dispositions-<round>.json disposing it.
fix_entry() {
  jq -n -c --argjson round "$1" --arg disposition "$2" --argjson identity "${3:-$VETOED_IDENTITY}" \
    '{schema: 1, round: $round, entries: [{member: $identity[0], finding_class: $identity[1], path: $identity[2], line: $identity[3], disposition: $disposition, reason: "r"}]}' >"$RUN/dispositions-$1.json"
}

# fixer_result <round> <disposition>: fixer-<round>-audit.json with one result on the vetoed identity.
fixer_result() {
  jq -n -c --argjson identity "$VETOED_IDENTITY" --arg disposition "$2" \
    '{attempt: 1, results: [{member: $identity[0], finding_class: $identity[1], path: $identity[2], line: $identity[3], disposition: $disposition, reason: "r", changed_paths: ["f.txt"]}]}' >"$RUN/fixer-$1-audit.json"
}

# satisfied_base: every condition holds for the vetoed identity at round 3:
# round 1 on TREE_WAIVED fixes it, and rounds 2 and 3 sit on TREE_FIXED, whose
# diff from TREE_WAIVED rewrites the vetoed line.
satisfied_base() {
  inline_trees || return 1
  veto 1
  fix_entry 1 fix
  fixer_result 1 fixed
  STATE="$(state_with "[{\"tree\":\"$TREE_WAIVED\",\"members\":[\"code-audit-frontend\"],\"keys\":[$VETOED_IDENTITY]},
    {\"tree\":\"$TREE_FIXED\",\"members\":[\"code-audit-frontend\"],\"keys\":[$OTHER_IDENTITY]},
    {\"tree\":\"$TREE_FIXED\",\"members\":[\"code-audit-frontend\"],\"keys\":null}]")"
  ROUND_KEYS="[$OTHER_IDENTITY]"
}

# veto_state: the library's answer for round 3 on STATE and ROUND_KEYS.
veto_state() {
  gaia_veto_keys_state "$MAIN" "$BRANCH_NAME" "$STATE" 3 "$ROUND_KEYS"
}

# reset_run: put the run folder, roster and vetoed identity back to a fresh
# state between the cases of one test, so no case reads another's leftovers.
reset_run() {
  rm -f "$RUN"/vetoes.json "$RUN"/dispositions-*.json "$RUN"/fixer-*-audit.json "$MAIN/.gaia/audit-ci.yml"
  VETOED_IDENTITY='["code-audit-frontend","rule/x","f.txt",2]'
}

assert_unsatisfied() {
  local answer
  answer="$(veto_state)" || { echo "rc $?"; return 1; }
  [ "$(jq -c . <<<"$answer")" = "{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}" ] || { echo "$answer"; return 1; }
}

@test "veto-state: no vetoes file means nothing is vetoed" {
  satisfied_base
  rm -f "$RUN/vetoes.json"
  [ "$(veto_state | jq -c .)" = '{"satisfied":[],"unsatisfied":[]}' ]
}

@test "veto-state fixer route: a fix satisfies a key only when it landed, was committed and the member, dispatched after it, did not re-report" {
  local tree line expected unsatisfied
  satisfied_base
  [ "$(veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ]
  reset_run # veto-state: a fix entry before effective_from_round does not count
  # The veto binds from round 3, so its waiver round 2 already sits on
  # TREE_FIXED and the commit route sees no change; only counting round 1's fix
  # could satisfy it.
  satisfied_base || return 1
  veto 3
  assert_unsatisfied
  reset_run # veto-state: a fixer result of disputed or cannot_fix is not a fix
  local result
  for result in disputed cannot_fix; do
    satisfied_base
    fixer_result 1 "$result"
    assert_unsatisfied || { echo "fixer $result"; return 1; }
  done
  reset_run # veto-state: a fix that no later round committed is not a fix
  satisfied_base
  STATE="$(jq -c --arg tree "$TREE_WAIVED" '.history.rounds |= map(.tree = $tree | .commit = $tree)' <<<"$STATE")"
  assert_unsatisfied
  reset_run # veto-state: the member must be dispatched after the fix
  satisfied_base
  STATE="$(jq -c '.history.rounds[1].members = [] | .history.rounds[2].members = ["code-audit-shell"]' <<<"$STATE")"
  assert_unsatisfied
  reset_run # veto-state: the exact key re-reported in round r, or in an earlier dispatched round, is unsatisfied
  satisfied_base
  ROUND_KEYS="[$VETOED_IDENTITY]"
  assert_unsatisfied || return 1
  satisfied_base
  STATE="$(jq -c --argjson identity "$VETOED_IDENTITY" '.history.rounds[1].snapshot.keys = [$identity]' <<<"$STATE")"
  assert_unsatisfied
  reset_run # veto-state: after a re-report, only a later round whose tree changed the key's path again can satisfy the key
  local tree expected
  while read -r tree expected; do
    satisfied_base || return 1
    STATE="$(jq -c --argjson identity "$VETOED_IDENTITY" --arg tree "${!tree}" \
      '.history.rounds[1].snapshot.keys = [$identity] | .history.rounds[2].tree = $tree' <<<"$STATE")"
    ROUND_KEYS='[]'
    [ "$(veto_state | jq -c '.satisfied | length')" = "$expected" ] || { echo "round 3 on $tree"; return 1; }
  done <<'CASES'
TREE_FIXED 0
TREE_UNRELATED 0
TREE_MOVED 1
CASES
  reset_run # veto-state: an earlier dispatched round with no stored keys proves nothing
  satisfied_base
  STATE="$(jq -c '.history.rounds[1].snapshot = null' <<<"$STATE")"
  assert_unsatisfied
  reset_run # veto-state fixer: satisfied only when a later round's tree changed the key's path, not when an unrelated commit moved the tree
  fixer_base TREE_FIXED || return 1
  [ "$(inline_veto_state | jq -c '.satisfied | length')" = 1 ] || { echo "repair committed"; return 1; }
  fixer_base TREE_UNRELATED || return 1
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}" ] || { echo "repair never committed"; return 1; }
  reset_run # veto-state fixer: a same-class re-report within the tolerance of the fixed line leaves the key unsatisfied, as on the commit route
  local line expected
  while read -r line expected; do
    fixer_base TREE_FIXED || return 1
    ROUND_KEYS="[[\"code-audit-frontend\",\"rule/x\",\"f.txt\",$line]]"
    [ "$(inline_veto_state | jq -c '.satisfied | length')" = "$expected" ] || { echo "line $line"; return 1; }
  done <<'CASES'
3 0
5 0
6 1
CASES
}

# inline_commit <message>: commits f.txt and g.txt at MAIN and prints the commit's tree.
inline_commit() {
  git -C "$MAIN" add f.txt g.txt && git -C "$MAIN" -c user.name=t -c user.email=t@t commit -q -m "$1" &&
    git -C "$MAIN" rev-parse 'HEAD^{tree}'
}

# inline_trees: a repository at MAIN whose f.txt holds lines l1..l40 when the
# waiver is held, and the trees a main-thread fix can leave. Each tree after
# TREE_WAIVED is diffed against TREE_WAIVED, and a case that puts two of them
# in successive rounds also diffs them against each other:
#   TREE_UNRELATED: only g.txt changed.
#   TREE_FIXED: f.txt line 2 rewritten in place.
#   TREE_MOVED: five lines inserted at the top, shifting every line by five.
#   TREE_RELOCATED: line 2 deleted and a line added at 29, where the fix
#     moved the code the finding was about.
# The run folder under MAIN stays untracked.
inline_trees() {
  [ -n "${TREE_FIXED-}" ] && return 0
  git init -q "$MAIN" || return 1
  seq -f 'l%g' 1 40 >"$MAIN/f.txt"
  printf 'a\n' >"$MAIN/g.txt"
  TREE_WAIVED="$(inline_commit waived)" || return 1
  printf 'b\n' >"$MAIN/g.txt"
  # shellcheck disable=SC2034 # inline_base reads it by name
  TREE_UNRELATED="$(inline_commit unrelated)" || return 1
  seq -f 'l%g' 1 40 | sed '2s/.*/fixed/' >"$MAIN/f.txt"
  TREE_FIXED="$(inline_commit fixed)" || return 1
  { seq -f 'n%g' 1 5; seq -f 'l%g' 1 40; } >"$MAIN/f.txt"
  # shellcheck disable=SC2034 # inline_base reads it by name
  TREE_MOVED="$(inline_commit moved)" || return 1
  seq -f 'l%g' 1 40 | sed -e '2d' -e '29a\
relocated' >"$MAIN/f.txt"
  # shellcheck disable=SC2034 # inline_base reads it by name
  TREE_RELOCATED="$(inline_commit relocated)" || return 1
}

# inline_base <round-2-tree-variable>: the main-thread fix sequence at round
# 2, the tree named by variable since the trees exist only once built. Round 1
# held the waiver on TREE_WAIVED; the veto binds from round 2; no dispositions
# or fixer file exists, so only the inline path can satisfy it. Round 2's
# member left the key out.
inline_base() {
  inline_trees || return 1
  veto 2
  STATE="$(state_with "[{\"tree\":\"$TREE_WAIVED\",\"members\":[\"code-audit-frontend\"],\"keys\":[$VETOED_IDENTITY]},
    {\"tree\":\"${!1}\",\"members\":[\"code-audit-frontend\"],\"keys\":null}]")"
  ROUND_KEYS='[["code-audit-frontend","rule/y","f.txt",9]]'
}

inline_veto_state() {
  gaia_veto_keys_state "$MAIN" "$BRANCH_NAME" "$STATE" 2 "$ROUND_KEYS"
}

@test "veto-state inline route: a main-thread commit satisfies a key only when it touched the key's path, the key's member then reviewed clean on a readable tree, and no same-class finding sits near the vetoed line's new place or a line the fix wrote; a round-1 veto needs the fixer route" {
  local tree line expected unsatisfied
  # veto-state inline: a main-thread commit touching the key's path after the waiver round, then a clean review, satisfies the veto with no fixer result
  inline_base TREE_FIXED || return 1
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ]
  reset_run # veto-state inline: unsatisfied when the tree is unmoved, moved without touching the key's path, or the member re-reports the key
  local unsatisfied="{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}"
  inline_base TREE_WAIVED || return 1
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "unmoved"; return 1; }
  inline_base TREE_UNRELATED || return 1
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "path untouched"; return 1; }
  inline_base TREE_FIXED || return 1
  ROUND_KEYS="[$VETOED_IDENTITY]"
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "re-reported"; return 1; }
  reset_run # veto-state inline: an edit that only moves the finding to another line of the file leaves the veto unsatisfied
  # Line 20 lands at 25, far from the five lines the edit wrote at the top.
  VETOED_IDENTITY='["code-audit-frontend","rule/x","f.txt",20]'
  inline_base TREE_MOVED || return 1
  ROUND_KEYS='[["code-audit-frontend","rule/x","f.txt",25]]'
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}" ] || return 1
  # Another class on the same path, or the same class on another path, is not the vetoed finding.
  ROUND_KEYS="[[\"code-audit-frontend\",\"rule/y\",\"f.txt\",25],[\"code-audit-frontend\",\"rule/x\",\"g.txt\",20]]"
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ]
  reset_run # veto-state inline: a same-class finding on the path re-reports the veto only near the vetoed line's new place or near a line the fix wrote
  # The tolerance is 3 lines: the vetoed line maps to [2,2] in TREE_FIXED, so 5
  # is inside it and 6 is past it; TREE_RELOCATED's fix wrote line 29 and
  # deleted line 2, mapping the vetoed line to the gap [1,2], so 20 is on code
  # it left alone.
  local tree line expected
  while read -r tree line expected; do
    inline_base "$tree" || return 1
    ROUND_KEYS="[[\"code-audit-frontend\",\"rule/x\",\"f.txt\",$line]]"
    [ "$(inline_veto_state | jq -c '.satisfied | length')" = "$expected" ] || { echo "$tree line $line"; return 1; }
  done <<'CASES'
TREE_FIXED 40 1
TREE_FIXED 5 0
TREE_FIXED 6 1
TREE_RELOCATED 29 0
TREE_RELOCATED 20 1
CASES
  reset_run # veto-state inline: a re-report after the fix is not passed over by a later round on the same tree
  inline_base TREE_FIXED || return 1
  STATE="$(jq -c --argjson identity "$VETOED_IDENTITY" '.history.rounds[1].snapshot = {keys: [$identity]}
    | .history.rounds += [.history.rounds[1] | .round = 3 | .snapshot = null]' <<<"$STATE")"
  ROUND_KEYS='[]'
  [ "$(gaia_veto_keys_state "$MAIN" "$BRANCH_NAME" "$STATE" 3 "$ROUND_KEYS" | jq -c .)" = "{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}" ]
  reset_run # veto-state inline: unsatisfied when no round after the fix dispatched the key's member, or a tree cannot be read
  local unsatisfied="{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}"
  inline_base TREE_FIXED || return 1
  STATE="$(jq -c '.history.rounds[1].members = ["code-audit-shell"]' <<<"$STATE")"
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "member not dispatched"; return 1; }
  inline_base TREE_FIXED || return 1
  STATE="$(jq -c --arg tree "$TREE_TWO" '.history.rounds[1].tree = $tree' <<<"$STATE")"
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "unreadable tree"; return 1; }
  reset_run # veto-state inline: a veto binding from round 1 has no waiver round to diff against, so only the fixer path satisfies it
  inline_base TREE_FIXED || return 1
  veto 1
  # Round 1 left the key out too, so only the missing waiver round keeps the
  # veto unsatisfied (jq reads index -1 as the last round, not as absent).
  STATE="$(jq -c '.history.rounds[0].snapshot.keys = [["code-audit-frontend","rule/y","f.txt",9]]' <<<"$STATE")"
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}" ]
}

# fixer_base <round-2-tree-variable>: the fixer's sequence on real trees.
# Round 1 on TREE_WAIVED reports the key, disposes it fix and the fixer
# reports it fixed; round 2 sits on the named tree with a clean review.
fixer_base() {
  inline_base "$1" || return 1
  veto 1
  fix_entry 1 fix
  fixer_result 1 fixed
}

# roster_owning_vetoed_path <member>: a roster at MAIN giving f.txt to the
# member, so the vetoed key is cross-remit unless it is the key's own member.
roster_owning_vetoed_path() {
  mkdir -p "$MAIN/.gaia"
  printf 'auditors:\n  - name: %s\n    globs:\n      - "f.txt"\n    audience: adopter\n  - name: code-audit-frontend\n    globs:\n      - "**"\n    audience: adopter\n    default: true\n' \
    "$1" >"$MAIN/.gaia/audit-ci.yml"
}

# owner_reviews <state-json>: the state with every round after the first
# dispatching only code-audit-shell.
owner_reviews() {
  jq -c '.history.rounds |= (.[0:1] + (.[1:] | map(.members = ["code-audit-shell"])))' <<<"$1"
}

@test "veto-state cross-remit: a clean review by the path's roster owner satisfies a key its reporting member never reviews, unless the owner reports at the fixed line, the reporting member owns the path, no roster is readable or only the reporting member is dispatched" {
  local tree line expected unsatisfied
  # satisfied on the fixer and the commit route
  roster_owning_vetoed_path code-audit-shell
  satisfied_base
  STATE="$(owner_reviews "$STATE")"
  [ "$(veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ] || { echo "fixer route"; return 1; }
  inline_base TREE_FIXED || return 1
  STATE="$(owner_reviews "$STATE")"
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ] || { echo "commit route"; return 1; }
  reset_run # veto-state cross-remit: the owner reporting any class at the fixed line leaves the key unsatisfied; a finding elsewhere on the path does not
  roster_owning_vetoed_path code-audit-shell
  satisfied_base
  STATE="$(owner_reviews "$STATE")"
  ROUND_KEYS='[["code-audit-shell","rule/other","f.txt",3]]'
  assert_unsatisfied || { echo "fixer route, round r"; return 1; }
  STATE="$(jq -c '.history.rounds[1].snapshot.keys = [["code-audit-shell","rule/other","f.txt",2]]' <<<"$STATE")"
  ROUND_KEYS='[]'
  assert_unsatisfied || { echo "fixer route, earlier round"; return 1; }
  STATE="$(jq -c '.history.rounds[1].snapshot.keys = [["code-audit-shell","rule/other","f.txt",30]]' <<<"$STATE")"
  [ "$(veto_state | jq -c '.satisfied | length')" = 1 ] || { echo "a finding far from the fixed line"; return 1; }
  inline_base TREE_FIXED || return 1
  STATE="$(owner_reviews "$STATE")"
  ROUND_KEYS='[["code-audit-shell","rule/other","f.txt",4]]'
  [ "$(inline_veto_state | jq -c '.satisfied | length')" = 0 ] || { echo "commit route"; return 1; }
  reset_run # veto-state cross-remit: another member's review satisfies nothing when the key's member owns the path or no roster is readable
  roster_owning_vetoed_path code-audit-frontend
  satisfied_base
  STATE="$(owner_reviews "$STATE")"
  assert_unsatisfied || { echo "the reporting member owns the path"; return 1; }
  rm -f "$MAIN/.gaia/audit-ci.yml"
  assert_unsatisfied || { echo "no roster"; return 1; }
  reset_run # veto-state cross-remit: a round dispatching only the reporting member leaves the key unsatisfied until the path's owner is dispatched
  roster_owning_vetoed_path code-audit-shell
  satisfied_base
  assert_unsatisfied || { echo "reporting member only"; return 1; }
  STATE="$(owner_reviews "$STATE")"
  [ "$(veto_state | jq -c '.satisfied | length')" = 1 ] || { echo "owner dispatched"; return 1; }
}

# fixer_result_on <round> <disposition> <identity>: fixer-<round>-audit.json with one result on the identity.
fixer_result_on() {
  jq -n -c --argjson identity "$3" --arg disposition "$2" \
    '{attempt: 1, results: [{member: $identity[0], finding_class: $identity[1], path: $identity[2], line: $identity[3], disposition: $disposition, reason: "r", changed_paths: ["f.txt"]}]}' >"$RUN/fixer-$1-audit.json"
}

# pr_review_base: a pr-reviewer veto on f.txt:2 from round 2, which a
# main-thread commit repaired (round 2 on TREE_FIXED). The roster gives f.txt to
# code-audit-shell, which reviews rounds 2 and 3. Round 2's owner reported
# NEIGHBOUR, two lines from the vetoed line; round 3 reports nothing. A round-3
# tree argument other than TREE_FIXED changes f.txt there, and round 3 then
# dispatches no member: a clean round-3 owner review would satisfy the key on
# its own, so only the round-2 review, and what the dispositions say of its
# NEIGHBOUR, decides the case.
pr_review_base() {
  local round_three_tree="${1:-TREE_FIXED}"
  VETOED_IDENTITY='["pr-reviewer","pr-review/pr-1","f.txt",2]'
  NEIGHBOUR='["code-audit-shell","holistic/unclassified","f.txt",4]'
  roster_owning_vetoed_path code-audit-shell
  inline_base TREE_FIXED || return 1
  STATE="$(jq -c --argjson neighbour "$NEIGHBOUR" '.history.rounds[1].members = ["code-audit-shell"]
    | .history.rounds[1].snapshot = {keys: [$neighbour]}
    | .history.rounds += [.history.rounds[1] | .round = 3 | .snapshot = null | .tree = $round_three_tree
      | if $undispatched then .members = [] else . end]' --arg round_three_tree "${!round_three_tree}" \
    --argjson undispatched "$([ "$round_three_tree" = TREE_FIXED ] && echo false || echo true)" <<<"$STATE")"
  ROUND_KEYS='[]'
}

pr_review_veto_state() {
  gaia_veto_keys_state "$MAIN" "$BRANCH_NAME" "$STATE" 3 "$ROUND_KEYS" | jq -c '.satisfied | length'
}

@test "veto-state pr-reviewer: an owner finding near the repair stops counting as the vetoed one only when an earlier round fixed it under its own key; a waived one, or one in round r, still does" {
  # fixed neighbour clears
  pr_review_base TREE_MOVED || return 1
  fix_entry 2 fix "$NEIGHBOUR"
  fixer_result_on 2 fixed "$NEIGHBOUR"
  [ "$(pr_review_veto_state)" = 1 ] || { echo "a neighbour fixed under its own key"; return 1; }
  reset_run # a fixed claim with no change to the neighbour's path since the round does not excuse it
  pr_review_base TREE_FIXED || return 1
  fix_entry 2 fix "$NEIGHBOUR"
  fixer_result_on 2 fixed "$NEIGHBOUR"
  [ "$(pr_review_veto_state)" = 0 ] || { echo "a fixed claim with no tree change"; return 1; }
  reset_run # waived, filed or diverted neighbour still blocks
  local disposition
  for disposition in waive-out-of-scope file divert; do
    pr_review_base TREE_MOVED || return 1
    fix_entry 2 "$disposition" "$NEIGHBOUR"
    [ "$(pr_review_veto_state)" = 0 ] || { echo "a neighbour disposed $disposition"; return 1; }
  done
  reset_run # disposed fix but the fixer did not fix it
  pr_review_base TREE_MOVED || return 1
  fix_entry 2 fix "$NEIGHBOUR"
  fixer_result_on 2 disputed "$NEIGHBOUR"
  [ "$(pr_review_veto_state)" = 0 ] || { echo "a neighbour the fixer disputed"; return 1; }
  reset_run # the same defect re-reported in round r still blocks, even with a round-r fix record for it
  pr_review_base TREE_MOVED || return 1
  fix_entry 2 fix "$NEIGHBOUR"
  fixer_result_on 2 fixed "$NEIGHBOUR"
  STATE="$(jq -c '.history.rounds[2].members = ["code-audit-shell"]' <<<"$STATE")"
  ROUND_KEYS='[["code-audit-shell","holistic/unclassified","f.txt",3]]'
  fix_entry 3 fix '["code-audit-shell","holistic/unclassified","f.txt",3]'
  fixer_result_on 3 fixed '["code-audit-shell","holistic/unclassified","f.txt",3]'
  [ "$(pr_review_veto_state)" = 0 ] || { echo "a re-report in round r"; return 1; }
  reset_run # a cross-remit audit-member key keeps reading every owner finding nearby as its re-report
  pr_review_base TREE_MOVED || return 1
  VETOED_IDENTITY='["code-audit-frontend","rule/x","f.txt",2]'
  veto 2
  fix_entry 2 fix "$NEIGHBOUR"
  fixer_result_on 2 fixed "$NEIGHBOUR"
  [ "$(pr_review_veto_state)" = 0 ] || { echo "a cross-remit audit-member key"; return 1; }
}

# repair_veto <effective_from_round> <repair-paths-json>: vetoes.json holding the
# vetoed identity with repair_paths.
repair_veto() {
  veto "$1"
  jq -c --argjson repair_paths "$2" '.keys[0].repair_paths = $repair_paths' "$RUN/vetoes.json" >"$RUN/vetoes.json.new" && mv "$RUN/vetoes.json.new" "$RUN/vetoes.json"
}

# roster_owning <f.txt-member> [g.txt-member]: a roster with no default member,
# so a path it names no member for has no owner.
roster_owning() {
  mkdir -p "$MAIN/.gaia"
  {
    printf 'auditors:\n  - name: %s\n    globs:\n      - "f.txt"\n    audience: adopter\n' "$1"
    [ -z "${2-}" ] || printf '  - name: %s\n    globs:\n      - "g.txt"\n    audience: adopter\n' "$2"
  } >"$MAIN/.gaia/audit-ci.yml"
}

# repair_base <round-2-tree-variable>: the key on f.txt:2 from round 2 names
# g.txt as its repair path, which code-audit-shell owns; round 2 dispatches the
# key's member and that owner, and both report nothing.
repair_base() {
  roster_owning code-audit-frontend code-audit-shell
  inline_base "$1" || return 1
  repair_veto 2 '["g.txt"]'
  STATE="$(jq -c '.history.rounds[1].members = ["code-audit-frontend", "code-audit-shell"]' <<<"$STATE")"
  ROUND_KEYS='[]'
}

@test "veto-state repair_paths: a repair landing only in the named path satisfies the key once that path's owner reviewed it clean, and never without that review, the change, an owner or the key's own clean review" {
  local unsatisfied
  repair_base TREE_UNRELATED || return 1
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ] || { echo "the repair path reviewed clean"; return 1; }
  unsatisfied="{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}"
  veto 2
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "no repair_paths"; return 1; }
  repair_base TREE_UNRELATED || return 1
  STATE="$(jq -c '.history.rounds[1].members = ["code-audit-frontend"]' <<<"$STATE")"
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "the repair path's owner not dispatched"; return 1; }
  repair_base TREE_UNRELATED || return 1
  ROUND_KEYS='[["code-audit-shell","rule/y","g.txt",1]]'
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "the owner reported on the repair path"; return 1; }
  repair_base TREE_UNRELATED || return 1
  ROUND_KEYS="[$VETOED_IDENTITY]"
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "the key re-reported on its own path"; return 1; }
  # The repair landed only in g.txt, so f.txt has no hunk: a same-class finding far from the vetoed line is another finding.
  repair_base TREE_UNRELATED || return 1
  ROUND_KEYS='[["code-audit-frontend","rule/x","f.txt",30]]'
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ] || { echo "a far finding on a key path with no hunk"; return 1; }
  ROUND_KEYS='[["code-audit-frontend","rule/x","f.txt",3]]'
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "a near finding on a key path with no hunk"; return 1; }
  # The owner's finding on the repair path far from the hunk the repair wrote is another finding.
  repair_base TREE_UNRELATED || return 1
  ROUND_KEYS='[["code-audit-shell","rule/y","g.txt",30]]'
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ] || { echo "a far owner finding on the repair path"; return 1; }
  # TREE_FIXED is built on TREE_UNRELATED, so from that waiver tree only f.txt changed.
  repair_base TREE_FIXED || return 1
  STATE="$(jq -c --arg tree "$TREE_UNRELATED" '.history.rounds[0].tree = $tree' <<<"$STATE")"
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "the repair path never changed"; return 1; }
  repair_base TREE_UNRELATED || return 1
  roster_owning code-audit-frontend
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "an unowned repair path"; return 1; }
  printf '%s' "$(inline_veto_state)" >"$BATS_TEST_TMPDIR/state.json"
  [ "$(gaia_veto_reviewers "$MAIN" "$BRANCH_NAME" "$MAIN" "$(cat "$BATS_TEST_TMPDIR/state.json")" | jq -c .reviewers)" = '["code-audit-frontend"]' ] || return 1
  roster_owning code-audit-frontend code-audit-shell
  [ "$(gaia_veto_reviewers "$MAIN" "$BRANCH_NAME" "$MAIN" "$(cat "$BATS_TEST_TMPDIR/state.json")" | jq -c .reviewers)" = '["code-audit-frontend","code-audit-shell"]' ] || { echo "the repair path's owner is not dispatched"; return 1; }
  repair_veto 2 '[1]'
  run gaia_veto_keys_state "$MAIN" "$BRANCH_NAME" "$STATE" 2 "$ROUND_KEYS"
  [ "$status" -ne 0 ]
}

@test "roster owners: a release-skipped owner is not named on a release branch, where the resolver never dispatches it" {
  . "$REPO_ROOT/.gaia/tests/helpers/release-skip-fixture.sh"
  release_skip_init "$BATS_TEST_TMPDIR/release"
  release_skip_branch "$BATS_TEST_TMPDIR/release" release
  [ "$(_roster_owners "$BATS_TEST_TMPDIR/release" "$REPO_ROOT/.gaia/scripts" '[".claude/hooks/gaia-guard.sh"]' | jq -r '.[".claude/hooks/gaia-guard.sh"]')" = fixture-default ]
  release_skip_branch "$BATS_TEST_TMPDIR/release" hand-edit
  [ "$(_roster_owners "$BATS_TEST_TMPDIR/release" "$REPO_ROOT/.gaia/scripts" '[".claude/hooks/gaia-guard.sh"]' | jq -r '.[".claude/hooks/gaia-guard.sh"]')" = fixture-shell ]
}

@test "veto-state: a malformed vetoes file fails" {
  satisfied_base
  printf '{"version":1,"keys":"no"}\n' >"$RUN/vetoes.json"
  run gaia_veto_keys_state "$MAIN" "$BRANCH_NAME" "$STATE" 3 "$ROUND_KEYS"
  [ "$status" -ne 0 ]
}

@test "veto-state: a key whose repair_paths holds an empty path fails" {
  satisfied_base
  jq -c '.keys[0].repair_paths = [""]' "$RUN/vetoes.json" >"$RUN/vetoes.json.next"
  mv "$RUN/vetoes.json.next" "$RUN/vetoes.json"
  run gaia_veto_keys_state "$MAIN" "$BRANCH_NAME" "$STATE" 3 "$ROUND_KEYS"
  [ "$status" -ne 0 ] || { echo "an empty repair path read as a valid vetoes file: $output"; return 1; }
}

# stop_snapshot <default_stop>: a snapshot whose stop set is the vetoed identity.
stop_snapshot() {
  jq -n -c --argjson default_stop "$1" --argjson identity "$VETOED_IDENTITY" '{round: 3, verdict: "enriching", signals: {enriching: true},
    default_stop: $default_stop, default_stop_keys: (if $default_stop then [$identity] else [] end)}'
}

# override_of <snapshot>: stop_override as the library adds it for round 3.
override_of() {
  gaia_loop_stop_override "$MAIN" "$BRANCH_NAME" 3 "$1" | jq -r '.stop_override'
}

@test "stop override: true for a default stop with no round-r dispositions, false when it is not a default stop" {
  [ "$(override_of "$(stop_snapshot true)")" = true ]
  [ "$(override_of "$(stop_snapshot false)")" = false ]
}

@test "stop override: a fix on a stop key withdraws it; a fix on any other key keeps it" {
  fix_entry 3 fix
  [ "$(override_of "$(stop_snapshot true)")" = false ] || return 1
  fix_entry 3 fix "$OTHER_IDENTITY"
  [ "$(override_of "$(stop_snapshot true)")" = true ] || return 1
  fix_entry 3 accept-residual
  [ "$(override_of "$(stop_snapshot true)")" = true ]
}

@test "stop override: a malformed round-r dispositions file reads false" {
  printf 'not json\n' >"$RUN/dispositions-3.json"
  [ "$(override_of "$(stop_snapshot true)")" = false ]
}

@test "stop override: default_stop itself is left as evaluated, a null snapshot stays null, and nothing is written" {
  local before after
  fix_entry 3 fix
  before="$(find "$MAIN" -type f | sort | xargs cat | shasum)"
  [ "$(gaia_loop_stop_override "$MAIN" "$BRANCH_NAME" 3 "$(stop_snapshot true)" | jq -c '[.default_stop, .default_stop_keys, .stop_override]')" = "[true,[$VETOED_IDENTITY],false]" ] || return 1
  [ "$(gaia_loop_stop_override "$MAIN" "$BRANCH_NAME" 3 null)" = null ] || return 1
  after="$(find "$MAIN" -type f | sort | xargs cat | shasum)"
  [ "$before" = "$after" ]
}

@test "reopen due: no round prints false, and a malformed vetoes or gate failure file fails rather than reading as absent" {
  local empty_state one_round
  empty_state="$(state_with '[]')"
  one_round="$(state_with "[{\"tree\":\"$TREE_ONE\",\"members\":[\"code-audit-frontend\"],\"keys\":null}]")"
  veto 1
  [ "$(gaia_loop_reopen_due "$MAIN" "$BRANCH_NAME" "$empty_state" "$TREE_ONE")" = false ] || return 1
  veto 2
  [ "$(gaia_loop_reopen_due "$MAIN" "$BRANCH_NAME" "$one_round" "$TREE_ONE")" = true ] || return 1
  printf '{"version":1,"keys":"no"}\n' >"$RUN/vetoes.json"
  run gaia_loop_reopen_due "$MAIN" "$BRANCH_NAME" "$one_round" "$TREE_ONE"
  [ "$status" -ne 0 ] || return 1
  rm -f "$RUN/vetoes.json"
  printf '{broken' >"$RUN/gate-failure.json"
  run gaia_loop_reopen_due "$MAIN" "$BRANCH_NAME" "$one_round" "$TREE_ONE"
  [ "$status" -ne 0 ]
}
