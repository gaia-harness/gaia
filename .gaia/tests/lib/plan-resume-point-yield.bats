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

@test "a yield block for phase 3 after committed phases 1 and 2 resumes at phase 3" {
  local sha_one sha_two
  sha_one="$(commit_one one)"
  sha_two="$(commit_one two)"
  {
    commit_block 1 "$sha_one"
    commit_block 2 "$sha_two"
    yield_block 3 1
  } >"$PLAN/PROGRESS.md"
  resume --phases 4
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "3" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha_one" ]
  [ "${lines[2]}" = "COMPLETE 2 $sha_two" ]
  [ "${#lines[@]}" -eq 3 ]
  echo "$output" | grep -qF 'COMPLETE 3' && return 1
  true
}

@test "a yield block for phase 3 followed by its commit block completes phase 3" {
  local sha_one sha_two sha_three
  sha_one="$(commit_one one)"
  sha_two="$(commit_one two)"
  sha_three="$(commit_one three)"
  {
    commit_block 1 "$sha_one"
    commit_block 2 "$sha_two"
    yield_block 3 1
    commit_block 3 "$sha_three"
  } >"$PLAN/PROGRESS.md"
  resume --phases 4
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "4" ]
  [ "${lines[3]}" = "COMPLETE 3 $sha_three" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "two yield blocks for the same phase followed by its commit block complete the phase" {
  local sha_one sha_two
  sha_one="$(commit_one one)"
  sha_two="$(commit_one two)"
  {
    commit_block 1 "$sha_one"
    yield_block 2 1
    yield_block 2 2
    commit_block 2 "$sha_two"
  } >"$PLAN/PROGRESS.md"
  resume --phases 2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "3" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha_one" ]
  [ "${lines[2]}" = "COMPLETE 2 $sha_two" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "red twin: a reader that accepts the Yield line as an anchor reports a yielded phase complete" {
  local sha_one sha_two mutated="$BATS_TEST_TMPDIR/plan-resume-point-mutated.sh"
  sha_one="$(commit_one one)"
  sha_two="$(commit_one two)"
  # The yield number is the token a mutated reader would try as a commit, so a
  # tag of that name on an ancestor lets the mutation show its effect.
  git -C "$REPO" tag 1 "$sha_one"
  {
    commit_block 1 "$sha_one"
    commit_block 2 "$sha_two"
    yield_block 3 1
  } >"$PLAN/PROGRESS.md"
  sed -e 's|\^Commit:\[\[:space:\]\]\*|^(Commit\|Yield):[[:space:]]*|g' "$SCRIPT" >"$mutated"
  cmp -s "$SCRIPT" "$mutated" && return 1
  run bash "$SCRIPT" --git-dir "$REPO" --plan-dir "$PLAN" --phases 4
  [ "${lines[0]}" = "3" ]
  run bash "$mutated" --git-dir "$REPO" --plan-dir "$PLAN" --phases 4
  [ "${lines[0]}" = "4" ]
}
