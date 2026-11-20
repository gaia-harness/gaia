#!/usr/bin/env bats
# .gaia/scripts/update-gaia-local.sh `baseline` and `notes-not-run`, the
# version ranking helper in update-gaia-local-lib.sh, the selector boundary a
# local sync relies on (an unreleased blocking note is never selected), and the
# ban on ranking tags with `sort -V`. Fixtures live under $BATS_TEST_TMPDIR; the
# script runs from a fixture project root.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  LOCAL_SCRIPT="$REPO_ROOT/.gaia/scripts/update-gaia-local.sh"
  LOCAL_LIB="$REPO_ROOT/.gaia/scripts/update-gaia-local-lib.sh"
  PREFLIGHT="$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh"
  PROJECT="$BATS_TEST_TMPDIR/project"
  CACHE="$PROJECT/.gaia/local/cache/shared/update-gaia"
  SHA=0123456789ab
  mkdir -p "$PROJECT/.gaia"
}

run_local() {
  run bash -c 'cd "$1" || exit 99; shift; bash "$@"' _ "$PROJECT" "$LOCAL_SCRIPT" "$@"
}

project_at() {
  printf '%s\n' "$1" > "$PROJECT/.gaia/VERSION"
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2" > "$PROJECT/.gaia/VERSION-dev"
  fi
}

# Writes a complete cache entry (tarball and checksum) for the tag.
cache_entry() {
  mkdir -p "$CACHE/$1"
  printf 'bytes\n' > "$CACHE/$1/gaia-bundle-$1.tar.gz"
  printf '%064d  gaia-bundle-%s.tar.gz\n' 0 "$1" > "$CACHE/$1/gaia-bundle-$1.tar.gz.sha256"
}

# A bundle tree carrying the selector and the notes named by "<version>:<mode>"
# arguments.
make_notes_tree() {
  local tree="$BATS_TEST_TMPDIR/notes-tree" note
  mkdir -p "$tree/.gaia/scripts/lib" "$tree/.gaia/migrations"
  cp "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" "$tree/.gaia/scripts/"
  cp "$REPO_ROOT/.gaia/scripts/lib/version-compare.awk" "$tree/.gaia/scripts/lib/"
  for note in "$@"; do
    printf -- '---\nmode: %s\n---\n\nbody\n' "${note#*:}" > "$tree/.gaia/migrations/${note%%:*}.md"
  done
}

# Clears the fixture project's version files and cache between table cases.
reset_project() {
  rm -rf "$PROJECT"
  mkdir -p "$PROJECT/.gaia"
}

# bats test_tags=protected
@test "baseline resolves the release tag, a recorded build or its fallback, reports a stale record, and refuses a malformed record or version" {
  echo "case: a project with no build record gets only the release tag"
  project_at 2.2.0
  run_local baseline
  [ "$status" -eq 0 ]
  [ "$output" = "BASELINE_TAG=v2.2.0" ]

  echo "case: a cached recorded build is the baseline"
  reset_project
  project_at 2.2.0 "dev.$SHA"
  cache_entry "v2.2.0-dev.$SHA"
  run_local baseline
  [ "$status" -eq 0 ]
  [ "$output" = "BASELINE_TAG=v2.2.0-dev.$SHA
RECORDED_BUILD dev.$SHA" ]
  echo "case: an uncached recorded build falls back by id"
  rm -rf "$CACHE"
  run_local baseline
  [ "$status" -eq 0 ]
  [ "$output" = "BASELINE_TAG=v2.2.0
BASELINE_FALLBACK dev.$SHA" ]

  echo "case: a recorded build cached under another core is reported stale"
  reset_project
  project_at 2.3.0 "dev.$SHA"
  cache_entry "v2.2.0-dev.$SHA"
  run_local baseline
  [ "$status" -eq 0 ]
  [ "$output" = "BASELINE_TAG=v2.3.0
RECORDED_BUILD_STALE dev.$SHA 2.2.0" ]

  echo "case: a cache directory without its checksum does not count as cached"
  reset_project
  project_at 2.2.0 "dev.$SHA"
  cache_entry "v2.2.0-dev.$SHA"
  rm "$CACHE/v2.2.0-dev.$SHA/gaia-bundle-v2.2.0-dev.$SHA.tar.gz.sha256"
  run_local baseline
  [ "$status" -eq 0 ]
  [ "$output" = "BASELINE_TAG=v2.2.0
BASELINE_FALLBACK dev.$SHA" ]

  reset_project
  project_at 2.2.0
  cache_entry "v2.2.0-dev.$SHA"
  local shape
  for shape in 'dev.0/../../x' 'dev.XYZ' '' "dev.$SHA
dev.$SHA"; do
    echo "case: a malformed or traversal-shaped build record '$shape' is refused and the cache is untouched"
    printf '%s\n' "$shape" > "$PROJECT/.gaia/VERSION-dev"
    run_local baseline
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" | grep -qxF 'BUILD_ID_INVALID .gaia/VERSION-dev'
    printf '%s\n' "$output" | grep -q '^Next step:'
    [ -f "$CACHE/v2.2.0-dev.$SHA/gaia-bundle-v2.2.0-dev.$SHA.tar.gz" ]
  done

  echo "case: a malformed project version is refused"
  reset_project
  project_at 2.2
  run_local baseline
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'VERSION_INVALID .gaia/VERSION'
  printf '%s\n' "$output" | grep -q '^Next step:'
}

@test "lib: version ranking is numeric by component" {
  run bash -c '. "$1"; gaia_local_version_below 2.1.9 2.2.0 && gaia_local_version_below 2.2.0 2.10.0 && ! gaia_local_version_below 2.2.0 2.2.0 && ! gaia_local_version_below 2.10.0 2.9.0' _ "$LOCAL_LIB"
  [ "$status" -eq 0 ]
}

# bats test_tags=protected
@test "lib: build id and dev tag validators accept the shape and refuse the rest" {
  run bash -c '
    . "$1"
    gaia_local_is_build_id dev.0123456789ab || exit 1
    gaia_local_is_build_id dev.0123456 || exit 2
    gaia_local_is_build_id dev.012345 && exit 3
    gaia_local_is_build_id dev.0123456/../x && exit 4
    gaia_local_is_build_id "$(printf "dev.0123456\ndev.0123456")" && exit 5
    gaia_local_is_dev_tag v2.2.0-dev.0123456789ab || exit 6
    gaia_local_is_dev_tag v2.2.0 && exit 7
    gaia_local_is_dev_tag v02.2.0-dev.0123456789ab && exit 8
    [ "$(gaia_local_tag_for 2.2.0 dev.0123456789ab)" = v2.2.0-dev.0123456789ab ] || exit 9
  ' _ "$LOCAL_LIB"
  [ "$status" -eq 0 ]
}

@test "notes-not-run lists every note above the core ascending and stops on a malformed note" {
  local tree="$BATS_TEST_TMPDIR/notes-tree"
  echo "case: lists every note above the core, blocking ones included, ascending"
  make_notes_tree 2.1.0:after-merge 2.2.0:after-merge 2.3.0:blocking 2.4.0:after-merge
  run_local notes-not-run --latest-dir "$tree" --core 2.2.0
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_RUN 2.3.0 blocking $tree/.gaia/migrations/2.3.0.md
NOT_RUN 2.4.0 after-merge $tree/.gaia/migrations/2.4.0.md" ]
  echo "case: a malformed note stops with NOTES_FAILED"
  printf 'no frontmatter\n' > "$tree/.gaia/migrations/2.4.0.md"
  run_local notes-not-run --latest-dir "$tree" --core 2.2.0
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'NOTES_FAILED'
  printf '%s\n' "$output" | grep -q '^Next step:'
  printf '%s\n' "$output" | grep -q '^NOT_RUN' && return 1
  true
}

@test "selector boundary: a local sync selects the bundle's own release notes and never an unreleased blocking one" {
  make_notes_tree 2.1.0:after-merge 2.2.0:after-merge 2.3.0:blocking
  local tree="$BATS_TEST_TMPDIR/notes-tree"
  run env PATH="$PATH" bash -c 'cd "$1" || exit 99; shift; bash "$@"' _ "$PROJECT" "$PREFLIGHT" select-notes --latest-dir "$tree" --baseline 2.1.0 --latest 2.2.0
  [ "$status" -eq 0 ]
  [ "$output" = "AFTER_MERGE 2.2.0 $tree/.gaia/migrations/2.2.0.md" ]
  run env PATH="$PATH" bash -c 'cd "$1" || exit 99; shift; bash "$@"' _ "$PROJECT" "$PREFLIGHT" select-notes --latest-dir "$tree" --baseline 2.2.0 --latest 2.2.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf '%s\n' "$output" | grep -q 'BLOCKING 2.3.0' && return 1
  true
}

# The ranking ban reads only code lines: the lib header explains the ban in a
# comment, which must stay legal.
code_lines_naming_sort_v() {
  grep -v '^[[:space:]]*#' "$@" | grep -qF 'sort -V'
}

@test "ranking ban: neither new script ranks tags with sort -V" {
  [ -s "$LOCAL_SCRIPT" ]
  [ -s "$LOCAL_LIB" ]
  code_lines_naming_sort_v "$LOCAL_SCRIPT" && return 1
  code_lines_naming_sort_v "$LOCAL_LIB" && return 1
  true
}
