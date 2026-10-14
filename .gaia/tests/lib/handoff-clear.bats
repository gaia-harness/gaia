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

@test "with a yield number only that unit's file for that number is removed" {
  seed planner-yield-1.md planner-yield-2.md planner-yield-12.md phase-1-task-a-yield-1.md
  run bash "$SCRIPT" "$PLAN" planner 1
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/planner-yield-1.md" ]
  [ -f "$HANDOFFS/planner-yield-2.md" ]
  [ -f "$HANDOFFS/planner-yield-12.md" ]
  [ -f "$HANDOFFS/phase-1-task-a-yield-1.md" ]
}

@test "without a yield number every file of that unit is removed and other units are left" {
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
}

@test "a unit whose name extends another unit's name keeps its own files when the shorter unit is cleared" {
  seed phase-1-task-a-yield-1.md phase-1-task-a-yield-2-yield-1.md
  run bash "$SCRIPT" "$PLAN" phase-1-task-a
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/phase-1-task-a-yield-1.md" ]
  [ -f "$HANDOFFS/phase-1-task-a-yield-2-yield-1.md" ]
}

@test "a missing target is not an error, with or without a yield number" {
  seed planner-yield-1.md
  run bash "$SCRIPT" "$PLAN" phase-3-task-none 4
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" "$PLAN" phase-3-task-none
  [ "$status" -eq 0 ]
  [ -f "$HANDOFFS/planner-yield-1.md" ]
}

@test "the planner unit and a phase task unit both work" {
  seed planner-yield-3.md phase-12-task-a1-b2-yield-3.md
  run bash "$SCRIPT" "$PLAN" planner 3
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/planner-yield-3.md" ]
  run bash "$SCRIPT" "$PLAN" phase-12-task-a1-b2 3
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/phase-12-task-a1-b2-yield-3.md" ]
}

@test "a trailing slash on the plan folder is accepted" {
  seed planner-yield-1.md
  run bash "$SCRIPT" "$PLAN/" planner 1
  [ "$status" -eq 0 ]
  [ ! -e "$HANDOFFS/planner-yield-1.md" ]
}

@test "a symlinked handoffs folder is refused and the file behind it survives" {
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
}

@test "a handoffs path that is a regular file is refused" {
  printf 'not a folder\n' >"$HANDOFFS"
  run bash "$SCRIPT" "$PLAN" planner 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'not a directory'
  [ -f "$HANDOFFS" ]
}

@test "a symlinked plan folder is refused and nothing behind it is touched" {
  mkdir -p "$BATS_TEST_TMPDIR/real/handoffs"
  printf 'keep\n' >"$BATS_TEST_TMPDIR/real/handoffs/planner-yield-1.md"
  ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/linked"
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/linked" planner 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'symlink'
  [ -f "$BATS_TEST_TMPDIR/real/handoffs/planner-yield-1.md" ]
}

@test "a matching name that is a directory is not removed" {
  mkdir -p "$HANDOFFS/planner-yield-1.md"
  printf 'inside\n' >"$HANDOFFS/planner-yield-1.md/file"
  run bash "$SCRIPT" "$PLAN" planner 1
  [ "$status" -eq 0 ]
  [ -f "$HANDOFFS/planner-yield-1.md/file" ]
  run bash "$SCRIPT" "$PLAN" planner
  [ "$status" -eq 0 ]
  [ -f "$HANDOFFS/planner-yield-1.md/file" ]
}

@test "a matching name that is a symlink is not followed or removed" {
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

@test "red twin: a copy without the symlink check removes the file behind the symlink" {
  local copy="$BATS_TEST_TMPDIR/handoff-clear-unguarded.sh"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  printf 'keep\n' >"$BATS_TEST_TMPDIR/elsewhere/planner-yield-1.md"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HANDOFFS"
  sed -e 's/^if \[ -L "\$handoffs" \]; then$/if false; then/' -e 's/^\[ "\$resolved_handoffs" = .*$/:/' "$SCRIPT" >"$copy"
  grep -qF 'if false; then' "$copy"
  cmp -s "$SCRIPT" "$copy" && return 1
  run bash "$SCRIPT" "$PLAN" planner 1
  [ "$status" -eq 1 ]
  [ -f "$BATS_TEST_TMPDIR/elsewhere/planner-yield-1.md" ]
  run bash "$copy" "$PLAN" planner 1
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere/planner-yield-1.md" ]
}
