#!/usr/bin/env bats
#
# Suite for .gaia/scripts/select-migration-notes.sh, the selector /update-gaia
# runs from the verified target bundle to pick the migration notes a hop
# crosses. It guards the range and ascending numeric order, the fail-closed
# validation of the whole folder (in range or not), the unreadable-note
# report, and the shared version comparison.
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

# expect_selected <expected output> <baseline> <target> [<bundle root>]
expect_selected() {
  run --separate-stderr bash "$SCRIPT" "${4:-$ROOT}" "$2" "$3"
  [ "$status" -eq 0 ] || { echo "selection $2..$3: status $status"; return 1; }
  [ "$output" = "$1" ] || { echo "selection $2..$3: got '$output'"; return 1; }
  [ -z "$stderr" ] || { echo "selection $2..$3: stderr '$stderr'"; return 1; }
}

@test "selects notes above the baseline through the target, ascending numerically, each with its mode and path" {
  write_note 2.1.0 blocking
  write_note 2.2.0 after-merge
  write_note 2.3.0 blocking
  write_note 3.0.0 blocking
  expect_selected "$(printf '2.2.0\tafter-merge\t%s/.gaia/migrations/2.2.0.md\n2.3.0\tblocking\t%s/.gaia/migrations/2.3.0.md' "$ROOT" "$ROOT")" 2.1.0 2.3.0

  # one trailing slash on the bundle root is stripped from the printed path
  expect_selected "$(printf '2.2.0\tafter-merge\t%s/.gaia/migrations/2.2.0.md\n2.3.0\tblocking\t%s/.gaia/migrations/2.3.0.md' "$ROOT" "$ROOT")" 2.1.0 2.3.0 "$ROOT/"

  # a note equal to the baseline is excluded and one equal to the target is included
  expect_selected "$(printf '2.3.0\tblocking\t%s/.gaia/migrations/2.3.0.md' "$ROOT")" 2.2.0 2.3.0

  # numeric per component: 2.9.0 before 2.10.0
  rm -rf "$NOTES"
  write_note 2.10.0 blocking
  write_note 2.9.0 after-merge
  expect_selected "$(printf '2.9.0\tafter-merge\t%s/.gaia/migrations/2.9.0.md\n2.10.0\tblocking\t%s/.gaia/migrations/2.10.0.md' "$ROOT" "$ROOT")" 2.8.0 2.10.0
}

@test "an absent or empty migrations folder prints nothing and exits 0" {
  mkdir -p "$ROOT"
  expect_selected "" 1.0.0 2.0.0
  mkdir -p "$NOTES"
  expect_selected "" 1.0.0 2.0.0
}

# seed_malformed <case>: writes the folder content for one fail-closed case.
seed_malformed() {
  rm -rf "$ROOT"
  mkdir -p "$NOTES"
  case "$1" in
    no-frontmatter) printf '# Just a heading\n' >"$NOTES/2.2.0.md" ;;
    unknown-mode) printf -- '---\nmode: sometimes\n---\n' >"$NOTES/2.2.0.md" ;;
    unknown-mode-out-of-range)
      write_note 2.2.0 blocking
      printf -- '---\nmode: sometimes\n---\n' >"$NOTES/9.0.0.md" ;;
    quoted-mode) printf -- '---\nmode: "blocking"\n---\n' >"$NOTES/2.2.0.md" ;;
    other-key) printf -- '---\nkind: blocking\n---\n' >"$NOTES/2.2.0.md" ;;
    second-key) printf -- '---\nmode: blocking\nextra: 1\n---\n' >"$NOTES/2.2.0.md" ;;
    trailing-text) printf -- '---\nmode: blocking # note\n---\n' >"$NOTES/2.2.0.md" ;;
    trailing-space) printf -- '---\nmode: blocking \n---\n' >"$NOTES/2.2.0.md" ;;
    non-version-name)
      write_note 2.2.0 blocking
      printf -- '---\nmode: blocking\n---\n' >"$NOTES/2.0.md" ;;
    v-prefixed) printf -- '---\nmode: blocking\n---\n' >"$NOTES/v2.0.0.md" ;;
    non-md) printf -- '---\nmode: blocking\n---\n' >"$NOTES/2.0.0.txt" ;;
    leading-zero-major) printf -- '---\nmode: blocking\n---\n' >"$NOTES/02.0.0.md" ;;
    leading-zero-minor) printf -- '---\nmode: blocking\n---\n' >"$NOTES/2.01.0.md" ;;
    readme)
      write_note 2.2.0 blocking
      printf '# notes\n' >"$NOTES/README.md" ;;
    dotfile)
      write_note 2.2.0 blocking
      : >"$NOTES/.gitkeep" ;;
    subdirectory)
      write_note 2.2.0 blocking
      mkdir "$NOTES/archive" ;;
    symlink)
      mkdir -p "$BATS_TEST_TMPDIR/outside"
      printf -- '---\nmode: blocking\n---\n' >"$BATS_TEST_TMPDIR/outside/real.md"
      ln -s "$BATS_TEST_TMPDIR/outside/real.md" "$NOTES/2.2.0.md" ;;
    byte-order-mark) printf '\xef\xbb\xbf---\nmode: blocking\n---\n' >"$NOTES/2.2.0.md" ;;
    crlf) printf -- '---\r\nmode: blocking\r\n---\r\n' >"$NOTES/2.2.0.md" ;;
    body-carriage-return) printf -- '---\nmode: blocking\n---\nbody\r\n' >"$NOTES/2.2.0.md" ;;
    empty-file) : >"$NOTES/2.2.0.md" ;;
    no-final-line-feed) printf -- '---\nmode: blocking\n---' >"$NOTES/2.2.0.md" ;;
    spaces-in-name)
      write_note 2.2.0 blocking
      : >"$NOTES/my note.md" ;;
  esac
}

@test "a malformed entry in the folder fails closed, names the entry and prints nothing" {
  local row label file reason
  for row in \
    "no-frontmatter|2.2.0.md|frontmatter" \
    "unknown-mode|2.2.0.md|mode" \
    "unknown-mode-out-of-range|9.0.0.md|mode" \
    "quoted-mode|2.2.0.md|mode" \
    "other-key|2.2.0.md|mode" \
    "second-key|2.2.0.md|frontmatter" \
    "trailing-text|2.2.0.md|mode" \
    "trailing-space|2.2.0.md|mode" \
    "non-version-name|2.0.md|version" \
    "v-prefixed|v2.0.0.md|version" \
    "non-md|2.0.0.txt|version" \
    "leading-zero-major|02.0.0.md|version" \
    "leading-zero-minor|2.01.0.md|version" \
    "readme|README.md|version" \
    "dotfile|.gitkeep|version" \
    "subdirectory|archive|directory" \
    "symlink|2.2.0.md|symlink" \
    "byte-order-mark|2.2.0.md|byte-order mark" \
    "crlf|2.2.0.md|carriage return" \
    "body-carriage-return|2.2.0.md|carriage return" \
    "empty-file|2.2.0.md|empty" \
    "no-final-line-feed|2.2.0.md|frontmatter" \
    "spaces-in-name|my note.md|version"; do
    label=${row%%|*}; file=${row#*|}; reason=${file#*|}; file=${file%%|*}
    seed_malformed "$label"
    run --separate-stderr bash "$SCRIPT" "$ROOT" 1.0.0 3.0.0
    [ "$status" -eq 1 ] || { echo "row $label: status $status"; return 1; }
    [ -z "$output" ] || { echo "row $label: stdout '$output'"; return 1; }
    grep -qF -- "select-migration-notes: $NOTES/$file:" <<<"$stderr" || { echo "row $label: entry not named: $stderr"; return 1; }
    grep -qF -- "$reason" <<<"$stderr" || { echo "row $label: reason '$reason' missing: $stderr"; return 1; }
  done
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

# Prints each of the two scripts in <dir> that defines its own vcmp.
inline_vcmp_scripts() {
  local script
  for script in select-migration-notes.sh changelog-range.sh; do
    if grep -q 'function vcmp' "$1/$script"; then
      printf '%s\n' "$script"
    fi
  done
}

@test "both scripts load the shared comparison and neither defines its own vcmp" {
  [ -r "$SCRIPTS_DIR/lib/version-compare.awk" ]
  grep -q 'function vcmp' "$SCRIPTS_DIR/lib/version-compare.awk"
  for script in select-migration-notes.sh changelog-range.sh; do
    grep -qF 'lib/version-compare.awk' "$SCRIPTS_DIR/$script"
  done
  [ -z "$(inline_vcmp_scripts "$SCRIPTS_DIR")" ]
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
