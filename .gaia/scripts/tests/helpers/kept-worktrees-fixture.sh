# shellcheck shell=bash
# Shared fixture for the kept-worktree suites (kept-worktrees.bats and
# kept-worktrees-orphan.bats). Sourced from a suite's setup().
#
# kept_worktrees_setup builds a throwaway repository under BATS_TEST_TMPDIR (a
# bare origin, a main checkout whose origin/HEAD names main, and a linked
# worktree on a pushed branch) and stages copies of the scripts side by side,
# so a red twin can mutate one copy and leave the others real.

kept_worktrees_setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GAIA_PORTS_STATE_DIRECTORY
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="Fixture" GIT_AUTHOR_EMAIL="fixture@example.invalid"
  export GIT_COMMITTER_NAME="Fixture" GIT_COMMITTER_EMAIL="fixture@example.invalid"
  BRANCH=feat-tree
  make_tree "$BATS_TEST_TMPDIR/fixture" || return 1
  stage_scripts
}

# make_tree <dir>: sets MAIN, TREE and LEDGER. The worktree holds BRANCH, which
# is pushed with its upstream set and sits level with its remote-tracking ref.
# Both paths are physical, the spelling git itself prints for a worktree.
make_tree() {
  local dir=$1
  mkdir -p "$dir" || return 1
  dir=$(cd "$dir" && pwd -P) || return 1
  git init -q --bare -b main "$dir/origin.git" || return 1
  MAIN="$dir/main-checkout"
  git init -q -b main "$MAIN" || return 1
  git -C "$MAIN" remote add origin "$dir/origin.git" || return 1
  printf 'base\n' >"$MAIN/base" || return 1
  git -C "$MAIN" add base || return 1
  git -C "$MAIN" commit -q -m base || return 1
  git -C "$MAIN" push -q -u origin main 2>/dev/null || return 1
  git -C "$MAIN" remote set-head origin main >/dev/null 2>&1 || return 1
  git -C "$MAIN" branch "$BRANCH" || return 1
  git -C "$MAIN" push -q -u origin "$BRANCH" 2>/dev/null || return 1
  TREE="$dir/tree"
  git -C "$MAIN" worktree add -q "$TREE" "$BRANCH" || return 1
  LEDGER="$MAIN/.gaia/local/kept-worktrees.tsv"
}

# stage_scripts: copies the check, the ledger script and the libraries it
# sources into one directory, the layout the scripts find each other by.
stage_scripts() {
  SCRIPTS="$BATS_TEST_TMPDIR/scripts"
  mkdir -p "$SCRIPTS" || return 1
  cp "$REPO_ROOT/.gaia/scripts/worktree-removal-check.sh" \
    "$REPO_ROOT/.gaia/scripts/kept-worktrees.sh" \
    "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" \
    "$REPO_ROOT/.gaia/scripts/server-process-lib.sh" "$SCRIPTS/" || return 1
  # shellcheck disable=SC2034 # read by the suites that source this file
  CHECK="$SCRIPTS/worktree-removal-check.sh"
  KEPT="$SCRIPTS/kept-worktrees.sh"
}

# mutate <script name> <sed args...>: rewrites the staged copy in place; fails
# when the mutation changed nothing, so a twin cannot go vacuous.
mutate() {
  local name=$1
  shift
  sed "$@" "$REPO_ROOT/.gaia/scripts/$name" >"$SCRIPTS/$name.mutated" || return 1
  if cmp -s "$SCRIPTS/$name.mutated" "$REPO_ROOT/.gaia/scripts/$name"; then
    echo "the mutation changed nothing"
    return 1
  fi
  mv "$SCRIPTS/$name.mutated" "$SCRIPTS/$name"
}

seed_ledger() { # tree branch why
  mkdir -p "${LEDGER%/*}" || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$LEDGER"
}

remind() { # [directory]
  run bash "$KEPT" remind "${1:-$MAIN}"
}

# plain_output: the reminder's output with each tree line's `, last commit <age>`
# dropped, so a case can match the line exactly without a clock.
plain_output() {
  # shellcheck disable=SC2154 # set by bats' run
  printf '%s\n' "$output" | sed 's/, last commit [^)]*)/)/'
}

# gone_upstream: deletes BRANCH on the origin and prunes, so the tree's
# upstream reads [gone], the state a merge that deletes the head branch
# leaves after a later prune.
gone_upstream() {
  git -C "$MAIN" push -q origin --delete "$BRANCH" 2>/dev/null || return 1
  git -C "$MAIN" fetch -q --prune origin || return 1
}
