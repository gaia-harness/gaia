#!/usr/bin/env bats

# Tests for .claude/hooks/lib/git-segments.sh, the segment helpers the two git
# deny guards (block-no-verify.sh, block-main-destructive-git.sh) share. Each
# test sources the library in a fresh bash and calls one function, so a case
# pins the function itself rather than a guard's verdict; the guards' own
# suites pin what they do with the result.

setup() {
  GIT_SEGMENTS_LIBRARY="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/git-segments.sh"
}

# collapse TEXT: run gaia_collapsed_substitutions on TEXT.
collapse() {
  run bash -c '. "$1" && gaia_collapsed_substitutions "$2"' _ "$GIT_SEGMENTS_LIBRARY" "$1"
}

# command_word SEGMENT: run gaia_segment_command_word on SEGMENT.
command_word() {
  run bash -c '. "$1" && gaia_segment_command_word "$2"' _ "$GIT_SEGMENTS_LIBRARY" "$1"
}

# --- gaia_collapsed_substitutions ---

@test "gaia_collapsed_substitutions collapses substitutions, leaves backticks and newline-spanning spans" {
  local row label text expected
  for row in \
    "no substitution|git commit -m x|" \
    'bare underscore|git -C "$(pwd)" commit --no-verify|git -C "_" commit --no-verify' \
    'nested over successive passes|git -C $(dirname $(pwd)) commit -n|git -C _ commit -n' \
    'backtick alone|git -C `pwd` commit -n|' \
    'backtick beside a substitution|git -C `pwd` commit -m "$(cat f)" -n|git -C `pwd` commit -m "_" -n' \
    $'newline-spanning substitution|git commit -m "$(cat\nf)" -n|'; do
    label=${row%%|*}
    text=${row#*|}; text=${text%|*}
    expected=${row##*|}
    collapse "$text"
    [ "$status" -eq 0 ] || { echo "case $label: status=$status"; return 1; }
    [ "$output" = "$expected" ] || { echo "case $label: output=[$output] want [$expected]"; return 1; }
  done
}

# --- gaia_segment_command_word: one input per strip alternative ---

@test "gaia_segment_command_word strips whitespace, assignments, redirections, reserved words and time, leaves wrappers" {
  local row label segment expected
  for row in \
    "leading whitespace|   git commit|git commit" \
    "NAME=value prefix|GIT_AUTHOR_NAME=x git commit|git commit" \
    'double-quoted assignment with a space|GIT_AUTHOR_DATE="2024-01-01 12:00" git commit|git commit' \
    "single-quoted assignment with a space|GIT_AUTHOR_DATE='2024-01-01 12:00' git commit|git commit" \
    "stdout redirection|>/tmp/out git commit|git commit" \
    "stderr redirection|2>/dev/null git commit|git commit" \
    "brace|{ git commit|git commit" \
    "bang|! git commit|git commit" \
    "reserved coproc|coproc git commit|git commit" \
    "reserved elif|elif git commit|git commit" \
    "reserved else|else git commit|git commit" \
    "reserved while|while git commit|git commit" \
    "reserved until|until git commit|git commit" \
    "reserved then|then git commit|git commit" \
    "reserved do|do git commit|git commit" \
    "reserved if|if git commit|git commit" \
    "time|time git commit|git commit" \
    "time -p|time -p git commit|git commit" \
    "time --|time -- git commit|git commit" \
    "mixed prefixes|then A=1 B+=2 >/dev/null time -p git push|git push" \
    "wrapper stays|env -i git commit|env -i git commit" \
    "no prefix stays|ls -la|ls -la"; do
    label=${row%%|*}
    segment=${row#*|}; segment=${segment%|*}
    expected=${row##*|}
    command_word "$segment"
    [ "$output" = "$expected" ] || { echo "case $label: output=[$output] want [$expected]"; return 1; }
  done
}

# --- sourcing contract ---

@test "sourcing the library does no work and is idempotent" {
  run bash -c '. "$1"' _ "$GIT_SEGMENTS_LIBRARY"
  [ "$status" -eq 0 ] || { echo "case sourced once: status=$status"; return 1; }
  [ -z "$output" ] || { echo "case sourced once: printed [$output]"; return 1; }

  run bash -c '. "$1" && . "$1" && type gaia_collapsed_substitutions && type gaia_segment_command_word' _ "$GIT_SEGMENTS_LIBRARY"
  [ "$status" -eq 0 ] || { echo "case sourced twice: a function is undefined, status=$status"; return 1; }
}
