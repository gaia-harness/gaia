#!/usr/bin/env bats
# Independent-oracle tests for .gaia/scripts/plan-resume-point.sh.
#
# plan-resume-point.sh computes a git-arbitrated resume point for a GAIA
# plan: for each PROGRESS.md phase block it proves the recorded Commit: sha
# is an ancestor of a given ref, echoes the first-gap phase (or M+1 when all
# phases are complete) on line 1, followed by zero or more
# `COMPLETE <n> <short-sha>` lines for the verified-complete phases, and
# always exits 0.
#
# This suite is built ONLY from the frozen contract in a spec-derived plan's
# README (the plan folder nested in its spec's notebook folder) and the
# per-UAT echo table; it does not read the helper's implementation. Fixtures are real git repos
# with real commits (no mocked git): non-ancestor fixtures move the branch
# away with `git reset --hard`, and the worktree-HEAD fixture uses a real
# second branch. Assertions follow .claude/rules/bats-assertions.md
# (bash-3.2-safe): no bare `[[ ]]` as a non-final assertion.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/plan-resume-point.sh"
  REPO="$(mktemp -d -t gaia-resume-XXXXXX)"
  PLAN="$REPO/plan"
  new_repo
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

# Reset $REPO to an empty repo with an empty plan folder, so each case starts clean.
new_repo() {
  rm -rf "$REPO"
  mkdir -p "$REPO"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  mkdir -p "$PLAN"
}

# Make a commit on the current branch of $REPO, echo its short-sha.
_commit() {
  echo "$1" >> "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit --quiet -m "$1"
  git -C "$REPO" rev-parse --short HEAD
}

# Invoke the real helper. Git context is $REPO; plan dir is $PLAN. Extra
# args (e.g. --phases 3, --branch wt) are passed through.
_run_helper() {
  run bash "$SCRIPT" --git-dir "$REPO" --plan-dir "$PLAN" "$@"
}

# _block <heading> <commit line>: one PROGRESS.md block.
_block() {
  printf '## %s\nCommit: %s\n\n_No notes._\n\n' "$1" "$2"
}

# _expect <label> <expected output> [helper args]: the helper exits 0 and prints
# exactly the expected lines.
_expect() {
  local label="$1" expected="$2"
  shift 2
  _run_helper "$@"
  [ "$status" -eq 0 ] || { echo "$label: status $status"; return 1; }
  [ "$output" = "$expected" ] || { echo "$label: got '$output'"; return 1; }
}

@test "resume point: line 1 is the first gap and COMPLETE lines list the ancestor-Commit phases before it" {
  local sha1 sha2 sha3 sha30 nonrepo

  new_repo
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  { _block "Phase 1, First" "$sha1"; _block "Phase 2, Second" "$sha2"; } >"$PLAN/PROGRESS.md"
  _expect "P1 and P2 ancestors, no P3 block" "$(printf '3\nCOMPLETE 1 %s\nCOMPLETE 2 %s' "$sha1" "$sha2")" --phases 3 || return 1

  new_repo
  sha1=$(_commit p1)
  _block "Phase 1, First" "$sha1" >"$PLAN/PROGRESS.md"
  _expect "only a P1 block" "$(printf '2\nCOMPLETE 1 %s' "$sha1")" --phases 3 || return 1

  new_repo
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  git -C "$REPO" reset --hard --quiet HEAD~1
  { _block "Phase 1, First" "$sha1"; _block "Phase 2, Second" "$sha2"; } >"$PLAN/PROGRESS.md"
  _expect "P2 non-ancestor after branch reset" "$(printf '2\nCOMPLETE 1 %s' "$sha1")" --phases 2 || return 1

  new_repo
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  sha3=$(_commit p3)
  { _block "Phase 1, First" "$sha1"; _block "Phase 2, Second" "$sha2"; _block "Phase 3, Third" "$sha3"; } >"$PLAN/PROGRESS.md"
  _expect "P1 P2 P3 all ancestors" "$(printf '4\nCOMPLETE 1 %s\nCOMPLETE 2 %s\nCOMPLETE 3 %s' "$sha1" "$sha2" "$sha3")" --phases 3 || return 1

  new_repo
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  {
    _block "Phase 1, First" "$sha1"
    printf '## Phase 2, Second (HALTED)\n\nRan out of budget before finishing.\n\n'
    _block "Phase 2, Second" "$sha2"
  } >"$PLAN/PROGRESS.md"
  _expect "HALTED Phase 2 block superseded by a later completion block" "$(printf '3\nCOMPLETE 1 %s\nCOMPLETE 2 %s' "$sha1" "$sha2")" --phases 2 || return 1

  new_repo
  sha1=$(_commit p1)
  {
    _block "Phase 1, First" "$sha1"
    printf '## Phase 2, Second\n\nThis block has no Commit anchor, just prose as the first content line.\n'
  } >"$PLAN/PROGRESS.md"
  _expect "P2 block with no Commit anchor" "$(printf '2\nCOMPLETE 1 %s' "$sha1")" --phases 2 || return 1

  new_repo
  sha1=$(_commit p1)
  { _block "Phase 1, First" "$sha1"; _block "Phase 2, Second" "not-a-sha"; } >"$PLAN/PROGRESS.md"
  _expect "P2 Commit is not a sha token" "$(printf '2\nCOMPLETE 1 %s' "$sha1")" --phases 2 || return 1

  new_repo
  sha1=$(_commit p1)
  { _block "Phase 1, First" "$sha1"; _block "Phase 2, Second" "0000000000000000000000000000000000000000"; } >"$PLAN/PROGRESS.md"
  _expect "P2 Commit is a well-formed but non-existent sha" "$(printf '2\nCOMPLETE 1 %s' "$sha1")" --phases 2 || return 1

  new_repo
  sha1=$(_commit p1)
  _block "Phase 1, First" "$sha1" >"$PLAN/PROGRESS.md"
  nonrepo="$BATS_TEST_TMPDIR/nonrepo"
  mkdir -p "$nonrepo"
  run bash "$SCRIPT" --git-dir "$nonrepo" --plan-dir "$PLAN" --phases 2
  [ "$status" -eq 0 ] || { echo "non-repo git dir: status $status"; return 1; }
  [ "$output" = "1" ] || { echo "non-repo git dir: got '$output'"; return 1; }

  new_repo
  sha1=$(_commit p1)
  _block "Phase 1, First" "$sha1" >"$PLAN/PROGRESS.md"
  _expect "canonical single-phase block" "$(printf '2\nCOMPLETE 1 %s' "$sha1")" --phases 1 || return 1

  new_repo
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  sha3=$(_commit p3)
  git -C "$REPO" reset --hard --quiet HEAD~1
  sha30=$(_commit p30)
  {
    _block "Phase 1, First" "$sha1"
    _block "Phase 2, Second" "$sha2"
    _block "Phase 3, Third" "$sha3"
    _block "Phase 30, Thirtieth" "$sha30"
  } >"$PLAN/PROGRESS.md"
  _expect "P3 non-ancestor beside an ancestor Phase 30 block" "$(printf '3\nCOMPLETE 1 %s\nCOMPLETE 2 %s' "$sha1" "$sha2")" --phases 3 || return 1

  new_repo
  sha1=$(_commit p1)
  _block "Phase 1 - First" "$sha1" >"$PLAN/PROGRESS.md"
  _expect "dash-form heading" "$(printf '2\nCOMPLETE 1 %s' "$sha1")" --phases 1 || return 1

  new_repo
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  { _block "Phase 1, First" "$sha1"; _block "Phase 2, Second" "$sha2"; } >"$PLAN/PROGRESS.md"
  _expect "no --phases flag" "$(printf '3\nCOMPLETE 1 %s\nCOMPLETE 2 %s' "$sha1" "$sha2")" || return 1
}

@test "resume point: a plan folder with no PROGRESS.md ledger resumes at phase 1 with no COMPLETE lines" {
  local sha1

  new_repo
  _commit p1 >/dev/null
  _expect "no PROGRESS.md" "1" --phases 3 || return 1

  new_repo
  _commit p1 >/dev/null
  : > "$PLAN/PROGRESS.md"
  _expect "empty PROGRESS.md" "1" --phases 3 || return 1

  new_repo
  _commit p1 >/dev/null
  printf 'this is not a valid summary file\nrandom garbage text\nno phase headings anywhere in here\n' >"$PLAN/PROGRESS.md"
  _expect "garbage PROGRESS.md" "1" --phases 3 || return 1

  # SUMMARY.md is the consolidation output a reduced plan folder keeps, never
  # a ledger, so even one shaped like a ledger block is not read.
  new_repo
  sha1=$(_commit p1)
  _block "Phase 1, First" "$sha1" >"$PLAN/SUMMARY.md"
  _expect "SUMMARY.md without PROGRESS.md" "1" --phases 1 || return 1
}

@test "resume point: ancestry is checked against the --branch ref, not the main ref" {
  local branch_sha main_sha

  new_repo
  _commit base >/dev/null
  git -C "$REPO" checkout --quiet -b wt
  branch_sha=$(_commit wt-only)
  _block "Phase 1, First" "$branch_sha" >"$PLAN/PROGRESS.md"
  _expect "commit reachable only from wt, --branch wt" "$(printf '2\nCOMPLETE 1 %s' "$branch_sha")" --branch wt --phases 1 || return 1
  _expect "same commit, --branch main" "1" --branch main --phases 1 || return 1

  new_repo
  _commit base >/dev/null
  git -C "$REPO" checkout --quiet -b wt
  git -C "$REPO" checkout --quiet main
  main_sha=$(_commit main-only)
  _block "Phase 1, First" "$main_sha" >"$PLAN/PROGRESS.md"
  _expect "commit absent from wt, --branch wt" "1" --branch wt --phases 1 || return 1
}
