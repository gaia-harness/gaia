#!/usr/bin/env bats
# .gaia/scripts/update-gaia-preflight.sh with dev tags: a locally built bundle
# (tag v<core>-dev.<sha>) resolves from the update cache only, never through
# `gh`, as the target, as a recorded-build baseline and as a deferred item's
# extra baseline, and prune keeps a dev baseline named by --baseline-tag. Also
# pins that the release path is unchanged and that no update script ranks tags
# with `sort -V`. Fixtures live under $BATS_TEST_TMPDIR with a stub `gh` that
# logs every call; every absence pin has a red twin.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  PREFLIGHT="$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh"
  DECISIONS="$REPO_ROOT/.gaia/scripts/update-decisions.sh"
  BRANCH_STATE="$REPO_ROOT/.gaia/scripts/update-gaia-branch-state.sh"
  PROJECT="$BATS_TEST_TMPDIR/project"
  CACHE="$PROJECT/.gaia/local/cache/shared/update-gaia"
  CACHE_PREFIX=.gaia/local/cache/shared/update-gaia
  FIXTURE_RELEASES="$BATS_TEST_TMPDIR/releases"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export FIXTURE_RELEASES GH_LOG
  DEV_A=v2.2.0-dev.aaaaaaaaaaaa
  DEV_B=v2.2.0-dev.bbbbbbbbbbbb
  DEV_C=v2.2.0-dev.cccccccccccc
  mkdir -p "$PROJECT" "$BATS_TEST_TMPDIR/bin"
  : > "$GH_LOG"
}

run_preflight() {
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'cd "$1" || exit 99; script="$2"; shift 2; bash "$script" "$@"' _ "$PROJECT" "$PREFLIGHT" "$@"
}

# A release fixture under $FIXTURE_RELEASES/<tag>/ with a matching checksum.
write_release() {
  local tag="$1" stage="$BATS_TEST_TMPDIR/stage/$1" assets="$FIXTURE_RELEASES/$1" hex
  mkdir -p "$stage/gaia-$tag/.gaia" "$assets"
  printf '%s\n' "${tag#v}" > "$stage/gaia-$tag/.gaia/VERSION"
  tar -czf "$assets/gaia-bundle-$tag.tar.gz" -C "$stage" "gaia-$tag"
  hex="$(shasum -a 256 "$assets/gaia-bundle-$tag.tar.gz" | awk '{ print $1 }')"
  printf '%s  gaia-bundle-%s.tar.gz\n' "$hex" "$tag" > "$assets/gaia-bundle-$tag.tar.gz.sha256"
}

# A stub gh that serves the release fixtures and logs the tag.
write_serving_gh() {
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

# A stub gh with no network: every call is logged and fails.
write_failing_gh() {
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
exit 1
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# Seeds the cache entry of dev tag `$1` the way a local source step leaves it:
# the tarball, a locally computed checksum, top directory gaia-<tag>/.
seed_dev() {
  local tag="$1" stage="$BATS_TEST_TMPDIR/stage/$1" hex
  mkdir -p "$stage/gaia-$tag/.gaia" "$CACHE/$tag"
  printf '%s\n' "$tag" > "$stage/gaia-$tag/.gaia/VERSION"
  tar -czf "$CACHE/$tag/gaia-bundle-$tag.tar.gz" -C "$stage" "gaia-$tag"
  hex="$(shasum -a 256 "$CACHE/$tag/gaia-bundle-$tag.tar.gz" | awk '{ print $1 }')"
  printf '%s  gaia-bundle-%s.tar.gz\n' "$hex" "$tag" > "$CACHE/$tag/gaia-bundle-$tag.tar.gz.sha256"
}

# --- verify-bundles --------------------------------------------------------------

@test "verify-bundles: a cached dev target beside a release baseline verifies locally and downloads only the baseline" {
  write_release v2.2.0
  write_serving_gh
  seed_dev "$DEV_A"
  run_preflight verify-bundles --baseline 2.2.0 --latest-tag "$DEV_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'VERIFIED v2.2.0\nVERIFIED_LOCAL %s\nBASELINE_DIR=%s/v2.2.0/tree\nLATEST_DIR=%s/%s/tree' "$DEV_A" "$CACHE_PREFIX" "$CACHE_PREFIX" "$DEV_A")" ]
  [ "$(cat "$GH_LOG")" = v2.2.0 ]
  [ "$(cat "$CACHE/$DEV_A/tree/.gaia/VERSION")" = "$DEV_A" ]
}

@test "verify-bundles: with no network a cached dev target succeeds and an uncached one reports CACHE_MISSING, neither calling gh for it" {
  write_release v2.2.0
  write_serving_gh
  seed_dev "$DEV_A"
  run_preflight verify-bundles --baseline 2.2.0 --latest-tag "$DEV_A"
  [ "$status" -eq 0 ]
  write_failing_gh
  : > "$GH_LOG"
  run_preflight verify-bundles --baseline 2.2.0 --latest-tag "$DEV_A"
  [ "$status" -eq 0 ]
  grep -q 'dev' "$GH_LOG" && return 1
  run_preflight verify-bundles --baseline 2.2.0 --latest-tag "$DEV_B"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF "CACHE_MISSING $DEV_B"
  grep -q 'dev' "$GH_LOG" && return 1
  true
}

@test "verify-bundles: a missing dev tag removes nothing already cached" {
  write_failing_gh
  seed_dev "$DEV_A"
  run_preflight verify-bundles --baseline 2.2.0 --baseline-tag "$DEV_A" --latest-tag "$DEV_B"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF "CACHE_MISSING $DEV_B"
  [ -f "$CACHE/$DEV_A/gaia-bundle-$DEV_A.tar.gz" ]
}

@test "verify-bundles: a dev baseline from --baseline-tag and a dev target make no gh call" {
  write_failing_gh
  seed_dev "$DEV_A"
  seed_dev "$DEV_B"
  run_preflight verify-bundles --baseline 2.2.0 --baseline-tag "$DEV_A" --latest-tag "$DEV_B"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "BASELINE_DIR=$CACHE_PREFIX/$DEV_A/tree"
  printf '%s\n' "$output" | grep -qxF "LATEST_DIR=$CACHE_PREFIX/$DEV_B/tree"
  printf '%s\n' "$output" | grep -qxF "VERIFIED_LOCAL $DEV_A"
  printf '%s\n' "$output" | grep -qxF "VERIFIED_LOCAL $DEV_B"
  [ ! -s "$GH_LOG" ]
}

@test "verify-bundles: a tampered cached dev bundle fails verification and removes only its own directory" {
  write_failing_gh
  seed_dev "$DEV_A"
  seed_dev "$DEV_B"
  printf 'tampered' >> "$CACHE/$DEV_B/gaia-bundle-$DEV_B.tar.gz"
  run_preflight verify-bundles --baseline 2.2.0 --baseline-tag "$DEV_A" --latest-tag "$DEV_B"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF "VERIFY_FAILED $DEV_B"
  printf '%s\n' "$output" | grep -qxF "VERIFIED_LOCAL $DEV_B" && return 1
  [ -e "$CACHE/$DEV_B" ] && return 1
  [ -f "$CACHE/$DEV_A/gaia-bundle-$DEV_A.tar.gz" ]
}

@test "verify-bundles: a deferred item's dev baseline resolves from the cache as an extra directory" {
  write_release v2.2.0
  write_serving_gh
  seed_dev "$DEV_A"
  seed_dev "$DEV_B"
  run_preflight verify-bundles --baseline 2.2.0 --latest-tag "$DEV_B" --extra-tag "$DEV_A"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "EXTRA_DIR=$DEV_A:$CACHE_PREFIX/$DEV_A/tree"
  grep -q 'dev' "$GH_LOG" && return 1
  run_preflight verify-bundles --baseline 2.2.0 --latest-tag "$DEV_B" --extra-tag "$DEV_C"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF "CACHE_MISSING $DEV_C"
  grep -q 'dev' "$GH_LOG" && return 1
  true
}

@test "verify-bundles: a release run is byte-identical with no dev tag and no baseline flag" {
  write_release v2.0.0
  write_release v2.1.0
  write_serving_gh
  run_preflight verify-bundles --baseline 2.0.0 --latest-tag v2.1.0
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'VERIFIED v2.0.0\nVERIFIED v2.1.0\nBASELINE_DIR=%s/v2.0.0/tree\nLATEST_DIR=%s/v2.1.0/tree' "$CACHE_PREFIX" "$CACHE_PREFIX")" ]
}

# --- prune -----------------------------------------------------------------------

seed_prune_cache() {
  local name
  for name in "$@"; do
    mkdir -p "$CACHE/$name"
    : > "$CACHE/$name/marker"
  done
}

cache_listing() {
  ls "$CACHE" | tr '\n' ' '
}

@test "prune: --baseline-tag keeps a dev baseline on a release run and its absence removes it" {
  seed_prune_cache "$DEV_A" v2.3.0 v2.1.0 run
  run_preflight prune --baseline 2.2.0 --latest-tag v2.3.0 --baseline-tag "$DEV_A"
  [ "$status" -eq 0 ]
  [ "$(cache_listing)" = "$DEV_A v2.3.0 " ]
  rm -rf "$CACHE"
  seed_prune_cache "$DEV_A" v2.3.0 v2.1.0 run
  run_preflight prune --baseline 2.2.0 --latest-tag v2.3.0
  [ "$status" -eq 0 ]
  [ "$(cache_listing)" = "v2.3.0 " ]
}

@test "prune: a local run keeps its dev target and dev baseline, and a dev keep-tag only when named" {
  seed_prune_cache "$DEV_A" "$DEV_B" "$DEV_C" run
  run_preflight prune --baseline 2.2.0 --latest-tag "$DEV_B" --baseline-tag "$DEV_A" --keep-tag "$DEV_C"
  [ "$status" -eq 0 ]
  [ "$(cache_listing)" = "$DEV_A $DEV_B $DEV_C " ]
  rm -rf "$CACHE"
  seed_prune_cache "$DEV_A" "$DEV_B" "$DEV_C" run
  run_preflight prune --baseline 2.2.0 --latest-tag "$DEV_B" --baseline-tag "$DEV_A"
  [ "$status" -eq 0 ]
  [ "$(cache_listing)" = "$DEV_A $DEV_B " ]
}

@test "prune: the release path with --keep-tag keeps exactly the baseline, target and kept tag" {
  seed_prune_cache v2.0.0 v2.1.0 v2.0.5 v1.9.0 run
  run_preflight prune --baseline 2.0.0 --latest-tag v2.1.0 --keep-tag v2.0.5
  [ "$status" -eq 0 ]
  [ "$(cache_listing)" = "v2.0.0 v2.0.5 v2.1.0 " ]
}

# --- --baseline-tag validation ---------------------------------------------------

@test "a malformed --baseline-tag is a usage error that touches no cache path" {
  local bad subcommand
  seed_prune_cache v2.0.0 run
  for bad in v2.2 ../x 'v2.2.0/..'; do
    for subcommand in verify-bundles prune; do
      run_preflight "$subcommand" --baseline 2.2.0 --latest-tag v2.3.0 --baseline-tag "$bad"
      [ "$status" -eq 2 ]
    done
  done
  [ "$(cache_listing)" = "run v2.0.0 " ]
  [ ! -e "$CACHE/v2.3.0" ]
}

# --- ranking and the sort -V ban -------------------------------------------------

@test "deferred-tags ranks a dev tag between its predecessor and its plain release" {
  local log="$BATS_TEST_TMPDIR/decisions.json"
  printf '%s\n' "{\"schemaVersion\": 1, \"decisions\": [{\"path\": \"a.md\", \"decision\": \"deferred\", \"tag\": \"v2.2.0\", \"baselineTag\": \"v2.2.0\"}, {\"path\": \"b.md\", \"decision\": \"deferred\", \"tag\": \"v2.2.0\", \"baselineTag\": \"$DEV_A\"}, {\"path\": \"c.md\", \"decision\": \"deferred\", \"tag\": \"v2.2.0\", \"baselineTag\": \"v2.1.0\"}]}" > "$log"
  run bash "$DECISIONS" deferred-tags --file "$log"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'v2.1.0\n%s\nv2.2.0' "$DEV_A")" ]
}

@test "sort -V does not rank a dev tag below its plain release, which is why it is banned for tags" {
  local ranked
  ranked="$(printf '%s\n' v2.2.0 "$DEV_A" v2.1.0 | sort -V | tr '\n' ' ')"
  [ "$ranked" != "v2.1.0 $DEV_A v2.2.0 " ]
}

# Prints the non-comment lines of the file at `$1` that hold the flag pair.
sort_version_code_lines() {
  grep -v '^[[:space:]]*#' "$1" | grep -F 'sort -V' || true
}

@test "no update script ranks tags with sort -V on a code line" {
  local script scanned=0
  for script in "$PREFLIGHT" "$DECISIONS" "$BRANCH_STATE"; do
    [ -f "$script" ]
    scanned=$((scanned + 1))
    [ -z "$(sort_version_code_lines "$script")" ]
  done
  [ "$scanned" -eq 3 ]
}

@test "the sort -V scan finds a code line that carries it" {
  local copy="$BATS_TEST_TMPDIR/scratch-preflight.sh"
  cp "$PREFLIGHT" "$copy"
  printf '%s\n' 'tags | sort -V' >> "$copy"
  [ -n "$(sort_version_code_lines "$copy")" ]
}

# --- the verify comment states the trust invariant -------------------------------

has_trust_comment() {
  grep -qF 'release .sha256 asset' "$1" \
    && grep -qF 'computed locally' "$1" \
    && grep -qF 'never authenticity' "$1"
}

@test "the verify comment says release bundles verify against the release checksum asset and a local checksum never proves authenticity" {
  has_trust_comment "$PREFLIGHT"
}

@test "the trust comment check fails on a copy with the comment removed" {
  local copy="$BATS_TEST_TMPDIR/scratch-preflight.sh"
  grep -vF 'never authenticity' "$PREFLIGHT" > "$copy"
  has_trust_comment "$copy" && return 1
  true
}

# --- existing suites stay unmodified ---------------------------------------------

@test "the existing preflight, flow and release-asset-name suites are unmodified" {
  run git -C "$REPO_ROOT" diff --quiet -- .gaia/tests/lib/update-gaia-preflight.bats .gaia/tests/lib/update-gaia-flow.bats .gaia/tests/lib/release-asset-name.bats
  [ "$status" -eq 0 ]
}
