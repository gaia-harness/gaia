#!/usr/bin/env bats
# .gaia/scripts/update-gaia-preflight.sh: the /update-gaia steps that run before
# the merge (1.x refusal, bundle download and verification, migration note
# selection, CHANGELOG range, prune of prior-run artifacts) as subcommands.
# Each runs against fixtures under $BATS_TEST_TMPDIR with stub `gh` and `curl`
# executables, from a fixture project root as the working directory.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]]; POSIX [ ] and grep; `&& return 1` for a non-final absence.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  PREFLIGHT="$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh"
  SELECTOR="$REPO_ROOT/.gaia/scripts/select-migration-notes.sh"
  COMPARE_LIB="$REPO_ROOT/.gaia/scripts/lib/version-compare.awk"
}

# Runs the script at `$1` with the rest of the arguments, from the fixture
# project root as the working directory, with the stub executables first on
# PATH.
run_preflight_at() {
  local script="$1"
  shift
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'cd "$1" || exit 99; script="$2"; shift 2; bash "$script" "$@"' _ "$PROJECT" "$script" "$@"
}

run_preflight() {
  run_preflight_at "$PREFLIGHT" "$@"
}

# Prints a table case's label so a failing case names itself in the bats output.
start_case() {
  printf 'case: %s\n' "$1"
}

# --- verify-bundles --------------------------------------------------------------

# Writes a release fixture for tag `$1` under $FIXTURE_RELEASES/<tag>/: the
# tarball (a staging top directory holding a note and VERSION) and a matching
# checksum file.
write_release() {
  local tag="$1" stage="$BATS_TEST_TMPDIR/stage/$1" assets="$FIXTURE_RELEASES/$1" hex
  mkdir -p "$stage/gaia-$tag/.gaia/migrations" "$assets"
  printf '%s\n' "${tag#v}" > "$stage/gaia-$tag/.gaia/VERSION"
  printf -- '---\nmode: after-merge\n---\n\npristine\n' > "$stage/gaia-$tag/.gaia/migrations/${tag#v}.md"
  tar -czf "$assets/gaia-bundle-$tag.tar.gz" -C "$stage" "gaia-$tag"
  hex="$(shasum -a 256 "$assets/gaia-bundle-$tag.tar.gz" | awk '{ print $1 }')"
  printf '%s  gaia-bundle-%s.tar.gz\n' "$hex" "$tag" > "$assets/gaia-bundle-$tag.tar.gz.sha256"
}

# A stub gh: `release download <tag> ... --dir <dir>` copies the fixture
# assets for <tag> and logs the tag to $GH_LOG.
write_stub_gh() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = release ] && [ "$2" = download ] || exit 2
tag="$3"
target=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) target="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$tag" >> "$GH_LOG"
[ -d "$FIXTURE_RELEASES/$tag" ] || exit 1
mkdir -p "$target"
cp "$FIXTURE_RELEASES/$tag"/* "$target"/
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# Builds the release fixtures for the tags given once, into a pristine folder
# that verify_case copies for each case, since cases edit or remove assets.
verify_bundles_setup() {
  local tag
  export FIXTURE_RELEASES="$BATS_TEST_TMPDIR/pristine-releases"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  for tag in "$@"; do
    write_release "$tag"
  done
  export FIXTURE_RELEASES="$BATS_TEST_TMPDIR/releases"
  write_stub_gh
  PROJECT="$BATS_TEST_TMPDIR/project"
  CACHE="$PROJECT/.gaia/local/cache/shared/update-gaia"
}

# Starts a verify-bundles case on an empty project, an empty gh log and a fresh
# copy of the pristine releases.
verify_case() {
  start_case "$1"
  rm -rf "$PROJECT" "$FIXTURE_RELEASES"
  mkdir -p "$PROJECT"
  cp -R "$BATS_TEST_TMPDIR/pristine-releases" "$FIXTURE_RELEASES"
  : > "$GH_LOG"
}

run_verify_bundles() {
  run_preflight verify-bundles --baseline 2.0.0 --latest-tag v2.1.0
}

# bats test_tags=protected
@test "verify-bundles verifies fresh and cached bundles and refuses a bad checksum, missing checksum, unreachable release or foreign checklist" {
  verify_bundles_setup v2.0.0 v2.1.0

  verify_case 'fresh downloads verify and extract both bundles'
  run_verify_bundles
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.0.0'
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.1.0'
  printf '%s\n' "$output" | grep -qxF 'LATEST_DIR=.gaia/local/cache/shared/update-gaia/v2.1.0/tree'
  printf '%s\n' "$output" | grep -qxF 'BASELINE_DIR=.gaia/local/cache/shared/update-gaia/v2.0.0/tree'
  [ "$(cat "$CACHE/v2.0.0/tree/.gaia/VERSION")" = 2.0.0 ]
  [ "$(cat "$CACHE/v2.1.0/tree/.gaia/VERSION")" = 2.1.0 ]
  [ "$(grep -c . "$GH_LOG")" -eq 2 ]

  verify_case 'a freshly downloaded mismatched checksum stops with VERIFY_FAILED and removes the tag'
  printf '%064d  gaia-bundle-v2.1.0.tar.gz\n' 0 > "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256"
  run_verify_bundles
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFY_FAILED v2.1.0'
  [ -e "$CACHE/v2.1.0" ] && return 1
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.1.0' && return 1

  verify_case 'a cached tarball that no longer matches its checksum stops with VERIFY_FAILED'
  run_verify_bundles
  [ "$status" -eq 0 ]
  printf 'tampered' >> "$CACHE/v2.0.0/gaia-bundle-v2.0.0.tar.gz"
  : > "$GH_LOG"
  run_verify_bundles
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFY_FAILED v2.0.0'
  [ -e "$CACHE/v2.0.0" ] && return 1
  # The cached pair was reused, not downloaded again.
  grep -qxF v2.0.0 "$GH_LOG" && return 1

  verify_case 'a cached tree with an edited note or a stray file is replaced by a pristine extract'
  run_verify_bundles
  [ "$status" -eq 0 ]
  note="$CACHE/v2.1.0/tree/.gaia/migrations/2.1.0.md"
  printf 'edited\n' >> "$note"
  printf 'stray\n' > "$CACHE/v2.1.0/tree/.gaia/migrations/2.2.0.md"
  : > "$GH_LOG"
  run_verify_bundles
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.1.0'
  grep -qF edited "$note" && return 1
  [ -e "$CACHE/v2.1.0/tree/.gaia/migrations/2.2.0.md" ] && return 1
  grep -qF pristine "$note"
  # Reuse skipped only the download.
  [ ! -s "$GH_LOG" ]

  verify_case 'a legacy cache directory without a checksum is removed, downloaded and verified'
  mkdir -p "$CACHE/v2.0.0/.gaia"
  printf 'legacy\n' > "$CACHE/v2.0.0/.gaia/VERSION"
  cp "$FIXTURE_RELEASES/v2.0.0/gaia-bundle-v2.0.0.tar.gz" "$CACHE/v2.0.0/"
  run_verify_bundles
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.0.0'
  grep -qxF v2.0.0 "$GH_LOG"
  [ -f "$CACHE/v2.0.0/gaia-bundle-v2.0.0.tar.gz.sha256" ]
  [ -e "$CACHE/v2.0.0/.gaia" ] && return 1

  verify_case 'a release without the checksum asset stops with CHECKSUM_MISSING'
  rm -f "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256"
  run_verify_bundles
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'CHECKSUM_MISSING v2.1.0'
  [ -e "$CACHE/v2.1.0" ] && return 1

  verify_case 'a release the fetch cannot reach stops with FETCH_FAILED'
  rm -rf "$FIXTURE_RELEASES/v2.1.0"
  run_verify_bundles
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'FETCH_FAILED v2.1.0'
  [ -e "$CACHE/v2.1.0" ] && return 1

  verify_case 'a checklist naming another file never vouches for the tarball'
  hex="$(shasum -a 256 "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256" | awk '{ print $1 }')"
  printf '%s  gaia-bundle-v2.1.0.tar.gz.sha256\n' "$hex" > "$BATS_TEST_TMPDIR/other.sha256"
  cp "$BATS_TEST_TMPDIR/other.sha256" "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256"
  run_verify_bundles
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFY_FAILED v2.1.0'
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.1.0' && return 1
  true
}

# bats test_tags=protected
@test "verify-bundles handles an extra tag: verified, fetched once, unreachable, mismatched or not a version" {
  verify_bundles_setup v2.0.0 v2.1.0

  verify_case 'an extra tag is verified, extracted and named after LATEST_DIR'
  write_release v2.0.4
  run_preflight verify-bundles --baseline 2.0.0 --latest-tag v2.1.0 --extra-tag v2.0.4
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.0.4'
  [ "$(printf '%s\n' "$output" | grep -c '^EXTRA_DIR=')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -n 1)" = 'EXTRA_DIR=v2.0.4:.gaia/local/cache/shared/update-gaia/v2.0.4/tree' ]
  [ "$(printf '%s\n' "$output" | tail -n 2 | head -n 1)" = 'LATEST_DIR=.gaia/local/cache/shared/update-gaia/v2.1.0/tree' ]
  [ "$(cat "$CACHE/v2.0.4/tree/.gaia/VERSION")" = 2.0.4 ]

  verify_case 'an extra tag equal to the baseline is fetched once'
  run_preflight verify-bundles --baseline 2.0.0 --latest-tag v2.1.0 --extra-tag v2.0.0 --extra-tag v2.0.0
  [ "$status" -eq 0 ]
  [ "$(grep -cxF v2.0.0 "$GH_LOG")" -eq 1 ]
  [ "$(grep -c . "$GH_LOG")" -eq 2 ]
  printf '%s\n' "$output" | grep -qxF 'EXTRA_DIR=v2.0.0:.gaia/local/cache/shared/update-gaia/v2.0.0/tree'

  verify_case 'an extra tag the fetch cannot reach stops with FETCH_FAILED and removes that tag'
  run_preflight verify-bundles --baseline 2.0.0 --latest-tag v2.1.0 --extra-tag v2.0.4
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'FETCH_FAILED v2.0.4'
  [ -e "$CACHE/v2.0.4" ] && return 1
  printf '%s\n' "$output" | grep -qF 'EXTRA_DIR=' && return 1

  verify_case 'an extra tag with a mismatched checksum stops with VERIFY_FAILED'
  write_release v2.0.4
  printf '%064d  gaia-bundle-v2.0.4.tar.gz\n' 0 > "$FIXTURE_RELEASES/v2.0.4/gaia-bundle-v2.0.4.tar.gz.sha256"
  run_preflight verify-bundles --baseline 2.0.0 --latest-tag v2.1.0 --extra-tag v2.0.4
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFY_FAILED v2.0.4'
  [ -e "$CACHE/v2.0.4" ] && return 1

  verify_case 'an extra tag that is not a version exits 2 before any gh call'
  for bad in latest 2.0.4 'v2.0' 'v2.0.4;x' 'v2.0.4/../x'; do
    run_preflight verify-bundles --baseline 2.0.0 --latest-tag v2.1.0 --extra-tag "$bad"
    [ "$status" -eq 2 ] || { echo "$bad exited $status" >&2; return 1; }
  done
  [ ! -s "$GH_LOG" ]
  [ -e "$CACHE" ] && return 1
  true
}

# --- select-notes ------------------------------------------------------------------

# A fixture verified bundle holding the repository's own selector and the
# notes given as version:mode pairs.
make_bundle() {
  BUNDLE="$BATS_TEST_TMPDIR/bundle"
  rm -rf "$BUNDLE"
  mkdir -p "$BUNDLE/.gaia/scripts/lib" "$BUNDLE/.gaia/migrations"
  cp "$SELECTOR" "$BUNDLE/.gaia/scripts/select-migration-notes.sh"
  cp "$COMPARE_LIB" "$BUNDLE/.gaia/scripts/lib/version-compare.awk"
  local pair
  for pair in "$@"; do
    printf -- '---\nmode: %s\n---\n\nnote\n' "${pair#*:}" > "$BUNDLE/.gaia/migrations/${pair%%:*}.md"
  done
}

run_select_notes() {
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT"
  run_preflight select-notes --latest-dir "$BUNDLE" --baseline "$1" --latest "$2"
}

@test "select-notes prints after-merge notes in order, the first blocking note, and NOTES_FAILED on a malformed note" {
  start_case 'after-merge notes print in version order with no BLOCKING'
  make_bundle 2.2.0:after-merge 2.1.0:after-merge 2.0.0:after-merge
  run_select_notes 2.0.0 2.2.0
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "AFTER_MERGE 2.1.0 $BUNDLE/.gaia/migrations/2.1.0.md" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "AFTER_MERGE 2.2.0 $BUNDLE/.gaia/migrations/2.2.0.md" ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  printf '%s\n' "$output" | grep -qF BLOCKING && return 1

  start_case 'a blocking note names its path inside the bundle and lists the after-merge notes below it'
  make_bundle 2.2.0:after-merge 2.3.0:blocking
  run_select_notes 2.1.0 2.3.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "AFTER_MERGE 2.2.0 $BUNDLE/.gaia/migrations/2.2.0.md"
  printf '%s\n' "$output" | grep -qxF "BLOCKING 2.3.0 $BUNDLE/.gaia/migrations/2.3.0.md"

  start_case 'the first blocking note wins and later notes are left for the next run'
  make_bundle 2.2.0:blocking 2.3.0:blocking 2.4.0:after-merge
  run_select_notes 2.1.0 2.4.0
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKING 2.2.0 $BUNDLE/.gaia/migrations/2.2.0.md" ]

  start_case 'a malformed note stops with NOTES_FAILED and a next step'
  make_bundle 2.2.0:after-merge
  printf 'no frontmatter\n' > "$BUNDLE/.gaia/migrations/2.3.0.md"
  run_select_notes 2.1.0 2.2.0
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF NOTES_FAILED
  printf '%s\n' "$output" | grep -qF "select-migration-notes: $BUNDLE/.gaia/migrations/2.3.0.md"
  printf '%s\n' "$output" | grep -qF 'Next step:'
  printf '%s\n' "$output" | grep -qF AFTER_MERGE && return 1
  true
}

@test "select-notes: a mode only the target's selector knows is accepted, while this repository's selector rejects it" {
  make_bundle
  awk '{ print } /^    "mode: after-merge"\) mode="after-merge" ;;$/ { print "    \"mode: future\") mode=\"future\" ;;" }' \
    "$SELECTOR" > "$BUNDLE/.gaia/scripts/select-migration-notes.sh"
  grep -qF '"mode: future"' "$BUNDLE/.gaia/scripts/select-migration-notes.sh"
  printf -- '---\nmode: future\n---\n\nnote\n' > "$BUNDLE/.gaia/migrations/2.1.0.md"
  run_select_notes 2.0.0 2.1.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "BLOCKING 2.1.0 $BUNDLE/.gaia/migrations/2.1.0.md"
  # Control: this repository's selector rejects the same folder.
  run bash "$SELECTOR" "$BUNDLE" 2.0.0 2.1.0
  [ "$status" -eq 1 ]
}

# --- changelog -------------------------------------------------------------------

# A project holding the range walk, a verified-cache directory for v2.1.0, and
# stub curl and gh executables. The stub curl prints $CURL_FIXTURE, or fails
# when it is unset; the stub gh always fails.
changelog_setup() {
  PROJECT="$BATS_TEST_TMPDIR/project"
  CACHE="$PROJECT/.gaia/local/cache/shared/update-gaia"
  mkdir -p "$PROJECT/.gaia/scripts/lib" "$CACHE/v2.1.0/tree" "$BATS_TEST_TMPDIR/bin"
  cp "$REPO_ROOT/.gaia/scripts/changelog-range.sh" "$PROJECT/.gaia/scripts/"
  cp "$COMPARE_LIB" "$PROJECT/.gaia/scripts/lib/"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FIXTURE:-}" ] || exit 22
cat "$CURL_FIXTURE"
STUB
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl" "$BATS_TEST_TMPDIR/bin/gh"
  printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '## [2.1.0]' '' '### Removed' '' '- dropped `pnpm remove left-pad`' '' '## [2.0.0]' '' '- base' > "$BATS_TEST_TMPDIR/CHANGELOG.md"
}

# Starts a changelog case on an empty project.
changelog_case() {
  start_case "$1"
  rm -rf "$BATS_TEST_TMPDIR/project"
}

run_changelog() {
  run env CURL_FIXTURE="${1:-}" PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'cd "$1" || exit 99; bash "$2" changelog --baseline 2.0.0 --latest 2.1.0 --latest-tag v2.1.0' _ "$PROJECT" "$PREFLIGHT"
}

@test "changelog saves the range beside the verified target, honors --save-from and clears a stale file on failure" {
  changelog_case 'a fetched range is saved beside the verified target bundle'
  changelog_setup
  run_changelog "$BATS_TEST_TMPDIR/CHANGELOG.md"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF '## [2.1.0]'
  grep -qxF '## [2.1.0]' "$CACHE/v2.1.0/changelog-range.md"
  grep -qxF -- '- dropped `pnpm remove left-pad`' "$CACHE/v2.1.0/changelog-range.md"
  grep -qxF '## [2.0.0]' "$CACHE/v2.1.0/changelog-range.md" && return 1

  changelog_case 'a failed fetch leaves no saved range, removing one an earlier run saved'
  changelog_setup
  printf 'stale\n' > "$CACHE/v2.1.0/changelog-range.md"
  run_changelog
  [ -e "$CACHE/v2.1.0/changelog-range.md" ] && return 1

  changelog_case '--save-from saves the wider range and prints only the baseline-to-latest range'
  wide_changelog_setup
  run_changelog_save_from 2.0.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF '## [2.0.5]'
  printf '%s\n' "$output" | grep -qxF '## [2.0.7]'
  printf '%s\n' "$output" | grep -qxF '## [2.0.4]' && return 1
  printf '%s\n' "$output" | grep -qxF '## [2.0.1]' && return 1
  saved="$CACHE/v2.0.7/changelog-range.md"
  [ "$(grep -c '^## \[' "$saved")" -eq 7 ]
  grep -qxF '## [2.0.1]' "$saved"
  grep -qxF '## [2.0.4]' "$saved"
  grep -qxF '## [2.0.0]' "$saved" && return 1

  changelog_case 'a prerelease --save-from saves the same file as its core version'
  wide_changelog_setup
  run_changelog_save_from 2.0.0
  cp "$CACHE/v2.0.7/changelog-range.md" "$BATS_TEST_TMPDIR/core-range.md"
  rm -f "$CACHE/v2.0.7/changelog-range.md"
  run_changelog_save_from 2.0.0-rc.1
  [ "$status" -eq 0 ]
  cmp "$CACHE/v2.0.7/changelog-range.md" "$BATS_TEST_TMPDIR/core-range.md"

  changelog_case 'a --save-from that is not a version exits 2 and saves nothing'
  wide_changelog_setup
  run_changelog_save_from latest
  [ "$status" -eq 2 ]
  [ -e "$CACHE/v2.0.7/changelog-range.md" ] && return 1

  changelog_case 'without --save-from the saved file is the printed range'
  wide_changelog_setup
  run env CURL_FIXTURE="$BATS_TEST_TMPDIR/CHANGELOG-wide.md" PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'cd "$1" || exit 99; bash "$2" changelog --baseline 2.0.4 --latest 2.0.7 --latest-tag v2.0.7' _ "$PROJECT" "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output")" = "$(cat "$CACHE/v2.0.7/changelog-range.md")" ]
}

run_changelog_save_from() {
  run env CURL_FIXTURE="$BATS_TEST_TMPDIR/CHANGELOG-wide.md" PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'cd "$1" || exit 99; bash "$2" changelog --baseline 2.0.4 --latest 2.0.7 --latest-tag v2.0.7 --save-from "$3"' _ "$PROJECT" "$PREFLIGHT" "$1"
}

wide_changelog_setup() {
  changelog_setup
  mkdir -p "$CACHE/v2.0.7/tree"
  : > "$BATS_TEST_TMPDIR/CHANGELOG-wide.md"
  local version
  printf '%s\n' '# Changelog' '' '## [Unreleased]' '' >> "$BATS_TEST_TMPDIR/CHANGELOG-wide.md"
  for version in 2.0.7 2.0.6 2.0.5 2.0.4 2.0.3 2.0.2 2.0.1 2.0.0; do
    printf '## [%s]\n\n- change %s\n\n' "$version" "$version" >> "$BATS_TEST_TMPDIR/CHANGELOG-wide.md"
  done
}

# --- prune -----------------------------------------------------------------------

make_prune_fixture() {
  PROJECT="$BATS_TEST_TMPDIR/prune"
  rm -rf "$PROJECT"
  local tag
  for tag in v2.0.0 v2.1.0 v1.9.0 v2.0.5; do
    mkdir -p "$PROJECT/.gaia/local/cache/shared/update-gaia/$tag/tree"
  done
  mkdir -p "$PROJECT/.gaia-backup/20200101-000000" "$PROJECT/.gaia-merge"
  printf 'patch\n' > "$PROJECT/.gaia-merge/a.patch"
}

# bats test_tags=protected
@test "prune keeps the baseline, target and named keep-tags, leaves .gaia-merge and cache siblings, and refuses a non-version keep-tag" {
  start_case 'keeps the verified baseline and target and removes other cached tags'
  make_prune_fixture
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0
  [ "$status" -eq 0 ]
  [ "$(ls "$PROJECT/.gaia/local/cache/shared/update-gaia" | tr '\n' ' ')" = 'v2.0.0 v2.1.0 ' ]
  [ -e "$PROJECT/.gaia-backup" ] && return 1

  start_case '--keep-tag keeps that tag directory and removes the leftover run directory'
  make_prune_fixture
  mkdir -p "$PROJECT/.gaia/local/cache/shared/update-gaia/run/candidates"
  printf '{}\n' > "$PROJECT/.gaia/local/cache/shared/update-gaia/run/report.json"
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0 --keep-tag v2.0.5
  [ "$status" -eq 0 ]
  [ "$(ls "$PROJECT/.gaia/local/cache/shared/update-gaia" | tr '\n' ' ')" = 'v2.0.0 v2.0.5 v2.1.0 ' ]

  start_case 'a tag not named by --keep-tag is removed, and a repeated --keep-tag keeps each'
  make_prune_fixture
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0 --keep-tag v2.0.5 --keep-tag v1.9.0
  [ "$status" -eq 0 ]
  [ "$(ls "$PROJECT/.gaia/local/cache/shared/update-gaia" | tr '\n' ' ')" = 'v1.9.0 v2.0.0 v2.0.5 v2.1.0 ' ]

  start_case 'a --keep-tag that is not a version exits 2 and removes nothing'
  make_prune_fixture
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0 --keep-tag latest
  [ "$status" -eq 2 ]
  [ -d "$PROJECT/.gaia/local/cache/shared/update-gaia/v1.9.0" ]
  [ -d "$PROJECT/.gaia-backup" ]

  start_case 'a populated .gaia-merge folder is left exactly as it was, with no warning'
  make_prune_fixture
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/.gaia-merge/a.patch")" = patch ]
  [ "$(ls -A "$PROJECT/.gaia-merge")" = a.patch ]
  printf '%s\n' "$output" | grep -qF 'Heads up' && return 1
  [ -z "$output" ]

  start_case 'a resumed run keeps .gaia-backup'
  make_prune_fixture
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0 --resume
  [ "$status" -eq 0 ]
  [ -d "$PROJECT/.gaia-backup/20200101-000000" ]
  [ "$(ls "$PROJECT/.gaia/local/cache/shared/update-gaia" | tr '\n' ' ')" = 'v2.0.0 v2.1.0 ' ]

  start_case 'files one level above the tag directories survive'
  make_prune_fixture
  printf '{}\n' > "$PROJECT/.gaia/local/cache/shared/update-check.json"
  mkdir -p "$PROJECT/.gaia/local/cache/shared/migrate-2"
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.gaia/local/cache/shared/update-check.json" ]
  [ -d "$PROJECT/.gaia/local/cache/shared/migrate-2" ]
}

# --- refuse-1x -------------------------------------------------------------------

@test "refuse-1x: a 1.x baseline is refused and a 2.x baseline proceeds silently" {
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT"
  run_preflight refuse-1x --baseline 1.6.1
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'REFUSED'
  run_preflight refuse-1x --baseline 2.0.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
