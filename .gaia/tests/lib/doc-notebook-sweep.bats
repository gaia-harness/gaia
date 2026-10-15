#!/usr/bin/env bats
#
# Prose half of the notebook's reaping and save contracts: the executed prose
# calls the scripts that do the work. The scripts' own behavior is proven in
# their suites; this suite proves the skill text still hands the work to them.
#
#   - lifecycle.md's `## Pre-flight sweep` runs the merged-spec, merged-plan
#     and abandoned-spec reapers, and spec.md step 2 no longer runs the
#     abandoned reaper itself (the sweep owns it).
#   - spec.md step 9 saves the SPEC through the notebook library's path verb,
#     under the notebook's specs folder.
#
# Each check is a function of the file it reads, and each has a red twin that
# runs it on a temp copy with the call removed (.claude/rules/guards-must-fail.md).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIFECYCLE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/lifecycle.md"
  SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"
}

# The `## Pre-flight sweep` section of a lifecycle.md, to the end of the file.
sweep_section() {
  local start_line
  start_line="$(grep -n -F -- '## Pre-flight sweep' "$1" | head -1 | cut -d: -f1)"
  [ -n "$start_line" ] || { printf 'no "## Pre-flight sweep" section in %s\n' "$1" >&2; return 1; }
  sed -n "${start_line},\$p" "$1"
}

# Text of <file> from the first line containing <start> up to the first line
# containing <end>.
range_between() {
  local file="$1" start_pattern="$2" end_pattern="$3" start_line end_line
  start_line="$(grep -n -F -- "$start_pattern" "$file" | head -1 | cut -d: -f1)"
  end_line="$(grep -n -F -- "$end_pattern" "$file" | head -1 | cut -d: -f1)"
  [ -n "$start_line" ] || { printf 'start anchor not found in %s: %s\n' "$file" "$start_pattern" >&2; return 1; }
  [ -n "$end_line" ] || { printf 'end anchor not found in %s: %s\n' "$file" "$end_pattern" >&2; return 1; }
  sed -n "${start_line},$((end_line - 1))p" "$file"
}

SWEEP_REAPERS=(spec-archive-merged.sh plan-archive-merged.sh spec-archive-abandoned.sh)

check_sweep_runs_reapers() {
  local section reaper
  section="$(sweep_section "$1")" || return 1
  [ -n "$section" ] || { printf 'the pre-flight sweep section is empty\n' >&2; return 1; }
  for reaper in "${SWEEP_REAPERS[@]}"; do
    if ! printf '%s\n' "$section" | grep -qE "^bash \.gaia/scripts/spec/${reaper//./\\.} \"\\\$PWD\""; then
      printf 'the pre-flight sweep does not run %s\n' "$reaper" >&2
      return 1
    fi
  done
  true
}

@test "the pre-flight sweep runs the merged-spec, merged-plan and abandoned-spec reapers" {
  check_sweep_runs_reapers "$LIFECYCLE_MD"
}

@test "red twin: a sweep without one of its reaper calls fails the reaper check" {
  local reaper mutated
  for reaper in "${SWEEP_REAPERS[@]}"; do
    mutated="$BATS_TEST_TMPDIR/lifecycle-without-${reaper}.md"
    grep -v -F "bash .gaia/scripts/spec/${reaper} " "$LIFECYCLE_MD" > "$mutated" || true
    if cmp -s "$LIFECYCLE_MD" "$mutated"; then
      printf 'the %s call was not removed\n' "$reaper" >&2
      return 1
    fi
    check_sweep_runs_reapers "$mutated" 2>/dev/null && return 1
  done
  true
}

check_step_two_leaves_abandoned_reap_to_the_sweep() {
  local step_two
  step_two="$(range_between "$1" '### 2. Resume-vs-start-new prompt' '### 3. Initial draft')" || return 1
  [ -n "$step_two" ] || { printf 'spec.md step 2 is empty\n' >&2; return 1; }
  if printf '%s\n' "$step_two" | grep -qF 'spec-archive-abandoned.sh'; then
    printf 'spec.md step 2 still runs the abandoned reaper the sweep owns\n' >&2
    return 1
  fi
  true
}

@test "spec.md step 2 leaves the abandoned reap to the pre-flight sweep" {
  check_step_two_leaves_abandoned_reap_to_the_sweep "$SPEC_MD"
}

@test "red twin: an abandoned reap call back in spec.md step 2 fails the check" {
  local mutated="$BATS_TEST_TMPDIR/spec-abandoned-reap.md"
  awk '
    { print }
    !done && index($0, "bash .gaia/scripts/spec/spec-abandon-empty.sh") { print "bash .gaia/scripts/spec/spec-archive-abandoned.sh \"$PWD\" 2>/dev/null || true"; done = 1 }
  ' "$SPEC_MD" > "$mutated"
  if cmp -s "$SPEC_MD" "$mutated"; then
    printf 'the planted call was not applied\n' >&2
    return 1
  fi
  check_step_two_leaves_abandoned_reap_to_the_sweep "$mutated" 2>/dev/null && return 1
  true
}

check_save_step_uses_the_library() {
  local file="$1" step_nine
  step_nine="$(range_between "$file" '### 9. Save to' '### 10. Immutability lint')" || return 1
  [ -n "$step_nine" ] || { printf 'spec.md step 9 is empty\n' >&2; return 1; }
  if ! grep -qF -- '### 9. Save to .notebook/specs/SPEC-NNN/SPEC.md' "$file"; then
    printf 'spec.md step 9 does not save under .notebook/specs/\n' >&2
    return 1
  fi
  if ! printf '%s\n' "$step_nine" | grep -qF 'notebook-lib.sh path spec "$SPEC_ID"'; then
    printf 'spec.md step 9 does not resolve the SPEC folder through the notebook library\n' >&2
    return 1
  fi
  true
}

@test "spec.md step 9 saves the SPEC through the notebook library under .notebook/specs/" {
  check_save_step_uses_the_library "$SPEC_MD"
}

@test "red twin: a step 9 that builds its own folder path fails the save check" {
  local mutated="$BATS_TEST_TMPDIR/spec-save-relative.md"
  # Replace the library call only inside step 9; step 3 carries the same line.
  awk '
    index($0, "### 9. Save to") { in_step_nine = 1 }
    in_step_nine && index($0, "notebook-lib.sh path spec \"$SPEC_ID\"") && !done {
      print "SPEC_FOLDER=\".notebook/specs/${SPEC_ID}\""
      done = 1
      next
    }
    { print }
  ' "$SPEC_MD" > "$mutated"
  if cmp -s "$SPEC_MD" "$mutated"; then
    printf 'the step-9 library call was not replaced\n' >&2
    return 1
  fi
  check_save_step_uses_the_library "$mutated" 2>/dev/null && return 1
  true
}
