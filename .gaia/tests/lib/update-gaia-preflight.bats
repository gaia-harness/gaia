#!/usr/bin/env bats
# .gaia/scripts/update-gaia-preflight.sh: the /update-gaia steps that run before
# the merge (1.x refusal, bundle download and verification, migration note
# selection, CHANGELOG range, prune of prior-run artifacts) as subcommands.
# Each runs against fixtures under $BATS_TEST_TMPDIR with stub `gh` and `curl`
# executables, from a fixture project root as the working directory. Every
# absence pin has a red twin: a fixture copy carrying the forbidden content, or
# missing the required content.
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

verify_bundles_setup() {
  export FIXTURE_RELEASES="$BATS_TEST_TMPDIR/releases"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GH_LOG"
  write_release v2.0.0
  write_release v2.1.0
  write_stub_gh
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT"
  CACHE="$PROJECT/.gaia/local/cache/shared/update-gaia"
}

run_verify_bundles() {
  run_preflight verify-bundles --baseline 2.0.0 --latest-tag v2.1.0
}

@test "verify-bundles: fresh downloads verify and extract both bundles" {
  verify_bundles_setup
  run_verify_bundles
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.0.0'
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.1.0'
  printf '%s\n' "$output" | grep -qxF 'LATEST_DIR=.gaia/local/cache/shared/update-gaia/v2.1.0/tree'
  printf '%s\n' "$output" | grep -qxF 'BASELINE_DIR=.gaia/local/cache/shared/update-gaia/v2.0.0/tree'
  [ "$(cat "$CACHE/v2.0.0/tree/.gaia/VERSION")" = 2.0.0 ]
  [ "$(cat "$CACHE/v2.1.0/tree/.gaia/VERSION")" = 2.1.0 ]
  [ "$(grep -c . "$GH_LOG")" -eq 2 ]
}

@test "verify-bundles: a freshly downloaded mismatched checksum stops with VERIFY_FAILED and removes the tag" {
  verify_bundles_setup
  printf '%064d  gaia-bundle-v2.1.0.tar.gz\n' 0 > "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256"
  run_verify_bundles
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFY_FAILED v2.1.0'
  [ -e "$CACHE/v2.1.0" ] && return 1
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.1.0' && return 1
  true
}

@test "verify-bundles: a cached tarball that no longer matches its checksum stops with VERIFY_FAILED" {
  verify_bundles_setup
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
  true
}

@test "verify-bundles: a cached tree with an edited note or a stray file is replaced by a pristine extract" {
  verify_bundles_setup
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
}

@test "verify-bundles: a legacy cache directory without a checksum is removed, downloaded and verified" {
  verify_bundles_setup
  mkdir -p "$CACHE/v2.0.0/.gaia"
  printf 'legacy\n' > "$CACHE/v2.0.0/.gaia/VERSION"
  cp "$FIXTURE_RELEASES/v2.0.0/gaia-bundle-v2.0.0.tar.gz" "$CACHE/v2.0.0/"
  run_verify_bundles
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.0.0'
  grep -qxF v2.0.0 "$GH_LOG"
  [ -f "$CACHE/v2.0.0/gaia-bundle-v2.0.0.tar.gz.sha256" ]
  [ -e "$CACHE/v2.0.0/.gaia" ] && return 1
  true
}

@test "verify-bundles: a release without the checksum asset stops with CHECKSUM_MISSING" {
  verify_bundles_setup
  rm -f "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256"
  run_verify_bundles
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'CHECKSUM_MISSING v2.1.0'
  [ -e "$CACHE/v2.1.0" ] && return 1
  true
}

@test "verify-bundles: a release the fetch cannot reach stops with FETCH_FAILED" {
  verify_bundles_setup
  rm -rf "$FIXTURE_RELEASES/v2.1.0"
  run_verify_bundles
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'FETCH_FAILED v2.1.0'
  [ -e "$CACHE/v2.1.0" ] && return 1
  true
}

@test "verify-bundles: a checklist naming another file never vouches for the tarball" {
  verify_bundles_setup
  hex="$(shasum -a 256 "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256" | awk '{ print $1 }')"
  printf '%s  gaia-bundle-v2.1.0.tar.gz.sha256\n' "$hex" > "$BATS_TEST_TMPDIR/other.sha256"
  cp "$BATS_TEST_TMPDIR/other.sha256" "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256"
  run_verify_bundles
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFY_FAILED v2.1.0'
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.1.0' && return 1
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

@test "select-notes: after-merge notes print in version order with no BLOCKING" {
  make_bundle 2.2.0:after-merge 2.1.0:after-merge 2.0.0:after-merge
  run_select_notes 2.0.0 2.2.0
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "AFTER_MERGE 2.1.0 $BUNDLE/.gaia/migrations/2.1.0.md" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "AFTER_MERGE 2.2.0 $BUNDLE/.gaia/migrations/2.2.0.md" ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  printf '%s\n' "$output" | grep -qF BLOCKING && return 1
  true
}

@test "select-notes: a blocking note names its path inside the bundle and lists the after-merge notes below it" {
  make_bundle 2.2.0:after-merge 2.3.0:blocking
  run_select_notes 2.1.0 2.3.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "AFTER_MERGE 2.2.0 $BUNDLE/.gaia/migrations/2.2.0.md"
  printf '%s\n' "$output" | grep -qxF "BLOCKING 2.3.0 $BUNDLE/.gaia/migrations/2.3.0.md"
}

@test "select-notes: the first blocking note wins and later notes are left for the next run" {
  make_bundle 2.2.0:blocking 2.3.0:blocking 2.4.0:after-merge
  run_select_notes 2.1.0 2.4.0
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKING 2.2.0 $BUNDLE/.gaia/migrations/2.2.0.md" ]
}

@test "select-notes: a malformed note stops with NOTES_FAILED and a next step" {
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

# 0 when script text in file `$1` holds no git call, no rm, no .gaia/VERSION
# and no spawn inside its select_notes function.
select_notes_is_read_only() {
  local body
  body="$(awk '/^select_notes\(\) \{$/ { inside = 1 } inside { print } inside && /^}$/ { exit }' "$1")"
  [ -n "$body" ] || return 1
  printf '%s\n' "$body" | grep -qF 'git ' && return 1
  printf '%s\n' "$body" | grep -qF 'rm ' && return 1
  printf '%s\n' "$body" | grep -qF '.gaia/VERSION' && return 1
  printf '%s\n' "$body" | grep -qiE 'spawn|Agent\(' && return 1
  return 0
}

@test "select-notes: the step changes nothing, and a copy that writes the version is reported" {
  select_notes_is_read_only "$PREFLIGHT"
  copy="$BATS_TEST_TMPDIR/preflight-copy.sh"
  for forbidden in 'echo x > .gaia/VERSION' 'git switch main' 'rm -rf .gaia-backup'; do
    awk -v extra="  $forbidden" '{ print } /^select_notes\(\) \{$/ { print extra }' "$PREFLIGHT" > "$copy"
    select_notes_is_read_only "$copy" && { echo "not reported: $forbidden" >&2; return 1; }
  done
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

# 0 when script `$1` calls the selector through anything but the --latest-dir
# value: a non-comment line naming the selector that does not spell the bundle
# path. Also 0 when no line calls it through the bundle at all, because a
# script that never reads the target's selector is just as wrong.
selector_call_is_wrong() {
  local named bundled
  named="$(grep -v '^[[:space:]]*#' "$1" | grep -F 'select-migration-notes.sh' || true)"
  bundled="$(printf '%s\n' "$named" | grep -cF '"$latest_dir/.gaia/scripts/select-migration-notes.sh"' || true)"
  [ "$bundled" -ge 1 ] || return 0
  printf '%s\n' "$named" | grep -vF '"$latest_dir/.gaia/scripts/select-migration-notes.sh"' | grep -q . && return 0
  return 1
}

@test "select-notes: the script calls the selector only through the bundle, and a copy calling this repository's is reported" {
  selector_call_is_wrong "$PREFLIGHT" && return 1
  copy="$BATS_TEST_TMPDIR/preflight-own-selector.sh"
  { cat "$PREFLIGHT"; printf '%s\n' 'bash .gaia/scripts/select-migration-notes.sh "$latest_dir" "$baseline" "$latest"'; } > "$copy"
  selector_call_is_wrong "$copy"
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

run_changelog() {
  run env CURL_FIXTURE="${1:-}" PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'cd "$1" || exit 99; bash "$2" changelog --baseline 2.0.0 --latest 2.1.0 --latest-tag v2.1.0' _ "$PROJECT" "$PREFLIGHT"
}

@test "changelog: a fetched range is saved beside the verified target bundle" {
  changelog_setup
  run_changelog "$BATS_TEST_TMPDIR/CHANGELOG.md"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF '## [2.1.0]'
  grep -qxF '## [2.1.0]' "$CACHE/v2.1.0/changelog-range.md"
  grep -qxF -- '- dropped `pnpm remove left-pad`' "$CACHE/v2.1.0/changelog-range.md"
  grep -qxF '## [2.0.0]' "$CACHE/v2.1.0/changelog-range.md" && return 1
  true
}

@test "changelog: a failed fetch leaves no saved range, removing one an earlier run saved" {
  changelog_setup
  printf 'stale\n' > "$CACHE/v2.1.0/changelog-range.md"
  run_changelog
  [ -e "$CACHE/v2.1.0/changelog-range.md" ] && return 1
  true
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

@test "prune: keeps the verified baseline and target and the populated merge folder" {
  make_prune_fixture
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0
  [ "$status" -eq 0 ]
  [ "$(ls "$PROJECT/.gaia/local/cache/shared/update-gaia" | tr '\n' ' ')" = 'v2.0.0 v2.1.0 ' ]
  [ -e "$PROJECT/.gaia-backup" ] && return 1
  [ -f "$PROJECT/.gaia-merge/a.patch" ]
  printf '%s\n' "$output" | grep -qF 'Heads up: .gaia-merge/ still holds unresolved patches'
  printf '%s\n' "$output" | grep -qxF 'a.patch'
}

@test "prune: a resumed run keeps .gaia-backup" {
  make_prune_fixture
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0 --resume
  [ "$status" -eq 0 ]
  [ -d "$PROJECT/.gaia-backup/20200101-000000" ]
  [ "$(ls "$PROJECT/.gaia/local/cache/shared/update-gaia" | tr '\n' ' ')" = 'v2.0.0 v2.1.0 ' ]
}

@test "prune: an empty merge folder is removed" {
  make_prune_fixture
  rm -f "$PROJECT/.gaia-merge/a.patch"
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0
  [ "$status" -eq 0 ]
  [ -e "$PROJECT/.gaia-merge" ] && return 1
  true
}

@test "prune: files one level above the tag directories survive" {
  make_prune_fixture
  printf '{}\n' > "$PROJECT/.gaia/local/cache/shared/update-check.json"
  mkdir -p "$PROJECT/.gaia/local/cache/shared/serena-guard"
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.gaia/local/cache/shared/update-check.json" ]
  [ -d "$PROJECT/.gaia/local/cache/shared/serena-guard" ]
}

# --- refuse-1x and usage ---------------------------------------------------------

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

# The subcommands and their required flags, as `subcommand:flag flag ...`.
required_flag_table() {
  printf '%s\n' \
    'refuse-1x:--baseline' \
    'verify-bundles:--baseline --latest-tag' \
    'select-notes:--latest-dir --baseline --latest' \
    'changelog:--baseline --latest --latest-tag' \
    'prune:--baseline --latest-tag'
}

@test "usage: an unknown subcommand, no arguments and an unknown flag exit 2" {
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT"
  run_preflight bogus --baseline 2.0.0
  [ "$status" -eq 2 ]
  run_preflight
  [ "$status" -eq 2 ]
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0 --bogus
  [ "$status" -eq 2 ]
  # A flag with no value is a usage error too.
  run_preflight prune --baseline 2.0.0 --latest-tag
  [ "$status" -eq 2 ]
}

@test "usage: each missing required flag exits 2" {
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT"
  checked=0
  while IFS=: read -r subcommand flags; do
    for omitted in $flags; do
      arguments=()
      for flag in $flags; do
        [ "$flag" = "$omitted" ] && continue
        arguments+=("$flag" x)
      done
      run_preflight "$subcommand" "${arguments[@]}"
      [ "$status" -eq 2 ] || { echo "$subcommand without $omitted exited $status" >&2; return 1; }
      checked=$((checked + 1))
    done
  done <<EOF
$(required_flag_table)
EOF
  # 1 + 2 + 3 + 3 + 2 omissions.
  [ "$checked" -eq 11 ]
}
