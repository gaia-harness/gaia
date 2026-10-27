#!/usr/bin/env bats
# Two clones that decline the same finding class, each on its own branch,
# squash-merge in turn without conflict: the committed decline store names every
# file uniquely, so concurrent declines never collide, and exactly one file
# governs the class afterwards.
#
# The writer under test is the committed CLI bundle, run as a subprocess with a
# scratch clone as its working directory. The mutation case forces two
# different declines onto one filename and asserts the second merge conflicts,
# which proves the merge assertion can fail and that the per-file naming is
# what prevents the conflict.
#
# Every scratch repository lives under $BATS_TEST_TMPDIR; the real checkout's
# index, HEAD and working tree are never touched.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  export REPO_ROOT
  export DECLINE_FOLDER=".gaia/codify-declines"
  export FROZEN_INSTANT="2026-10-27T12:00:00.000Z"
}

# Pin the shared identity in clone $1: both clones are the same engineer.
pin_identity() {
  git -C "$1" config user.name "Scratch Tester"
  git -C "$1" config user.email "scratch@example.com"
}

# Stage everything in clone $1 and record it as one revision titled $2.
record_revision() {
  git -C "$1" add -A || return 1
  git -C "$1" commit --quiet -m "$2"
}

# Seed a bare origin whose main holds one initial revision.
make_origin() {
  local seed="$BATS_TEST_TMPDIR/seed"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init --quiet --bare --initial-branch=main "$ORIGIN" || return 1
  git init --quiet --initial-branch=main "$seed" || return 1
  pin_identity "$seed"
  printf 'seed\n' > "$seed/README.md"
  record_revision "$seed" "initial" || return 1
  git -C "$seed" remote add origin "$ORIGIN" || return 1
  git -C "$seed" push --quiet origin main || return 1
}

clone_origin() {
  git clone --quiet --local "$ORIGIN" "$1" || return 1
  pin_identity "$1"
}

# decline_on_branch <clone> <branch> <pr-count> [rename-to-basename]
# Declines rule/x on its own branch with the real bundle, freezes the recorded
# instant, optionally renames the file, then records and pushes the branch.
# Prints the decline file's repo-relative path.
decline_on_branch() {
  local clone="$1" branch="$2" pr_count="$3" rename_to="${4:-}" relative_path
  git -C "$clone" checkout --quiet -b "$branch" || return 1
  relative_path="$( cd "$clone" && "$REPO_ROOT/.gaia/cli/gaia" codify-ledger record \
    --finding-class rule/x --pr-count "$pr_count" --audited-pr-count 40 )" || return 1
  [ -f "$clone/$relative_path" ] || { echo "no decline file at $relative_path" >&2; return 1; }
  jq --arg instant "$FROZEN_INSTANT" '.declined_at = $instant' "$clone/$relative_path" \
    > "$clone/$relative_path.new" || return 1
  mv "$clone/$relative_path.new" "$clone/$relative_path"
  if [ -n "$rename_to" ]; then
    mv "$clone/$relative_path" "$clone/$DECLINE_FOLDER/$rename_to"
    relative_path="$DECLINE_FOLDER/$rename_to"
  fi
  record_revision "$clone" "decline rule/x on $branch" || return 1
  git -C "$clone" push --quiet origin "$branch" || return 1
  printf '%s\n' "$relative_path"
}

# squash_merge_into_main <clone> <branch>: non-zero when the merge conflicts.
squash_merge_into_main() {
  git -C "$1" merge --squash --quiet "origin/$2" || {
    echo "squash merge of $2 conflicted" >&2
    return 1
  }
  git -C "$1" commit --quiet -m "squash $2"
}

@test "two same-class declines from clones with one identity squash-merge without conflict" {
  make_origin || return 1
  clone_origin "$BATS_TEST_TMPDIR/clone-a" || return 1
  clone_origin "$BATS_TEST_TMPDIR/clone-b" || return 1
  local path_a path_b
  path_a="$(decline_on_branch "$BATS_TEST_TMPDIR/clone-a" decline-a 4)" || return 1
  path_b="$(decline_on_branch "$BATS_TEST_TMPDIR/clone-b" decline-b 4)" || return 1
  [ "$path_a" != "$path_b" ] || { echo "both declines share the name $path_a" >&2; return 1; }

  local merged="$BATS_TEST_TMPDIR/merged"
  clone_origin "$merged" || return 1
  git -C "$merged" fetch --quiet origin || return 1
  squash_merge_into_main "$merged" decline-a || return 1
  squash_merge_into_main "$merged" decline-b || return 1

  local file_count
  file_count="$(find "$merged/$DECLINE_FOLDER" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
  [ "$file_count" = "2" ] || { echo "expected 2 decline files, found $file_count" >&2; return 1; }
}

@test "exactly one merged decline governs and it is the byte-wise last filename" {
  make_origin || return 1
  clone_origin "$BATS_TEST_TMPDIR/clone-a" || return 1
  clone_origin "$BATS_TEST_TMPDIR/clone-b" || return 1
  local path_a path_b expected_basename
  path_a="$(decline_on_branch "$BATS_TEST_TMPDIR/clone-a" decline-a 4)" || return 1
  path_b="$(decline_on_branch "$BATS_TEST_TMPDIR/clone-b" decline-b 4)" || return 1

  local merged="$BATS_TEST_TMPDIR/merged"
  clone_origin "$merged" || return 1
  git -C "$merged" fetch --quiet origin || return 1
  squash_merge_into_main "$merged" decline-a || return 1
  squash_merge_into_main "$merged" decline-b || return 1

  expected_basename="$(printf '%s\n%s\n' "$(basename "$path_a")" "$(basename "$path_b")" | LC_ALL=C sort | tail -1)"
  local listing governing_count governing_basename committed_count
  listing="$( cd "$merged" && "$REPO_ROOT/.gaia/cli/gaia" codify-ledger list )" || return 1
  committed_count="$(jq '.committed | length' <<<"$listing")"
  [ "$committed_count" = "2" ] || { echo "expected 2 committed entries, found $committed_count" >&2; return 1; }
  governing_count="$(jq '[.committed[] | select(.governing)] | length' <<<"$listing")"
  [ "$governing_count" = "1" ] || { echo "expected 1 governing entry, found $governing_count" >&2; return 1; }
  governing_basename="$(jq -r '.committed[] | select(.governing) | .path' <<<"$listing" | xargs -n1 basename)"
  [ "$governing_basename" = "$expected_basename" ] || {
    echo "governing $governing_basename, expected $expected_basename" >&2
    return 1
  }
}

@test "two different declines forced onto one filename conflict on the second merge" {
  make_origin || return 1
  clone_origin "$BATS_TEST_TMPDIR/clone-a" || return 1
  clone_origin "$BATS_TEST_TMPDIR/clone-b" || return 1
  local path_a
  path_a="$(decline_on_branch "$BATS_TEST_TMPDIR/clone-a" decline-a 4)" || return 1
  # Different pr-count, so the content differs under the shared name.
  decline_on_branch "$BATS_TEST_TMPDIR/clone-b" decline-b 5 "$(basename "$path_a")" > /dev/null || return 1

  local merged="$BATS_TEST_TMPDIR/merged"
  clone_origin "$merged" || return 1
  git -C "$merged" fetch --quiet origin || return 1
  squash_merge_into_main "$merged" decline-a || return 1
  run squash_merge_into_main "$merged" decline-b
  [ "$status" -ne 0 ] || return 1
  grep -qF -- "conflicted" <<<"$output" || return 1
}
