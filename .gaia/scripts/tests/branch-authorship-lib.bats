#!/usr/bin/env bats
#
# Suite for .gaia/scripts/branch-authorship-lib.sh: the three-state authorship
# answer for the audit loop, the filer and the worthiness step.
#
# AUTHORSHIP_SCRIPTS_DIRECTORY points the suite at a scratch copy of the
# scripts, which is how a mutant is run against it without touching the file.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/branch-authorship-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="${AUTHORSHIP_SCRIPTS_DIRECTORY:-$REPO_ROOT/.gaia/scripts}"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  unset GIT_DIR GIT_WORK_TREE
  # shellcheck source=/dev/null
  . "$SCRIPTS/branch-authorship-lib.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  build_fixture "$FIXTURE" main
}

# build_fixture <dir> <default-branch>: f.txt (10 lines) and g.txt on the
# default branch, then a `feature` branch whose commit rewrites f.txt line 3.
build_fixture() {
  mkdir -p "$1"
  git -C "$1" init -q -b "$2"
  seq 1 10 | sed 's/^/line /' >"$1/f.txt"
  printf 'x\n' >"$1/g.txt"
  git -C "$1" add -A
  git -C "$1" commit -q -m base
  git -C "$1" checkout -q -b feature
  sed -i.bak 's/^line 3$/edited 3/' "$1/f.txt"
  rm -f "$1/f.txt.bak"
  git -C "$1" commit -q -am edit
}

@test "sourcing defines the contract names and runs nothing" {
  run bash -c ". '$SCRIPTS/branch-authorship-lib.sh' && declare -F gaia_authorship_for_head gaia_authorship_site_state gaia_authorship_merge_base gaia_authorship_names gaia_authorship_hunks_json && [ -n \"\$GAIA_AUTHORSHIP_JQ\" ]"
  [ "$status" -eq 0 ]
  run bash -c ". '$SCRIPTS/branch-authorship-lib.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "self-contained: a clean shell without the state library answers for_head" {
  run env -i PATH="$PATH" GIT_AUTHOR_NAME=t bash -c ". '$SCRIPTS/branch-authorship-lib.sh'; gaia_authorship_for_head '$FIXTURE'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = computed ]
  [ "$(jq -r '.names | join(",")' <<<"$output")" = f.txt ]
}

@test "sourcing into a shell holding the state library leaves its git and oid helpers unchanged" {
  run bash -c ". '$SCRIPTS/audit-loop-state-lib.sh'; before=\$(declare -f _gaia_loop_git gaia_loop_is_oid); . '$SCRIPTS/branch-authorship-lib.sh'; after=\$(declare -f _gaia_loop_git gaia_loop_is_oid); [ -n \"\$before\" ] && [ \"\$before\" = \"\$after\" ]"
  [ "$status" -eq 0 ]
}

@test "the library never redefines a gaia_loop name" {
  run grep -nE '^_?gaia_loop_[a-z_]*\(\)' "$SCRIPTS/branch-authorship-lib.sh"
  [ "$status" -eq 1 ]
}

@test "site_state: authored, not-authored and outside-the-diff answers" {
  [ "$(gaia_authorship_site_state "$FIXTURE" f.txt 3)" = authored ]
  [ "$(gaia_authorship_site_state "$FIXTURE" f.txt 7)" = not-authored ]
  [ "$(gaia_authorship_site_state "$FIXTURE" g.txt 1)" = not-authored ]
  [ "$(gaia_authorship_site_state "$FIXTURE" f.txt 0)" = authored ]
  [ "$(gaia_authorship_site_state "$FIXTURE" f.txt null)" = authored ]
}

@test "site_state: unsafe path and out-of-range line answer unknown" {
  [ "$(gaia_authorship_site_state "$FIXTURE" ../x 1)" = unknown ]
  [ "$(gaia_authorship_site_state "$FIXTURE" -rf 1)" = unknown ]
  [ "$(gaia_authorship_site_state "$FIXTURE" f.txt 9999999999)" = unknown ]
  [ "$(gaia_authorship_site_state "$FIXTURE" f.txt -1)" = unknown ]
  [ "$(gaia_authorship_site_state "$FIXTURE" f.txt x)" = unknown ]
}

@test "site_state: ./path and tree-prefixed path answer as the bare path" {
  [ "$(gaia_authorship_site_state "$FIXTURE" ./f.txt 3)" = authored ]
  [ "$(gaia_authorship_site_state "$FIXTURE" "$FIXTURE/f.txt" 3)" = authored ]
  [ "$(gaia_authorship_site_state "$FIXTURE" "$FIXTURE/f.txt" 7)" = not-authored ]
}

@test "for_head from a linked worktree returns the branch hunks, not an empty diff" {
  git -C "$FIXTURE" checkout -q main
  git -C "$FIXTURE" worktree add -q "$BATS_TEST_TMPDIR/wt" feature
  run gaia_authorship_for_head "$BATS_TEST_TMPDIR/wt"
  [ "$(jq -r '.state' <<<"$output")" = computed ]
  [ "$(jq -r '.hunks | length' <<<"$output")" -gt 0 ]
  [ "$(jq -r '.hunks[0].p' <<<"$output")" = f.txt ]
  [ "$(gaia_authorship_for_head "$FIXTURE" | jq -r .state)" = on-default-branch ]
  [ "$(gaia_authorship_site_state "$BATS_TEST_TMPDIR/wt" f.txt 3)" = authored ]
}

@test "an uncommitted edit adds nothing" {
  printf 'more\n' >>"$FIXTURE/g.txt"
  printf 'new\n' >"$FIXTURE/h.txt"
  run gaia_authorship_for_head "$FIXTURE"
  [ "$(jq -c '.names' <<<"$output")" = '["f.txt"]' ]
  [ "$(jq -r '.hunks | map(.p) | unique | join(",")' <<<"$output")" = f.txt ]
}

@test "on the default branch it answers on-default-branch, even with main ahead of origin/main" {
  git -C "$FIXTURE" update-ref refs/remotes/origin/main "$(git -C "$FIXTURE" rev-parse main)"
  git -C "$FIXTURE" checkout -q main
  printf 'ahead\n' >"$FIXTURE/a.txt"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m ahead
  [ "$(gaia_authorship_for_head "$FIXTURE" | jq -r .state)" = on-default-branch ]
  [ "$(gaia_authorship_site_state "$FIXTURE" a.txt 1)" = on-default-branch ]
}

@test "a repo with no default ref answers unknown with null names and hunks" {
  build_fixture "$BATS_TEST_TMPDIR/trunk-repo" trunk
  run gaia_authorship_for_head "$BATS_TEST_TMPDIR/trunk-repo"
  [ "$(jq -c '[.state,.names,.hunks]' <<<"$output")" = '["unknown",null,null]' ]
  [ "$(gaia_authorship_site_state "$BATS_TEST_TMPDIR/trunk-repo" f.txt 3)" = unknown ]
}

@test "authorship jq: three outcomes from the predicate directly" {
  run jq -n -r "$GAIA_AUTHORSHIP_JQ"'
    [ ({path:"f.txt",line:3} | authorship(["f.txt"]; [{p:"f.txt",s:3,e:3}])),
      ({path:"f.txt",line:5} | authorship(["f.txt"]; [{p:"f.txt",s:3,e:3}])),
      ({path:"f.txt",line:5} | authorship(null; null)) ] | join(",")'
  [ "$output" = "authored,not-authored,unknown" ]
}

@test "red twin: no merge base counts for the audit mapping and reads unknown for the library" {
  build_fixture "$BATS_TEST_TMPDIR/trunk-repo" trunk
  local state audit_answer
  state="$(gaia_authorship_for_head "$BATS_TEST_TMPDIR/trunk-repo")"
  audit_answer="$(jq -n -r --argjson s "$state" "$GAIA_AUTHORSHIP_JQ"'
    {path:"f.txt",line:7} | (authorship($s.names; $s.hunks) != "not-authored")')"
  [ "$audit_answer" = true ]
  [ "$(gaia_authorship_site_state "$BATS_TEST_TMPDIR/trunk-repo" f.txt 7)" = unknown ]
}
