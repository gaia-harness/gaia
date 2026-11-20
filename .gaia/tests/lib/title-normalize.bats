#!/usr/bin/env bats
# Tests for title-normalize.sh: the shared catalog-title truncation rule
# (collapse whitespace -> first sentence -> bounded word-safe prefix, or a
# hard cut when the over-bound text has no interior word boundary). Dual-mode
# (sourced function + argv/stdin filter); setup_file copies the script, which
# sources nothing, into the file's tmp dir so the lib is exercised as a real
# file on disk, not the live working tree.

setup_file() {
  cp "$BATS_TEST_DIRNAME/../../scripts/spec/title-normalize.sh" "$BATS_FILE_TMPDIR/title-normalize.sh"
}

setup() {
  LIBRARY_PATH="$BATS_FILE_TMPDIR/title-normalize.sh"
  OVER_BOUND='The quick brown fox jumps over the lazy dog while the astonishingly persistent watchdog barks incessantly at the mail carrier every single morning without fail, causing considerable frustration.'
}

# Sourced-mode call: bash -c '. "$1"; gaia_normalize_title "$2"' _ "$LIBRARY_PATH" "<raw>"
# Raw text is passed as a positional arg (never interpolated into the script
# string), so embedded quotes/newlines in the raw text are never a hazard.
_normalize_title() {
  bash -c '. "$1"; gaia_normalize_title "$2"' _ "$LIBRARY_PATH" "$1"
}

@test "title normalization: short, collapsed, empty, over-bound word-safe and hard-cut inputs" {
  echo "case 1: short single-sentence input returns unchanged"
  run _normalize_title "Add a widget."
  [ "$status" -eq 0 ]
  [ "$output" = "Add a widget." ]

  echo "case 2: within-bound input with no terminator returns the collapsed line unchanged"
  run _normalize_title "a short subject with no terminator"
  [ "$status" -eq 0 ]
  [ "$output" = "a short subject with no terminator" ]

  echo "case 3: multi-line input collapses to one space-joined line"
  raw="$(printf 'a\n  b\nc')"
  run _normalize_title "$raw"
  [ "$status" -eq 0 ]
  [ "$output" = "a b c" ]

  echo "case 4: over-bound first sentence with interior spaces -> word-safe prefix ending in ..."
  run _normalize_title "$OVER_BOUND"
  [ "$status" -eq 0 ]
  body="${output%...}"
  [ "$body" != "$output" ]
  [ "${#body}" -le 120 ]
  last="${body:$((${#body} - 1)):1}"
  [ "$last" != " " ]

  echo "case 5: single over-bound token with no interior space is hard-cut to 120 chars + ..."
  token="$(printf 'a%.0s' $(seq 1 200))"
  run _normalize_title "$token"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 123 ]
  first120="${output:0:120}"
  without_letter_a="$(printf '%s' "$first120" | tr -d 'a')"
  [ -z "$without_letter_a" ]

  echo "case 6: empty input yields empty output"
  run _normalize_title ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  echo "case 7: a real three-line intent opening normalizes to a word-safe prefix, not the defect string"
  # Literal copy of an archived SPEC intent block's opening lines (a
  # multi-line YAML block scalar in the live, gitignored notebook data);
  # embedded here so the suite is hermetic and does not depend on that local,
  # untracked file being present. Built with printf (not a heredoc) since a
  # single-quoted heredoc containing an apostrophe confuses bats' own file
  # discovery on stock macOS /bin/bash (3.2).
  raw="$(printf '%s\n%s\n%s' \
    "GAIA's test-driven workflow already instructs the agent to write a failing" \
    "test first, but that \"failing first\" claim is self-certified: nothing checks" \
    "the test actually ran and failed before the agent made it pass. This feature")"
  defect="GAIA's test-driven workflow already instructs the agent to write a failing"
  run _normalize_title "$raw"
  [ "$status" -eq 0 ]
  [ "$output" != "$defect" ]
  body="${output%...}"
  [ "$body" != "$output" ]
}

@test "normalization is idempotent on source and on its own output" {
  echo "case 8: idempotency on source; the same raw over-bound source twice yields identical output"
  first_output="$(_normalize_title "$OVER_BOUND")"
  second_output="$(_normalize_title "$OVER_BOUND")"
  [ "$first_output" = "$second_output" ]

  echo "case 10: output idempotency; an already-...-suffixed over-bound title is a fixed point"
  fixed_point_output="$(_normalize_title "$first_output")"
  [ "$first_output" = "$fixed_point_output" ]
}

@test "9: filter mode matches the sourced function for the same raw input" {
  sourced_output="$(_normalize_title "$OVER_BOUND")"
  filter_output="$(printf '%s' "$OVER_BOUND" | bash "$LIBRARY_PATH")"
  [ "$sourced_output" = "$filter_output" ]
}

@test "11: sourcing is a silent no-op even with a non-empty positional \$1" {
  run bash -c 'library="$1"; set -- next; . "$library"' _ "$LIBRARY_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
