#!/usr/bin/env bats

# Static guard for the sub-agent context yield doctrine: the file the sub-agent
# checkpoint hook injects verbatim. Run it with
# `.gaia/scripts/bats5.sh .gaia/tests/hooks/context-yield-doctrine.bats < /dev/null`.
#
# Each guard is a helper that takes the file to check, so the same helper runs
# once on the real tree (must pass) and once on a mutated scratch copy (must
# fail). Helpers return explicitly (never lean on `set -e`, which is suppressed
# inside `if`/`||`); tests call them in `if` form so a red twin that stops
# failing fails the test.

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOCTRINE_RELATIVE_PATH='.claude/doctrine/context-yield.md'
  DOCTRINE="$REPO_ROOT/$DOCTRINE_RELATIVE_PATH"
  TEMPORARY_DIRECTORY="$BATS_TEST_TMPDIR"
}

# ---------------------------------------------------------------- helpers

# Sentence-level fixed strings the doctrine must state. Each literal sits on one line of the doctrine so a line-deletion twin can
# remove exactly it.
ANCHORS=(
  'Only a hook-delivered sub-agent context checkpoint instruction starts a yield; never yield on your own estimate of your context.'
  'no tool call, background task or nested sub-agent in flight, and no file half-edited'
  '- Red: yield at the next stopping point.'
  '- Fire: yield before starting any new unit of work.'
  '- Skull: write the handoff and reply now.'
  'Write the handoff before replying, at the absolute path the header names.'
  'Use Bash with a heredoc, then read it back'
  'can refuse a path outside your worktree'
  'The handoff opens with the goal, then `Facts`'
  '`Status checklist` of done and remaining items'
  'one `NEXT:` line. At most 4 KB.'
  'the band that fired, the in-flight state'
  'and the files touched so far'
  'A planner also names its scratch path and the plan files it already wrote.'
  'never commit, stash or discard at a yield'
  'The dispatcher owns commits.'
  'Reply with a first line of exactly `YIELDED <band>: <handoff path>`'
  'Dispatch nothing after writing the handoff.'
  'A nested sub-agent you dispatch never gets a `Yield handoff:` line.'
)

BAND_LINES=(
  '- Red: yield at the next stopping point.'
  '- Fire: yield before starting any new unit of work.'
  '- Skull: write the handoff and reply now.'
)

# number of lines of the file that equal the text exactly
count_exact_lines() {
  grep -cxF -- "$2" "$1" || true
}

# number of lines of the file that contain the text
count_containing_lines() {
  grep -cF -- "$2" "$1" || true
}

# 1-based number of the first line containing the text, empty when absent
first_line_of() {
  grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

# every anchor is present
anchors_present_ok() {
  local file_path="$1" anchor
  [ -f "$file_path" ] || return 1
  [ "${#ANCHORS[@]}" -gt 0 ] || return 1
  for anchor in "${ANCHORS[@]}"; do
    [ -n "$(first_line_of "$file_path" "$anchor")" ] || return 1
  done
  return 0
}

# the file with every line containing the text removed
without_lines_containing() {
  grep -vF -- "$2" "$1" || true
  return 0
}

# each band line appears exactly once, verbatim
band_lines_ok() {
  local file_path="$1" band_line
  [ -f "$file_path" ] || return 1
  [ "${#BAND_LINES[@]}" -eq 3 ] || return 1
  for band_line in "${BAND_LINES[@]}"; do
    [ "$(count_exact_lines "$file_path" "$band_line")" -eq 1 ] || return 1
  done
  return 0
}

# the handoff is written before the reply form is stated
write_before_reply_ok() {
  local file_path="$1" write_line reply_line
  [ -f "$file_path" ] || return 1
  write_line="$(first_line_of "$file_path" 'Write the handoff before replying')"
  reply_line="$(first_line_of "$file_path" 'YIELDED <band>: <handoff path>')"
  [ -n "$write_line" ] || return 1
  [ -n "$reply_line" ] || return 1
  [ "$write_line" -lt "$reply_line" ] || return 1
  return 0
}

# the file stays within the byte budget
budget_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  [ "$(wc -c <"$file_path" | tr -d ' ')" -le 3584 ] || return 1
  return 0
}

# ------------------------------------------------------------- the doctrine

@test "doctrine red twin: an absent file fails every guard" {
  local missing="$TEMPORARY_DIRECTORY/absent/context-yield.md"
  [ ! -e "$missing" ]
  if anchors_present_ok "$missing"; then return 1; fi
  if band_lines_ok "$missing"; then return 1; fi
  if write_before_reply_ok "$missing"; then return 1; fi
  if budget_ok "$missing"; then return 1; fi
  true
}

@test "doctrine anchors: every required sentence is present" {
  anchors_present_ok "$DOCTRINE"
}

@test "doctrine anchors red twins: deleting any anchor's line fails the check" {
  local anchor index=0 visited=0 mutated
  for anchor in "${ANCHORS[@]}"; do
    index=$((index + 1))
    mutated="$TEMPORARY_DIRECTORY/without-anchor-$index.md"
    without_lines_containing "$DOCTRINE" "$anchor" >"$mutated"
    if cmp -s "$DOCTRINE" "$mutated"; then return 1; fi
    if anchors_present_ok "$mutated"; then return 1; fi
    visited=$((visited + 1))
  done
  [ "$visited" -eq "${#ANCHORS[@]}" ]
}

@test "doctrine bands: each band line appears exactly once, verbatim" {
  band_lines_ok "$DOCTRINE"
}

@test "doctrine bands red twins: swapped red and skull actions, a missing line, a duplicated line fail" {
  local swapped="$TEMPORARY_DIRECTORY/bands-swapped.md" removed="$TEMPORARY_DIRECTORY/bands-removed.md" duplicated="$TEMPORARY_DIRECTORY/bands-duplicated.md"
  sed -e 's|^- Red: yield at the next stopping point\.$|- Red: write the handoff and reply now.|' \
    -e 's|^- Skull: write the handoff and reply now\.$|- Skull: yield at the next stopping point.|' "$DOCTRINE" >"$swapped"
  if cmp -s "$DOCTRINE" "$swapped"; then return 1; fi
  if band_lines_ok "$swapped"; then return 1; fi
  without_lines_containing "$DOCTRINE" '- Fire: ' >"$removed"
  if cmp -s "$DOCTRINE" "$removed"; then return 1; fi
  if band_lines_ok "$removed"; then return 1; fi
  { cat "$DOCTRINE"; printf '%s\n' "${BAND_LINES[1]}"; } >"$duplicated"
  if cmp -s "$DOCTRINE" "$duplicated"; then return 1; fi
  if band_lines_ok "$duplicated"; then return 1; fi
  true
}

@test "doctrine order: the handoff is written before the reply form" {
  write_before_reply_ok "$DOCTRINE"
}

@test "doctrine order red twin: the reply form moved above the write sentence fails" {
  local mutated="$TEMPORARY_DIRECTORY/reply-first.md"
  {
    grep -F -- 'YIELDED <band>: <handoff path>' "$DOCTRINE"
    grep -vF -- 'YIELDED <band>: <handoff path>' "$DOCTRINE" || true
  } >"$mutated"
  if cmp -s "$DOCTRINE" "$mutated"; then return 1; fi
  if write_before_reply_ok "$mutated"; then return 1; fi
  true
}

@test "doctrine reply form: the reply form appears verbatim, with lowercase band words" {
  [ "$(count_containing_lines "$DOCTRINE" 'exactly `YIELDED <band>: <handoff path>`')" -eq 1 ]
  [ "$(count_containing_lines "$DOCTRINE" '(`red`, `fire` or `skull`)')" -eq 1 ]
}

# ------------------------------------------------------------------ budget

@test "doctrine budget: the shipped file is at most 3584 bytes" {
  budget_ok "$DOCTRINE"
}

@test "doctrine budget red twin: a copy padded past 3584 bytes fails the same check" {
  local size padding mutated="$TEMPORARY_DIRECTORY/oversize.md"
  size="$(wc -c <"$DOCTRINE" | tr -d ' ')"
  padding=$((3585 - size - 1))
  [ "$padding" -gt 0 ]
  { cat "$DOCTRINE"; head -c "$padding" /dev/zero | tr '\0' x; printf '\n'; } >"$mutated"
  [ "$(wc -c <"$mutated" | tr -d ' ')" -eq 3585 ]
  if budget_ok "$mutated"; then return 1; fi
  true
}
