#!/usr/bin/env bats
#
# .gaia/scripts/plan-resume-point.sh against PROGRESS.md yield blocks.
#
# An orchestrator records a sub-agent yield as a block headed
# `## Phase N, <title> (YIELD k)` whose first content line is `Yield: k` and
# which carries no Commit line. The resume point must read that block as no
# anchor for its phase (the phase is incomplete), and a Commit block appended
# for the same phase afterwards must still complete it, whatever number of
# yield blocks precede it.
#
# Fixtures are real git repos with real commits in $BATS_TEST_TMPDIR.
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/plan-resume-point.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  PLAN="$BATS_TEST_TMPDIR/plan"
  mkdir -p "$REPO" "$PLAN"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
}

# commit_one <message>: a commit on the fixture repo, echoing its short sha.
commit_one() {
  echo "$1" >>"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit --quiet -m "$1"
  git -C "$REPO" rev-parse --short HEAD
}

# commit_block <n> <sha>: a PROGRESS.md commit block.
commit_block() {
  printf '## Phase %s, Phase %s title\nCommit: %s\n\n_No notes._\n\n' "$1" "$1" "$2"
}

# yield_block <n> <k>: a PROGRESS.md yield block in the format the
# orchestrator appends.
yield_block() {
  printf '## Phase %s, Phase %s title (YIELD %s)\nYield: %s\nTask: task-build.md\nBand: elevated\nHandoff: /plan/handoffs/phase-%s-task-build-yield-%s.md\n\n' "$1" "$1" "$2" "$2" "$1" "$2"
}

resume() {
  run bash "$SCRIPT" --git-dir "$REPO" --plan-dir "$PLAN" "$@"
}

@test "a yield block is no anchor for its phase and a later commit block completes it after one or several yields" {
  local sha_one sha_two sha_three expected
  sha_one="$(commit_one one)"
  sha_two="$(commit_one two)"
  sha_three="$(commit_one three)"

  {
    commit_block 1 "$sha_one"
    commit_block 2 "$sha_two"
    yield_block 3 1
  } >"$PLAN/PROGRESS.md"
  resume --phases 4
  expected="$(printf '3\nCOMPLETE 1 %s\nCOMPLETE 2 %s' "$sha_one" "$sha_two")"
  [ "$status" -eq 0 ] || { echo "yield after two commits: status $status"; return 1; }
  [ "$output" = "$expected" ] || { echo "yield after two commits: got '$output'"; return 1; }

  {
    commit_block 1 "$sha_one"
    commit_block 2 "$sha_two"
    yield_block 3 1
    commit_block 3 "$sha_three"
  } >"$PLAN/PROGRESS.md"
  resume --phases 4
  expected="$(printf '4\nCOMPLETE 1 %s\nCOMPLETE 2 %s\nCOMPLETE 3 %s' "$sha_one" "$sha_two" "$sha_three")"
  [ "$status" -eq 0 ] || { echo "yield then commit: status $status"; return 1; }
  [ "$output" = "$expected" ] || { echo "yield then commit: got '$output'"; return 1; }

  {
    commit_block 1 "$sha_one"
    yield_block 2 1
    yield_block 2 2
    commit_block 2 "$sha_two"
  } >"$PLAN/PROGRESS.md"
  resume --phases 2
  expected="$(printf '3\nCOMPLETE 1 %s\nCOMPLETE 2 %s' "$sha_one" "$sha_two")"
  [ "$status" -eq 0 ] || { echo "two yields then commit: status $status"; return 1; }
  [ "$output" = "$expected" ] || { echo "two yields then commit: got '$output'"; return 1; }
}
