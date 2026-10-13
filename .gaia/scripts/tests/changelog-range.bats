#!/usr/bin/env bats
#
# Suite for .gaia/scripts/changelog-range.sh, the CHANGELOG range walk
# /update-gaia runs twice: once on the fetched CHANGELOG to show the release
# notes, once on the release copy to recover documented adopter actions. It
# guards the range bounds (strictly newer than the baseline, through the
# latest), numeric version ordering, the dropped [Unreleased] block and link
# list, both input modes, and the misuse exits.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/changelog-range.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/changelog-range.sh"
  CHANGELOG="$BATS_TEST_TMPDIR/CHANGELOG.md"
  cat >"$CHANGELOG" <<'EOF'
# Changelog

## [Unreleased]

- unreleased entry

## [1.10.0] - 2026-09-01

- ten

## [1.9.0] - 2026-08-01

- nine

## [1.2.0] - 2026-07-01

- two

## [1.1.0] - 2026-06-01

- one

[1.10.0]: https://example.com/1.10.0
[1.9.0]: https://example.com/1.9.0
EOF
}

@test "prints every section strictly newer than the baseline through the latest, in file order" {
  run --separate-stderr bash "$SCRIPT" 1.1.0 1.10.0 "$CHANGELOG"
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' '## [1.10.0] - 2026-09-01' '' '- ten' '' '## [1.9.0] - 2026-08-01' '' '- nine' '' '## [1.2.0] - 2026-07-01' '' '- two' '')"
  [ "$output" = "$expected" ]
}

@test "compares versions numerically, so 1.10.0 sits above 1.9.0" {
  run --separate-stderr bash "$SCRIPT" 1.9.0 1.10.0 "$CHANGELOG"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' '## [1.10.0] - 2026-09-01' '' '- ten' '')" ]
}

@test "stops at the latest bound and drops the Unreleased block and the link list" {
  run --separate-stderr bash "$SCRIPT" 1.1.0 1.9.0 "$CHANGELOG"
  [ "$status" -eq 0 ]
  grep -qF -- '- unreleased entry' <<<"$output" && return 1
  grep -qF -- '- ten' <<<"$output" && return 1
  grep -qF -- 'https://example.com' <<<"$output" && return 1
  grep -qF -- '- nine' <<<"$output"
  grep -qF -- '- two' <<<"$output"
}

@test "reads the CHANGELOG from stdin when no file is given" {
  run --separate-stderr bash "$SCRIPT" 1.2.0 1.9.0 <"$CHANGELOG"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' '## [1.9.0] - 2026-08-01' '' '- nine' '')" ]
}

@test "prints nothing and exits 0 when no section falls in the range" {
  run --separate-stderr bash "$SCRIPT" 1.10.0 1.10.0 "$CHANGELOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exits 2 with a usage line when a version is missing or malformed" {
  run --separate-stderr bash "$SCRIPT" 1.1.0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage: changelog-range.sh"* ]]
  run --separate-stderr bash "$SCRIPT" v1.1.0 1.10.0 "$CHANGELOG"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage: changelog-range.sh"* ]]
}

@test "exits 2 naming the file when the CHANGELOG file is unreadable" {
  run --separate-stderr bash "$SCRIPT" 1.1.0 1.10.0 "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"absent.md"* ]]
}
