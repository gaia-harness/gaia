#!/usr/bin/env bats
# Executable-truth coverage for the cleanup fences in the shared work-lifecycle
# reference (`.claude/skills/gaia/references/work-lifecycle.md`, `## 8. Cleanup`).
#
# Why this suite executes rather than greps. The reference holds the only
# command statement of GAIA's post-merge cleanup. A prose suite can prove the
# right words are present; it cannot prove the commands do what the page
# promises. So each fence is pulled out of the reference at run time, its
# placeholders are replaced by literal substitution, and the result runs
# against a throwaway fixture repository (a bare origin, a main checkout, a
# feature branch, and a squash merge simulated on the remote so the local
# branch is unmerged by ancestry exactly as after a real squash). The fence is
# never transcribed into this file: a transcription would stay green while the
# page drifts.
#
# What is asserted, per arm:
#
#   - Every arm resolves the default branch rather than assuming `main`: a
#     fixture whose remote's default is `master` (no `origin/HEAD`) and one
#     whose `origin/HEAD` names `trunk` must pull that branch.
#   - Feature branch: the main checkout ends on `main` at `origin/main`, the
#     merged branch and its remote-tracking ref are gone; a peer branch held
#     by the main checkout is left alone (no pull); a linked worktree holding
#     `main` makes the script stop having deleted nothing.
#   - Worktree entered by name: the pre-removal check, then the tail after the
#     runtime removed the tree.
#   - Worktree entered by path: the tree is addressed by the path and the
#     branch by the name the porcelain record shows, which differ; the arm
#     also runs with the session's cwd inside the tree it removes.
#   - Both worktree arms: a stop at the pre-removal check (an untracked
#     file, an uncommitted edit) leaves the tree, the branch, `main` and the
#     package manager untouched; an ignored file, a populated `.gaia-backup/`
#     and a local commit with no upstream ref do not stop it; the install in
#     the main checkout runs only after a pull that changed the lockfile.
#     A `pnpm` stub on PATH records how it was called and can be told to fail.
#
# Each arm also runs the state-cleanup verb after its branch delete. A fixture
# main checkout carries a copy of the verb, its libraries and the committed
# registry, and the rendered fence runs that copy, so the verb prunes only
# fixture state: a merged branch's state is gone afterwards while an open
# branch's state remains.
#
# Every check is a function that returns non-zero on a broken outcome. A test
# is a case table: it runs each case's check against a fresh copy of a fixture
# template and names the failing case. Building a fixture costs more than
# copying one, so each distinct fixture is built once per file and copied per
# case.
#
# The suite never touches the real repository: every git command targets a
# directory under BATS_TEST_TMPDIR.
#
# Assertion style: .claude/rules/bats-assertions.md.

# Git environment that keeps fixture repositories independent of the host's.
fixture_git_environment() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="Fixture" GIT_AUTHOR_EMAIL="fixture@example.invalid"
  export GIT_COMMITTER_NAME="Fixture" GIT_COMMITTER_EMAIL="fixture@example.invalid"
}

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  REFERENCE="$REPO_ROOT/.claude/skills/gaia/references/work-lifecycle.md"
  fixture_git_environment

  NAME_ARM="### Worktree entered by name in this session"
  PATH_ARM="### Worktree entered by path or in an earlier session"
  FEATURE_ARM="### Feature branch"
  CHECK_SCRIPT="$REPO_ROOT/.gaia/scripts/worktree-removal-check.sh"
  # The fixture's default branch, and whether origin/HEAD is recorded for it.
  # A fixture made with `git init` plus `remote add` has no origin/HEAD, which
  # is the shape a locally created and then pushed repository has.
  FIXTURE_DEFAULT=main
  FIXTURE_ORIGIN_HEAD=""

  # A pnpm stand-in on PATH: it logs "<physical cwd>|<arguments>" and exits
  # with PNPM_STUB_EXIT, so a case can tell how and from where it was called.
  PNPM_LOG="$BATS_TEST_TMPDIR/pnpm.log"
  export PNPM_LOG
  mkdir -p "$BATS_TEST_TMPDIR/stub-bin"
  cat >"$BATS_TEST_TMPDIR/stub-bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$(pwd -P)" "$*" >>"$PNPM_LOG"
exit "${PNPM_STUB_EXIT:-0}"
STUB
  chmod +x "$BATS_TEST_TMPDIR/stub-bin/pnpm"
  export PATH="$BATS_TEST_TMPDIR/stub-bin:$PATH"
}

# ---------------------------------------------------------------------------
# Fence extraction

# section <file> <heading>: the lines under an exact heading line, up to the
# next heading of the same or a higher level. Fence-aware: a `#` line inside a
# fence neither starts nor ends a section.
section() {
  awk -v heading="$2" '
    function level(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    /^```/ { fenced = !fenced; if (on) print; next }
    !fenced && $0 == heading { on = 1; wanted = level(heading); print; next }
    on && !fenced && /^#+ / && level($0) <= wanted { exit }
    on { print }
  ' "$1"
}

# bash_fences <index>: stdin is a document; prints the body of its Nth
# (1-based) ```bash fence. Fences of other languages are skipped.
bash_fences() {
  awk -v wanted="$1" '
    state == 0 && /^```bash[ ]*$/ { state = 1; seen++; next }
    state == 0 && /^```/ { state = 2; next }
    state != 0 && /^```[ ]*$/ { state = 0; next }
    state == 1 && seen == wanted { print }
  '
}

# fence_body <heading> <index>
fence_body() {
  section "$REFERENCE" "$1" | bash_fences "$2"
}

# rendered_body <heading> <index> <branch> <worktree path> <main checkout path>:
# the fence with its three placeholders replaced by literal substitution, and
# the repo-relative check script replaced by CHECK_SCRIPT so a fixture runs the
# real file, and the repo-relative cleanup verb replaced by
# the fixture main checkout's copy (the absolute-path spellings already reach
# it through the main checkout placeholder). Fails when the fence is empty or any
# angle-bracket placeholder survives, because bash would read a leftover
# `<token>` as a redirection and `bash -n` would not notice.
rendered_body() {
  local body
  body=$(fence_body "$1" "$2")
  [ -n "$body" ] || { echo "FAIL: no fence $2 under $1"; return 1; }
  body=${body//"<branch-name>"/$3}
  body=${body//"<worktree path>"/$4}
  body=${body//"<main checkout path>"/${5:-/fixture/main}}
  body=${body//".gaia/scripts/worktree-removal-check.sh"/$CHECK_SCRIPT}
  body=${body//"bash .gaia/scripts/state-cleanup.sh"/"bash ${MAIN:-/fixture/main}/.gaia/scripts/state-cleanup.sh"}
  if printf '%s\n' "$body" | grep -Eq '<[A-Za-z][^>]*>'; then
    echo "FAIL: a placeholder survives substitution under $1"
    return 1
  fi
  printf '%s\n' "$body"
}

# ---------------------------------------------------------------------------
# Fixture

commit_file() { # repo name
  printf '%s\n' "$2" >"$1/$2" || return 1
  git -C "$1" add "$2" || return 1
  git -C "$1" commit -q -m "add $2" || return 1
}

# build_fixture_template <dir> <branch> <lock|nolock>: builds the fixture in
# <dir> and sets ORIGIN, MAIN. The main checkout is left on FIXTURE_DEFAULT, one
# commit behind its remote-tracking ref, and origin/HEAD is recorded only when
# FIXTURE_ORIGIN_HEAD is set; <branch> exists locally and its remote-tracking
# ref exists, while the remote has dropped it. With `lock` the squash commit
# also changes `pnpm-lock.yaml`.
build_fixture_template() {
  local dir=$1 branch=$2 other
  mkdir -p "$dir" || return 1
  ORIGIN="$dir/origin.git"
  MAIN="$dir/main-checkout"
  other="$dir/other"
  git init -q --bare -b "$FIXTURE_DEFAULT" "$ORIGIN" || return 1
  git init -q -b "$FIXTURE_DEFAULT" "$MAIN" || return 1
  git -C "$MAIN" remote add origin "$ORIGIN" || return 1
  commit_file "$MAIN" base || return 1
  git -C "$MAIN" push -q -u origin "$FIXTURE_DEFAULT" 2>/dev/null || return 1
  if [ -n "$FIXTURE_ORIGIN_HEAD" ]; then
    git -C "$MAIN" remote set-head origin "$FIXTURE_DEFAULT" >/dev/null || return 1
  fi
  git -C "$MAIN" checkout -q -b "$branch" || return 1
  commit_file "$MAIN" feature || return 1
  git -C "$MAIN" push -q -u origin "$branch" 2>/dev/null || return 1
  git -C "$MAIN" checkout -q "$FIXTURE_DEFAULT" || return 1
  # The squash merge: the default branch on origin gains a commit that is not an ancestor of
  # the feature branch, and the remote drops the feature branch.
  git clone -q "$ORIGIN" "$other" 2>/dev/null || return 1
  commit_file "$other" squashed || return 1
  if [ "$3" = lock ]; then
    commit_file "$other" pnpm-lock.yaml || return 1
  fi
  git -C "$other" push -q origin "$FIXTURE_DEFAULT" 2>/dev/null || return 1
  git -C "$other" push -q origin --delete "$branch" 2>/dev/null || return 1
  rm -rf "$other" || return 1
  install_cleanup_verb || return 1
}

# make_fixture <dir> <branch> [lock]: sets ORIGIN, MAIN, OLD_SHA. Copies the
# template for this default branch, origin/HEAD, branch and lockfile shape,
# building it on first use, and points the copy's origin at the copied bare
# repository.
make_fixture() {
  local dir=$1 branch=$2 lock=${3:-nolock} template
  template="$BATS_FILE_TMPDIR/templates/$FIXTURE_DEFAULT-${FIXTURE_ORIGIN_HEAD:-nohead}-$branch-$lock"
  if [ ! -d "$template" ]; then
    mkdir -p "$BATS_FILE_TMPDIR/templates" || return 1
    build_fixture_template "$template.building.$$" "$branch" "$lock" || return 1
    mv "$template.building.$$" "$template" || return 1
  fi
  mkdir -p "$dir" || return 1
  cp -R "$template/." "$dir/" || return 1
  ORIGIN="$dir/origin.git"
  MAIN="$dir/main-checkout"
  git -C "$MAIN" remote set-url origin "$ORIGIN" || return 1
  OLD_SHA=$(git -C "$MAIN" rev-parse "$FIXTURE_DEFAULT") || return 1
}

# install_cleanup_verb: copies the cleanup verb, its libraries and the
# committed registry into the fixture main checkout, where the verb resolves
# its main root from its own location.
install_cleanup_verb() {
  local file
  mkdir -p "$MAIN/.gaia/scripts" "$MAIN/.gaia/local" || return 1
  for file in state-cleanup.sh state-reaper-classes.sh state-reaper-lib.sh main-root-lib.sh state-registry-lib.sh branch-name-lib.sh audit-key-lib.sh audit-loop-state-lib.sh exclusive-lock-lib.sh branch-authorship-lib.sh filing-outcomes-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$file" "$MAIN/.gaia/scripts/$file" || return 1
  done
  cp "$REPO_ROOT/.gaia/state-registry.json" "$MAIN/.gaia/state-registry.json" || return 1
}

# branch_state_paths <branch>: sets BRANCH_STATE_PATHS to an audit review
# file, a run folder and a PR-cache file keyed to the branch by the real key
# functions.
branch_state_paths() {
  local slug normalized
  slug=$(bash -c '. "$1/.gaia/scripts/audit-key-lib.sh"; gaia_key_slug "$2"' _ "$REPO_ROOT" "$1") || return 1
  normalized=$(bash -c '. "$1/.gaia/scripts/branch-name-lib.sh"; gaia_branch_normalize "$2"' _ "$REPO_ROOT" "$1") || return 1
  BRANCH_STATE_PATHS="audit/0123abc.$slug.review.diff runs/$normalized/STATE.md cache/gh-artifact-pr.$slug.json"
}

# plant_branch_state <branch>: creates the branch's three kinds of state.
plant_branch_state() {
  local relative
  branch_state_paths "$1" || return 1
  for relative in $BRANCH_STATE_PATHS; do
    mkdir -p "$(dirname "$MAIN/.gaia/local/$relative")" || return 1
    : >"$MAIN/.gaia/local/$relative" || return 1
  done
}

# state_remaining <branch>: prints how many of the branch's planted paths exist.
state_remaining() {
  local relative remaining=0
  branch_state_paths "$1" || return 1
  for relative in $BRANCH_STATE_PATHS; do
    [ -e "$MAIN/.gaia/local/$relative" ] && remaining=$((remaining + 1))
  done
  printf '%s\n' "$remaining"
}

# run_body <body>: runs a rendered fence body with cwd = the main checkout.
# Sets OUT and STATUS (stdout and stderr combined).
run_body() {
  local script="$MAIN/../cleanup-script.sh"
  printf '%s\n' "$1" >"$script" || return 1
  STATUS=0
  OUT=$(cd "$MAIN" && bash "$script" 2>&1) || STATUS=$?
  return 0
}

# run_fences <cwd> <body> [<cwd> <body>]...: runs each rendered body in order
# from its own cwd, stopping at the first non-zero exit, as a caller running
# the arm's fences in order does. Sets OUT (all output), STATUS (the stopping
# fence's exit, else 0) and STOPPED_AT (its 1-based position, 0 for none).
run_fences() {
  local dir body script piece rc index=0
  OUT=""
  STATUS=0
  STOPPED_AT=0
  while [ $# -gt 0 ]; do
    dir=$1
    body=$2
    shift 2
    index=$((index + 1))
    script="$BATS_TEST_TMPDIR/fence-$index.sh"
    printf '%s\n' "$body" >"$script" || return 1
    rc=0
    piece=$(cd "$dir" && bash "$script" 2>&1) || rc=$?
    OUT="$OUT$piece"$'\n'
    if [ "$rc" -ne 0 ]; then
      STATUS=$rc
      STOPPED_AT=$index
      return 0
    fi
  done
  return 0
}

ref_exists() { git -C "$MAIN" show-ref --verify --quiet "$1"; }

main_matches_origin() {
  [ "$(git -C "$MAIN" rev-parse "$FIXTURE_DEFAULT")" = "$(git -C "$MAIN" rev-parse "origin/$FIXTURE_DEFAULT")" ]
}

# ---------------------------------------------------------------------------
# Checks. Each takes a fresh case directory, makes its fixture there with
# make_fixture, and returns
# non-zero with a FAIL line when the promised outcome does not hold.

check_feature_head_on_merged_branch() {
  local branch=feat-merged body
  make_fixture "$1" "$branch" || return 1
  git -C "$MAIN" checkout -q "$branch" || return 1
  body=$(rendered_body "$FEATURE_ARM" 1 "$branch" "") || { echo "$body"; return 1; }
  run_body "$body"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: exit $STATUS: $OUT"; return 1; }
  [ "$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)" = "$FIXTURE_DEFAULT" ] || { echo "FAIL: HEAD is not $FIXTURE_DEFAULT"; return 1; }
  main_matches_origin || { echo "FAIL: $FIXTURE_DEFAULT is not at origin/$FIXTURE_DEFAULT"; return 1; }
  ref_exists "refs/heads/$branch" && { echo "FAIL: local branch survives"; return 1; }
  ref_exists "refs/remotes/origin/$branch" && { echo "FAIL: remote-tracking ref survives"; return 1; }
  return 0
}

check_feature_head_on_main() {
  local branch=feat-merged body
  make_fixture "$1" "$branch" || return 1
  body=$(rendered_body "$FEATURE_ARM" 1 "$branch" "") || { echo "$body"; return 1; }
  run_body "$body"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: exit $STATUS: $OUT"; return 1; }
  [ "$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)" = "$FIXTURE_DEFAULT" ] || { echo "FAIL: HEAD is not $FIXTURE_DEFAULT"; return 1; }
  main_matches_origin || { echo "FAIL: $FIXTURE_DEFAULT is not at origin/$FIXTURE_DEFAULT"; return 1; }
  ref_exists "refs/heads/$branch" && { echo "FAIL: local branch survives"; return 1; }
  ref_exists "refs/remotes/origin/$branch" && { echo "FAIL: remote-tracking ref survives"; return 1; }
  return 0
}

check_feature_peer_branch_left_alone() {
  local branch=feat-merged body
  make_fixture "$1" "$branch" || return 1
  git -C "$MAIN" branch peer "$OLD_SHA" || return 1
  git -C "$MAIN" checkout -q peer || return 1
  body=$(rendered_body "$FEATURE_ARM" 1 "$branch" "") || { echo "$body"; return 1; }
  run_body "$body"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: exit $STATUS: $OUT"; return 1; }
  [ "$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)" = peer ] || { echo "FAIL: HEAD left the peer branch"; return 1; }
  [ "$(git -C "$MAIN" rev-parse refs/heads/peer)" = "$OLD_SHA" ] || { echo "FAIL: the peer branch moved: a pull ran"; return 1; }
  ref_exists "refs/heads/$branch" && { echo "FAIL: local branch survives"; return 1; }
  ref_exists "refs/remotes/origin/$branch" && { echo "FAIL: remote-tracking ref survives"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "held by a peer session" || { echo "FAIL: no peer-held notice: $OUT"; return 1; }
  return 0
}

check_feature_stops_when_linked_worktree_holds_main() {
  local branch=feat-merged body head_before
  make_fixture "$1" "$branch" || return 1
  git -C "$MAIN" checkout -q "$branch" || return 1
  git -C "$MAIN" worktree add -q "$1/linked-main" "$FIXTURE_DEFAULT" || return 1
  head_before=$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)
  body=$(rendered_body "$FEATURE_ARM" 1 "$branch" "") || { echo "$body"; return 1; }
  run_body "$body"
  [ "$STATUS" -ne 0 ] || { echo "FAIL: the script exited 0: $OUT"; return 1; }
  [ "$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)" = "$head_before" ] || { echo "FAIL: HEAD moved"; return 1; }
  ref_exists "refs/heads/$branch" || { echo "FAIL: the merged branch was deleted"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "linked worktree holds $FIXTURE_DEFAULT" || { echo "FAIL: the stop was not the linked-worktree check: $OUT"; return 1; }
  return 0
}

# check_name_arm_tail <dir> <main|peer>
check_name_arm_tail() {
  local branch=feat-merged body
  make_fixture "$1" "$branch" || return 1
  git -C "$MAIN" worktree add -q "$1/entered-tree" "$branch" || return 1
  # Stands in for ExitWorktree, which only the runtime can call.
  git -C "$MAIN" worktree remove --force "$1/entered-tree" || return 1
  if [ "$2" = peer ]; then
    git -C "$MAIN" branch peer "$OLD_SHA" || return 1
    git -C "$MAIN" checkout -q peer || return 1
  fi
  body=$(rendered_body "$NAME_ARM" 2 "$branch" "" "$MAIN") || { echo "$body"; return 1; }
  run_body "$body"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: exit $STATUS: $OUT"; return 1; }
  ref_exists "refs/heads/$branch" && { echo "FAIL: local branch survives"; return 1; }
  ref_exists "refs/remotes/origin/$branch" && { echo "FAIL: remote-tracking ref survives"; return 1; }
  if [ "$2" = peer ]; then
    [ "$(git -C "$MAIN" rev-parse refs/heads/peer)" = "$OLD_SHA" ] || { echo "FAIL: the peer branch moved: a pull ran"; return 1; }
  else
    main_matches_origin || { echo "FAIL: $FIXTURE_DEFAULT is not at origin/$FIXTURE_DEFAULT"; return 1; }
  fi
  return 0
}

check_path_arm_addresses_tree_and_branch_separately() {
  local branch=hand-name tree_dir=rehearsal-dir porcelain record wt_path wt_branch body check
  make_fixture "$1" "$branch" || return 1
  mkdir -p "$MAIN/.claude/worktrees" || return 1
  git -C "$MAIN" worktree add -q "$MAIN/.claude/worktrees/$tree_dir" "$branch" || return 1
  body=$(rendered_body "$PATH_ARM" 1 "" "" "$MAIN") || { echo "$body"; return 1; }
  run_body "$body"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: porcelain fence exit $STATUS: $OUT"; return 1; }
  porcelain=$OUT
  record=$(printf '%s\n' "$porcelain" | awk -v suffix="/$tree_dir" '
    BEGIN { RS = ""; FS = "\n" }
    {
      path = ""; branch_name = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^worktree /) path = substr($i, 10)
        if ($i ~ /^branch refs\/heads\//) branch_name = substr($i, 19)
      }
      n = length(path) - length(suffix)
      if (n >= 0 && substr(path, n + 1) == suffix) print path "\t" branch_name
    }')
  IFS=$'\t' read -r wt_path wt_branch <<<"$record"
  [ -n "$wt_path" ] || { echo "FAIL: the porcelain output has no record for the tree"; return 1; }
  [ "$wt_branch" = "$branch" ] || { echo "FAIL: porcelain branch is '$wt_branch'"; return 1; }
  check=$(rendered_body "$PATH_ARM" 2 "$wt_branch" "$wt_path" "$MAIN") || { echo "$check"; return 1; }
  body=$(rendered_body "$PATH_ARM" 3 "$wt_branch" "$wt_path" "$MAIN") || { echo "$body"; return 1; }
  run_fences "$MAIN" "$check" "$MAIN" "$body"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: exit $STATUS: $OUT"; return 1; }
  [ -e "$wt_path" ] && { echo "FAIL: the worktree directory survives"; return 1; }
  ref_exists "refs/heads/$branch" && { echo "FAIL: local branch survives"; return 1; }
  ref_exists "refs/remotes/origin/$branch" && { echo "FAIL: remote-tracking ref survives"; return 1; }
  main_matches_origin || { echo "FAIL: $FIXTURE_DEFAULT is not at origin/$FIXTURE_DEFAULT"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Worktree arm scenarios: a linked worktree on a pushed branch, put into one of
# a few states, then an arm's fences run in order the way a caller runs them.

# prepare_tree <dir> <lock|nolock> <state>: sets BRANCH, TREE, MAIN, OLD_SHA.
# States: clean, untracked, backup-only, dirty, ignored, no-upstream (a local
# commit while the remote branch is deleted and pruned).
prepare_tree() {
  rm -f "$PNPM_LOG"
  BRANCH=feat-merged
  make_fixture "$1" "$BRANCH" "$2" || return 1
  TREE="$1/tree"
  git -C "$MAIN" worktree add -q "$TREE" "$BRANCH" || return 1
  case "$3" in
    clean) ;;
    untracked)
      printf 'notes\n' >"$TREE/stray-notes.txt" || return 1
      ;;
    backup-only)
      mkdir -p "$TREE/.gaia-backup" || return 1
      printf 'pre-image\n' >"$TREE/.gaia-backup/old.txt" || return 1
      printf '.gaia-backup/\n' >>"$MAIN/.git/info/exclude" || return 1
      ;;
    dirty)
      printf 'unsaved edit\n' >>"$TREE/feature" || return 1
      ;;
    ignored)
      printf 'node_modules/\n' >>"$MAIN/.git/info/exclude" || return 1
      mkdir -p "$TREE/node_modules" || return 1
      printf 'x\n' >"$TREE/node_modules/pkg.js" || return 1
      ;;
    no-upstream)
      commit_file "$TREE" local-only || return 1
      git -C "$MAIN" fetch -q --prune origin || return 1
      ;;
    *)
      echo "unknown state $3"
      return 1
      ;;
  esac
}

# run_arm <path|name> [cwd for the path arm]: renders the arm's executable
# fences against the prepared tree and runs them in order. The by-name arm's
# check runs from inside the tree, and the runtime's removal call is stood in
# for by a forced worktree removal that runs only after a clear check.
run_arm() {
  local check removal standin
  if [ "$1" = path ]; then
    check=$(rendered_body "$PATH_ARM" 2 "$BRANCH" "$TREE" "$MAIN") || { echo "$check"; return 1; }
    removal=$(rendered_body "$PATH_ARM" 3 "$BRANCH" "$TREE" "$MAIN") || { echo "$removal"; return 1; }
    run_fences "${2:-$MAIN}" "$check" "${2:-$MAIN}" "$removal"
  else
    check=$(rendered_body "$NAME_ARM" 1 "$BRANCH" "$TREE" "$MAIN") || { echo "$check"; return 1; }
    removal=$(rendered_body "$NAME_ARM" 2 "$BRANCH" "$TREE" "$MAIN") || { echo "$removal"; return 1; }
    standin="git -C '$MAIN' worktree remove --force '$TREE'"
    run_fences "$TREE" "$check" "$MAIN" "$standin" "$MAIN" "$removal"
  fi
}

# tree_untouched: the tree, the branch, `main` and the package manager are as
# the fixture left them.
tree_untouched() {
  [ -d "$TREE" ] || { echo "FAIL: the worktree directory was removed"; return 1; }
  ref_exists "refs/heads/$BRANCH" || { echo "FAIL: the local branch was deleted"; return 1; }
  [ "$(git -C "$MAIN" rev-parse main)" = "$OLD_SHA" ] || { echo "FAIL: main moved: a pull ran"; return 1; }
  [ ! -s "$PNPM_LOG" ] || { echo "FAIL: pnpm was called: $(cat "$PNPM_LOG")"; return 1; }
  return 0
}

# tree_removed: the directory and the local branch are gone.
tree_removed() {
  [ -e "$TREE" ] && { echo "FAIL: the worktree directory survives"; return 1; }
  ref_exists "refs/heads/$BRANCH" && { echo "FAIL: local branch survives"; return 1; }
  return 0
}

# check_arm_stops_on_untracked_file <dir> <arm>: an untracked file stops the
# arm at its check fence with nothing touched.
check_arm_stops_on_untracked_file() {
  prepare_tree "$1" nolock untracked || return 1
  run_arm "$2" || return 1
  [ "$STATUS" -ne 0 ] || { echo "FAIL: the arm exited 0: $OUT"; return 1; }
  [ "$STOPPED_AT" -eq 1 ] || { echo "FAIL: the check fence did not stop the arm: $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "stray-notes.txt" || { echo "FAIL: the stop does not list the file: $OUT"; return 1; }
  tree_untouched
}

# check_arm_stops_on_dirty <dir> <arm>: an uncommitted edit stops the arm and
# the output carries the dirty path, a next step and both removal commands.
check_arm_stops_on_dirty() {
  prepare_tree "$1" lock dirty || return 1
  run_arm "$2" || return 1
  [ "$STATUS" -ne 0 ] || { echo "FAIL: the arm exited 0: $OUT"; return 1; }
  [ "$STOPPED_AT" -eq 1 ] || { echo "FAIL: the check fence did not stop the arm: $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq " M feature" || { echo "FAIL: the stop does not name the dirty path: $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "Next step:" || { echo "FAIL: no next step: $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "git worktree remove --force $TREE" || { echo "FAIL: no worktree removal command: $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "git branch -D $BRANCH" || { echo "FAIL: no branch delete command: $OUT"; return 1; }
  tree_untouched || return 1
  git -C "$TREE" status --porcelain | grep -Fq " M feature" || { echo "FAIL: the edit is gone from the tree"; return 1; }
  return 0
}

# check_arm_removes <dir> <arm> <state>: a state that must not stop the arm.
check_arm_removes() {
  prepare_tree "$1" nolock "$3" || return 1
  run_arm "$2" || return 1
  [ "$STATUS" -eq 0 ] || { echo "FAIL: the arm stopped (exit $STATUS, fence $STOPPED_AT): $OUT"; return 1; }
  tree_removed
}

# check_arm_installs_on_lockfile_change <dir> <arm> <lock|nolock>: pnpm is
# called once, frozen, against the main checkout when the pull changed the
# lockfile, and never otherwise.
check_arm_installs_on_lockfile_change() {
  local real_main expected
  prepare_tree "$1" "$3" clean || return 1
  run_arm "$2" || return 1
  [ "$STATUS" -eq 0 ] || { echo "FAIL: the arm stopped (exit $STATUS): $OUT"; return 1; }
  tree_removed || return 1
  if [ "$3" = nolock ]; then
    [ ! -s "$PNPM_LOG" ] || { echo "FAIL: pnpm was called without a lockfile change: $(cat "$PNPM_LOG")"; return 1; }
    return 0
  fi
  real_main=$(cd "$MAIN" && pwd -P)
  if [ "$2" = path ]; then
    expected="$real_main|-C $MAIN install --frozen-lockfile"
  else
    expected="$real_main|install --frozen-lockfile"
  fi
  [ -s "$PNPM_LOG" ] || { echo "FAIL: pnpm was never called"; return 1; }
  [ "$(wc -l <"$PNPM_LOG" | tr -d ' ')" -eq 1 ] || { echo "FAIL: pnpm was called more than once: $(cat "$PNPM_LOG")"; return 1; }
  grep -Fxq -- "$expected" "$PNPM_LOG" || { echo "FAIL: pnpm was not called as '$expected': $(cat "$PNPM_LOG")"; return 1; }
  return 0
}

# check_arm_reports_failed_install <dir> <arm>: a failing install is reported
# with its next step and the removal stands.
check_arm_reports_failed_install() {
  PNPM_STUB_EXIT=1
  export PNPM_STUB_EXIT
  prepare_tree "$1" lock clean || return 1
  run_arm "$2" || return 1
  [ "$STATUS" -ne 0 ] || { echo "FAIL: a failed install exited 0: $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "The install failed" || { echo "FAIL: no failed-install report: $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "pnpm install --frozen-lockfile" || { echo "FAIL: no install next step: $OUT"; return 1; }
  tree_removed
}

# check_arm_skips_install_for_peer <dir> <arm>: a peer branch in the main
# checkout means no pull and no install, and both are named as next steps.
check_arm_skips_install_for_peer() {
  prepare_tree "$1" lock clean || return 1
  git -C "$MAIN" branch peer "$OLD_SHA" || return 1
  git -C "$MAIN" checkout -q peer || return 1
  run_arm "$2" || return 1
  [ "$STATUS" -eq 0 ] || { echo "FAIL: the arm stopped (exit $STATUS): $OUT"; return 1; }
  [ "$(git -C "$MAIN" rev-parse refs/heads/peer)" = "$OLD_SHA" ] || { echo "FAIL: the peer branch moved: a pull ran"; return 1; }
  [ ! -s "$PNPM_LOG" ] || { echo "FAIL: pnpm was called: $(cat "$PNPM_LOG")"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "git pull --ff-only origin $FIXTURE_DEFAULT" || { echo "FAIL: the pull is not a named next step: $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "pnpm install --frozen-lockfile" || { echo "FAIL: the install is not a named next step: $OUT"; return 1; }
  tree_removed
}

# check_arm_skips_install_when_pull_fails <dir> <arm>: a main that diverged from
# origin makes the pull fail; no install runs and both are named next steps.
check_arm_skips_install_when_pull_fails() {
  prepare_tree "$1" lock clean || return 1
  commit_file "$MAIN" local-only || return 1
  run_arm "$2" || return 1
  [ "$STATUS" -ne 0 ] || { echo "FAIL: a failed pull exited 0: $OUT"; return 1; }
  [ ! -s "$PNPM_LOG" ] || { echo "FAIL: pnpm was called after a failed pull: $(cat "$PNPM_LOG")"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "The pull failed" || { echo "FAIL: no failed-pull report: $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "git pull --ff-only origin $FIXTURE_DEFAULT" || { echo "FAIL: the pull is not a named next step: $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "pnpm install --frozen-lockfile" || { echo "FAIL: the install is not a named next step: $OUT"; return 1; }
  tree_removed
}

# check_path_arm_from_inside_the_tree <dir>: the session's cwd is the tree being
# removed, so every command after the removal has to name the main checkout.
check_path_arm_from_inside_the_tree() {
  prepare_tree "$1" lock clean || return 1
  run_arm path "$TREE" || return 1
  [ "$STATUS" -eq 0 ] || { echo "FAIL: the arm stopped (exit $STATUS, fence $STOPPED_AT): $OUT"; return 1; }
  tree_removed || return 1
  main_matches_origin || { echo "FAIL: main is not at origin/main"; return 1; }
  [ -s "$PNPM_LOG" ] || { echo "FAIL: pnpm was never called"; return 1; }
  return 0
}

# seed_branch_state: leaves the merged branch without a local ref beside an
# open branch that has one, with state planted for both.
seed_branch_state() {
  git -C "$MAIN" branch feat-open "$OLD_SHA" || return 1
  plant_branch_state feat-merged || return 1
  plant_branch_state feat-open || return 1
}

# assert_merged_state_pruned: the arm ran clean, the merged branch's state is
# gone, and the open branch's state is whole.
assert_merged_state_pruned() {
  [ "$STATUS" -eq 0 ] || { echo "FAIL: the arm stopped (exit $STATUS): $OUT"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq 'command not found' && { echo "FAIL: a command was not found: $OUT"; return 1; }
  [ "$(state_remaining feat-merged)" = 0 ] || { echo "FAIL: the merged branch keeps its state"; return 1; }
  [ "$(state_remaining feat-open)" = 3 ] || { echo "FAIL: the open branch lost state"; return 1; }
  return 0
}

# check_feature_arm_prunes_state <dir>
check_feature_arm_prunes_state() {
  local body
  make_fixture "$1" feat-merged || return 1
  seed_branch_state || return 1
  body=$(rendered_body "$FEATURE_ARM" 1 feat-merged "") || { echo "$body"; return 1; }
  run_body "$body"
  assert_merged_state_pruned
}

# check_worktree_arm_prunes_state <dir> <path|name>
check_worktree_arm_prunes_state() {
  prepare_tree "$1" nolock clean || return 1
  seed_branch_state || return 1
  run_arm "$2" || return 1
  assert_merged_state_pruned
}

# check_path_arm_prunes_state_from_inside_the_tree <dir>: the verb still prunes
# the merged branch's state when the session's cwd is the tree being removed.
check_path_arm_prunes_state_from_inside_the_tree() {
  prepare_tree "$1" nolock clean || return 1
  seed_branch_state || return 1
  run_arm path "$TREE" || return 1
  assert_merged_state_pruned
}

# ---------------------------------------------------------------------------
# Case tables

# run_case <label> <default branch> <origin/HEAD recorded: 1 or empty> <check>
# [check arguments]: runs the check against a fresh fixture directory and fails
# naming the case.
run_case() {
  local label=$1 FIXTURE_DEFAULT=$2 FIXTURE_ORIGIN_HEAD=$3 check=$4
  shift 4
  CASE_NUMBER=$((${CASE_NUMBER:-0} + 1))
  run "$check" "$BATS_TEST_TMPDIR/case-$CASE_NUMBER" "$@"
  [ "$status" -eq 0 ] || { printf 'case failed: %s\n%s\n' "$label" "$output"; return 1; }
}

@test "feature branch cleanup arm: HEAD on the merged branch or on main ends on main at origin/main, a peer branch is not pulled, a linked worktree holding main stops it" {
  run_case "HEAD on the merged branch ends on main at origin/main with the branch and its remote ref gone" main "" check_feature_head_on_merged_branch || return 1
  run_case "HEAD already on main pulls, deletes the branch and prunes" main "" check_feature_head_on_main || return 1
  run_case "a peer branch in the main checkout is not pulled and the merged branch is still cleaned" main "" check_feature_peer_branch_left_alone || return 1
  run_case "a linked worktree holding main stops the script with nothing deleted" main "" check_feature_stops_when_linked_worktree_holds_main
}

@test "worktree cleanup arm removal: by-name tail, by-path addressing, and the states that do not stop the removal" {
  run_case "by name: the tail after the tree is gone cleans the branch and pulls main" main "" check_name_arm_tail main || return 1
  run_case "by name: the tail does not pull when a peer branch holds the main checkout" main "" check_name_arm_tail peer || return 1
  run_case "by path: the tree is removed by path and the branch by its own name when the two differ" main "" check_path_arm_addresses_tree_and_branch_separately || return 1
  run_case "by path: a populated .gaia-backup does not stop the removal" main "" check_arm_removes path backup-only || return 1
  run_case "by path: an ignored file alone does not stop the removal" main "" check_arm_removes path ignored || return 1
  run_case "by name: an ignored file alone does not stop the removal" main "" check_arm_removes name ignored || return 1
  run_case "by path: a local commit with no upstream ref does not stop the removal" main "" check_arm_removes path no-upstream || return 1
  run_case "by name: a local commit with no upstream ref does not stop the removal" main "" check_arm_removes name no-upstream || return 1
  run_case "by path: the arm works with the session's cwd inside the tree it removes" main "" check_path_arm_from_inside_the_tree
}

@test "worktree cleanup arm refuses on untracked or uncommitted work, leaving the tree, branch, main and pnpm untouched" {
  run_case "by path: an untracked file stops at the check" main "" check_arm_stops_on_untracked_file path || return 1
  run_case "by name: an untracked file stops at the check before the tail is reached" main "" check_arm_stops_on_untracked_file name || return 1
  run_case "by path: an uncommitted edit stops the arm and prints the removal commands" main "" check_arm_stops_on_dirty path || return 1
  run_case "by name: an uncommitted edit stops the arm and prints the removal commands" main "" check_arm_stops_on_dirty name
}

@test "worktree cleanup arm pull and install: install only after a lockfile change, and a failed install, a peer branch or a failed pull is reported with its next steps" {
  local arm
  for arm in path name; do
    run_case "by $arm: a pull that changed the lockfile installs once, frozen, in the main checkout" main "" check_arm_installs_on_lockfile_change "$arm" lock || return 1
    run_case "by $arm: a pull that left the lockfile alone runs no install" main "" check_arm_installs_on_lockfile_change "$arm" nolock || return 1
    run_case "by $arm: a failed install is reported with its next step and the removal stands" main "" check_arm_reports_failed_install "$arm" || return 1
    run_case "by $arm: a peer branch in the main checkout means no pull and no install, both named as next steps" main "" check_arm_skips_install_for_peer "$arm" || return 1
    run_case "by $arm: a failed pull runs no install and names both as next steps" main "" check_arm_skips_install_when_pull_fails "$arm" || return 1
  done
}

@test "cleanup arms resolve the default branch: master with no origin/HEAD, and origin/HEAD naming trunk" {
  run_case "master: feature branch ends on master at origin/master" master "" check_feature_head_on_merged_branch || return 1
  run_case "master: a linked worktree holding master stops the feature script" master "" check_feature_stops_when_linked_worktree_holds_main || return 1
  run_case "master: the by-name tail pulls master" master "" check_name_arm_tail main || return 1
  run_case "master: the by-path arm pulls master" master "" check_path_arm_addresses_tree_and_branch_separately || return 1
  run_case "master: a peer branch names the master pull as the next step" master "" check_arm_skips_install_for_peer name || return 1
  run_case "trunk: the feature arm pulls trunk" trunk 1 check_feature_head_on_merged_branch || return 1
  run_case "trunk: the by-name tail pulls trunk" trunk 1 check_name_arm_tail main || return 1
  run_case "trunk: the by-path arm pulls trunk" trunk 1 check_path_arm_addresses_tree_and_branch_separately
}

@test "cleanup arms run the state-cleanup verb: a merged branch's state is pruned and an open branch's kept" {
  run_case "feature branch" main "" check_feature_arm_prunes_state || return 1
  run_case "worktree by name" main "" check_worktree_arm_prunes_state name || return 1
  run_case "worktree by path" main "" check_worktree_arm_prunes_state path || return 1
  run_case "worktree by path from inside the tree" main "" check_path_arm_prunes_state_from_inside_the_tree
}
