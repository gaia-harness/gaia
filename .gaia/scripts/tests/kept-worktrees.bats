#!/usr/bin/env bats
# Tests for .gaia/scripts/kept-worktrees.sh, the ledger of worktrees a
# post-merge cleanup kept and the session-start reminder that lists them, and
# for the record call worktree-removal-check.sh makes when it stops a removal.
#
# Every case builds a throwaway repository under BATS_TEST_TMPDIR (a bare
# origin, a main checkout, and a linked worktree on a pushed branch) and runs
# copies of the scripts staged side by side, so a red twin can mutate one copy
# and leave the other real. No case touches the real repository.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="Fixture" GIT_AUTHOR_EMAIL="fixture@example.invalid"
  export GIT_COMMITTER_NAME="Fixture" GIT_COMMITTER_EMAIL="fixture@example.invalid"
  BRANCH=feat-tree
  make_tree "$BATS_TEST_TMPDIR/fixture"
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
  git -C "$MAIN" branch "$BRANCH" || return 1
  git -C "$MAIN" push -q -u origin "$BRANCH" 2>/dev/null || return 1
  TREE="$dir/tree"
  git -C "$MAIN" worktree add -q "$TREE" "$BRANCH" || return 1
  LEDGER="$MAIN/.gaia/local/kept-worktrees.tsv"
}

# stage_scripts: copies the check, the ledger script and the main-root library
# into one directory, the layout the scripts find each other by.
stage_scripts() {
  SCRIPTS="$BATS_TEST_TMPDIR/scripts"
  mkdir -p "$SCRIPTS" || return 1
  cp "$REPO_ROOT/.gaia/scripts/worktree-removal-check.sh" \
    "$REPO_ROOT/.gaia/scripts/kept-worktrees.sh" \
    "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$SCRIPTS/" || return 1
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

# gone_upstream: deletes BRANCH on the origin and prunes, so the tree's
# upstream reads [gone], the state a squash merge leaves after a later prune.
gone_upstream() {
  git -C "$MAIN" push -q origin --delete "$BRANCH" 2>/dev/null || return 1
  git -C "$MAIN" fetch -q --prune origin || return 1
}

# --- the record the check makes ---

@test "a tree the check stops is recorded and listed with its removal commands" {
  printf 'edited\n' >>"$TREE/base"
  run bash "$CHECK" --tree "$TREE"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; return 1; }
  remind
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "git worktree remove --force $TREE" || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "git branch -D $BRANCH" || { printf '%s\n' "$output"; return 1; }
}

@test "red twin: a check that never records leaves the reminder empty" {
  mutate worktree-removal-check.sh -e 's/^  bash "\$here\/kept-worktrees.sh" record .*/  :/' || return 1
  printf 'edited\n' >>"$TREE/base"
  run bash "$CHECK" --tree "$TREE"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; return 1; }
  remind
  [ -z "$output" ] || { printf 'stayed green: %s\n' "$output"; return 1; }
}

@test "the why names every condition that stopped the removal" {
  mkdir "$TREE/.gaia-merge"
  printf 'p\n' >"$TREE/.gaia-merge/a.patch"
  printf 'edited\n' >>"$TREE/base"
  git -C "$TREE" commit -q -am more
  printf 'again\n' >>"$TREE/base"
  run bash "$CHECK" --tree "$TREE"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; return 1; }
  remind
  printf '%s\n' "$output" | grep -Fxq -- "- $TREE (branch $BRANCH): unresolved .gaia-merge/ files, uncommitted changes, 1 unpushed commit(s)" || { printf '%s\n' "$output"; return 1; }
}

@test "a CLEAR verdict records nothing" {
  run bash "$CHECK" --tree "$TREE"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ -e "$LEDGER" ] && { printf 'ledger written on CLEAR\n'; return 1; }
  true
}

@test "stopping the same tree twice keeps one ledger line" {
  printf 'edited\n' >>"$TREE/base"
  run bash "$CHECK" --tree "$TREE"
  run bash "$CHECK" --tree "$TREE"
  [ "$(grep -c '' "$LEDGER")" -eq 1 ] || { cat "$LEDGER"; return 1; }
}

@test "red twin: appending without dropping the tree's old line keeps two" {
  mutate kept-worktrees.sh -e 's/\$1 != ENVIRON\["KEPT_TREE"\]/1/' || return 1
  printf 'edited\n' >>"$TREE/base"
  run bash "$CHECK" --tree "$TREE"
  run bash "$CHECK" --tree "$TREE"
  [ "$(grep -c '' "$LEDGER")" -eq 2 ] || { printf 'stayed green\n'; cat "$LEDGER"; return 1; }
}

# --- a ledger write failure never changes the check ---

# blocked_ledger_run: runs the check once with a writable ledger as the
# baseline, then again with .gaia/local a plain file so no ledger can be
# written, and fails unless the two runs match in status and output.
blocked_ledger_run() {
  local baseline_status baseline_output
  printf 'edited\n' >>"$TREE/base"
  run bash "$CHECK" --tree "$TREE"
  baseline_status=$status baseline_output=$output
  rm -rf "$MAIN/.gaia/local" || return 1
  printf 'not a directory\n' >"$MAIN/.gaia/local" || return 1
  run bash "$CHECK" --tree "$TREE"
  [ "$status" -eq "$baseline_status" ] || { printf 'status %s, baseline %s\n' "$status" "$baseline_status"; return 1; }
  [ "$output" = "$baseline_output" ] || { printf 'output changed:\n%s\n' "$output"; return 1; }
}

@test "a ledger write failure leaves the check's stop and exit code unchanged" {
  blocked_ledger_run || return 1
  [ "$status" -eq 1 ] || return 1
  printf '%s\n' "$output" | grep -Fq "git worktree remove --force $TREE" || { printf '%s\n' "$output"; return 1; }
}

@test "red twin: a record that fails loudly, passed through by the check, changes its exit code" {
  mutate kept-worktrees.sh -e 's/^  mkdir -p "\$ledger_directory" 2>\/dev\/null || return 0$/  mkdir -p "$ledger_directory" || exit 4/' || return 1
  sed -e 's/ >\/dev\/null 2>&1 || true$/ || exit $?/' "$CHECK" >"$CHECK.mutated" || return 1
  cmp -s "$CHECK" "$CHECK.mutated" && { echo "the check mutation changed nothing"; return 1; }
  mv "$CHECK.mutated" "$CHECK"
  run blocked_ledger_run
  [ "$status" -ne 0 ] || { printf 'stayed green: %s\n' "$output"; return 1; }
}

# --- the reminder ---

@test "a ledger entry is listed with its why and removal commands" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  remind
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "git worktree remove --force $TREE" || { printf '%s\n' "$output"; return 1; }
}

@test "red twin: a reminder that skips the ledger does not list it" {
  mutate kept-worktrees.sh -e 's/^  \[ -f "\$ledger" \] && ledger_input=\$ledger$/  :/' || return 1
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  remind
  printf '%s\n' "$output" | grep -Fq -- "- $TREE" && { printf 'stayed green: %s\n' "$output"; return 1; }
  true
}

@test "a linked worktree whose upstream reads [gone] is listed" {
  gone_upstream || return 1
  remind
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fxq -- "- $TREE (branch $BRANCH): its upstream branch is gone" || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "git branch -D $BRANCH" || { printf '%s\n' "$output"; return 1; }
}

@test "a [gone] tree's next step runs the removal check first and does not force or claim a merge" {
  gone_upstream || return 1
  remind
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "worktree-removal-check.sh --tree $TREE" || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq -- "--force" && { printf 'forced: %s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq "merged branch" && { printf 'claims a merge: %s\n' "$output"; return 1; }
  true
}

@test "red twin: a [gone] tree treated as already checked is handed the forced removal" {
  mutate kept-worktrees.sh -e 's/us "unchecked"/us "checked"/' || return 1
  gone_upstream || return 1
  remind
  printf '%s\n' "$output" | grep -Fq -- "--force" || { printf 'stayed green: %s\n' "$output"; return 1; }
}

@test "red twin: a reminder blind to [gone] does not list it" {
  mutate kept-worktrees.sh -e 's/"\[gone\]"/"[never]"/' || return 1
  gone_upstream || return 1
  remind
  [ -z "$output" ] || { printf 'stayed green: %s\n' "$output"; return 1; }
}

@test "a tree in the ledger whose upstream is also [gone] is listed once, with the ledger's why" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  gone_upstream || return 1
  remind
  [ "$(printf '%s\n' "$output" | grep -c -- "^- $TREE ")" -eq 1 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
}

@test "a live branch is not listed, level or ahead of its upstream" {
  printf 'more\n' >"$TREE/more"
  git -C "$TREE" add more
  git -C "$TREE" commit -q -m more
  remind
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ -z "$output" ] || { printf '%s\n' "$output"; return 1; }
}

@test "red twin: a reminder that reads any tracking state as gone lists a live branch" {
  mutate kept-worktrees.sh -e 's/substr(references\[i\], tab + 1) == "\[gone\]"/1/' || return 1
  remind
  printf '%s\n' "$output" | grep -Fq -- "- $TREE" || { printf 'stayed green: %s\n' "$output"; return 1; }
}

@test "nothing kept prints nothing and exits 0" {
  git -C "$MAIN" worktree remove --force "$TREE" || return 1
  remind
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ -z "$output" ] || { printf '%s\n' "$output"; return 1; }
}

@test "red twin: a reminder without the empty guard prints a header for nothing" {
  mutate kept-worktrees.sh -e 's/^  \[ -n "\$kept" \] || return 0$/  :/' || return 1
  git -C "$MAIN" worktree remove --force "$TREE" || return 1
  remind
  [ -n "$output" ] || { printf 'stayed green\n'; return 1; }
}

@test "a ledger entry for a removed tree is pruned and not listed" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  git -C "$MAIN" worktree remove --force "$TREE" || return 1
  remind
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ -z "$output" ] || { printf '%s\n' "$output"; return 1; }
  grep -Fq "$TREE" "$LEDGER" && { printf 'not pruned:\n'; cat "$LEDGER"; return 1; }
  true
}

@test "a ledger entry for a tree deleted without git is pruned and not listed" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  rm -rf "$TREE"
  remind
  [ -z "$output" ] || { printf '%s\n' "$output"; return 1; }
  grep -Fq "$TREE" "$LEDGER" && { printf 'not pruned:\n'; cat "$LEDGER"; return 1; }
  true
}

@test "red twin: a reminder that trusts the ledger lists a removed tree" {
  mutate kept-worktrees.sh -e 's/^  if (!(tree in listed) || (tree in printed)) {$/  if (tree in printed) {/' || return 1
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  git -C "$MAIN" worktree remove --force "$TREE" || return 1
  remind
  printf '%s\n' "$output" | grep -Fq -- "- $TREE" || { printf 'stayed green: %s\n' "$output"; return 1; }
}

@test "pruning keeps the entries whose tree still exists" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  seed_ledger "$BATS_TEST_TMPDIR/gone-tree" other "uncommitted changes"
  remind
  [ "$(grep -c '' "$LEDGER")" -eq 1 ] || { cat "$LEDGER"; return 1; }
  grep -Fq "$TREE" "$LEDGER" || { cat "$LEDGER"; return 1; }
}

@test "the reminder never removes a tree" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  gone_upstream || return 1
  remind
  [ -d "$TREE" ] || return 1
  git -C "$MAIN" worktree list --porcelain | grep -Fxq "worktree $TREE" || return 1
}

@test "the main checkout itself is never listed, even on a [gone] branch" {
  git -C "$MAIN" worktree remove --force "$TREE" || return 1
  git -C "$MAIN" checkout -q "$BRANCH" || return 1
  gone_upstream || return 1
  remind
  [ -z "$output" ] || { printf '%s\n' "$output"; return 1; }
}

@test "the reminder from inside the linked worktree reads the main checkout's ledger" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  remind "$TREE"
  printf '%s\n' "$output" | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
}

@test "the --main-root form lists the same trees as the resolved form" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  remind
  local resolved_output=$output
  run bash "$KEPT" remind --main-root "$MAIN"
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
  [ "$output" = "$resolved_output" ] || { printf '%s\n---\n%s\n' "$output" "$resolved_output"; return 1; }
}

@test "outside a git repository the reminder is silent and exits 0" {
  mkdir "$BATS_TEST_TMPDIR/plain"
  remind "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || { printf '%s\n' "$output"; return 1; }
}

# --- platforms ---

@test "the reminder runs no jq" {
  local shim="$BATS_TEST_TMPDIR/jq-shim"
  mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nprintf "jq\\n" >> "%s/jq-calls.log"\nexit 127\n' "$BATS_TEST_TMPDIR" >"$shim/jq"
  chmod +x "$shim/jq"
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  PATH="$shim:$PATH" run bash "$KEPT" remind "$MAIN"
  printf '%s\n' "$output" | grep -Fq -- "- $TREE" || { printf '%s\n' "$output"; return 1; }
  [ ! -s "$BATS_TEST_TMPDIR/jq-calls.log" ]
}

@test "under /bin/bash (3.2 on macOS) the reminder lists, prunes and matches bash 5" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  seed_ledger "$BATS_TEST_TMPDIR/gone-tree" other "uncommitted changes"
  run /bin/bash "$KEPT" remind "$MAIN"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
  [ "$(grep -c '' "$LEDGER")" -eq 1 ] || { cat "$LEDGER"; return 1; }
  local old_shell_output=$output
  remind
  [ "$output" = "$old_shell_output" ] || { printf 'bash 5:\n%s\n/bin/bash:\n%s\n' "$output" "$old_shell_output"; return 1; }
}

@test "under /bin/bash the check still records the tree it stops" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  printf 'edited\n' >>"$TREE/base"
  run /bin/bash "$CHECK" --tree "$TREE"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; return 1; }
  grep -Fq "$TREE" "$LEDGER" || return 1
}
