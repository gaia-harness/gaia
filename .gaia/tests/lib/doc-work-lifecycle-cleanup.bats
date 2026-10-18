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
# Every check is a function that returns non-zero on a broken outcome. The
# red twins run the same function against a sed-mutated copy of the reference
# (via WORK_LIFECYCLE_REFERENCE) and require it to fail with the reason the
# mutation should cause, so each guard is proven able to fail.
#
# The suite never touches the real repository: every git command targets a
# directory under BATS_TEST_TMPDIR.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  REFERENCE="${WORK_LIFECYCLE_REFERENCE:-$REPO_ROOT/.claude/skills/gaia/references/work-lifecycle.md}"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="Fixture" GIT_AUTHOR_EMAIL="fixture@example.invalid"
  export GIT_COMMITTER_NAME="Fixture" GIT_COMMITTER_EMAIL="fixture@example.invalid"

  CLEANUP_HEADING="## 8. Cleanup"
  NAME_ARM="### Worktree entered by name in this session"
  PATH_ARM="### Worktree entered by path or in an earlier session"
  FEATURE_ARM="### Feature branch"
  CONTINUATION="### Sub-agent context: continuation prompt"
  CHECK_SCRIPT="$REPO_ROOT/.gaia/scripts/worktree-removal-check.sh"
  DEBT_REFERENCE="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
  LIFECYCLE_REFERENCE="$REPO_ROOT/.claude/skills/gaia/references/spec/lifecycle.md"
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

# bash_fence_count: stdin is a document; prints how many ```bash fences it has.
bash_fence_count() {
  awk '
    state == 0 && /^```bash[ ]*$/ { state = 1; seen++; next }
    state == 0 && /^```/ { state = 2; next }
    state != 0 && /^```[ ]*$/ { state = 0; next }
    END { print seen + 0 }
  '
}

# fence_body <heading> <index>
fence_body() {
  section "$REFERENCE" "$1" | bash_fences "$2"
}

# rendered_body <heading> <index> <branch> <worktree path> <main checkout path>:
# the fence with its three placeholders replaced by literal substitution, and
# the repo-relative check script replaced by CHECK_SCRIPT so a fixture runs the
# real file (or a mutated copy). Fails when the fence is empty or any
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

# make_fixture <dir> <branch> [lock]: sets ORIGIN, MAIN, OLD_SHA. The main
# checkout is left on FIXTURE_DEFAULT, one commit behind its remote-tracking
# ref, and origin/HEAD is recorded only when FIXTURE_ORIGIN_HEAD is set; <branch> exists
# locally and its remote-tracking ref exists, while the remote has dropped it.
# With a third argument of `lock` the squash commit also changes
# `pnpm-lock.yaml`.
make_fixture() {
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
  OLD_SHA=$(git -C "$MAIN" rev-parse "$FIXTURE_DEFAULT") || return 1
  git -C "$MAIN" checkout -q -b "$branch" || return 1
  commit_file "$MAIN" feature || return 1
  git -C "$MAIN" push -q -u origin "$branch" 2>/dev/null || return 1
  git -C "$MAIN" checkout -q "$FIXTURE_DEFAULT" || return 1
  # The squash merge: the default branch on origin gains a commit that is not an ancestor of
  # the feature branch, and the remote drops the feature branch.
  git clone -q "$ORIGIN" "$other" 2>/dev/null || return 1
  commit_file "$other" squashed || return 1
  if [ "${3:-}" = lock ]; then
    commit_file "$other" pnpm-lock.yaml || return 1
  fi
  git -C "$other" push -q origin "$FIXTURE_DEFAULT" 2>/dev/null || return 1
  git -C "$other" push -q origin --delete "$branch" 2>/dev/null || return 1
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
# Checks. Each takes a scratch dir, builds its own fixture, and returns
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

# continuation_commands: the indented command lines of the continuation prompt.
continuation_commands() {
  section "$REFERENCE" "$CONTINUATION" | grep -E '^    [^ ]'
}

# check_continuation_prompt_order: the check first, the frozen install last.
check_continuation_prompt_order() {
  local commands first last
  commands=$(continuation_commands)
  [ -n "$commands" ] || { echo "FAIL: the continuation prompt holds no command lines"; return 1; }
  first=$(printf '%s\n' "$commands" | head -n 1)
  last=$(printf '%s\n' "$commands" | tail -n 1)
  printf '%s\n' "$first" | grep -Fq 'worktree-removal-check.sh --tree <ABSOLUTE-PATH-TO-WORKTREE>' || { echo "FAIL: the first command is not the check: $first"; return 1; }
  printf '%s\n' "$last" | grep -Fq -- '--frozen-lockfile' || { echo "FAIL: the last command is not the frozen install: $last"; return 1; }
  return 0
}

# check_report_pin <file>: the sentence that sends a stop into the run's report.
check_report_pin() {
  grep -F 'A stop at the pre-removal check goes into' "$1" | grep -Fq "the check's output and the removal commands" || {
    echo "FAIL: $1 has no report sentence for a pre-removal-check stop"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Helpers for the tests

mutate_check_script() { # sed args: points CHECK_SCRIPT at a mutated copy
  local copy="$BATS_TEST_TMPDIR/mutated-check.sh"
  sed "$@" "$REPO_ROOT/.gaia/scripts/worktree-removal-check.sh" >"$copy" || return 1
  if cmp -s "$copy" "$REPO_ROOT/.gaia/scripts/worktree-removal-check.sh"; then
    echo "the mutation changed nothing"
    return 1
  fi
  CHECK_SCRIPT=$copy
}

assert_check_green() { # function name and arguments
  run "$@"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

# mutate_reference <sed args...>: points REFERENCE at a mutated copy; fails
# when the mutation changed nothing, so a twin cannot go vacuous.
mutate_reference() {
  local copy="$BATS_TEST_TMPDIR/mutated-reference.md"
  sed "$@" "$REFERENCE" >"$copy" || return 1
  if cmp -s "$copy" "$REFERENCE"; then
    echo "the mutation changed nothing"
    return 1
  fi
  REFERENCE=$copy
}

assert_check_red() { # expected reason, then function name and arguments
  local reason=$1
  shift
  run "$@"
  [ "$status" -ne 0 ] || { echo "the check stayed green on the mutated reference"; return 1; }
  printf '%s\n' "$output" | grep -Fq -- "$reason" || { printf 'red for another reason: %s\n' "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# Fence contract

@test "each cleanup arm carries the fences the fixtures expect" {
  [ -s "$REFERENCE" ] || { echo "the reference is absent"; return 1; }
  [ "$(section "$REFERENCE" "$NAME_ARM" | bash_fence_count)" -eq 2 ] || return 1
  [ "$(section "$REFERENCE" "$PATH_ARM" | bash_fence_count)" -eq 3 ] || return 1
  [ "$(section "$REFERENCE" "$FEATURE_ARM" | bash_fence_count)" -eq 1 ] || return 1
  [ "$(section "$REFERENCE" "$CLEANUP_HEADING" | bash_fence_count)" -eq 6 ] || {
    echo "the cleanup section holds a bash fence no arm accounts for"
    return 1
  }
  [ "$(fence_body "$NAME_ARM" 1)" = "bash .gaia/scripts/worktree-removal-check.sh --tree <worktree path>" ] || return 1
  [ "$(fence_body "$PATH_ARM" 1)" = "git -C <main checkout path> worktree list --porcelain" ] || return 1
  [ "$(fence_body "$PATH_ARM" 2)" = "bash .gaia/scripts/worktree-removal-check.sh --tree <worktree path>" ] || return 1
  fence_body "$PATH_ARM" 3 | head -n 1 | grep -Fq 'git -C <main checkout path> worktree remove --force <worktree path>' || return 1
}

@test "every cleanup fence parses after substitution and leaves no placeholder" {
  local arm count index body
  for arm in "$NAME_ARM:2" "$PATH_ARM:3" "$FEATURE_ARM:1"; do
    count=${arm##*:}
    arm=${arm%:*}
    index=1
    while [ "$index" -le "$count" ]; do
      body=$(rendered_body "$arm" "$index" "feat-merged" "/fixture/tree" "/fixture/main") || { echo "$body"; return 1; }
      printf '%s\n' "$body" | bash -n || { echo "does not parse: $arm fence $index"; return 1; }
      index=$((index + 1))
    done
  done
}

@test "the worktree arms never check out or switch a branch" {
  local arm count index body
  for arm in "$NAME_ARM:2" "$PATH_ARM:3"; do
    count=${arm##*:}
    arm=${arm%:*}
    index=1
    while [ "$index" -le "$count" ]; do
      body=$(fence_body "$arm" "$index")
      [ -n "$body" ] || { echo "empty fence $index under $arm"; return 1; }
      printf '%s\n' "$body" | grep -Eq 'git (checkout|switch)' && { echo "$arm fence $index moves a branch"; return 1; }
      index=$((index + 1))
    done
  done
  true
}

# ---------------------------------------------------------------------------
# Executed outcomes

@test "feature branch: HEAD on the merged branch ends on main at origin/main with the branch and its remote ref gone" {
  assert_check_green check_feature_head_on_merged_branch "$BATS_TEST_TMPDIR/fixture"
}

@test "feature branch: HEAD already on main pulls, deletes the branch and prunes" {
  assert_check_green check_feature_head_on_main "$BATS_TEST_TMPDIR/fixture"
}

@test "feature branch: a peer branch in the main checkout is not pulled and the merged branch is still cleaned" {
  assert_check_green check_feature_peer_branch_left_alone "$BATS_TEST_TMPDIR/fixture"
}

@test "feature branch: a linked worktree holding main stops the script with nothing deleted" {
  assert_check_green check_feature_stops_when_linked_worktree_holds_main "$BATS_TEST_TMPDIR/fixture"
}

@test "worktree by name: the tail after the tree is gone cleans the branch and pulls main" {
  assert_check_green check_name_arm_tail "$BATS_TEST_TMPDIR/fixture" main
}

@test "worktree by name: the tail does not pull when a peer branch holds the main checkout" {
  assert_check_green check_name_arm_tail "$BATS_TEST_TMPDIR/fixture" peer
}

@test "worktree by path: the tree is removed by path and the branch by its own name when the two differ" {
  assert_check_green check_path_arm_addresses_tree_and_branch_separately "$BATS_TEST_TMPDIR/fixture"
}

# ---------------------------------------------------------------------------
# Red twins: the same check against a mutated reference must fail.

@test "red twin: without the linked-worktree check the feature script no longer says why it stopped" {
  mutate_reference -e '/git worktree list --porcelain | awk/,/^  fi$/d' || return 1
  assert_check_red "the stop was not the linked-worktree check" \
    check_feature_stops_when_linked_worktree_holds_main "$BATS_TEST_TMPDIR/fixture"
}

@test "red twin: an unconditional pull moves the peer branch" {
  mutate_reference -e 's/^if \[ "\$head_branch" = "\$default_branch" \]; then$/if true; then/' || return 1
  assert_check_red "the peer branch moved" \
    check_feature_peer_branch_left_alone "$BATS_TEST_TMPDIR/fixture"
}

@test "red twin: addressing the branch by the directory name leaves the real branch behind" {
  mutate_reference \
    -e '/^### Worktree entered by path/,/^### Feature branch/s/refs\/heads\/<branch-name>/refs\/heads\/$(basename "<worktree path>")/' \
    -e '/^### Worktree entered by path/,/^### Feature branch/s/branch -D <branch-name>/branch -D $(basename "<worktree path>")/' || return 1
  assert_check_red "local branch survives" \
    check_path_arm_addresses_tree_and_branch_separately "$BATS_TEST_TMPDIR/fixture"
}

@test "red twin: without fetch --prune the remote-tracking ref survives the tail" {
  mutate_reference -e '/^git fetch --prune origin$/d' || return 1
  assert_check_red "remote-tracking ref survives" \
    check_name_arm_tail "$BATS_TEST_TMPDIR/fixture" main
}

# ---------------------------------------------------------------------------
# Worktree arms: the pre-removal check, the pull gate and the conditional install

@test "worktree by path: an untracked file stops at the check with the tree, branch, main and pnpm untouched" {
  assert_check_green check_arm_stops_on_untracked_file "$BATS_TEST_TMPDIR/fixture" path
}

@test "worktree by name: an untracked file stops at the check before the tail is reached" {
  assert_check_green check_arm_stops_on_untracked_file "$BATS_TEST_TMPDIR/fixture" name
}

@test "worktree by path: a populated .gaia-backup does not stop the removal" {
  assert_check_green check_arm_removes "$BATS_TEST_TMPDIR/fixture" path backup-only
}

@test "worktree by path: an uncommitted edit stops the arm and prints the removal commands" {
  assert_check_green check_arm_stops_on_dirty "$BATS_TEST_TMPDIR/fixture" path
}

@test "worktree by name: an uncommitted edit stops the arm and prints the removal commands" {
  assert_check_green check_arm_stops_on_dirty "$BATS_TEST_TMPDIR/fixture" name
}

@test "worktree by path: an ignored file alone does not stop the removal" {
  assert_check_green check_arm_removes "$BATS_TEST_TMPDIR/fixture" path ignored
}

@test "worktree by name: an ignored file alone does not stop the removal" {
  assert_check_green check_arm_removes "$BATS_TEST_TMPDIR/fixture" name ignored
}

@test "worktree by path: a local commit with no upstream ref does not stop the removal" {
  assert_check_green check_arm_removes "$BATS_TEST_TMPDIR/fixture" path no-upstream
}

@test "worktree by name: a local commit with no upstream ref does not stop the removal" {
  assert_check_green check_arm_removes "$BATS_TEST_TMPDIR/fixture" name no-upstream
}

@test "worktree by path: a pull that changed the lockfile installs once, frozen, in the main checkout" {
  assert_check_green check_arm_installs_on_lockfile_change "$BATS_TEST_TMPDIR/fixture" path lock
}

@test "worktree by path: a pull that left the lockfile alone runs no install" {
  assert_check_green check_arm_installs_on_lockfile_change "$BATS_TEST_TMPDIR/fixture" path nolock
}

@test "worktree by name: a pull that changed the lockfile installs once, frozen, in the main checkout" {
  assert_check_green check_arm_installs_on_lockfile_change "$BATS_TEST_TMPDIR/fixture" name lock
}

@test "worktree by name: a pull that left the lockfile alone runs no install" {
  assert_check_green check_arm_installs_on_lockfile_change "$BATS_TEST_TMPDIR/fixture" name nolock
}

@test "worktree by path: a failed install is reported with its next step and the removal stands" {
  assert_check_green check_arm_reports_failed_install "$BATS_TEST_TMPDIR/fixture" path
}

@test "worktree by name: a failed install is reported with its next step and the removal stands" {
  assert_check_green check_arm_reports_failed_install "$BATS_TEST_TMPDIR/fixture" name
}

@test "worktree by path: a peer branch in the main checkout means no pull and no install, both named as next steps" {
  assert_check_green check_arm_skips_install_for_peer "$BATS_TEST_TMPDIR/fixture" path
}

@test "worktree by name: a peer branch in the main checkout means no pull and no install, both named as next steps" {
  assert_check_green check_arm_skips_install_for_peer "$BATS_TEST_TMPDIR/fixture" name
}

@test "worktree by path: a failed pull runs no install and names both as next steps" {
  assert_check_green check_arm_skips_install_when_pull_fails "$BATS_TEST_TMPDIR/fixture" path
}

@test "worktree by name: a failed pull runs no install and names both as next steps" {
  assert_check_green check_arm_skips_install_when_pull_fails "$BATS_TEST_TMPDIR/fixture" name
}

@test "worktree by path: the arm works with the session's cwd inside the tree it removes" {
  assert_check_green check_path_arm_from_inside_the_tree "$BATS_TEST_TMPDIR/fixture"
}

@test "the continuation prompt lists the check first and the frozen install last" {
  assert_check_green check_continuation_prompt_order
}

@test "debt.md and the spec lifecycle each send a pre-removal-check stop into the run's report" {
  assert_check_green check_report_pin "$DEBT_REFERENCE"
  assert_check_green check_report_pin "$LIFECYCLE_REFERENCE"
}

# ---------------------------------------------------------------------------
# Red twins for the worktree arms

@test "red twin: a by-path arm whose check fence does nothing removes a tree holding an untracked file" {
  mutate_reference -e '/^### Worktree entered by path/,/^### Feature branch/s|^bash .gaia/scripts/worktree-removal-check.sh --tree <worktree path>$|true|' || return 1
  assert_check_red "the arm exited 0" \
    check_arm_stops_on_untracked_file "$BATS_TEST_TMPDIR/fixture" path
}

@test "red twin: a by-name arm whose check fence does nothing reaches the tail with an untracked file" {
  mutate_reference -e '/^### Worktree entered by name/,/^### Worktree entered by path/s|^bash .gaia/scripts/worktree-removal-check.sh --tree <worktree path>$|true|' || return 1
  assert_check_red "the arm exited 0" \
    check_arm_stops_on_untracked_file "$BATS_TEST_TMPDIR/fixture" name
}

@test "red twin: a check script without the status test lets a dirty tree through both arms" {
  mutate_check_script -e 's/^dirty=.*/dirty=""/' || return 1
  assert_check_red "the arm exited 0" \
    check_arm_stops_on_dirty "$BATS_TEST_TMPDIR/fixture-path" path
  assert_check_red "the arm exited 0" \
    check_arm_stops_on_dirty "$BATS_TEST_TMPDIR/fixture-name" name
}

@test "red twin: a check script that counts ignored files stops both arms on an ignored file" {
  mutate_check_script -e 's/status --porcelain/status --porcelain --ignored/' || return 1
  assert_check_red "the arm stopped" \
    check_arm_removes "$BATS_TEST_TMPDIR/fixture-path" path ignored
  assert_check_red "the arm stopped" \
    check_arm_removes "$BATS_TEST_TMPDIR/fixture-name" name ignored
}

@test "red twin: a check script that counts against origin/main without the upstream guard stops both arms with no upstream" {
  mutate_check_script -e 's|^if upstream=.*|upstream=origin/main; if true; then|' -e "s|'@{upstream}\\.\\.HEAD'|origin/main..HEAD|" || return 1
  assert_check_red "the arm stopped" \
    check_arm_removes "$BATS_TEST_TMPDIR/fixture-path" path no-upstream
  assert_check_red "the arm stopped" \
    check_arm_removes "$BATS_TEST_TMPDIR/fixture-name" name no-upstream
}

@test "red twin: a bare git in the by-path removal fence fails from inside the tree" {
  mutate_reference -e '/^### Worktree entered by path/,/^### Feature branch/s/git -C <main checkout path> //' || return 1
  assert_check_red "FAIL:" \
    check_path_arm_from_inside_the_tree "$BATS_TEST_TMPDIR/fixture"
}

@test "red twin: an unconditional install runs pnpm when the pull changed no lockfile" {
  mutate_reference -e 's/^\( *\)if ! git .*diff --quiet .*pnpm-lock.yaml; then$/\1if true; then/' || return 1
  assert_check_red "pnpm was called without a lockfile change" \
    check_arm_installs_on_lockfile_change "$BATS_TEST_TMPDIR/fixture-path" path nolock
  assert_check_red "pnpm was called without a lockfile change" \
    check_arm_installs_on_lockfile_change "$BATS_TEST_TMPDIR/fixture-name" name nolock
}

@test "red twin: an install without --frozen-lockfile is not the call the stub must see" {
  mutate_reference -e 's/^\( *if ! pnpm .*install\) --frozen-lockfile; then$/\1; then/' || return 1
  assert_check_red "pnpm was not called as" \
    check_arm_installs_on_lockfile_change "$BATS_TEST_TMPDIR/fixture-path" path lock
  assert_check_red "pnpm was not called as" \
    check_arm_installs_on_lockfile_change "$BATS_TEST_TMPDIR/fixture-name" name lock
}

@test "red twin: a pull gate that no longer exits lets a failed pull read as success" {
  mutate_reference -e '/The pull failed/{n;s/exit 1/:/;}' || return 1
  assert_check_red "a failed pull exited 0" \
    check_arm_skips_install_when_pull_fails "$BATS_TEST_TMPDIR/fixture-path" path
  assert_check_red "a failed pull exited 0" \
    check_arm_skips_install_when_pull_fails "$BATS_TEST_TMPDIR/fixture-name" name
}

@test "red twin: a continuation prompt without the check line fails the order check" {
  mutate_reference -e '/^    bash .gaia\/scripts\/worktree-removal-check.sh --tree <ABSOLUTE-PATH-TO-WORKTREE>/d' || return 1
  assert_check_red "the first command is not the check" check_continuation_prompt_order
}

@test "red twin: a continuation prompt without the install line fails the order check" {
  mutate_reference -e '/^    pnpm -C <ABSOLUTE-PATH-TO-MAIN-CHECKOUT> install --frozen-lockfile/d' || return 1
  assert_check_red "the last command is not the frozen install" check_continuation_prompt_order
}

@test "red twin: a debt.md copy without the report sentence is reported" {
  sed -e 's/ A stop at the pre-removal check goes into[^;]*; the merge itself still counts as done\.//' "$DEBT_REFERENCE" >"$BATS_TEST_TMPDIR/debt-copy.md" || return 1
  cmp -s "$BATS_TEST_TMPDIR/debt-copy.md" "$DEBT_REFERENCE" && { echo "the mutation changed nothing"; return 1; }
  assert_check_red "has no report sentence" check_report_pin "$BATS_TEST_TMPDIR/debt-copy.md"
}

@test "red twin: a spec lifecycle copy without the report sentence is reported" {
  sed -e 's/ A stop at the pre-removal check goes into[^;]*; the merge itself still counts as done\.//' "$LIFECYCLE_REFERENCE" >"$BATS_TEST_TMPDIR/lifecycle-copy.md" || return 1
  cmp -s "$BATS_TEST_TMPDIR/lifecycle-copy.md" "$LIFECYCLE_REFERENCE" && { echo "the mutation changed nothing"; return 1; }
  assert_check_red "has no report sentence" check_report_pin "$BATS_TEST_TMPDIR/lifecycle-copy.md"
}

# ---------------------------------------------------------------------------
# A default branch other than main

@test "master default, no origin/HEAD: feature branch ends on master at origin/master" {
  FIXTURE_DEFAULT=master
  assert_check_green check_feature_head_on_merged_branch "$BATS_TEST_TMPDIR/fixture"
}

@test "master default, no origin/HEAD: a linked worktree holding master stops the feature script" {
  FIXTURE_DEFAULT=master
  assert_check_green check_feature_stops_when_linked_worktree_holds_main "$BATS_TEST_TMPDIR/fixture"
}

@test "master default, no origin/HEAD: the by-name tail pulls master" {
  FIXTURE_DEFAULT=master
  assert_check_green check_name_arm_tail "$BATS_TEST_TMPDIR/fixture" main
}

@test "master default, no origin/HEAD: the by-path arm pulls master" {
  FIXTURE_DEFAULT=master
  assert_check_green check_path_arm_addresses_tree_and_branch_separately "$BATS_TEST_TMPDIR/fixture"
}

@test "master default, no origin/HEAD: a peer branch names the master pull as the next step" {
  FIXTURE_DEFAULT=master
  assert_check_green check_arm_skips_install_for_peer "$BATS_TEST_TMPDIR/fixture" name
}

@test "origin/HEAD naming trunk: every arm pulls trunk" {
  FIXTURE_DEFAULT=trunk
  FIXTURE_ORIGIN_HEAD=1
  assert_check_green check_feature_head_on_merged_branch "$BATS_TEST_TMPDIR/fixture-feature"
  assert_check_green check_name_arm_tail "$BATS_TEST_TMPDIR/fixture-name" main
  assert_check_green check_path_arm_addresses_tree_and_branch_separately "$BATS_TEST_TMPDIR/fixture-path"
}

@test "red twin: a literal main default leaves a master repository unpulled in every arm" {
  mutate_reference -e 's/^\( *\)\[ -n "\$default_branch" \] || default_branch=main$/\1default_branch=main/' || return 1
  FIXTURE_DEFAULT=master
  assert_check_red "FAIL:" check_feature_head_on_merged_branch "$BATS_TEST_TMPDIR/fixture-feature"
  assert_check_red "FAIL:" check_name_arm_tail "$BATS_TEST_TMPDIR/fixture-name" main
  assert_check_red "FAIL:" check_path_arm_addresses_tree_and_branch_separately "$BATS_TEST_TMPDIR/fixture-path"
}

@test "red twin: without the origin/HEAD read a trunk default is not pulled" {
  mutate_reference -e 's|symbolic-ref --quiet --short refs/remotes/origin/HEAD|symbolic-ref --quiet --short refs/remotes/origin/NONE|' || return 1
  FIXTURE_DEFAULT=trunk
  FIXTURE_ORIGIN_HEAD=1
  assert_check_red "is not at origin/trunk" check_name_arm_tail "$BATS_TEST_TMPDIR/fixture-name" main
}
