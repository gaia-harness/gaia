#!/usr/bin/env bats
#
# Suite for .gaia/scripts/audit-veto-lib.sh: when a veto key counts as
# satisfied, the in-memory stop override the bound hook applies to a
# snapshot, and the reopened-round test's fail-loud reads. Pure state and
# run-folder fixtures, except the inline-fix cases: satisfaction by a commit
# made outside the fixer reads the diff between two round trees, so those
# cases commit real trees in a repository at MAIN.
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

# satisfied_base: every condition holds for the vetoed identity at round 3.
satisfied_base() {
  veto 1
  fix_entry 1 fix
  fixer_result 1 fixed
  STATE="$(state_with "[{\"tree\":\"$TREE_ONE\",\"members\":[\"code-audit-frontend\"],\"keys\":[$VETOED_IDENTITY]},
    {\"tree\":\"$TREE_TWO\",\"members\":[\"code-audit-frontend\"],\"keys\":[$OTHER_IDENTITY]},
    {\"tree\":\"$TREE_TWO\",\"members\":[\"code-audit-frontend\"],\"keys\":null}]")"
  ROUND_KEYS="[$OTHER_IDENTITY]"
}

# veto_state: the library's answer for round 3 on STATE and ROUND_KEYS.
veto_state() {
  gaia_veto_keys_state "$MAIN" "$BRANCH_NAME" "$STATE" 3 "$ROUND_KEYS"
}

assert_unsatisfied() {
  local answer
  answer="$(veto_state)" || { echo "rc $?"; return 1; }
  [ "$(jq -c . <<<"$answer")" = "{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}" ] || { echo "$answer"; return 1; }
}

@test "veto-state: a key whose fix landed, was committed and the member did not re-report is satisfied" {
  satisfied_base
  [ "$(veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ]
}

@test "veto-state: no vetoes file means nothing is vetoed" {
  satisfied_base
  rm -f "$RUN/vetoes.json"
  [ "$(veto_state | jq -c .)" = '{"satisfied":[],"unsatisfied":[]}' ]
}

@test "veto-state: a fix entry before effective_from_round does not count" {
  satisfied_base
  veto 2
  assert_unsatisfied
}

@test "veto-state: a fixer result of disputed or cannot_fix is not a fix" {
  local result
  for result in disputed cannot_fix; do
    satisfied_base
    fixer_result 1 "$result"
    assert_unsatisfied || { echo "fixer $result"; return 1; }
  done
}

@test "veto-state: a fix that no later round committed is not a fix" {
  satisfied_base
  STATE="$(jq -c --arg tree "$TREE_ONE" '.history.rounds |= map(.tree = $tree | .commit = $tree)' <<<"$STATE")"
  assert_unsatisfied
}

@test "veto-state: the member must be dispatched after the fix" {
  satisfied_base
  STATE="$(jq -c '.history.rounds[1].members = [] | .history.rounds[2].members = ["code-audit-shell"]' <<<"$STATE")"
  assert_unsatisfied
}

@test "veto-state: the exact key re-reported in round r, or in an earlier dispatched round, is unsatisfied" {
  satisfied_base
  ROUND_KEYS="[$VETOED_IDENTITY]"
  assert_unsatisfied || return 1
  satisfied_base
  STATE="$(jq -c --argjson identity "$VETOED_IDENTITY" '.history.rounds[1].snapshot.keys = [$identity]' <<<"$STATE")"
  assert_unsatisfied
}

@test "veto-state: an earlier dispatched round with no stored keys proves nothing" {
  satisfied_base
  STATE="$(jq -c '.history.rounds[1].snapshot = null' <<<"$STATE")"
  assert_unsatisfied
}

# inline_commit <message>: commits f.txt and g.txt at MAIN and prints the commit's tree.
inline_commit() {
  git -C "$MAIN" add f.txt g.txt && git -C "$MAIN" -c user.name=t -c user.email=t@t commit -q -m "$1" &&
    git -C "$MAIN" rev-parse 'HEAD^{tree}'
}

# inline_trees: a repository at MAIN whose f.txt holds lines l1..l40 when the
# waiver is held, and the trees a main-thread fix can leave. Each tree after
# TREE_WAIVED is diffed against TREE_WAIVED, so their order does not matter:
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

@test "veto-state inline: a main-thread commit touching the key's path after the waiver round, then a clean review, satisfies the veto with no fixer result" {
  inline_base TREE_FIXED || return 1
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ]
}

@test "veto-state inline: unsatisfied when the tree is unmoved, moved without touching the key's path, or the member re-reports the key" {
  local unsatisfied="{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}"
  inline_base TREE_WAIVED || return 1
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "unmoved"; return 1; }
  inline_base TREE_UNRELATED || return 1
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "path untouched"; return 1; }
  inline_base TREE_FIXED || return 1
  ROUND_KEYS="[$VETOED_IDENTITY]"
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "re-reported"; return 1; }
}

@test "veto-state inline: an edit that only moves the finding to another line of the file leaves the veto unsatisfied" {
  # Line 20 lands at 25, far from the five lines the edit wrote at the top.
  VETOED_IDENTITY='["code-audit-frontend","rule/x","f.txt",20]'
  inline_base TREE_MOVED || return 1
  ROUND_KEYS='[["code-audit-frontend","rule/x","f.txt",25]]'
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}" ] || return 1
  # Another class on the same path, or the same class on another path, is not the vetoed finding.
  ROUND_KEYS="[[\"code-audit-frontend\",\"rule/y\",\"f.txt\",25],[\"code-audit-frontend\",\"rule/x\",\"g.txt\",20]]"
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[$VETOED_IDENTITY],\"unsatisfied\":[]}" ]
}

# The tolerance is 3 lines: the vetoed line maps to [2,2] in TREE_FIXED, so 5
# is inside it and 6 is past it; TREE_RELOCATED's fix wrote line 29 and
# deleted line 2, mapping the vetoed line to the gap [1,2], so 20 is on code
# it left alone.
@test "veto-state inline: a same-class finding on the path re-reports the veto only near the vetoed line's new place or near a line the fix wrote" {
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
}

@test "veto-state inline: unsatisfied when no round after the fix dispatched the key's member, or a tree cannot be read" {
  local unsatisfied="{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}"
  inline_base TREE_FIXED || return 1
  STATE="$(jq -c '.history.rounds[1].members = ["code-audit-shell"]' <<<"$STATE")"
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "member not dispatched"; return 1; }
  inline_base TREE_FIXED || return 1
  STATE="$(jq -c --arg tree "$TREE_TWO" '.history.rounds[1].tree = $tree' <<<"$STATE")"
  [ "$(inline_veto_state | jq -c .)" = "$unsatisfied" ] || { echo "unreadable tree"; return 1; }
}

@test "veto-state inline: a veto binding from round 1 has no waiver round to diff against, so only the fixer path satisfies it" {
  inline_base TREE_FIXED || return 1
  veto 1
  # Round 1 left the key out too, so only the missing waiver round keeps the
  # veto unsatisfied (jq reads index -1 as the last round, not as absent).
  STATE="$(jq -c '.history.rounds[0].snapshot.keys = [["code-audit-frontend","rule/y","f.txt",9]]' <<<"$STATE")"
  [ "$(inline_veto_state | jq -c .)" = "{\"satisfied\":[],\"unsatisfied\":[$VETOED_IDENTITY]}" ]
}

@test "veto-state: a malformed vetoes file fails" {
  satisfied_base
  printf '{"version":1,"keys":"no"}\n' >"$RUN/vetoes.json"
  run gaia_veto_keys_state "$MAIN" "$BRANCH_NAME" "$STATE" 3 "$ROUND_KEYS"
  [ "$status" -ne 0 ]
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
