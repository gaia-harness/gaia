#!/usr/bin/env bats

# Anchor guard for the rate-limit checkpoint doctrine and the fan-out pointers
# that send a step to it. Each test fails when the doctrine loses the statement
# its behavior names. Run it with
# `.gaia/scripts/bats5.sh .gaia/tests/hooks/rate-limit-checkpoint-doctrine.bats < /dev/null`.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOCTRINE="$REPO_ROOT/.claude/doctrine/rate-limit-checkpoint.md"
  PLANNER="$REPO_ROOT/.claude/skills/gaia/references/plan/planner.md"
  MERGE_PAGE="$REPO_ROOT/wiki/concepts/PR Merge Workflow.md"
}

# every listed fixed string must appear in the file
require_all() {
  local file_path="$1" phrase
  shift
  [ -f "$file_path" ] || return 1
  for phrase in "$@"; do
    grep -qF -- "$phrase" "$file_path" || return 1
  done
  return 0
}

@test "the doctrine asks one question from the option matrix and never offers a smaller model" {
  require_all "$DOCTRINE" \
    'Ask one `AskUserQuestion`' \
    '`Chunk it`' \
    '`Wait until HH:MM`' \
    '`Push through`' \
    '(Recommended)' \
    'Recommend `Chunk it` when it is offered beside `Wait until`' \
    '`Wait until` when it is offered without `Chunk it`' \
    'otherwise `Push through`' \
    'A projection of `unknown` counts as not reaching it' \
    'When only `Push through` qualifies, ask nothing and proceed' \
    'Never offer a smaller model'
}

@test "the doctrine chunks at the warning band and saves and stops at the critical band with no human" {
  require_all "$DOCTRINE" \
    'Never ask.' \
    'At the warning band, chunk the work at the next phase boundary' \
    'At the critical band, save state as `.claude/doctrine/context-checkpoint.md` does' \
    'stop with a continuation prompt naming the reset time' \
    'schedule the wakeup after the reset' \
    'nothing resumes the work after the reset'
}

@test "the doctrine sends a lane's reading to its coordinator and falls back to the no-human policy" {
  require_all "$DOCTRINE" \
    'Send the reading to the coordinator and ask the maintainer nothing' \
    'With no answer from the coordinator, apply the no-human policy'
}

@test "the doctrine names optional heavy work for deferral on the 7-day window and never gates a dispatch on it" {
  require_all "$DOCTRINE" \
    'It never gates a single dispatch' \
    'fitness sweeps, tuning trials, debt batches'
}

@test "each fan-out step runs the reader and points at the doctrine without restating its policy" {
  local planner_bullet merge_section text
  planner_bullet="$(grep -F -- '**Phase order**' "$PLANNER")"
  merge_section="$(awk '$0 == "## Dispatch the audit loop unit" { on = 1; next } on && /^## / { exit } on { print }' "$MERGE_PAGE")"
  [ -n "$planner_bullet" ] || return 1
  [ -n "$merge_section" ] || return 1
  for text in "$planner_bullet" "$merge_section"; do
    printf '%s\n' "$text" | grep -qF -- 'bash .gaia/scripts/rate-limits.sh read' || return 1
    printf '%s\n' "$text" | grep -qF -- '.claude/doctrine/rate-limit-checkpoint.md' || return 1
    printf '%s\n' "$text" | grep -qE 'Chunk it|Push through|Wait until|75%|90%' && return 1
  done
  true
}
