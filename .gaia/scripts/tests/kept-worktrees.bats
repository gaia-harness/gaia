#!/usr/bin/env bats
# Tests for .gaia/scripts/kept-worktrees.sh, the ledger of worktrees a
# post-merge cleanup kept and the session-start reminder that lists them, and
# for the record call worktree-removal-check.sh makes when it stops a removal.
#
# Every case runs against the throwaway repository and staged script copies
# helpers/kept-worktrees-fixture.sh builds; no case touches the real
# repository. Which trees count as orphaned (merged, no live session, not the
# session's own tree) is kept-worktrees-orphan.bats.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  # shellcheck source=.gaia/scripts/tests/helpers/kept-worktrees-fixture.sh
  . "$BATS_TEST_DIRNAME/helpers/kept-worktrees-fixture.sh"
  kept_worktrees_setup
}

# --- the record the check makes ---

@test "a tree the check stops is recorded and listed with its removal commands" {
  printf 'edited\n' >>"$TREE/base"
  run bash "$CHECK" --tree "$TREE"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; return 1; }
  remind
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  plain_output | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
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
  printf 'edited\n' >>"$TREE/base"
  git -C "$TREE" commit -q -am more
  printf 'again\n' >>"$TREE/base"
  run bash "$CHECK" --tree "$TREE"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; return 1; }
  remind
  plain_output | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes, 1 unpushed commit(s)" || { printf '%s\n' "$output"; return 1; }
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
  plain_output | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
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
  plain_output | grep -Fxq -- "- $TREE (branch $BRANCH): merged, and its upstream branch is gone" || { printf '%s\n' "$output"; return 1; }
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
  plain_output | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
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
  mutate kept-worktrees.sh -e 's/fields\[2\] == "\[gone\]"/1/' || return 1
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
  mutate kept-worktrees.sh -e 's/^  \[ -n "\$candidates" \] || return 0$/  :/' -e 's/^  if \[ -n "\$listing" \]; then$/  if true; then/' || return 1
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
  plain_output | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
}

@test "the --main-root form lists the same trees as the resolved form" {
  seed_ledger "$TREE" "$BRANCH" "uncommitted changes"
  remind
  local resolved_output
  resolved_output=$(plain_output)
  run bash "$KEPT" remind --main-root "$MAIN"
  [ "$status" -eq 0 ] || return 1
  plain_output | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
  [ "$(plain_output)" = "$resolved_output" ] || { printf '%s\n---\n%s\n' "$output" "$resolved_output"; return 1; }
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
  plain_output | grep -Fxq -- "- $TREE (branch $BRANCH): uncommitted changes" || { printf '%s\n' "$output"; return 1; }
  [ "$(grep -c '' "$LEDGER")" -eq 1 ] || { cat "$LEDGER"; return 1; }
  local old_shell_output
  old_shell_output=$(plain_output)
  remind
  [ "$(plain_output)" = "$old_shell_output" ] || { printf 'bash 5:\n%s\n/bin/bash:\n%s\n' "$output" "$old_shell_output"; return 1; }
}

@test "under /bin/bash the check still records the tree it stops" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  printf 'edited\n' >>"$TREE/base"
  run /bin/bash "$CHECK" --tree "$TREE"
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; return 1; }
  grep -Fq "$TREE" "$LEDGER" || return 1
}
