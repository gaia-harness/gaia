#!/usr/bin/env bats
# Pins that wiki/concepts/Policy-Memory Loop.md carries no working-doc
# reference (UAT, SPEC, PR or as-of date).
#
# No lint guard for working-doc references in the wiki exists yet, so this one
# check stays here.

# assert_absent_across <ERE pattern> <file...>
# Fails the calling test if <pattern> (extended regex, case-insensitive)
# matches any listed file.
assert_absent_across() {
  local pattern="$1"
  shift
  local audited_file
  for audited_file in "$@"; do
    # An absence assertion has to prove it opened the file. grep exits 2 on a
    # missing or renamed path, so the `&&` arm never fires and the helper
    # returns 0, reporting a stale phrase absent from a file it never read.
    [ -f "$audited_file" ] || { echo "absence assertion target ${audited_file} does not exist" >&2; return 1; }
    grep -Eiq -- "$pattern" "$audited_file" && {
      echo "stale phrase /${pattern}/ survives in ${audited_file}" >&2
      return 1
    }
  done
  return 0
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WIKI_PAGE="$ROOT/wiki/concepts/Policy-Memory Loop.md"
}

@test "UAT-010: wiki page carries no UAT/SPEC/PR/date working-doc references" {
  assert_absent_across "UAT-[0-9]" "$WIKI_PAGE"
  assert_absent_across "SPEC-[0-9]" "$WIKI_PAGE"
  assert_absent_across "PR #[0-9]" "$WIKI_PAGE"
  assert_absent_across "as of [0-9]{4}" "$WIKI_PAGE"
}
