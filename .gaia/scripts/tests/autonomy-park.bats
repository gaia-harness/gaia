#!/usr/bin/env bats
# Guards .gaia/scripts/autonomy-park.sh, the park procedure.
#
# Each test runs the real script, copied with its sibling libraries into a
# throwaway repository whose origin is a bare remote. `gh` is a stub on PATH
# that logs its argv and keeps the comment body; audit-loop-eval.sh is a stub
# serving the brief's grant line, so an audit-checkpoint park needs no loop
# state. Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq missing"
  WORK="$BATS_TEST_TMPDIR/work"
  REMOTE="$BATS_TEST_TMPDIR/origin.git"
  BIN="$BATS_TEST_TMPDIR/bin"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export GH_BODY="$BATS_TEST_TMPDIR/gh-body.md"
  export GH_STUB_FAIL=""
  export EVAL_GRANT_LINE="audit-grant 2"
  mkdir -p "$WORK/.gaia/scripts" "$BIN"
  local library
  for library in autonomy-park.sh main-root-lib.sh branch-name-lib.sh usage-lib.sh machine-local-ref-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$library" "$WORK/.gaia/scripts/$library"
  done
  cp "$REPO_ROOT/.gaia/autonomy-park-reasons.json" "$WORK/.gaia/autonomy-park-reasons.json"
  REASONS="$WORK/.gaia/autonomy-park-reasons.json"
  printf '%s\n' '#!/usr/bin/env bash' \
    '[ -n "$EVAL_GRANT_LINE" ] || { echo "no recorded round" >&2; exit 2; }' \
    'jq -n --arg line "$EVAL_GRANT_LINE" "{grant_line: \$line}"' > "$WORK/.gaia/scripts/audit-loop-eval.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$GH_LOG"' \
    'if [ -n "$GH_STUB_FAIL" ]; then echo "gh: To get started with GitHub CLI, please run: gh auth login" >&2; exit 4; fi' \
    'while [ "$#" -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$GH_BODY"; shift; done' > "$BIN/gh"
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"

  git init -q --bare "$REMOTE"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.email park@example.invalid
  git -C "$WORK" config user.name park
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m base
  git -C "$WORK" remote add origin "$REMOTE"
  git -C "$WORK" push -q origin main
  git -C "$WORK" checkout -q -b feat/12-park-me
  git -C "$WORK" commit -q --allow-empty -m work
  RUN_DIRECTORY="$WORK/.gaia/local/runs/feat/12-park-me"
  MARKER="$RUN_DIRECTORY/$(jq -r .marker_file "$REASONS")"
}

park() {
  run bash -c 'cd "$1" && shift && bash .gaia/scripts/autonomy-park.sh "$@"' park "$WORK" "$@"
}

remote_head() {
  git -C "$REMOTE" rev-parse --verify --quiet "refs/heads/$1"
}

# no_side_effects: nothing pushed, no comment, no marker, no state.
no_side_effects() {
  [ -z "$(remote_head feat/12-park-me)" ] || return 1
  [ ! -e "$GH_LOG" ] || return 1
  [ ! -e "$MARKER" ] || return 1
  [ ! -e "$RUN_DIRECTORY/STATE.md" ]
}

@test "merge-ready: saves state, pushes, comments, then writes the marker and prints the next step" {
  mkdir -p "$RUN_DIRECTORY"
  printf '# State\n\n## Facts\n\n- kept line\n\nNEXT: re-run the audit\n' > "$RUN_DIRECTORY/STATE.md"
  park --reason merge-ready --pr 34
  [ "$status" -eq 0 ]
  [ "$output" = "Parked merge-ready on feat/12-park-me (PR #34). Next: send a PushNotification if that tool is available, then end this iteration and schedule no work on this item." ]
  [ "$(remote_head feat/12-park-me)" = "$(git -C "$WORK" rev-parse HEAD)" ]
  grep -qx 'pr comment 34 --body-file .*' "$GH_LOG"
  grep -qF "$(jq -r '.reasons["merge-ready"].resume' "$REASONS")" "$GH_BODY"
  grep -qF 'branch `feat/12-park-me`' "$GH_BODY"
  jq -e --arg head "$(git -C "$WORK" rev-parse HEAD)" \
    '.schema == 1 and .reason == "merge-ready" and .branch == "feat/12-park-me" and .pr == 34 and .head == $head
     and (.parked_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' "$MARKER"
  grep -qx -- '- kept line' "$RUN_DIRECTORY/STATE.md"
  grep -qx 'NEXT: re-run the audit' "$RUN_DIRECTORY/STATE.md"
  grep -qx -- '- Reason: merge-ready (a merge waiting for you)' "$RUN_DIRECTORY/STATE.md"
  grep -qx -- '- PR: #34' "$RUN_DIRECTORY/STATE.md"
}

@test "audit-checkpoint: the comment and the state carry the brief's grant line, fenced alone" {
  park --reason audit-checkpoint --pr 34
  [ "$status" -eq 0 ]
  [ "$(grep -n -x 'audit-grant 2' "$GH_BODY" | cut -d: -f1)" -gt 1 ]
  [ "$(grep -B1 -x 'audit-grant 2' "$GH_BODY")" = $'```\naudit-grant 2' ]
  [ "$(grep -A1 -x 'audit-grant 2' "$GH_BODY")" = $'audit-grant 2\n```' ]
  grep -qx -- '- Grant line: `audit-grant 2`' "$RUN_DIRECTORY/STATE.md"
}

@test "audit-checkpoint with no audit loop state is refused before any side effect" {
  EVAL_GRANT_LINE="" park --reason audit-checkpoint --pr 34
  [ "$status" -eq 2 ]
  [[ "$output" == *"no grant line"* ]]
  no_side_effects
}

@test "question with no PR: pushes and parks without a comment; the detail lands in the state" {
  park --reason question --detail "Which name should the flag take?"
  [ "$status" -eq 0 ]
  [ -n "$(remote_head feat/12-park-me)" ]
  [ ! -e "$GH_LOG" ]
  jq -e '.reason == "question" and .pr == null' "$MARKER"
  grep -qx -- '- Detail: Which name should the flag take?' "$RUN_DIRECTORY/STATE.md"
}

@test "question with a PR puts the question in the comment" {
  park --reason question --pr 9 --detail "Which name should the flag take?"
  [ "$status" -eq 0 ]
  grep -qx 'Which name should the flag take?' "$GH_BODY"
}

@test "every reason code in the data file parks" {
  local code count=0
  for code in $(jq -r '.reasons | keys[]' "$REASONS"); do
    rm -f "$GH_LOG"
    park --reason "$code" --pr 7 --detail "detail for $code"
    [ "$status" -eq 0 ] || return 1
    jq -e --arg code "$code" '.reason == $code' "$MARKER" || return 1
    count=$((count + 1))
  done
  [ "$count" -eq "$(jq '.reasons | length' "$REASONS")" ]
  [ "$count" -gt 0 ]
}

# bats test_tags=protected
@test "an unknown reason code is refused before any side effect and names the known codes" {
  park --reason later --pr 34
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown reason code 'later'"* ]]
  [[ "$output" == *"merge-ready"* ]]
  no_side_effects
}

@test "a malformed reason entry fails closed" {
  jq '.reasons["merge-ready"].requires_pr = "yes"' "$REASONS" > "$REASONS.new"
  mv "$REASONS.new" "$REASONS"
  park --reason merge-ready --pr 34
  [ "$status" -eq 2 ]
  no_side_effects
}

@test "a reason that needs a PR or a detail is refused without one" {
  park --reason merge-ready
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs --pr"* ]]
  park --reason question
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs --detail"* ]]
  park --reason merge-ready --pr 3x
  [ "$status" -eq 2 ]
  no_side_effects
}

# bats test_tags=protected
@test "a machine-local reference in the comment is refused before any side effect" {
  park --reason question --pr 9 --detail "see .gaia/local/runs/feat/12-park-me/findings.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"machine-local reference"* ]]
  no_side_effects
}

# bats test_tags=protected
@test "a refused push exits 1, names the push, and writes no marker or comment" {
  printf '#!/bin/sh\necho "rejected by policy" >&2\nexit 1\n' > "$REMOTE/hooks/pre-receive"
  chmod +x "$REMOTE/hooks/pre-receive"
  park --reason merge-ready --pr 34
  [ "$status" -eq 1 ]
  [[ "$output" == "autonomy-park: push refused:"* ]]
  [ ! -e "$MARKER" ]
  [ ! -e "$GH_LOG" ]
}

# bats test_tags=protected
@test "a failed gh comment exits 1, names gh, and writes no marker" {
  GH_STUB_FAIL=1 park --reason merge-ready --pr 34
  [ "$status" -eq 1 ]
  [[ "$output" == "autonomy-park: gh pr comment on PR #34 failed: "*"gh auth login"* ]]
  [ ! -e "$MARKER" ]
}

@test "a re-park that fails removes the earlier marker; a re-park that succeeds keeps one Parked section" {
  park --reason merge-ready --pr 34
  [ "$status" -eq 0 ]
  park --reason audit-checkpoint --pr 34
  [ "$status" -eq 0 ]
  [ "$(grep -c '^## Parked$' "$RUN_DIRECTORY/STATE.md")" -eq 1 ]
  grep -qx -- '- Reason: audit-checkpoint (an audit checkpoint)' "$RUN_DIRECTORY/STATE.md"
  GH_STUB_FAIL=1 park --reason merge-ready --pr 34
  [ "$status" -eq 1 ]
  [ ! -e "$MARKER" ]
}

@test "the default branch and a detached HEAD are refused" {
  git -C "$WORK" checkout -q main
  park --reason merge-ready --pr 34
  [ "$status" -eq 2 ]
  [[ "$output" == *"default branch"* ]]
  git -C "$WORK" checkout -q --detach feat/12-park-me
  park --reason merge-ready --pr 34
  [ "$status" -eq 2 ]
  [[ "$output" == *"detached"* ]]
  [ ! -e "$GH_LOG" ]
}
