#!/usr/bin/env bats
#
# Tests for .gaia/scripts/check-protected-tests.sh over a fixture repository:
# a protected test removed, untagged or renamed since the merge base fails the
# gate unless a commit trailer waives it with a reason.
#
# The fixture suites' tag lines are assembled at run time so this file never
# holds a column-0 tag line bats would apply to its own tests.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/check-protected-tests.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  GATE="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/check-protected-tests.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FIXTURE/tests"
  git -C "$FIXTURE" init -q -b main
  git -C "$FIXTURE" config user.email t@example.com
  git -C "$FIXTURE" config user.name t
  git -C "$FIXTURE" config commit.gpgsign false
  TEST_TAG="$(printf '# bats %s' 'test_tags=whole-tree,protected')"
  FILE_TAG="$(printf '# bats %s' 'file_tags=protected')"
  write_guard_suite
  printf '%s\n@test "every case" {\n  true\n}\n' "$FILE_TAG" > "$FIXTURE/tests/all.bats"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m base
  BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
}

# write_guard_suite [<deny test name>] [<deny tag line>]: the guard suite, a
# protected deny case and an untagged usage case.
write_guard_suite() {
  local deny_name="${1:-denies a forged token}" deny_tag="${2-$TEST_TAG}"
  printf '%s\n@test "%s" {\n  true\n}\n\n@test "prints usage" {\n  true\n}\n' \
    "$deny_tag" "$deny_name" > "$FIXTURE/tests/guard.bats"
}

commit_change() {
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m "$1"
}

run_gate() {
  run --separate-stderr bash -c "cd '$FIXTURE' && bash '$GATE' --base '$BASE'"
}

@test "kept protected tests and a removed untagged test pass" {
  sed -i.bak '/prints usage/,/^}/d' "$FIXTURE/tests/guard.bats" && rm -f "$FIXTURE/tests/guard.bats.bak"
  commit_change "drop the usage test"
  run_gate
  [ "$status" -eq 0 ] || { printf '%s\n%s\n' "$output" "$stderr" >&2; return 1; }
}

@test "a protected test deleted, untagged or renamed fails, naming it" {
  local change
  for change in deleted untagged renamed file-suite-deleted; do
    git -C "$FIXTURE" reset -q --hard "$BASE"
    case "$change" in
      deleted) printf '@test "prints usage" {\n  true\n}\n' > "$FIXTURE/tests/guard.bats" ;;
      untagged) write_guard_suite "denies a forged token" "" ;;
      renamed) write_guard_suite "denies a forged bearer token" ;;
      file-suite-deleted) rm "$FIXTURE/tests/all.bats" ;;
    esac
    commit_change "$change"
    run_gate
    [ "$status" -eq 1 ] || { printf '%s: status %s\n%s\n' "$change" "$status" "$output" >&2; return 1; }
    case "$change" in
      file-suite-deleted) [ "$output" = "REMOVED tests/all.bats :: every case" ] ;;
      *) [ "$output" = "REMOVED tests/guard.bats :: denies a forged token" ] ;;
    esac || { printf '%s: got\n%s\n' "$change" "$output" >&2; return 1; }
  done
}

@test "a commit trailer with a reason waives the removal, and one without a reason fails" {
  printf '@test "prints usage" {\n  true\n}\n' > "$FIXTURE/tests/guard.bats"
  commit_change "$(printf 'drop the deny case\n\nProtected-Test-Removed: tests/guard.bats :: denies a forged token -- covered by the hook suite')"
  run_gate
  [ "$status" -eq 0 ] || { printf '%s\n%s\n' "$output" "$stderr" >&2; return 1; }

  git -C "$FIXTURE" commit -q --allow-empty -m "$(printf 'note\n\nProtected-Test-Removed: tests/all.bats :: every case --')"
  run_gate
  [ "$status" -eq 1 ]
  [ "$output" = "BAD-WAIVER tests/all.bats :: every case --" ] || { printf 'got\n%s\n' "$output" >&2; return 1; }
}

@test "a waiver names a protected test whose name carries a backslash" {
  local backslash_name='denies a path with \n in it'
  write_guard_suite "$backslash_name"
  commit_change "a protected test with a backslash"
  BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
  printf '@test "prints usage" {\n  true\n}\n' > "$FIXTURE/tests/guard.bats"
  commit_change "$(printf 'drop it\n\nProtected-Test-Removed: tests/guard.bats :: %s -- covered elsewhere' "$backslash_name")"
  run_gate
  [ "$status" -eq 0 ] || { printf '%s\n%s\n' "$output" "$stderr" >&2; return 1; }
}
