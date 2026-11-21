#!/usr/bin/env bats
#
# .gaia/scripts/spec/handoff-clear.sh behavior: it creates a plan's handoffs
# folder, removes only the named unit's regular handoff files, refuses a
# handoffs folder or plan folder that is not a real directory, and rejects
# malformed arguments. Shell level only.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT_REAL/.gaia/scripts/spec/handoff-clear.sh"
  PLAN="$BATS_TEST_TMPDIR/plan"
  HANDOFFS="$PLAN/handoffs"
  mkdir -p "$PLAN"
}

# seed <name>...: empty files in the handoffs folder (created when absent).
seed() {
  local name
  mkdir -p "$HANDOFFS"
  for name in "$@"; do
    printf 'notes\n' >"$HANDOFFS/$name"
  done
}

@test "the handoffs folder is created when absent and the run prints nothing" {
  run bash "$SCRIPT" "$PLAN" planner
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -d "$HANDOFFS" ]
  [ ! -L "$HANDOFFS" ]
}

# fresh_handoffs: an empty plan folder with no handoffs folder.
fresh_handoffs() {
  rm -rf "$PLAN"
  mkdir -p "$PLAN"
}

@test "handoff-clear removes only the named unit's regular files, one yield or every yield, and tolerates a missing target and a trailing slash" {
  # one yield number: only that unit's file for that number
  seed planner-yield-1.md planner-yield-2.md planner-yield-12.md phase-1-task-a-yield-1.md
  run bash "$SCRIPT" "$PLAN" planner 1
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/planner-yield-1.md" ]
  [ -f "$HANDOFFS/planner-yield-2.md" ]
  [ -f "$HANDOFFS/planner-yield-12.md" ]
  [ -f "$HANDOFFS/phase-1-task-a-yield-1.md" ]

  # no yield number: every file of the unit, other units and extended names left
  fresh_handoffs
  seed phase-2-task-build-yield-1.md phase-2-task-build-yield-2.md phase-2-task-build-yield-10.md \
    phase-2-task-other-yield-1.md planner-yield-1.md phase-2-task-build-yield-2.md.keep
  run bash "$SCRIPT" "$PLAN" phase-2-task-build
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/phase-2-task-build-yield-1.md" ]
  [ ! -e "$HANDOFFS/phase-2-task-build-yield-2.md" ]
  [ ! -e "$HANDOFFS/phase-2-task-build-yield-10.md" ]
  [ -f "$HANDOFFS/phase-2-task-other-yield-1.md" ]
  [ -f "$HANDOFFS/planner-yield-1.md" ]
  [ -f "$HANDOFFS/phase-2-task-build-yield-2.md.keep" ]

  # a unit whose name extends the cleared unit's name keeps its files
  fresh_handoffs
  seed phase-1-task-a-yield-1.md phase-1-task-a-yield-2-yield-1.md
  run bash "$SCRIPT" "$PLAN" phase-1-task-a
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/phase-1-task-a-yield-1.md" ]
  [ -f "$HANDOFFS/phase-1-task-a-yield-2-yield-1.md" ]

  # a missing target is not an error, with or without a yield number
  fresh_handoffs
  seed planner-yield-1.md
  run bash "$SCRIPT" "$PLAN" phase-3-task-none 4
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" "$PLAN" phase-3-task-none
  [ "$status" -eq 0 ]
  [ -f "$HANDOFFS/planner-yield-1.md" ]

  # the planner unit and a multi-part phase task unit both work
  fresh_handoffs
  seed planner-yield-3.md phase-12-task-a1-b2-yield-3.md
  run bash "$SCRIPT" "$PLAN" planner 3
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/planner-yield-3.md" ]
  run bash "$SCRIPT" "$PLAN" phase-12-task-a1-b2 3
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/phase-12-task-a1-b2-yield-3.md" ]

  # a trailing slash on the plan folder is accepted
  fresh_handoffs
  seed planner-yield-1.md
  run bash "$SCRIPT" "$PLAN/" planner 1
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/planner-yield-1.md" ]
}

# bats test_tags=protected
@test "handoff-clear never removes through a symlinked handoffs or plan folder, refuses a regular-file handoffs path, and skips a matching directory or symlink" {
  # symlinked handoffs folder: refused, with and without a yield number
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  printf 'keep\n' >"$BATS_TEST_TMPDIR/elsewhere/planner-yield-1.md"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HANDOFFS"
  run bash "$SCRIPT" "$PLAN" planner 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'symlink'
  [ -f "$BATS_TEST_TMPDIR/elsewhere/planner-yield-1.md" ]
  run bash "$SCRIPT" "$PLAN" planner
  [ "$status" -eq 1 ]
  [ -f "$BATS_TEST_TMPDIR/elsewhere/planner-yield-1.md" ]

  # handoffs path that is a regular file
  fresh_handoffs
  printf 'not a folder\n' >"$HANDOFFS"
  run bash "$SCRIPT" "$PLAN" planner 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'not a directory'
  [ -f "$HANDOFFS" ]

  # symlinked plan folder
  mkdir -p "$BATS_TEST_TMPDIR/real/handoffs"
  printf 'keep\n' >"$BATS_TEST_TMPDIR/real/handoffs/planner-yield-1.md"
  ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/linked"
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/linked" planner 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'symlink'
  [ -f "$BATS_TEST_TMPDIR/real/handoffs/planner-yield-1.md" ]

  # matching name that is a directory
  fresh_handoffs
  mkdir -p "$HANDOFFS/planner-yield-1.md"
  printf 'inside\n' >"$HANDOFFS/planner-yield-1.md/file"
  run bash "$SCRIPT" "$PLAN" planner 1
  [ "$status" -eq 0 ]
  [ -f "$HANDOFFS/planner-yield-1.md/file" ]
  run bash "$SCRIPT" "$PLAN" planner
  [ "$status" -eq 0 ]
  [ -f "$HANDOFFS/planner-yield-1.md/file" ]

  # matching name that is a symlink: not followed, not removed
  fresh_handoffs
  printf 'keep\n' >"$BATS_TEST_TMPDIR/target.md"
  mkdir -p "$HANDOFFS"
  ln -s "$BATS_TEST_TMPDIR/target.md" "$HANDOFFS/planner-yield-1.md"
  run bash "$SCRIPT" "$PLAN" planner 1
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/target.md" ]
  [ -L "$HANDOFFS/planner-yield-1.md" ]
}

@test "usage errors exit 2 and remove nothing" {
  local bad
  seed planner-yield-1.md
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$PLAN"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$PLAN" planner 1 extra
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "plan" planner 1
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/no-such-plan" planner 1
  [ "$status" -eq 2 ]
  for bad in 'phase/1-task-a' '../planner' 'phase-1-task-..' 'phase-1-task-A' 'Planner' 'phase-1-task-a_b' 'phase-x-task-a' 'phase-1-task-' 'phase-1-task--a' ''; do
    run bash "$SCRIPT" "$PLAN" "$bad" 1
    [ "$status" -eq 2 ] || { echo "unit '$bad' exited $status" >&2; return 1; }
  done
  for bad in 0 -1 x 1.5 01 ''; do
    run bash "$SCRIPT" "$PLAN" planner "$bad"
    [ "$status" -eq 2 ] || { echo "yield number '$bad' exited $status" >&2; return 1; }
  done
  [ -f "$HANDOFFS/planner-yield-1.md" ]
}
