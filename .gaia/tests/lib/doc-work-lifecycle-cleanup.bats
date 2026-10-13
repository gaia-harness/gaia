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
#   - Feature branch: the main checkout ends on `main` at `origin/main`, the
#     merged branch and its remote-tracking ref are gone; a peer branch held
#     by the main checkout is left alone (no pull); a linked worktree holding
#     `main` makes the script stop having deleted nothing.
#   - Worktree entered by name: the tail after the runtime removed the tree.
#   - Worktree entered by path: the tree is addressed by the path and the
#     branch by the name the porcelain record shows, which differ.
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

# rendered_body <heading> <index> <branch> <worktree path>: the fence with its
# two placeholders replaced by literal substitution. Fails when the fence is
# empty or any angle-bracket placeholder survives, because bash would read a
# leftover `<token>` as a redirection and `bash -n` would not notice.
rendered_body() {
  local body
  body=$(fence_body "$1" "$2")
  [ -n "$body" ] || { echo "FAIL: no fence $2 under $1"; return 1; }
  body=${body//"<branch-name>"/$3}
  body=${body//"<worktree path>"/$4}
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

# make_fixture <dir> <branch>: sets ORIGIN, MAIN, OLD_SHA. The main checkout is
# left on `main`, one commit behind `origin/main`; <branch> exists locally and
# its remote-tracking ref exists, while the remote has dropped it.
make_fixture() {
  local dir=$1 branch=$2 other
  mkdir -p "$dir" || return 1
  ORIGIN="$dir/origin.git"
  MAIN="$dir/main-checkout"
  other="$dir/other"
  git init -q --bare -b main "$ORIGIN" || return 1
  git init -q -b main "$MAIN" || return 1
  git -C "$MAIN" remote add origin "$ORIGIN" || return 1
  commit_file "$MAIN" base || return 1
  git -C "$MAIN" push -q -u origin main 2>/dev/null || return 1
  OLD_SHA=$(git -C "$MAIN" rev-parse main) || return 1
  git -C "$MAIN" checkout -q -b "$branch" || return 1
  commit_file "$MAIN" feature || return 1
  git -C "$MAIN" push -q -u origin "$branch" 2>/dev/null || return 1
  git -C "$MAIN" checkout -q main || return 1
  # The squash merge: origin/main gains a commit that is not an ancestor of
  # the feature branch, and the remote drops the feature branch.
  git clone -q "$ORIGIN" "$other" 2>/dev/null || return 1
  commit_file "$other" squashed || return 1
  git -C "$other" push -q origin main 2>/dev/null || return 1
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

ref_exists() { git -C "$MAIN" show-ref --verify --quiet "$1"; }

main_matches_origin() {
  [ "$(git -C "$MAIN" rev-parse main)" = "$(git -C "$MAIN" rev-parse origin/main)" ]
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
  [ "$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)" = main ] || { echo "FAIL: HEAD is not main"; return 1; }
  main_matches_origin || { echo "FAIL: main is not at origin/main"; return 1; }
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
  [ "$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)" = main ] || { echo "FAIL: HEAD is not main"; return 1; }
  main_matches_origin || { echo "FAIL: main is not at origin/main"; return 1; }
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
  git -C "$MAIN" worktree add -q "$1/linked-main" main || return 1
  head_before=$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)
  body=$(rendered_body "$FEATURE_ARM" 1 "$branch" "") || { echo "$body"; return 1; }
  run_body "$body"
  [ "$STATUS" -ne 0 ] || { echo "FAIL: the script exited 0: $OUT"; return 1; }
  [ "$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)" = "$head_before" ] || { echo "FAIL: HEAD moved"; return 1; }
  ref_exists "refs/heads/$branch" || { echo "FAIL: the merged branch was deleted"; return 1; }
  printf '%s\n' "$OUT" | grep -Fq "linked worktree holds main" || { echo "FAIL: the stop was not the linked-worktree check: $OUT"; return 1; }
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
  body=$(rendered_body "$NAME_ARM" 1 "$branch" "") || { echo "$body"; return 1; }
  run_body "$body"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: exit $STATUS: $OUT"; return 1; }
  ref_exists "refs/heads/$branch" && { echo "FAIL: local branch survives"; return 1; }
  ref_exists "refs/remotes/origin/$branch" && { echo "FAIL: remote-tracking ref survives"; return 1; }
  if [ "$2" = peer ]; then
    [ "$(git -C "$MAIN" rev-parse refs/heads/peer)" = "$OLD_SHA" ] || { echo "FAIL: the peer branch moved: a pull ran"; return 1; }
  else
    main_matches_origin || { echo "FAIL: main is not at origin/main"; return 1; }
  fi
  return 0
}

check_path_arm_addresses_tree_and_branch_separately() {
  local branch=hand-name tree_dir=rehearsal-dir porcelain record wt_path wt_branch body
  make_fixture "$1" "$branch" || return 1
  mkdir -p "$MAIN/.claude/worktrees" || return 1
  git -C "$MAIN" worktree add -q "$MAIN/.claude/worktrees/$tree_dir" "$branch" || return 1
  body=$(rendered_body "$PATH_ARM" 1 "" "") || { echo "$body"; return 1; }
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
  body=$(rendered_body "$PATH_ARM" 2 "$wt_branch" "$wt_path") || { echo "$body"; return 1; }
  run_body "$body"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: exit $STATUS: $OUT"; return 1; }
  [ -e "$wt_path" ] && { echo "FAIL: the worktree directory survives"; return 1; }
  ref_exists "refs/heads/$branch" && { echo "FAIL: local branch survives"; return 1; }
  ref_exists "refs/remotes/origin/$branch" && { echo "FAIL: remote-tracking ref survives"; return 1; }
  main_matches_origin || { echo "FAIL: main is not at origin/main"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Helpers for the tests

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
  [ "$(section "$REFERENCE" "$NAME_ARM" | bash_fence_count)" -eq 1 ] || return 1
  [ "$(section "$REFERENCE" "$PATH_ARM" | bash_fence_count)" -eq 2 ] || return 1
  [ "$(section "$REFERENCE" "$FEATURE_ARM" | bash_fence_count)" -eq 1 ] || return 1
  [ "$(section "$REFERENCE" "$CLEANUP_HEADING" | bash_fence_count)" -eq 4 ] || {
    echo "the cleanup section holds a bash fence no arm accounts for"
    return 1
  }
  [ "$(fence_body "$PATH_ARM" 1)" = "git worktree list --porcelain" ] || return 1
  fence_body "$PATH_ARM" 2 | head -n 1 | grep -Fq 'git worktree remove --force <worktree path>' || return 1
}

@test "every cleanup fence parses after substitution and leaves no placeholder" {
  local arm count index body
  for arm in "$NAME_ARM:1" "$PATH_ARM:2" "$FEATURE_ARM:1"; do
    count=${arm##*:}
    arm=${arm%:*}
    index=1
    while [ "$index" -le "$count" ]; do
      body=$(rendered_body "$arm" "$index" "feat-merged" "/fixture/tree") || { echo "$body"; return 1; }
      printf '%s\n' "$body" | bash -n || { echo "does not parse: $arm fence $index"; return 1; }
      index=$((index + 1))
    done
  done
}

@test "the worktree arms never check out or switch a branch" {
  local arm count index body
  for arm in "$NAME_ARM:1" "$PATH_ARM:2"; do
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
  mutate_reference -e 's/^if \[ "\$head_branch" = main \]; then$/if true; then/' || return 1
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
