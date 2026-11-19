#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/audit-key-lib.sh (task 4.1,
# analysis/task-4.1-audit-key-design.md §2a-2c): the one function computing
# "<base-sha>.<branch-slug>", the key that partitions Code Audit Team
# findings sidecars and the re-run ledger across worktrees. Two worktrees cut
# from the same main tip compute an IDENTICAL base sha but never the same
# branch (git forbids checking out one branch in two worktrees at once), so
# the branch is the discriminator this key adds.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/audit-key-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  LIBRARY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/audit-key-lib.sh"
  # shellcheck disable=SC1090
  source "$LIBRARY"
  CLEANUP_DIRECTORIES=()
}

teardown() {
  local directory
  for directory in "${CLEANUP_DIRECTORIES[@]:-}"; do
    [ -n "$directory" ] && rm -rf "$directory"
  done
  return 0
}

git_identity() {
  git -C "$1" config user.email gaia-test@example.com
  git -C "$1" config user.name "GAIA Test"
  git -C "$1" config commit.gpgsign false
}

# make_repo [branch]: a fresh repo, one commit, checked out on [branch]
# (default "main"). Sets REPO and BASE (the commit sha both trees fork from
# in the linked-worktree test below).
make_repo() {
  local branch="${1:-main}"
  local raw
  raw=$(mktemp -d -t gaia-akl-repo-XXXXXX)
  REPO="$(cd "$raw" && pwd -P)"
  CLEANUP_DIRECTORIES+=("$REPO")
  git -C "$REPO" init -q --initial-branch="$branch"
  git_identity "$REPO"
  echo init >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
  BASE="$(git -C "$REPO" rev-parse HEAD)"
}

# ========== source-time purity ==========

@test "sourcing the lib has no side effects: succeeds under set -u with no git repo and no external PATH" {
  scratch="$BATS_TEST_TMPDIR/no-side-effects"
  mkdir -p "$scratch"
  run bash -c "cd '$scratch' && PATH='' && set -u && source '$LIBRARY' && echo sourced-ok"
  [ "$status" -eq 0 ]
  grep -qF "sourced-ok" <<<"$output"
  [ -z "$(ls -A "$scratch")" ]
}

# ========== gaia_branch_slug: the branch half, on its own ==========
# post-findings-block.sh selects sidecars on the branch half alone, across
# every base, so it needs that half without a base to pair it with. It calls
# this rather than repeating the derivation, which is what keeps the two halves
# of one key from being derived two different ways.

# gaia_key_slug is also called directly by gh-artifact-lib.sh's
# gaia_gh_artifact_path, so the rule is tested in isolation here. The read
# guard and the sandbox deny any file whose name holds "credential" in any
# case, so an audit file keyed by such a branch would be unreadable to the
# member reviewing it: the slug must never spell the word, and must still
# decode back to the branch, which keeps it injective.
@test "gaia_key_slug encodes every byte outside [A-Za-z0-9_-] and breaks every spelling of credential: plain, release/1.2, has%percent, credential in any case, credentia-l_cred" {
  local branch expected slug lower
  for branch in "worktree-program" "release/1.2" "has%percent" "credentia-l_cred"; do
    case "$branch" in
      worktree-program) expected="worktree-program" ;;
      release/1.2) expected="release%2F1%2E2" ;;
      has%percent) expected="has%25percent" ;;
      credentia-l_cred) expected="credentia-l_cred" ;;
    esac
    slug="$(gaia_key_slug "$branch")"
    [ "$slug" = "$expected" ] || { echo "slug of $branch: $slug, expected $expected"; return 1; }
  done
  for branch in "debt/2971-sandbox-credential-ts" "fix/Credentials" "CREDENTIAL" \
    "credentialcredential" "a.credential/b"; do
    slug="$(gaia_key_slug "$branch")"
    lower="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in *credential*) echo "slug spells it: $branch -> $slug"; return 1 ;; esac
    [ "$(printf '%b' "${slug//%/\\x}")" = "$branch" ] || { echo "does not decode: $branch -> $slug"; return 1; }
  done
}

# expect_refusal <case> <command...>: the command fails non-zero and prints
# nothing, so a half-built key is never printed.
expect_refusal() {
  local label="$1"
  shift
  local printed refusal_status=0
  printed="$("$@")" || refusal_status=$?
  [ "$refusal_status" -ne 0 ] || { echo "case $label: exited 0 with: $printed"; return 1; }
  [ -z "$printed" ] || { echo "case $label: printed: $printed"; return 1; }
}

# A failing slug is the way a key can be undeterminable that the documented
# contract used to promise without enforcing: the slug was interpolated
# straight into the output inside a command substitution, so a non-zero slug
# still printed "<base_sha>." at status 0, a plausible-looking key with the
# branch discriminator silently gone. The stub reproduces the failure shape
# without depending on what makes a real slug fail.
@test "gaia_branch_slug and gaia_audit_key print the encoded half or key, else fail non-zero printing nothing: missing base, detached HEAD, a dir outside a repository, a failing slug" {
  local nongit
  nongit=$(mktemp -d -t gaia-akl-nongit-XXXXXX)
  CLEANUP_DIRECTORIES+=("$nongit")
  make_repo "feat/x.y"

  [ "$(gaia_branch_slug "$REPO")" = "feat%2Fx%2Ey" ]
  expect_refusal "audit key, missing base with a resolvable branch" gaia_audit_key "" "$REPO"
  expect_refusal "branch slug, dir outside a repository" gaia_branch_slug "$nongit"
  expect_refusal "audit key, dir outside a repository" gaia_audit_key "deadbeef" "$nongit"

  # shellcheck disable=SC2329 # reached through gaia_branch_slug and gaia_audit_key
  gaia_key_slug() { return 1; }
  expect_refusal "branch slug, failing slug" gaia_branch_slug "$REPO"
  expect_refusal "audit key, failing slug (never a bare base)" gaia_audit_key "$BASE" "$REPO"
  unset -f gaia_key_slug
  # shellcheck disable=SC1090
  source "$LIBRARY"

  git -C "$REPO" checkout -q "$BASE"
  expect_refusal "branch slug, detached HEAD" gaia_branch_slug "$REPO"
  expect_refusal "audit key, detached HEAD with a resolvable base" gaia_audit_key "$BASE" "$REPO"
}

@test "gaia_branch_slug: it is exactly the half gaia_audit_key appends" {
  # The agreement that matters: a reader globbing on the branch half must
  # produce the byte-identical string the writer's key carries, or it selects
  # nothing. Derived independently here rather than asserted as a literal.
  make_repo "feat/x.y"
  local half key
  half="$(gaia_branch_slug "$REPO")"
  key="$(gaia_audit_key "$BASE" "$REPO")"
  [ -n "$half" ]
  [ "$key" = "${BASE}.${half}" ]
}

# ========== gaia_key_slug: the general slug rule, tested directly ==========
# gaia_audit_key's own tests below exercise this rule indirectly (through the
# key it builds); these test it in isolation, since gh-artifact-lib.sh's
# gaia_gh_artifact_path (task 4.2) now calls it directly too.

# ========== gaia_audit_key: the happy path ==========

@test "dir defaults to '.': omitting the second argument uses the process cwd" {
  make_repo "worktree-program"
  audit_key="$(cd "$REPO" && gaia_audit_key "$BASE")"
  [ "$audit_key" = "${BASE}.worktree-program" ]
}

# ========== fail-open: either half undeterminable ==========

# ========== the defect, expressed as a unit ==========

@test "two real linked worktrees off one base produce DIFFERENT keys from the SAME base sha" {
  make_repo "main"
  git -C "$REPO" branch tree-a "$BASE"
  git -C "$REPO" branch tree-b "$BASE"
  local worktree_a worktree_b
  worktree_a="$BATS_TEST_TMPDIR/wt-a"
  worktree_b="$BATS_TEST_TMPDIR/wt-b"
  git -C "$REPO" worktree add -q "$worktree_a" tree-a
  git -C "$REPO" worktree add -q "$worktree_b" tree-b

  key_a="$(gaia_audit_key "$BASE" "$worktree_a")"
  key_b="$(gaia_audit_key "$BASE" "$worktree_b")"

  [ -n "$key_a" ]
  [ -n "$key_b" ]
  [ "$key_a" != "$key_b" ]
  [ "$key_a" = "${BASE}.tree-a" ]
  [ "$key_b" = "${BASE}.tree-b" ]
}

# ========== structural hygiene ==========

@test "structural: no hardcoded /Users or /home paths" {
  grep -E '/Users/|/home/' "$LIBRARY" && return 1
  return 0
}

# gaia_key_slug walks its input with `${text:$i:1}`, not bash's bare
# `${text:i:1}`: zsh reads the bare identifier as a history modifier and aborts
# the function mid-walk. This is not a claim of zsh support -- the lib is a bash
# lib and every script caller is `#!/usr/bin/env bash` -- it is that a
# maintainer who sources it in an interactive zsh, which the header's own Usage
# block invites, gets the same slug rather than a quietly different one.
@test "portability: the slug is byte-identical under zsh, where zsh exists" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not available"
  local branch='feat/a.b%c-Credential' from_bash from_zsh
  from_bash="$(gaia_key_slug "$branch")"
  from_zsh="$(zsh -c "source '$LIBRARY'; gaia_key_slug '$branch'")"
  [ -n "$from_bash" ]
  [ "$from_zsh" = "$from_bash" ]
}
