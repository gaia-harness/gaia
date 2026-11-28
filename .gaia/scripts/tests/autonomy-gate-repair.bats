#!/usr/bin/env bats
#
# Suite for .gaia/scripts/autonomy-gate-repair.sh: an unattended phase gate
# repair starts only under a live switch and once per phase, and its delta is
# refused when it touches a path the phase's task docs do not name, deletes a
# path, or edits a protected or enforcement path.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/autonomy-gate-repair.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # GATE_REPAIR_SCRIPT lets a mutation proof point the suite at a scratch copy.
  SCRIPT="${GATE_REPAIR_SCRIPT:-$REPO_ROOT/.gaia/scripts/autonomy-gate-repair.sh}"
  FIX=$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/fix.XXXXXX")" && pwd -P)
  MAIN="$FIX/main"
  PLAN="$FIX/plan"
  mkdir -p "$MAIN/app" "$MAIN/.claude/hooks" "$MAIN/.gaia/local/protected" "$MAIN/apps/web" "$PLAN"
  # The protected set reads the package registry, whose built-in entry needs this descriptor.
  cp "$REPO_ROOT/apps/web/gaia.package.json" "$MAIN/apps/web/"
  printf 'one\n' >"$MAIN/app/db.ts"
  printf 'two\n' >"$MAIN/app/other.ts"
  printf 'hook\n' >"$MAIN/.claude/hooks/autonomy-gate.sh"
  printf '.gaia/local/\n' >"$MAIN/.gitignore"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" add -A
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q -m init
  # shellcheck disable=SC2016 # the backticks are the task doc's own markup
  printf 'Files to touch: `app/db.ts`, app/new.ts, .claude/hooks/autonomy-gate.sh.\n' >"$PLAN/task-db.md"
  # The phase's own edit, already in the tree before the gate fails.
  printf 'one, edited\n' >"$MAIN/app/db.ts"
  BASE="$FIX/baseline.txt"
}

live_switch() {
  jq -n '{enabled: true, expires_at: (now + 3600 | todate), may_merge: false, audit_extra_units_per_pr: 0, audit_units_pool: 0}' \
    >"$MAIN/.gaia/local/protected/autonomy.json"
}

take_baseline() {
  run bash "$SCRIPT" baseline --root "$MAIN" --plan-dir "$PLAN" --phase 2 --out "$BASE"
}

check_repair() {
  run bash "$SCRIPT" check --root "$MAIN" --baseline "$BASE" --task "$PLAN/task-db.md"
}

@test "an unattended first repair on declared paths passes and names what it changed" {
  live_switch
  take_baseline
  [ "$status" -eq 0 ] || return 1
  printf 'one, repaired\n' >"$MAIN/app/db.ts"
  printf 'new\n' >"$MAIN/app/new.ts"
  check_repair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$(printf 'changed app/db.ts\nchanged app/new.ts')" ]
}

# bats test_tags=protected
@test "an attended run gets no repair: the baseline refuses and writes nothing" {
  take_baseline
  [ "$status" -eq 1 ] || return 1
  [[ $output == attended* ]] || return 1
  [ ! -e "$BASE" ]
}

# bats test_tags=protected
@test "a phase that already recorded a repair gets no second one" {
  live_switch
  printf '## Phase 2, Two (GATE REPAIR)\nRepair: 1\n' >"$PLAN/PROGRESS.md"
  take_baseline
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "already-repaired phase 2" ] || return 1
  [ ! -e "$BASE" ] || return 1
  # Another phase's repair does not spend this phase's.
  printf '## Phase 1, One (GATE REPAIR)\nRepair: 1\n' >"$PLAN/PROGRESS.md"
  take_baseline
  [ "$status" -eq 0 ]
}

# bats test_tags=protected
@test "a repair touching a path no task doc names is refused" {
  live_switch
  take_baseline
  [ "$status" -eq 0 ] || return 1
  printf 'two, repaired\n' >"$MAIN/app/other.ts"
  check_repair
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "undeclared app/other.ts" ]
}

@test "a path that only a longer declared word contains is undeclared" {
  live_switch
  printf 'Files to touch: app/db.tsx\n' >"$PLAN/task-db.md"
  take_baseline
  printf 'one, repaired\n' >"$MAIN/app/db.ts"
  check_repair
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "undeclared app/db.ts" ]
}

# bats test_tags=protected
@test "a repair editing a protected and enforcement path is refused even when declared" {
  live_switch
  take_baseline
  printf 'weakened\n' >"$MAIN/.claude/hooks/autonomy-gate.sh"
  check_repair
  [ "$status" -eq 1 ] || return 1
  [[ $output == *"protected .claude/hooks/autonomy-gate.sh"* ]] || return 1
  [[ $output == *"enforcement .claude/hooks/autonomy-gate.sh"* ]]
}

@test "a repair deleting a declared path is refused" {
  live_switch
  take_baseline
  rm "$MAIN/app/db.ts"
  check_repair
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "deleted app/db.ts" ]
}

@test "a repair that changed nothing or moved HEAD is refused" {
  live_switch
  take_baseline
  check_repair
  [ "$status" -eq 1 ] || return 1
  [[ $output == no-change* ]] || return 1
  printf 'one, repaired\n' >"$MAIN/app/db.ts"
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m moved
  check_repair
  [ "$status" -eq 1 ] || return 1
  [[ $output == head-moved* ]]
}

@test "the orchestrator template baselines, repairs, checks, records and reruns the whole gate, under the switch only" {
  local template="$REPO_ROOT/.claude/skills/gaia/references/plan/orchestrator-template.md" section rest anchor
  section=$(awk '/^## Unattended gate repair$/ { inside = 1 } /^## Stop conditions$/ { inside = 0 } inside' "$template")
  [ -n "$section" ] || { echo 'section missing' >&2; return 1; }
  rest="$section"
  for anchor in \
    'Only while the autonomy switch is live' \
    'autonomy-gate-repair.sh baseline --root <RESOLVED_ROOT> --plan-dir {PLAN_DIR} --phase <N>' \
    'Never delete, skip or weaken a test, an assertion or a gate check' \
    'autonomy-gate-repair.sh check --root <RESOLVED_ROOT> --baseline <scratch file>' \
    '## Phase N, <title> (GATE REPAIR)' \
    'run the whole phase gate again from its first step' \
    'a failure halts under Stop conditions'; do
    case "$rest" in
      *"$anchor"*) rest="${rest#*"$anchor"}" ;;
      *) echo "anchor missing or out of order: $anchor" >&2; return 1 ;;
    esac
  done
}

@test "a gate repair block with no later commit resumes at its phase" {
  local sha
  sha=$(git -C "$MAIN" rev-parse --short HEAD)
  printf '## Phase 1, One\nCommit: %s\n\n_No notes._\n\n## Phase 2, Two (GATE REPAIR)\nRepair: 1\nGate: failed\n' "$sha" >"$PLAN/PROGRESS.md"
  run bash "$REPO_ROOT/.gaia/scripts/plan-resume-point.sh" --plan-dir "$PLAN" --phases 3 --git-dir "$MAIN"
  [ "${lines[0]}" = 2 ]
}
