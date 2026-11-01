#!/usr/bin/env bats
# Tests for the blocking 2.4.0 migration note as the old installed skill meets
# it: the skill of a 2.x release runs its own select_notes against the target
# bundle, so a project at 2.0.0, 2.3.0 or 2.3.1 reaches the note only through
# that tagged copy. The copies under .gaia/tests/fixtures/crossing/old-selector
# are committed, not read with `git show`, because these suites run in CI
# shards checked out at depth 2 with no tags. One integrity test compares the
# copies with the tags and skips where the tags are absent.
#
# Also here: the note's order of operations, its floors stopping the run before
# any crossing verb, and its release-scrub pass.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/crossing-note.bats < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$THIS_DIRECTORY/../../.." && pwd)"
  NOTE="$REPO_ROOT/.gaia/migrations/2.4.0.md"
  OLD_SELECTOR="$REPO_ROOT/.gaia/tests/fixtures/crossing/old-selector"
  CHECK="$REPO_ROOT/.gaia/scripts/toolchain-check.sh"
  FLOORS="$REPO_ROOT/.gaia/toolchain-floors.tsv"
  ABSOLUTE_BASH_PATH="$(command -v bash)"
}

# The tags whose select_notes the fixture copies, oldest first.
OLD_TAGS='v2.0.0 v2.3.0 v2.3.1'

# bundle_with <selector script> [<extra note version> <mode>]: a target bundle
# at $BUNDLE carrying this tree's notes, the given selector and the shared
# version comparison it loads from its own directory.
bundle_with() {
  BUNDLE="$BATS_TEST_TMPDIR/bundle"
  rm -rf "$BUNDLE"
  mkdir -p "$BUNDLE/.gaia/scripts/lib" "$BUNDLE/.gaia/migrations"
  cp "$REPO_ROOT"/.gaia/migrations/*.md "$BUNDLE/.gaia/migrations/"
  cp "$1" "$BUNDLE/.gaia/scripts/select-migration-notes.sh"
  cp "$REPO_ROOT/.gaia/scripts/lib/version-compare.awk" "$BUNDLE/.gaia/scripts/lib/"
  if [ "$#" -eq 3 ]; then
    printf -- '---\nmode: %s\n---\n\nbody\n' "$3" >"$BUNDLE/.gaia/migrations/$2.md"
  fi
}

# old_select <tag> <baseline> <target>: the tag's select_notes against $BUNDLE,
# with the variables its flag parse would set.
old_select() {
  run --separate-stderr "$ABSOLUTE_BASH_PATH" -c \
    '. "$1"; latest_dir="$2"; baseline="$3"; latest="$4"; select_notes' \
    _ "$OLD_SELECTOR/select-notes-$1.sh" "$BUNDLE" "$2" "$3"
}

# line_of <file> <fixed string>: the first line number holding it, or nothing.
line_of() {
  grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

# offset_of <file> <fixed string>: the character offset of its first
# occurrence, or nothing, so two parts on one line still order.
offset_of() {
  awk -v needle="$2" '{ text = text $0 "\n" } END { at = index(text, needle); if (at) print at }' "$1"
}

# bats test_tags=whole-tree
@test "each old select_notes copy, from either selector, stops a 2.x project at the blocking note" {
  local selector tag baseline expected
  for selector in "$OLD_SELECTOR/select-migration-notes.sh" "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh"; do
    bundle_with "$selector"
    old_select v2.0.0 2.0.0 2.4.0
    [ "$status" -eq 0 ]
    expected="$(printf 'AFTER_MERGE 2.3.0 %s\nBLOCKING 2.4.0 %s' "$BUNDLE/.gaia/migrations/2.3.0.md" "$BUNDLE/.gaia/migrations/2.4.0.md")"
    [ "$output" = "$expected" ]
    for tag in v2.3.0 v2.3.1; do
      baseline="${tag#v}"
      old_select "$tag" "$baseline" 2.4.0
      [ "$status" -eq 0 ]
      [ "$output" = "BLOCKING 2.4.0 $BUNDLE/.gaia/migrations/2.4.0.md" ]
    done
  done
}

# fixture_matches_tags <fixture dir>: status 0 when every copy equals its tag.
fixture_matches_tags() {
  local tag copies
  copies="$(find "$1" -name 'select-notes-v*.sh' | wc -l | tr -d ' ')"
  [ "$copies" -eq 3 ] || { echo "expected 3 select_notes copies, found $copies"; return 1; }
  for tag in $OLD_TAGS; do
    cmp -s \
      <(awk '/^select_notes\(\) \{/,/^}$/' "$1/select-notes-$tag.sh") \
      <(git -C "$REPO_ROOT" show "$tag:.gaia/scripts/update-gaia-preflight.sh" | awk '/^select_notes\(\) \{/,/^}$/') \
      || { echo "select_notes copy differs from $tag"; return 1; }
    cmp -s <(sed 2d "$1/select-migration-notes.sh") \
      <(git -C "$REPO_ROOT" show "$tag:.gaia/scripts/select-migration-notes.sh") \
      || { echo "selector copy differs from $tag"; return 1; }
  done
}

@test "the committed copies equal the tags they name, and a mutated copy fails the comparison" {
  local tag
  for tag in $OLD_TAGS; do
    git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null || skip "tag $tag absent in this checkout"
  done
  run fixture_matches_tags "$OLD_SELECTOR"
  [ "$status" -eq 0 ]
  cp -R "$OLD_SELECTOR" "$BATS_TEST_TMPDIR/mutated"
  sed -i.bak 's/echo "BLOCKING/echo "BLOCKED/' "$BATS_TEST_TMPDIR/mutated/select-notes-v2.3.0.sh"
  rm -f "$BATS_TEST_TMPDIR/mutated/select-notes-v2.3.0.sh.bak"
  run fixture_matches_tags "$BATS_TEST_TMPDIR/mutated"
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs from v2.3.0"* ]]
}

# bats test_tags=whole-tree
@test "a later target reaches the note, and its re-selection from 2.4.0 comes before the branch, with L the target bundle" {
  bundle_with "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" 2.4.1 after-merge
  old_select v2.3.1 2.3.1 2.4.1
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKING 2.4.0 $BUNDLE/.gaia/migrations/2.4.0.md" ]
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh" select-notes --latest-dir "$BUNDLE" --baseline 2.4.0 --latest 2.4.1
  [ "$status" -eq 0 ]
  [ "$output" = "AFTER_MERGE 2.4.1 $BUNDLE/.gaia/migrations/2.4.1.md" ]
  local reselection branch hop
  reselection="$(line_of "$NOTE" 'select-notes --latest-dir <bundle folder> --baseline 2.4.0 --latest <target>')"
  branch="$(line_of "$NOTE" 'branch-name-lib.sh name update')"
  [ -n "$reselection" ] && [ -n "$branch" ]
  [ "$reselection" -lt "$branch" ]
  grep -qF "L is the run's target bundle" "$NOTE"
  grep -qF 'gh release download' "$NOTE" && return 1
  grep -qF 'v2.4.0' "$NOTE" && return 1
  hop="$(line_of "$NOTE" '## The hop from below 2.4.0')"
  [ -n "$hop" ]
  tail -n "+$hop" "$NOTE" | grep -qiE 're-?runs? `/update-gaia`' && return 1
  true
}

# scratch_project: a committed git repository holding the project's copy of
# the preflight script, at $PROJECT.
scratch_project() {
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT/.gaia/scripts"
  cp "$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh" "$REPO_ROOT/.gaia/scripts/update-gaia-local-lib.sh" "$PROJECT/.gaia/scripts/"
  git -C "$PROJECT" init -q -b main
  git -C "$PROJECT" add .
  git -C "$PROJECT" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m init
}

# tree_state: HEAD, the branch list and the porcelain status of $PROJECT.
tree_state() {
  git -C "$PROJECT" rev-parse HEAD
  git -C "$PROJECT" for-each-ref --format='%(refname)' refs/heads
  git -C "$PROJECT" status --porcelain
}

# bats test_tags=whole-tree
@test "a later blocking note stops the note's re-selection before any branch is cut" {
  scratch_project
  bundle_with "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" 2.5.0 blocking
  local before command
  before="$(tree_state)"
  command="$(grep -F 'select-notes --latest-dir <bundle folder> --baseline 2.4.0 --latest <target>' "$NOTE")"
  [ -n "$command" ]
  command="${command//<bundle folder>/$BUNDLE}"
  command="${command//<target>/2.5.0}"
  local -a words
  read -r -a words <<<"$command"
  [ "${words[0]}" = bash ]
  cd "$PROJECT" || return 1
  run --separate-stderr "${words[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKING 2.5.0 $BUNDLE/.gaia/migrations/2.5.0.md" ]
  [ "$(tree_state)" = "$before" ]
  local stop branch
  stop="$(line_of "$NOTE" 'A `BLOCKING` line from it: stop before any merge')"
  branch="$(line_of "$NOTE" 'branch-name-lib.sh name update')"
  [ -n "$stop" ] && [ "$stop" -lt "$branch" ]
}

# note_carries_the_crossing <note>: status 0 when the note names every part of
# the crossing, with the ordered parts in order. Prints the first gap.
note_carries_the_crossing() {
  local needle offset previous=0
  local -a ordered=(
    '## Goal state'
    'select-notes --latest-dir <bundle folder> --baseline 2.4.0 --latest <target>'
    'update crossing preflight'
    'branch-name-lib.sh name update'
    '**Sweep.**'
    'update crossing roster'
    'run `pnpm install`'
    'Follow every persisted `AFTER_MERGE` line'
    'the `## Quality gate` section'
  )
  local -a present=(
    '### Goal state'
    'update crossing move'
    'update crossing rekey'
    'roster-prune-overbroad.sh'
    'GAIA_MANIFEST_WRITE=release'
    'Steps 9c, 9c2 and 9d'
    'Step 7e'
    'Steps 11 and 12'
    'the review point'
  )
  for needle in "${ordered[@]}"; do
    offset="$(offset_of "$1" "$needle")"
    [ -n "$offset" ] || { echo "missing: $needle"; return 1; }
    [ "$offset" -gt "$previous" ] || { echo "out of order: $needle"; return 1; }
    previous="$offset"
  done
  for needle in "${present[@]}"; do
    grep -qF -- "$needle" "$1" || { echo "missing: $needle"; return 1; }
  done
}

@test "the note names each part of the crossing in order, and a stub or a truncated note fails" {
  run note_carries_the_crossing "$NOTE"
  [ "$status" -eq 0 ]
  printf -- '---\nmode: blocking\n---\n\n## Goal state\n\nbody\n' >"$BATS_TEST_TMPDIR/stub.md"
  run note_carries_the_crossing "$BATS_TEST_TMPDIR/stub.md"
  [ "$status" -eq 1 ]
  local sweep
  sweep="$(line_of "$NOTE" '**Sweep.**')"
  head -n "$((sweep - 1))" "$NOTE" >"$BATS_TEST_TMPDIR/truncated.md"
  run note_carries_the_crossing "$BATS_TEST_TMPDIR/truncated.md"
  [ "$status" -eq 1 ]
  [ "$output" = 'missing: **Sweep.**' ]
  local notes_line
  notes_line="$(line_of "$NOTE" 'Follow every persisted `AFTER_MERGE` line')"
  awk -v sweep="$sweep" -v moved_line="$notes_line" \
    'NR == FNR { if (FNR == moved_line) moved = $0; next } FNR == sweep { print moved } FNR != moved_line { print }' \
    "$NOTE" "$NOTE" >"$BATS_TEST_TMPDIR/reordered.md"
  run note_carries_the_crossing "$BATS_TEST_TMPDIR/reordered.md"
  [ "$status" -eq 1 ]
  [[ "$output" == "out of order: "* ]]
}

@test "the note names no whole word warn, no working-document id and no machine-local path" {
  grep -qiw 'warn' "$NOTE" && return 1
  grep -qE '(SPEC|UAT|PLAN)-[0-9]' "$NOTE" && return 1
  grep -qE '(^|[^&[:alnum:]])#[0-9]+' "$NOTE" && return 1
  grep -qF '.notebook' "$NOTE" && return 1
  true
}

@test "the note passes the release scrub, and a leak in it fails" {
  local cli="$REPO_ROOT/.gaia/cli/gaia-maintainer" stage="$BATS_TEST_TMPDIR/stage"
  [ -x "$cli" ]
  mkdir -p "$stage/.gaia/migrations"
  cp "$NOTE" "$stage/.gaia/migrations/2.4.0.md"
  run "$cli" release scrub "$stage" --config "$REPO_ROOT/.gaia/release-scrub.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"leaks: none"* ]]
  printf 'See SPEC-123.\n' >>"$stage/.gaia/migrations/2.4.0.md"
  run "$cli" release scrub "$stage" --config "$REPO_ROOT/.gaia/release-scrub.yml"
  [ "$status" -ne 0 ]
}

# Floor rows: each tool the note's floors check, below its floor or missing,
# on an otherwise empty PATH that also carries a sentinel crossing command.
STUBS=''

stub() {
  printf '#!%s\nprintf "%%s\\n" "%s"\n' "$ABSOLUTE_BASH_PATH" "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

stub_floor_row() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  rm -rf "$STUBS"
  mkdir -p "$STUBS"
  stub git 'git version 2.56.0'
  stub jq 'jq-1.7.1'
  stub pnpm '12.11.2'
  stub lsof 'lsof 4.91'
  stub ss 'ss utility, iproute2-6.1.0'
  SENTINEL="$BATS_TEST_TMPDIR/crossing-ran"
  local name
  for name in gaia crossing; do
    printf '#!%s\ntouch "%s"\n' "$ABSOLUTE_BASH_PATH" "$SENTINEL" >"$STUBS/$name"
    chmod +x "$STUBS/$name"
  done
}

floor_of() {
  awk -F '\t' -v tool="$1" '$1 == tool { print $2 }' "$FLOORS"
}

# floor_row <tool> <expected line> <platform args...>: the check stops on the
# row, names the reason and the next step, and changes nothing.
floor_row() {
  local tool="$1" expected="$2" before
  shift 2
  before="$(tree_state)"
  cd "$PROJECT" || return 1
  run env -i PATH="$STUBS" "$ABSOLUTE_BASH_PATH" "$CHECK" "$@"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF -- "$expected"
  printf '%s\n' "$output" | grep -q "^GUIDE $tool: "
  [ "$(tree_state)" = "$before" ]
  [ ! -e "$SENTINEL" ]
}

@test "a floor below or missing stops the note before any crossing verb, naming the reason and next step" {
  scratch_project
  stub_floor_row
  stub git 'git version 2.39.5'
  floor_row git "BELOW git 2.39.5 $(floor_of git)" --platform darwin
  stub_floor_row
  stub jq 'jq-1.5'
  floor_row jq "BELOW jq 1.5 $(floor_of jq)" --platform darwin
  stub_floor_row
  stub pnpm '11.2.0'
  floor_row pnpm "BELOW pnpm 11.2.0 $(floor_of pnpm)" --platform darwin
  stub_floor_row
  rm "$STUBS/lsof"
  floor_row lsof 'MISSING lsof -' --platform darwin
  stub_floor_row
  rm "$STUBS/ss"
  floor_row ss 'MISSING ss -' --platform linux --os-id debian
}
