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

# --cleanup=verbatim keeps the trailer's trailing space: git's default cleanup
# strips it, the line then lacks the key's " -- ", and this case passes even
# against the bug it guards.
@test "a blank reason after a protected test name that carries ' -- ' does not waive it" {
  local dashed_name='denies a token -- forged signature'
  write_guard_suite "$dashed_name"
  commit_change "a protected test with a dash separator in its name"
  BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
  printf '@test "prints usage" {\n  true\n}\n' > "$FIXTURE/tests/guard.bats"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q --cleanup=verbatim -m "$(printf 'drop it\n\nProtected-Test-Removed: tests/guard.bats :: %s -- \nend' "$dashed_name")"
  run_gate
  [ "$status" -eq 1 ] || { printf 'status %s\n%s\n' "$status" "$output" >&2; return 1; }
  [ "$output" = "REMOVED tests/guard.bats :: $dashed_name" ] || { printf 'got\n%s\n' "$output" >&2; return 1; }
}

# The non-canonical spellings bats-preprocess accepts as a tag line or a test
# declaration, one fixture test each. The keyword and the directive word are
# spliced in at run time, so no fixture line is one bats would read in this file.
# Real bats counts the fixture's protected tests first, which proves each
# spelling is one bats tags.
@test "a protected test in a non-canonical spelling bats accepts is tracked when removed" {
  local keyword='@test' directive='bats' tab
  tab="$(printf '\t')"
  {
    printf '#%s test_tags=protected\n%s "no blank after the hash" {\n  true\n}\n' "$directive" "$keyword"
    printf '  #  %s   test_tags=protected\n%s "an indented tag line" {\n  true\n}\n' "$directive" "$keyword"
    printf '# %s test_tags=protected\n%s%s"a tab after the keyword" {\n  true\n}\n' "$directive" "$keyword" "$tab"
    printf '# %s test_tags=protected\n  %s "an indented test" {\n    true\n  }\n' "$directive" "$keyword"
    printf '# %s test_tags=protected\ncomment_form() { # %s\n  true\n}\n' "$directive" "$keyword"
    printf '%s "an untagged test" {\n  true\n}\n' "$keyword"
  } > "$FIXTURE/tests/forms.bats"
  run "$BATS_ROOT/bin/bats" --count --filter-tags protected "$FIXTURE/tests/forms.bats"
  [ "$output" = 5 ] || { printf 'bats counted %s protected tests\n' "$output" >&2; return 1; }
  commit_change "every spelling"
  BASE="$(git -C "$FIXTURE" rev-parse HEAD)"

  printf '%s "an untagged test" {\n  true\n}\n' "$keyword" > "$FIXTURE/tests/forms.bats"
  commit_change "drop every spelling"
  run_gate
  [ "$status" -eq 1 ]
  [ "$output" = "$(printf 'REMOVED tests/forms.bats :: %s\n' 'no blank after the hash' 'an indented tag line' \
    'a tab after the keyword' 'an indented test' 'comment_form')" ] || { printf 'got\n%s\n' "$output" >&2; return 1; }
}

# The merge base CI reaches decides whether the gate compares anything, so a
# checkout without one has to show on the run rather than read as clean.
@test "no merge base exits 0 and warns under GitHub Actions only" {
  run --separate-stderr bash -c "cd '$FIXTURE' && GITHUB_ACTIONS=true bash '$GATE'"
  [ "$status" -eq 0 ]
  [[ "$output" == '::warning::check-protected-tests compared nothing: '* ]] || { printf 'got\n%s\n' "$output" >&2; return 1; }
  run --separate-stderr bash -c "cd '$FIXTURE' && GITHUB_ACTIONS= bash '$GATE'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *'nothing was compared'* ]] || return 1
}

# The CI leg's own invocation: no --base, the base read from origin/main, and a
# missing base a failure rather than the warning.
@test "--require-base fails with no merge base and compares against origin/main when there is one" {
  run --separate-stderr bash -c "cd '$FIXTURE' && GITHUB_ACTIONS=true bash '$GATE' --require-base"
  [ "$status" -eq 2 ] || { printf 'status %s\n%s\n' "$status" "$output" >&2; return 1; }
  [[ "$stderr" == *'--require-base demands one'* ]] || return 1

  git -C "$FIXTURE" update-ref refs/remotes/origin/main "$BASE"
  printf '@test "prints usage" {\n  true\n}\n' > "$FIXTURE/tests/guard.bats"
  commit_change "drop the deny case"
  run --separate-stderr bash -c "cd '$FIXTURE' && GITHUB_ACTIONS=true bash '$GATE' --require-base"
  [ "$status" -eq 1 ]
  [ "$output" = "REMOVED tests/guard.bats :: denies a forged token" ] || { printf 'got\n%s\n' "$output" >&2; return 1; }

  git -C "$FIXTURE" commit -q --allow-empty -m "$(printf 'note\n\nProtected-Test-Removed: tests/guard.bats :: denies a forged token -- covered by the hook suite')"
  run --separate-stderr bash -c "cd '$FIXTURE' && GITHUB_ACTIONS=true bash '$GATE' --require-base"
  [ "$status" -eq 0 ] || { printf 'status %s\n%s\n%s\n' "$status" "$output" "$stderr" >&2; return 1; }
}
