#!/usr/bin/env bats
#
# Suite for .gaia/scripts/select-migration-notes.sh, the selector /update-gaia
# runs from the verified target bundle to pick the migration notes a hop
# crosses. It guards the range and ascending numeric order, the fail-closed
# validation of the whole folder (in range or not), the unreadable-note
# report, the usage exits, and the shared version comparison.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/select-migration-notes.bats < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$SCRIPTS_DIR/select-migration-notes.sh"
  ROOT="$BATS_TEST_TMPDIR/bundle"
  NOTES="$ROOT/.gaia/migrations"
}

# write_note <version> <mode>: a well-formed note.
write_note() {
  mkdir -p "$NOTES"
  printf -- '---\nmode: %s\n---\n\nbody\n' "$2" >"$NOTES/$1.md"
}

# expect_fail_closed <path fragment> <reason fragment>: the failing contract.
expect_fail_closed() {
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -qF -- "select-migration-notes: $1" <<<"$stderr"
  grep -qF -- "$2" <<<"$stderr"
}

@test "selects notes above the baseline through the target, ascending, each with its mode" {
  write_note 2.1.0 blocking
  write_note 2.2.0 after-merge
  write_note 2.3.0 blocking
  write_note 3.0.0 blocking
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '2.2.0\tafter-merge\t%s/.gaia/migrations/2.2.0.md\n2.3.0\tblocking\t%s/.gaia/migrations/2.3.0.md' "$ROOT" "$ROOT")" ]
  [ -z "$stderr" ]
}

@test "one trailing slash on the bundle root is stripped from the printed path" {
  write_note 2.2.0 blocking
  run --separate-stderr bash "$SCRIPT" "$ROOT/" 2.1.0 2.2.0
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '2.2.0\tblocking\t%s/.gaia/migrations/2.2.0.md' "$ROOT")" ]
}

@test "orders numerically per component: 2.9.0 before 2.10.0" {
  write_note 2.10.0 blocking
  write_note 2.9.0 after-merge
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.8.0 2.10.0
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '2.9.0\tafter-merge\t%s/.gaia/migrations/2.9.0.md\n2.10.0\tblocking\t%s/.gaia/migrations/2.10.0.md' "$ROOT" "$ROOT")" ]
}

@test "a note equal to the baseline is excluded and one equal to the target is included" {
  write_note 2.0.0 blocking
  write_note 2.1.0 blocking
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.0.0 2.1.0
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '2.1.0\tblocking\t%s/.gaia/migrations/2.1.0.md' "$ROOT")" ]
}

@test "an absent migrations folder prints nothing and exits 0" {
  mkdir -p "$ROOT"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 1.0.0 2.0.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "an empty migrations folder prints nothing and exits 0" {
  mkdir -p "$NOTES"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 1.0.0 2.0.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a note with no frontmatter fails closed" {
  mkdir -p "$NOTES"
  printf '# Just a heading\n' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "frontmatter"
}

@test "an unknown mode fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nmode: sometimes\n---\n' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "mode"
}

@test "an unknown mode outside the range still fails the whole folder" {
  write_note 2.2.0 blocking
  mkdir -p "$NOTES"
  printf -- '---\nmode: sometimes\n---\n' >"$NOTES/9.0.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/9.0.0.md:" "mode"
}

@test "a quoted mode value fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nmode: "blocking"\n---\n' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "mode"
}

@test "a frontmatter key other than mode fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nkind: blocking\n---\n' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "mode"
}

@test "a second frontmatter key fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nmode: blocking\nextra: 1\n---\n' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "frontmatter"
}

@test "trailing text after the mode value fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nmode: blocking # note\n---\n' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "mode"
}

@test "trailing whitespace after the mode value fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nmode: blocking \n---\n' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "mode"
}

@test "a non-version filename fails closed" {
  write_note 2.2.0 blocking
  printf -- '---\nmode: blocking\n---\n' >"$NOTES/2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.0.md:" "version"
}

@test "a v-prefixed or non-md filename fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nmode: blocking\n---\n' >"$NOTES/v2.0.0.md"
  printf -- '---\nmode: blocking\n---\n' >"$NOTES/2.0.0.txt"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 1.0.0 3.0.0
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -qF -- "select-migration-notes: $NOTES/v2.0.0.md:" <<<"$stderr"
  grep -qF -- "select-migration-notes: $NOTES/2.0.0.txt:" <<<"$stderr"
}

@test "a leading-zero major component fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nmode: blocking\n---\n' >"$NOTES/02.0.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 1.0.0 3.0.0
  expect_fail_closed "$NOTES/02.0.0.md:" "version"
}

@test "a leading-zero minor component fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nmode: blocking\n---\n' >"$NOTES/2.01.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 1.0.0 3.0.0
  expect_fail_closed "$NOTES/2.01.0.md:" "version"
}

@test "a README fails closed" {
  write_note 2.2.0 blocking
  printf '# notes\n' >"$NOTES/README.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/README.md:" "version"
}

@test "a dotfile fails closed" {
  write_note 2.2.0 blocking
  : >"$NOTES/.gitkeep"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/.gitkeep:" "version"
}

@test "a subdirectory fails closed" {
  write_note 2.2.0 blocking
  mkdir "$NOTES/archive"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/archive:" "directory"
}

@test "a symlink named like a valid note fails closed even when it points at a well-formed note" {
  mkdir -p "$NOTES" "$BATS_TEST_TMPDIR/outside"
  printf -- '---\nmode: blocking\n---\n' >"$BATS_TEST_TMPDIR/outside/real.md"
  ln -s "$BATS_TEST_TMPDIR/outside/real.md" "$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "symlink"
}

@test "a byte-order mark fails closed" {
  mkdir -p "$NOTES"
  printf '\xef\xbb\xbf---\nmode: blocking\n---\n' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "byte-order mark"
}

@test "CRLF line endings fail closed" {
  mkdir -p "$NOTES"
  printf -- '---\r\nmode: blocking\r\n---\r\n' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "carriage return"
}

@test "a carriage return in the body fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nmode: blocking\n---\nbody\r\n' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "carriage return"
}

@test "an empty file fails closed" {
  mkdir -p "$NOTES"
  : >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "empty"
}

@test "a frontmatter whose last line has no line feed fails closed" {
  mkdir -p "$NOTES"
  printf -- '---\nmode: blocking\n---' >"$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/2.2.0.md:" "frontmatter"
}

@test "an unreadable note fails closed and is named as unreadable" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "permission bits do not stop a read when the suite runs as root"
  fi
  write_note 2.2.0 blocking
  chmod 000 "$NOTES/2.2.0.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  chmod 644 "$NOTES/2.2.0.md"
  expect_fail_closed "$NOTES/2.2.0.md:" "unreadable"
}

@test "several malformed entries are all named in one run" {
  mkdir -p "$NOTES"
  printf '# no frontmatter\n' >"$NOTES/2.2.0.md"
  printf -- '---\nmode: nope\n---\n' >"$NOTES/9.0.0.md"
  printf '# notes\n' >"$NOTES/README.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -qF -- "select-migration-notes: $NOTES/2.2.0.md:" <<<"$stderr"
  grep -qF -- "select-migration-notes: $NOTES/9.0.0.md:" <<<"$stderr"
  grep -qF -- "select-migration-notes: $NOTES/README.md:" <<<"$stderr"
  [ "$(grep -c '^select-migration-notes: ' <<<"$stderr")" -eq 3 ]
}

@test "a malformed entry leaves stdout empty even when valid notes are in range" {
  write_note 2.2.0 blocking
  printf '# notes\n' >"$NOTES/README.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/README.md:" "version"
}

@test "names with spaces are validated, not split" {
  write_note 2.2.0 blocking
  : >"$NOTES/my note.md"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0 2.3.0
  expect_fail_closed "$NOTES/my note.md:" "version"
}

@test "two arguments is a usage error" {
  mkdir -p "$ROOT"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.1.0
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF -- "usage" <<<"$stderr"
}

@test "a baseline with a v prefix is a usage error" {
  mkdir -p "$ROOT"
  run --separate-stderr bash "$SCRIPT" "$ROOT" v2.0.0 2.1.0
  [ "$status" -eq 2 ]
  grep -qF -- "usage" <<<"$stderr"
}

@test "a two-part target is a usage error" {
  mkdir -p "$ROOT"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 2.0.0 2.1
  [ "$status" -eq 2 ]
  grep -qF -- "usage" <<<"$stderr"
}

@test "a leading-zero baseline is a usage error" {
  mkdir -p "$ROOT"
  run --separate-stderr bash "$SCRIPT" "$ROOT" 02.0.0 2.1.0
  [ "$status" -eq 2 ]
  grep -qF -- "usage" <<<"$stderr"
}

@test "a bundle root that does not exist is a usage error" {
  run --separate-stderr bash "$SCRIPT" "$BATS_TEST_TMPDIR/missing" 2.0.0 2.1.0
  [ "$status" -eq 2 ]
  grep -qF -- "usage" <<<"$stderr"
}

@test "both scripts load the shared comparison and neither defines its own vcmp" {
  [ -r "$SCRIPTS_DIR/lib/version-compare.awk" ]
  grep -q 'function vcmp' "$SCRIPTS_DIR/lib/version-compare.awk"
  for script in select-migration-notes.sh changelog-range.sh; do
    grep -qF 'lib/version-compare.awk' "$SCRIPTS_DIR/$script"
    grep -q 'function vcmp' "$SCRIPTS_DIR/$script" && return 1
  done
  true
}

@test "a copy of either script with an inline vcmp is reported by the definition check" {
  for script in select-migration-notes.sh changelog-range.sh; do
    cp "$SCRIPTS_DIR/$script" "$BATS_TEST_TMPDIR/$script"
    printf '# function vcmp(a,b){return 0}\n' >>"$BATS_TEST_TMPDIR/$script"
    grep -q 'function vcmp' "$BATS_TEST_TMPDIR/$script"
  done
}

@test "the selector loads the comparison from its own install directory" {
  # A copy of the scripts beside a lib whose vcmp is inverted must order the
  # other way, proving the comparison is read from the script's own directory.
  mkdir -p "$BATS_TEST_TMPDIR/copy/lib"
  cp "$SCRIPT" "$BATS_TEST_TMPDIR/copy/select-migration-notes.sh"
  cat >"$BATS_TEST_TMPDIR/copy/lib/version-compare.awk" <<'AWK'
function vcmp(a, b) { return 0 }
AWK
  write_note 2.2.0 blocking
  run --separate-stderr bash "$BATS_TEST_TMPDIR/copy/select-migration-notes.sh" "$ROOT" 2.1.0 2.3.0
  [ "$status" -eq 0 ]
  # vcmp always 0 makes "above baseline" false, so nothing is selected.
  [ -z "$output" ]
}
