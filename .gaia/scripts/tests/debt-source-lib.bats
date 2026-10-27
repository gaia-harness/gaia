#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-source-lib.sh: the source line, the branch
# digest, the tree-state read, the precedence resolve and the retry-file
# retention. Every fixture lives under $BATS_TEST_TMPDIR; no setup_file state
# is shared, so cases appended later cannot collide with it.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/debt-source-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# shellcheck disable=SC2154,SC2030,SC2031
# The library sets the globals the tests read, and bats runs each test in a subshell.

bats_require_minimum_version 1.5.0

setup() {
  REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIB="$REAL_ROOT/.gaia/scripts/debt-source-lib.sh"
  # shellcheck source=/dev/null
  . "$LIB"
}

# make_scratch_repo <directory> <branch>: a repository with one commit on <branch>.
make_scratch_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b "$2"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m init
}

hasher_all_a() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; }
hasher_short() { printf 'xyz'; }
hasher_fails() { return 1; }

@test "digest of a branch is pinned and the worktree spelling matches" {
  run gaia_debt_source_digest debt/1234-foo
  [ "$status" -eq 0 ]
  [ "$output" = "ce624e2ca1a2" ]
  run gaia_debt_source_digest worktree-debt+1234-foo
  [ "$status" -eq 0 ]
  [ "$output" = "ce624e2ca1a2" ]
}

@test "line for a branch has the exact format and no trailing newline" {
  run gaia_debt_source_line_for_branch debt/1234-foo
  [ "$status" -eq 0 ]
  [ "$output" = "<!-- gaia-debt-source: v1 branch=ce624e2ca1a2 -->" ]
  count="$(gaia_debt_source_line_for_branch debt/1234-foo | wc -c | tr -d ' ')"
  expected="$(printf '%s' '<!-- gaia-debt-source: v1 branch=ce624e2ca1a2 -->' | wc -c | tr -d ' ')"
  [ "$count" -eq "$expected" ]
}

@test "line prints the given value without a trailing newline" {
  run gaia_debt_source_line detached
  [ "$output" = "<!-- gaia-debt-source: v1 branch=detached -->" ]
  count="$(gaia_debt_source_line detached | wc -c | tr -d ' ')"
  expected="$(printf '%s' '<!-- gaia-debt-source: v1 branch=detached -->' | wc -c | tr -d ' ')"
  [ "$count" -eq "$expected" ]
}

@test "digest uses a supplied hasher that prints 64 hex characters" {
  run gaia_debt_source_digest debt/1234-foo hasher_all_a
  [ "$status" -eq 0 ]
  [ "$output" = "aaaaaaaaaaaa" ]
}

@test "digest fails and prints nothing for a malformed or failing hasher" {
  run gaia_debt_source_digest debt/1234-foo hasher_short
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run gaia_debt_source_digest debt/1234-foo hasher_fails
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run gaia_debt_source_line_for_branch debt/1234-foo hasher_fails
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "tree state names the checked-out branch" {
  make_scratch_repo "$BATS_TEST_TMPDIR/repo" debt/1234-foo
  status=0
  gaia_debt_source_tree_state "$BATS_TEST_TMPDIR/repo" || status=$?
  [ "$status" -eq 0 ]
  [ "$gaia_debt_source_tree_branch" = "debt/1234-foo" ]
}

@test "tree state reports a detached HEAD with an empty branch" {
  make_scratch_repo "$BATS_TEST_TMPDIR/repo" main
  git -C "$BATS_TEST_TMPDIR/repo" checkout -q --detach
  status=0
  gaia_debt_source_tree_state "$BATS_TEST_TMPDIR/repo" || status=$?
  [ "$status" -eq 1 ]
  [ -z "$gaia_debt_source_tree_branch" ]
}

@test "tree state reports a directory outside any repository" {
  mkdir -p "$BATS_TEST_TMPDIR/plain/inner"
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR/plain"
  status=0
  gaia_debt_source_tree_state "$BATS_TEST_TMPDIR/plain/inner" || status=$?
  [ "$status" -eq 2 ]
  [ -z "$gaia_debt_source_tree_branch" ]
}

@test "tree state answers the short name when a tag shares the branch name" {
  make_scratch_repo "$BATS_TEST_TMPDIR/repo" x
  git -C "$BATS_TEST_TMPDIR/repo" tag x
  gaia_debt_source_tree_state "$BATS_TEST_TMPDIR/repo" || true
  [ "$gaia_debt_source_tree_branch" = "x" ]
}

@test "tree state ignores an inherited git directory variable" {
  make_scratch_repo "$BATS_TEST_TMPDIR/first" debt/1-first
  make_scratch_repo "$BATS_TEST_TMPDIR/second" debt/2-second
  export GIT_DIR="$BATS_TEST_TMPDIR/second/.git"
  gaia_debt_source_tree_state "$BATS_TEST_TMPDIR/first" || true
  [ "$gaia_debt_source_tree_branch" = "debt/1-first" ]
}

@test "resolve prefers the finding field over the flag" {
  printf '{"source_branch": "debt/7-a"}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/8-b "$BATS_TEST_TMPDIR"
  [ "$gaia_debt_source_state" = "branch" ]
  [ "$gaia_debt_source_branch" = "debt/7-a" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=966c09ebcad9 -->" ]
}

@test "resolve uses the flag when the finding has no field" {
  printf '{"a": 1}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/8-b "$BATS_TEST_TMPDIR"
  [ "$gaia_debt_source_state" = "branch" ]
  [ "$gaia_debt_source_branch" = "debt/8-b" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=fe4badbbc786 -->" ]
}

@test "resolve treats an empty source_branch as detached" {
  printf '{"source_branch": ""}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/8-b "$BATS_TEST_TMPDIR"
  [ "$gaia_debt_source_state" = "detached" ]
  [ -z "$gaia_debt_source_branch" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=detached -->" ]
}

@test "resolve ignores a non-string source_branch" {
  printf '{"source_branch": 42}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/8-b "$BATS_TEST_TMPDIR"
  [ "$gaia_debt_source_state" = "branch" ]
  [ "$gaia_debt_source_branch" = "debt/8-b" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=fe4badbbc786 -->" ]
}

@test "resolve falls to unknown with no field, no flag and no repository" {
  printf '{"a": 1}\n' >"$BATS_TEST_TMPDIR/f.json"
  mkdir -p "$BATS_TEST_TMPDIR/plain/inner"
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR/plain"
  status=0
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR/plain/inner" || status=$?
  [ "$status" -eq 0 ]
  [ "$gaia_debt_source_state" = "unknown" ]
  [ -z "$gaia_debt_source_branch" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=unknown -->" ]
}

@test "resolve reads the tree when neither field nor flag is given" {
  printf '{"a": 1}\n' >"$BATS_TEST_TMPDIR/f.json"
  make_scratch_repo "$BATS_TEST_TMPDIR/repo" debt/5-x
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR/repo"
  [ "$gaia_debt_source_state" = "branch" ]
  [ "$gaia_debt_source_branch" = "debt/5-x" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=da97cdeaf0ed -->" ]
}

@test "resolve reads a detached tree as detached" {
  printf '{"a": 1}\n' >"$BATS_TEST_TMPDIR/f.json"
  make_scratch_repo "$BATS_TEST_TMPDIR/repo" main
  git -C "$BATS_TEST_TMPDIR/repo" checkout -q --detach
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR/repo"
  [ "$gaia_debt_source_state" = "detached" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=detached -->" ]
}

@test "resolve yields the unknown line when the digest fails" {
  printf '{"source_branch": "debt/7-a"}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR" hasher_fails
  [ "$gaia_debt_source_line_text" = "$GAIA_DEBT_SOURCE_UNKNOWN_LINE" ]
}

@test "retain records the branch on a retry file lacking the field" {
  printf '{"b": 2, "a": {"c": 1}}\n' >"$BATS_TEST_TMPDIR/retry.json"
  cp "$BATS_TEST_TMPDIR/retry.json" "$BATS_TEST_TMPDIR/orig.json"
  printf '{}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/5-x "$BATS_TEST_TMPDIR"
  gaia_debt_source_retain "$BATS_TEST_TMPDIR/retry.json"
  [ "$(jq -r .source_branch "$BATS_TEST_TMPDIR/retry.json")" = "debt/5-x" ]
  [ "$(jq -S 'del(.source_branch)' "$BATS_TEST_TMPDIR/retry.json")" = "$(jq -S . "$BATS_TEST_TMPDIR/orig.json")" ]
}

@test "retain records an empty branch for a detached resolve" {
  printf '{"b": 2}\n' >"$BATS_TEST_TMPDIR/retry.json"
  printf '{"source_branch": ""}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR"
  [ "$gaia_debt_source_state" = "detached" ]
  gaia_debt_source_retain "$BATS_TEST_TMPDIR/retry.json"
  [ "$(jq -c '.source_branch' "$BATS_TEST_TMPDIR/retry.json")" = '""' ]
}

@test "retain leaves a file that already carries the field byte-identical" {
  printf '{"b": 2,   "source_branch": "debt/9-z"}\n' >"$BATS_TEST_TMPDIR/retry.json"
  cp "$BATS_TEST_TMPDIR/retry.json" "$BATS_TEST_TMPDIR/before.json"
  printf '{}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/5-x "$BATS_TEST_TMPDIR"
  gaia_debt_source_retain "$BATS_TEST_TMPDIR/retry.json"
  cmp "$BATS_TEST_TMPDIR/retry.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "retain leaves the file byte-identical after an unknown resolve" {
  printf '{"b":   2}\n' >"$BATS_TEST_TMPDIR/retry.json"
  cp "$BATS_TEST_TMPDIR/retry.json" "$BATS_TEST_TMPDIR/before.json"
  printf '{}\n' >"$BATS_TEST_TMPDIR/f.json"
  mkdir -p "$BATS_TEST_TMPDIR/plain/inner"
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR/plain"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR/plain/inner"
  [ "$gaia_debt_source_state" = "unknown" ]
  gaia_debt_source_retain "$BATS_TEST_TMPDIR/retry.json"
  cmp "$BATS_TEST_TMPDIR/retry.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "retain keeps the file and returns 0 when the directory is read-only" {
  mkdir -p "$BATS_TEST_TMPDIR/ro"
  printf '{"b":   2}\n' >"$BATS_TEST_TMPDIR/ro/retry.json"
  cp "$BATS_TEST_TMPDIR/ro/retry.json" "$BATS_TEST_TMPDIR/before.json"
  printf '{}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/5-x "$BATS_TEST_TMPDIR"
  chmod 555 "$BATS_TEST_TMPDIR/ro"
  status=0
  gaia_debt_source_retain "$BATS_TEST_TMPDIR/ro/retry.json" || status=$?
  chmod 755 "$BATS_TEST_TMPDIR/ro"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/ro/retry.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "the metadata check ignores the source line and stays armed on the key line" {
  line="$(gaia_debt_source_line_for_branch debt/1234-foo)"
  key='<!-- gaia-debt-key: v1 class=holistic/swallowed-error path=app/a.ts line=10 -->'
  tail_text='**Location:** app/a.ts:10

**Failure mode:** swallowed error

**Suggested fix:** rethrow'
  printf '%s\n%s\n\n%s\n' "$key" "$line" "$tail_text" >"$BATS_TEST_TMPDIR/body.md"
  printf '%s\n\n%s\n' "$line" "$tail_text" >"$BATS_TEST_TMPDIR/nokey.md"
  run bash "$REAL_ROOT/.gaia/scripts/check-debt-issue-metadata.sh" --pre-file \
    --labels 'tech-debt,severity:minor,audience:adopter' --body-file "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "${output##* }" = "clean" ]
  run bash "$REAL_ROOT/.gaia/scripts/check-debt-issue-metadata.sh" --pre-file \
    --labels 'tech-debt,severity:minor,audience:adopter' --body-file "$BATS_TEST_TMPDIR/nokey.md"
  [ "$status" -ne 0 ]
}

@test "sourcing twice and under set -u prints nothing and succeeds" {
  run bash -c 'set -u; . "$1"; . "$1"; echo "rc=$?"' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=0" ]
}

@test "the library parses under the system bash" {
  run /bin/bash -n "$LIB"
  [ "$status" -eq 0 ]
}
