#!/usr/bin/env bats
#
# The stash reaper in .gaia/scripts/stash-reap-lib.sh: it drops the stash
# entries of spent branches from the stack every worktree shares, and keeps an
# entry whose branch is live, held by a worktree, or unnamed.
#
# Run under bash 5: `.gaia/scripts/bats5.sh .gaia/scripts/tests/stash-reap-lib.bats`.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  # shellcheck source=/dev/null
  . "$SCRIPT_DIRECTORY/branch-name-lib.sh"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIRECTORY/stash-reap-lib.sh"
  MAIN="$BATS_TEST_TMPDIR/main"
  git init -q -b trunk "$MAIN"
  git -C "$MAIN" config user.name fixture
  git -C "$MAIN" config user.email fixture@example.com
  echo base >"$MAIN/f.txt"
  git -C "$MAIN" add f.txt
  git -C "$MAIN" commit -q -m base
}

# stash_on <branch>: push one entry made on <branch> from the main checkout,
# leaving the checkout back on trunk with the branch in place.
stash_on() {
  git -C "$MAIN" checkout -q -B "$1" trunk
  echo "$1" >>"$MAIN/f.txt"
  git -C "$MAIN" stash push -q -m "$1 wip"
  git -C "$MAIN" checkout -q trunk
}

live_branches() {
  git -C "$MAIN" for-each-ref --format='%(refname:lstrip=2)' refs/heads/
  git -C "$MAIN" worktree list --porcelain | sed -n 's|^branch refs/heads/||p'
}

stash_subjects() { git -C "$MAIN" log -g --format=%s refs/stash 2>/dev/null; }

# bats test_tags=protected
@test "a spent branch's entry is dropped; a live, a worktree-held and an unnamed entry are kept" {
  stash_on gone
  stash_on live
  stash_on held
  git -C "$MAIN" worktree add -q "$BATS_TEST_TMPDIR/held-tree" held
  local spent_hash
  spent_hash="$(git -C "$MAIN" log -g --format='%H %s' refs/stash | sed -n 's/ On gone: gone wip$//p')"
  [ -n "$spent_hash" ]
  git -C "$MAIN" branch -q -D gone
  echo stray >>"$MAIN/f.txt"
  local created_hash
  created_hash="$(git -C "$MAIN" stash create)"
  git -C "$MAIN" checkout -q -- f.txt
  git -C "$MAIN" stash store -m autostash \
    "$(git -C "$MAIN" commit-tree -p HEAD -p "$created_hash^2" -m autostash "$created_hash^{tree}")"

  run gaia_stash_reap "$MAIN" "$(live_branches)"
  [ "$status" -eq 0 ]
  [ "$output" = "dropped $spent_hash gone" ]
  run stash_subjects
  grep -qF 'On gone:' <<<"$output" && return 1
  grep -qF 'On live: live wip' <<<"$output"
  grep -qF 'On held: held wip' <<<"$output"
  grep -qxF 'autostash' <<<"$output"
}

@test "with a branch named, only that spent branch's entries are dropped" {
  stash_on first
  stash_on second
  git -C "$MAIN" branch -q -D first second
  run gaia_stash_reap "$MAIN" "$(live_branches)" first
  [ "$status" -eq 0 ]
  grep -qF ' first' <<<"$output"
  run stash_subjects
  grep -qF 'On first:' <<<"$output" && return 1
  grep -qF 'On second: second wip' <<<"$output"
}

@test "an entry made under a worktree- spelling is live under its canonical branch" {
  stash_on 'worktree-fix+12-thing'
  git -C "$MAIN" branch -q -m 'worktree-fix+12-thing' fix/12-thing
  run gaia_stash_reap "$MAIN" "$(live_branches)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run stash_subjects
  grep -qF 'On worktree-fix+12-thing:' <<<"$output"
}

@test "an empty stack and an unloaded subject parser drop nothing" {
  run gaia_stash_reap "$MAIN" "$(live_branches)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  stash_on gone
  git -C "$MAIN" branch -q -D gone
  unset -f stash_subject_branch
  run gaia_stash_reap "$MAIN" "$(live_branches)"
  [ "$status" -eq 0 ]
  grep -qF 'skipped stash: the stash subject parser did not load' <<<"$output"
  run stash_subjects
  grep -qF 'On gone: gone wip' <<<"$output"
}
