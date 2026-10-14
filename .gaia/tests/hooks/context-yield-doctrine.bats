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
  CHECKPOINT="$REPO_ROOT/.claude/doctrine/context-checkpoint.md"
  TEMPORARY_DIRECTORY="$BATS_TEST_TMPDIR"
}

# ---------------------------------------------------------------- helpers

# Sentence-level fixed strings, in the order the doctrine must state them.
# Each literal sits on one line of the doctrine so a line-deletion twin can
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

# the tokens the handoff shape shares with the main-session checkpoint's STATE.md
SHARED_TOKENS=('Facts' 'Status checklist' 'NEXT:' '4 KB')

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

# every anchor is present and the first lines never decrease
anchors_ordered_ok() {
  local file_path="$1" anchor line previous=0
  [ -f "$file_path" ] || return 1
  [ "${#ANCHORS[@]}" -gt 0 ] || return 1
  for anchor in "${ANCHORS[@]}"; do
    line="$(first_line_of "$file_path" "$anchor")"
    [ -n "$line" ] || return 1
    [ "$line" -ge "$previous" ] || return 1
    previous="$line"
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

# one line of the doctrine names all four shared tokens, and the checkpoint doctrine names each
shape_matches_checkpoint_ok() {
  local doctrine_path="$1" checkpoint_path="$2" token shape_line
  [ -f "$doctrine_path" ] || return 1
  [ -f "$checkpoint_path" ] || return 1
  [ "${#SHARED_TOKENS[@]}" -eq 4 ] || return 1
  shape_line="$(grep -F -- 'The handoff opens with the goal' "$doctrine_path" | head -n 1)"
  [ -n "$shape_line" ] || return 1
  for token in "${SHARED_TOKENS[@]}"; do
    printf '%s\n' "$shape_line" | grep -qF -- "$token" || return 1
    grep -qF -- "$token" "$checkpoint_path" || return 1
  done
  return 0
}

# the file stays within the byte budget
budget_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  [ "$(wc -c <"$file_path" | tr -d ' ')" -le 3584 ] || return 1
  return 0
}

no_ids_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  grep -qE 'SPEC-[0-9]|UAT-[0-9]|PLAN-[0-9]|#[0-9]' "$file_path" && return 1
  grep -qF -- $'\xe2\x80\x94' "$file_path" && return 1
  return 0
}

# ------------------------------------------------------------- the doctrine

@test "doctrine path: the suite reads exactly the shipped yield doctrine path" {
  [ "$DOCTRINE_RELATIVE_PATH" = '.claude/doctrine/context-yield.md' ]
  [ -s "$DOCTRINE" ]
}

@test "doctrine path red twin: an absent file fails every guard" {
  local missing="$TEMPORARY_DIRECTORY/absent/context-yield.md"
  [ ! -e "$missing" ]
  if anchors_ordered_ok "$missing"; then return 1; fi
  if band_lines_ok "$missing"; then return 1; fi
  if write_before_reply_ok "$missing"; then return 1; fi
  if budget_ok "$missing"; then return 1; fi
  if no_ids_ok "$missing"; then return 1; fi
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

@test "doctrine anchors red twin: the first anchor line moved to the end fails the order check" {
  local first_anchor="${ANCHORS[0]}" mutated="$TEMPORARY_DIRECTORY/reordered.md"
  {
    without_lines_containing "$DOCTRINE" "$first_anchor"
    grep -F -- "$first_anchor" "$DOCTRINE"
  } >"$mutated"
  if cmp -s "$DOCTRINE" "$mutated"; then return 1; fi
  if anchors_ordered_ok "$mutated"; then return 1; fi
  true
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

@test "doctrine stopping point: the sentence names tool call, background task, nested sub-agent and half-edited file" {
  [ "$(count_containing_lines "$DOCTRINE" 'no tool call, background task or nested sub-agent in flight, and no file half-edited')" -eq 1 ]
}

@test "doctrine reply form: the reply form appears verbatim, with lowercase band words" {
  [ "$(count_containing_lines "$DOCTRINE" 'exactly `YIELDED <band>: <handoff path>`')" -eq 1 ]
  [ "$(count_containing_lines "$DOCTRINE" '(`red`, `fire` or `skull`)')" -eq 1 ]
}

@test "doctrine never-commit: the sentence names commit, stash and discard" {
  [ "$(count_containing_lines "$DOCTRINE" 'never commit, stash or discard at a yield')" -eq 1 ]
}

@test "doctrine never-yield: the instruction-only sentence appears" {
  [ "$(count_containing_lines "$DOCTRINE" 'never yield on your own estimate of your context')" -eq 1 ]
}

# ------------------------------------------------ shape shared with checkpoint

@test "doctrine shape: the handoff-shape line shares its four tokens with the checkpoint doctrine" {
  shape_matches_checkpoint_ok "$DOCTRINE" "$CHECKPOINT"
}

@test "doctrine shape red twins: a renamed token in the checkpoint copy or in the doctrine copy fails" {
  local token index=0 checkpoint_copy doctrine_copy
  for token in "${SHARED_TOKENS[@]}"; do
    index=$((index + 1))
    checkpoint_copy="$TEMPORARY_DIRECTORY/checkpoint-$index.md"
    doctrine_copy="$TEMPORARY_DIRECTORY/yield-$index.md"
    sed "s|$token|Renamed token|g" "$CHECKPOINT" >"$checkpoint_copy"
    if cmp -s "$CHECKPOINT" "$checkpoint_copy"; then return 1; fi
    if shape_matches_checkpoint_ok "$DOCTRINE" "$checkpoint_copy"; then return 1; fi
    sed "s|$token|Renamed token|g" "$DOCTRINE" >"$doctrine_copy"
    if cmp -s "$DOCTRINE" "$doctrine_copy"; then return 1; fi
    if shape_matches_checkpoint_ok "$doctrine_copy" "$CHECKPOINT"; then return 1; fi
  done
  [ "$index" -eq "${#SHARED_TOKENS[@]}" ]
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

# --------------------------------------------------------------- working ids

@test "doctrine: no working-document id and no em dash" {
  no_ids_ok "$DOCTRINE"
}

@test "doctrine id red twins: planted SPEC, UAT, plan and issue ids and an em dash fail" {
  local planted index=0
  for planted in 'See SPEC-7.' 'See UAT-3.' 'See PLAN-2.' 'See #4.' $'Dash \xe2\x80\x94 here.'; do
    index=$((index + 1))
    { cat "$DOCTRINE"; printf '%s\n' "$planted"; } >"$TEMPORARY_DIRECTORY/id-$index.md"
    if no_ids_ok "$TEMPORARY_DIRECTORY/id-$index.md"; then return 1; fi
  done
  [ "$index" -eq 5 ]
}
