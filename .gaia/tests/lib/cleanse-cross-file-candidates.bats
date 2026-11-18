#!/usr/bin/env bats
# The cross-file candidate script: blocks in different instruction files that
# share distinctive literals form clusters. Each fixture repo is built in
# $BATS_TEST_TMPDIR and the ownership classifier is a stub reading a class map,
# so a test sets the class of each file directly.
#
# Assertion style per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="${CROSS_FILE_SCRIPT_UNDER_TEST:-$REPO_ROOT/.gaia/scripts/cleanse/cross-file-candidates.mjs}"
  CLASS_MAP="$BATS_TEST_TMPDIR/classes.tsv"
  : >"$CLASS_MAP"
  export CLASS_MAP
  STUB="$BATS_TEST_TMPDIR/classifier.sh"
  cat >"$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
# Prints `<class>\t<path>` per path after `--`; a path missing from the map is adopter.
after_separator=0
for arg in "$@"; do
  if [ "$after_separator" = 1 ]; then
    class="$(awk -F'\t' -v p="$arg" '$1 == p {print $2}' "$CLASS_MAP")"
    printf '%s\t%s\n' "${class:-adopter}" "$arg"
  elif [ "$arg" = "--" ]; then
    after_separator=1
  fi
done
STUB_EOF
  export CROSS_FILE_OWNERSHIP_CLASSIFIER="$STUB"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
}

# One top-level list item whose three literals are named after $1, so two
# procedures with different names share nothing.
procedure() {
  # shellcheck disable=SC2016 # the backticks are the fixture's inline code spans
  printf -- '- Run `bash scripts/%s.sh --apply`, then `pnpm run %s-gate`, and keep `%s_LIMIT=500` in place.\n' "$1" "$1" "$1"
}

# write_file <path> <line>...: writes the lines to the path in $REPO and tracks it.
write_file() {
  local file="$1"
  shift
  mkdir -p "$REPO/$(dirname "$file")"
  printf '%s\n' "$@" >"$REPO/$file"
  git -C "$REPO" add -- "$file"
}

set_class() {
  printf '%s\t%s\n' "$2" "$1" >>"$CLASS_MAP"
}

member_paths() {
  jq -c '[.clusters[].members[].path]' <<<"$output"
}

cluster_count() {
  jq '.clusters | length' <<<"$output"
}

@test "two files restating one procedure's literals form one cluster, and a block repeated inside one file forms none" {
  write_file .claude/rules/a.md "# A" "" "$(procedure alpha)"
  write_file .claude/rules/b.md "# B" "" "Another file says it again:" "" "$(procedure alpha)"
  # shellcheck disable=SC2016 # the backticks are the fixture's inline code spans
  write_file .claude/rules/mention.md "Mentioned apart:" "" '`bash scripts/solo.sh --apply`' "" '`pnpm run solo-gate`' "" '`solo_LIMIT=500`'
  write_file .claude/rules/solo.md "# Solo" "" "$(procedure solo)" "" "Later in the same file:" "" "$(procedure solo)"
  run node "$SCRIPT" --root "$REPO"
  [ "$status" -eq 0 ] || return 1
  [ "$(cluster_count)" = 1 ] || return 1
  [ "$(member_paths)" = '[".claude/rules/a.md",".claude/rules/b.md"]' ] || return 1
  [ "$(jq -r '.clusters[0].id' <<<"$output")" = C001 ] || return 1
}

@test "a literal more files carry than --max-df allows counts toward no pair" {
  write_file .claude/rules/a.md "$(procedure alpha)"
  write_file .claude/rules/b.md "$(procedure alpha)"
  write_file .claude/rules/c.md "$(procedure alpha)"
  run node "$SCRIPT" --root "$REPO" --max-df 2
  [ "$status" -eq 0 ] || return 1
  [ "$(cluster_count)" = 0 ] || return 1
  run node "$SCRIPT" --root "$REPO" --max-df 3
  [ "$status" -eq 0 ] || return 1
  [ "$(cluster_count)" = 1 ] || return 1
  [ "$(jq '.clusters[0].members | length' <<<"$output")" = 3 ] || return 1
}

@test "the scanned set leaves out .gaia, wiki/log.md, wiki/meta, third-party and ignored files" {
  write_file .claude/rules/a.md "$(procedure alpha)"
  write_file wiki/concepts/B.md "$(procedure alpha)"
  write_file .gaia/.claude/rules/inside-gaia.md "$(procedure alpha)"
  write_file wiki/log.md "$(procedure alpha)"
  write_file wiki/meta/report.md "$(procedure alpha)"
  write_file .claude/skills/vendored.md "$(procedure alpha)"
  write_file .claude/rules/ignored.md "$(procedure alpha)"
  set_class third-party .claude/skills/vendored.md
  set_class ignored .claude/rules/ignored.md
  run node "$SCRIPT" --root "$REPO"
  [ "$status" -eq 0 ] || return 1
  [ "$(jq '.files_scanned' <<<"$output")" = 2 ] || return 1
  [ "$(cluster_count)" = 1 ] || return 1
  [ "$(member_paths)" = '[".claude/rules/a.md","wiki/concepts/B.md"]' ] || return 1
}

@test "a cluster of only GAIA-shipped copies is dropped on an adopter repo and kept on the maintainer repo" {
  write_file .claude/rules/x.md "$(procedure alpha)"
  write_file .claude/rules/y.md "$(procedure alpha)"
  write_file .claude/rules/z.md "$(procedure beta)"
  write_file .claude/rules/w.md "$(procedure beta)"
  set_class gaia-shipped .claude/rules/x.md
  set_class gaia-shipped .claude/rules/y.md
  set_class gaia-shipped .claude/rules/z.md

  run node "$SCRIPT" --root "$REPO"
  [ "$status" -eq 0 ] || return 1
  [ "$(jq '.maintainer_repo' <<<"$output")" = false ] || return 1
  [ "$(member_paths)" = '[".claude/rules/w.md",".claude/rules/z.md"]' ] || return 1
  [ "$(jq -c '[.clusters[0].members[].ownership]' <<<"$output")" = '["adopter","gaia-shipped"]' ] || return 1

  run node "$SCRIPT" --root "$REPO" --all
  [ "$status" -eq 0 ] || return 1
  [ "$(cluster_count)" = 2 ] || return 1

  mkdir -p "$REPO/.claude/rules/maintainers"
  : >"$REPO/.claude/rules/maintainers/harness-triage-threshold.md"
  run node "$SCRIPT" --root "$REPO"
  [ "$status" -eq 0 ] || return 1
  [ "$(jq '.maintainer_repo' <<<"$output")" = true ] || return 1
  [ "$(cluster_count)" = 2 ] || return 1
  [ "$(member_paths)" = '[".claude/rules/w.md",".claude/rules/z.md",".claude/rules/x.md",".claude/rules/y.md"]' ] || return 1
}

@test "an ownership classifier failure exits 3 and prints no clusters" {
  write_file .claude/rules/a.md "$(procedure alpha)"
  write_file .claude/rules/b.md "$(procedure alpha)"
  printf '#!/usr/bin/env bash\nbash "%s" "$@"\nexit 3\n' "$STUB" >"$BATS_TEST_TMPDIR/failing.sh"
  CROSS_FILE_OWNERSHIP_CLASSIFIER="$BATS_TEST_TMPDIR/failing.sh" run bash -c 'node "$1" --root "$2" 2>/dev/null' _ "$SCRIPT" "$REPO"
  [ "$status" -eq 3 ] || return 1
  [ -z "$output" ] || return 1

  printf '#!/usr/bin/env bash\nbash "%s" "$@" | head -n 1\n' "$STUB" >"$BATS_TEST_TMPDIR/short.sh"
  CROSS_FILE_OWNERSHIP_CLASSIFIER="$BATS_TEST_TMPDIR/short.sh" run bash -c 'node "$1" --root "$2" 2>/dev/null' _ "$SCRIPT" "$REPO"
  [ "$status" -eq 3 ] || return 1
  [ -z "$output" ] || return 1
}

@test "a member inside a maintainer-only block is marked maintainer_only" {
  write_file .claude/rules/a.md "# A" "" "<!-- gaia:maintainer-only:start -->" "$(procedure alpha)" "<!-- gaia:maintainer-only:end -->"
  write_file .claude/rules/b.md "# B" "" "$(procedure alpha)"
  run node "$SCRIPT" --root "$REPO"
  [ "$status" -eq 0 ] || return 1
  [ "$(cluster_count)" = 1 ] || return 1
  [ "$(jq -c '[.clusters[0].members[] | [.path, .maintainer_only]]' <<<"$output")" = '[[".claude/rules/a.md",true],[".claude/rules/b.md",false]]' ] || return 1
  [ "$(jq '[.clusters[0].members[].text | contains("gaia:maintainer-only")] | any' <<<"$output")" = false ] || return 1
}

@test "a focus path drops clusters outside it, and a usage error exits 2 with no output" {
  write_file .claude/rules/a.md "$(procedure alpha)"
  write_file .claude/rules/b.md "$(procedure alpha)"
  write_file wiki/concepts/C.md "$(procedure beta)"
  write_file wiki/concepts/D.md "$(procedure beta)"

  run node "$SCRIPT" --root "$REPO" --focus .claude/rules
  [ "$status" -eq 0 ] || return 1
  [ "$(member_paths)" = '[".claude/rules/a.md",".claude/rules/b.md"]' ] || return 1

  run node "$SCRIPT" --root "$REPO" --focus wiki/concepts/D.md
  [ "$status" -eq 0 ] || return 1
  [ "$(member_paths)" = '["wiki/concepts/C.md","wiki/concepts/D.md"]' ] || return 1

  run node "$SCRIPT" --root "$REPO" --focus .claude/rules --focus wiki
  [ "$status" -eq 0 ] || return 1
  [ "$(cluster_count)" = 2 ] || return 1

  run bash -c 'node "$1" --root "$2" --bogus 2>/dev/null' _ "$SCRIPT" "$REPO"
  [ "$status" -eq 2 ] || return 1
  [ -z "$output" ] || return 1

  run bash -c 'node "$1" 2>/dev/null' _ "$SCRIPT"
  [ "$status" -eq 2 ] || return 1
  [ -z "$output" ] || return 1
}
