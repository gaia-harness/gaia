#!/usr/bin/env bats
#
# Acceptance suite for how a strict-classified test is judged. Every changed
# test, strict included, is judged on honesty, so none of the evaluator prompt,
# the Worthiness Audit page or the Presence Gate page says a strict test is
# judged on worth only. The evaluator and the audit page state the
# classifier's remaining role, and the evaluator keeps the five worth criteria.
# The evaluator does not keep the review off the deterministic surface, and
# the Presence Gate page no longer claims a test is never gated by both.
#
# Both files are hard-wrapped, so every check matches on whitespace-normalized
# text. Each red twin removes (or restores) one needle in a scratch copy and
# asserts the check fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  EVALUATOR="$REPO_ROOT/.claude/agents/worthiness-evaluator.md"
  AUDIT="$REPO_ROOT/wiki/decisions/Worthiness Audit.md"
  GATE="$REPO_ROOT/wiki/decisions/Worthiness Presence Gate.md"
  ABSENT_NEEDLES=(
    'judged on worth only'
    'worth only'
    'never gets an honesty-axis verdict'
  )
  SHARED_NEEDLES=(
    'every changed test, strict included, is judged on honesty'
    'not whether honesty is judged'
  )
  CRITERIA_NEEDLES=(
    'trivial'
    'covered by an integration test'
    'proves what the type checker or lint already proves'
    'a table that should be one test'
    'a unit test whose logic is neither important nor likely to fail'
  )
  OLD_EVALUATOR_LINE='Do NOT review the deterministic surface'
  OLD_GATE_LINE='so a test is never gated by both'
}

normalized() {
  tr '\n' ' ' < "$1" | tr -s ' '
}

# Succeeds only when the file text carries the needle.
has_needle() {
  local file="$1" needle="$2"
  normalized "$file" | grep -qF -- "$needle"
}

# Fails with the first missing needle of the list.
all_needles_present() {
  local file="$1"
  shift
  local needle
  for needle in "$@"; do
    has_needle "$file" "$needle" || {
      printf 'missing needle: %s\n' "$needle" >&2
      return 1
    }
  done
}

# Succeeds only when the file text does not carry the old line.
old_line_absent() {
  local file="$1" old_line="$2"
  ! has_needle "$file" "$old_line"
}

# Fails when the file text carries the needle: a positive match plus return 1.
needle_absent() {
  local file="$1" needle="$2"
  has_needle "$file" "$needle" && return 1
  return 0
}

# Fails with the first needle of the list the file text still carries.
all_needles_absent() {
  local file="$1"
  shift
  local needle
  for needle in "$@"; do
    needle_absent "$file" "$needle" || {
      printf 'still carries: %s (%s)\n' "$needle" "$file" >&2
      return 1
    }
  done
  return 0
}

# Writes the normalized file text with every occurrence of the needle replaced
# by a marker, to a scratch path.
scratch_without() {
  local file="$1" needle="$2" scratch="$3"
  normalized "$file" | NEEDLE="$needle" awk '{
    out = ""
    rest = $0
    while ((i = index(rest, ENVIRON["NEEDLE"])) > 0) {
      out = out substr(rest, 1, i - 1) "REMOVED"
      rest = substr(rest, i + length(ENVIRON["NEEDLE"]))
    }
    print out rest
  }' > "$scratch"
}

@test "the evaluator and the Worthiness Audit page both say every changed test, strict included, is judged on honesty" {
  all_needles_present "$EVALUATOR" "${SHARED_NEEDLES[@]}"
  all_needles_present "$AUDIT" "${SHARED_NEEDLES[@]}"
}

@test "no page says a strict test is judged on worth only or never gets an honesty-axis verdict" {
  all_needles_absent "$EVALUATOR" "${ABSENT_NEEDLES[@]}"
  all_needles_absent "$AUDIT" "${ABSENT_NEEDLES[@]}"
  all_needles_absent "$GATE" "${ABSENT_NEEDLES[@]}"
}

@test "the evaluator names the five worth criteria for a strict test" {
  all_needles_present "$EVALUATOR" "${CRITERIA_NEEDLES[@]}"
}

@test "the evaluator tells a strict file by running the classifier" {
  has_needle "$EVALUATOR" 'node .gaia/scripts/classifier/classify-determinism.mjs'
}

@test "the evaluator no longer keeps the review off the deterministic surface" {
  old_line_absent "$EVALUATOR" "$OLD_EVALUATOR_LINE"
}

@test "the Presence Gate page no longer claims a test is never gated by both" {
  old_line_absent "$GATE" "$OLD_GATE_LINE"
}

@test "red twin: restoring any worth-only needle into each page fails the absence check" {
  local file needle scratch
  scratch="$BATS_TEST_TMPDIR/scratch.md"
  for file in "$EVALUATOR" "$AUDIT" "$GATE"; do
    for needle in "${ABSENT_NEEDLES[@]}"; do
      { cat "$file"; printf '\n%s\n' "$needle"; } > "$scratch"
      if all_needles_absent "$scratch" "${ABSENT_NEEDLES[@]}" 2>/dev/null; then
        printf 'check stayed green with: %s (%s)\n' "$needle" "$file" >&2
        return 1
      fi
    done
  done
}

@test "red twin: removing any honesty needle from either file fails the presence check" {
  local file needle scratch
  scratch="$BATS_TEST_TMPDIR/scratch.md"
  for file in "$EVALUATOR" "$AUDIT"; do
    for needle in "${SHARED_NEEDLES[@]}"; do
      scratch_without "$file" "$needle" "$scratch"
      if all_needles_present "$scratch" "${SHARED_NEEDLES[@]}" 2>/dev/null; then
        printf 'check stayed green without: %s (%s)\n' "$needle" "$file" >&2
        return 1
      fi
    done
  done
}

@test "red twin: removing any criterion needle from the evaluator fails the presence check" {
  local needle scratch
  scratch="$BATS_TEST_TMPDIR/scratch.md"
  for needle in "${CRITERIA_NEEDLES[@]}"; do
    scratch_without "$EVALUATOR" "$needle" "$scratch"
    if all_needles_present "$scratch" "${CRITERIA_NEEDLES[@]}" 2>/dev/null; then
      printf 'check stayed green without: %s\n' "$needle" >&2
      return 1
    fi
  done
}

@test "red twin: restoring the old scope line into the evaluator fails the absence check" {
  local scratch="$BATS_TEST_TMPDIR/evaluator.md"
  { cat "$EVALUATOR"; printf '\n%s\n' "$OLD_EVALUATOR_LINE"; } > "$scratch"
  run old_line_absent "$scratch" "$OLD_EVALUATOR_LINE"
  [ "$status" -ne 0 ]
}

@test "red twin: restoring the never-gated-by-both line into the Presence Gate page fails the absence check" {
  local scratch="$BATS_TEST_TMPDIR/gate.md"
  { cat "$GATE"; printf '\n%s\n' "$OLD_GATE_LINE"; } > "$scratch"
  run old_line_absent "$scratch" "$OLD_GATE_LINE"
  [ "$status" -ne 0 ]
}
