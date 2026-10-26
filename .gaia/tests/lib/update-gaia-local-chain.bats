#!/usr/bin/env bats
# The /update-gaia local-bundle scripts chained the way the skill calls them,
# across successive runs on one fixture project and one shared update cache:
# update-gaia-local.sh (source, baseline), update-gaia-preflight.sh
# (verify-bundles, prune), update-decisions.sh (record, reconcile,
# deferred-tags) and update-gaia-branch-state.sh (classify). The merge itself is
# agent-driven; this suite drives everything that decides what the merge reads
# (BASELINE_DIR, LATEST_DIR, EXTRA_DIR), what survives prune, what the decision
# log carries and what the record step leaves behind. The record step is
# simulated with the writes the skill prescribes, then committed, so the next
# run starts from the recorded state. Bundles are packed by hand in the release
# shape; the builder is not called. A stub `gh` serves the release fixtures and
# logs every call, so any network use is visible. Every absence pin has a red
# twin: the same fixture one step from the guarded state.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup_file() {
  local repo_root base
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  MERGE_BASE="$(git -C "$repo_root" merge-base HEAD origin/main 2>/dev/null || true)"
  base="$BATS_FILE_TMPDIR/merge-base/.gaia/scripts"
  if [ -n "$MERGE_BASE" ]; then
    mkdir -p "$base"
    git -C "$repo_root" show "$MERGE_BASE:.gaia/scripts/update-gaia-preflight.sh" > "$base/update-gaia-preflight.sh"
    git -C "$repo_root" show "$MERGE_BASE:.gaia/scripts/update-gaia-branch-state.sh" > "$base/update-gaia-branch-state.sh"
    git -C "$repo_root" show "$MERGE_BASE:.gaia/scripts/main-root-lib.sh" > "$base/main-root-lib.sh"
  fi
  export MERGE_BASE
}

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  MERGE_BASE_SCRIPTS="$BATS_FILE_TMPDIR/merge-base/.gaia/scripts"
  mkdir -p "$BATS_TEST_TMPDIR/project" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/bundles"
  PROJECT="$(cd "$BATS_TEST_TMPDIR/project" && pwd -P)"
  CACHE="$PROJECT/.gaia/local/cache/shared/update-gaia"
  CACHE_PREFIX=.gaia/local/cache/shared/update-gaia
  FIXTURE_RELEASES="$BATS_TEST_TMPDIR/releases"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export FIXTURE_RELEASES GH_LOG
  BUILD_A=dev.aaaaaaaaaaaa
  BUILD_B=dev.bbbbbbbbbbbb
  BUILD_C=dev.cccccccccccc
  BUILD_D=dev.dddddddddddd
  TAG_A=v2.2.0-dev.aaaaaaaaaaaa
  TAG_B=v2.2.0-dev.bbbbbbbbbbbb
  TAG_D=v2.2.0-dev.dddddddddddd
  : > "$GH_LOG"
  write_serving_gh
}

# --- fixtures ---------------------------------------------------------------------

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

# A release fixture under $FIXTURE_RELEASES/<tag>/ with a matching checksum.
write_release() {
  local tag="$1" stage="$BATS_TEST_TMPDIR/stage/$1" assets="$FIXTURE_RELEASES/$1" hex
  mkdir -p "$stage/gaia-$tag/.gaia" "$stage/gaia-$tag/docs" "$assets"
  printf '%s\n' "${tag#v}" > "$stage/gaia-$tag/.gaia/VERSION"
  printf 'release %s\n' "$tag" > "$stage/gaia-$tag/docs/shipped.md"
  tar -czf "$assets/gaia-bundle-$tag.tar.gz" -C "$stage" "gaia-$tag"
  hex="$(shasum -a 256 "$assets/gaia-bundle-$tag.tar.gz" | awk '{ print $1 }')"
  printf '%s  gaia-bundle-%s.tar.gz\n' "$hex" "$tag" > "$assets/gaia-bundle-$tag.tar.gz.sha256"
}

# make_bundle <name> <core> <build id> <shipped file content>: a local bundle in
# the release shape (one top directory, the version files, a manifest, the
# migration-note selector and its awk helper) at $BATS_TEST_TMPDIR/bundles/<name>.tar.gz.
make_bundle() {
  local name="$1" core="$2" build="$3" shipped="$4" top
  top="$BATS_TEST_TMPDIR/trees/$name/gaia-v$core-$build"
  mkdir -p "$top/.gaia/scripts/lib" "$top/docs"
  printf '%s\n' "$core" > "$top/.gaia/VERSION"
  printf '%s\n' "$build" > "$top/.gaia/VERSION-dev"
  printf '{}\n' > "$top/.gaia/manifest.json"
  cp "$SCRIPTS/select-migration-notes.sh" "$top/.gaia/scripts/select-migration-notes.sh"
  cp "$SCRIPTS/lib/version-compare.awk" "$top/.gaia/scripts/lib/version-compare.awk"
  printf '%s\n' "$shipped" > "$top/docs/shipped.md"
  tar -czf "$BATS_TEST_TMPDIR/bundles/$name.tar.gz" -C "$BATS_TEST_TMPDIR/trees/$name" "gaia-v$core-$build"
}

make_bundles() {
  make_bundle A 2.2.0 "$BUILD_A" 'shipped by A'
  make_bundle B 2.2.0 "$BUILD_B" 'shipped by B'
  make_bundle C 2.1.0 "$BUILD_C" 'shipped by C'
  make_bundle D 2.2.0 "$BUILD_D" 'shipped by D'
}

# Commits everything in tree `$1` with message `$2` at epoch `$3`.
commit_in() {
  git -C "$1" add -A
  GIT_AUTHOR_DATE="@$3" GIT_COMMITTER_DATE="@$3" \
    git -C "$1" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false \
    commit -q --allow-empty -m "$2"
}

# Makes directory `$1` a fixture project at core `$2`, committed, with the
# machine-local directory ignored the way a real project ignores it.
make_project() {
  mkdir -p "$1/.gaia"
  git init -q -b main "$1"
  printf '%s\n' "$2" > "$1/.gaia/VERSION"
  printf '.gaia/local/\n' > "$1/.gitignore"
  commit_in "$1" 'project' 1700000000
}

# The record step of a local sync, as the skill prescribes, committed.
record_local() {
  printf '%s\n' "$1" > "$PROJECT/.gaia/VERSION"
  printf '%s\n' "$2" > "$PROJECT/.gaia/VERSION-dev"
  commit_in "$PROJECT" "record $2" "${3:-1700000100}"
}

# The record step of a release sync: version write, then the build file removal.
record_release() {
  printf '%s\n' "$1" > "$PROJECT/.gaia/VERSION"
  rm -f "$PROJECT/.gaia/VERSION-dev"
  commit_in "$PROJECT" "release $1" "${2:-1700000200}"
}

# Runs script `$1` of directory `$2` from directory `$3` with the stub gh first
# on PATH; the remaining arguments go to the script.
run_script_from() {
  local script="$1" scripts_dir="$2" directory="$3"
  shift 3
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'cd "$1" || exit 99; script="$2"; shift 2; exec bash "$script" "$@"' _ "$directory" "$scripts_dir/$script" "$@"
}

run_local() { run_script_from update-gaia-local.sh "$SCRIPTS" "$PROJECT" "$@"; }
run_preflight() { run_script_from update-gaia-preflight.sh "$SCRIPTS" "$PROJECT" "$@"; }
run_decisions() { run_script_from update-decisions.sh "$SCRIPTS" "$PROJECT" "$@"; }
run_classify() { run_script_from update-gaia-branch-state.sh "$SCRIPTS" "$PROJECT" classify "$@"; }

cache_listing() {
  ls "$CACHE" | tr '\n' ' '
}

six_lines() {
  local core="$1" build="$2" sha
  sha="${build#dev.}"
  printf '%s\n' "LOCAL_SOURCE unverified" "LOCAL_TAG=v$core-$build" "LOCAL_CORE=$core" "LOCAL_BUILD=$build" "LOCAL_COMMIT=$sha" "LATEST_DIR=$CACHE_PREFIX/v$core-$build/tree"
}

# Sources bundle `$1` and expects the six lines for its core `$2` and build `$3`.
source_ok() {
  run_local source --tarball "$BATS_TEST_TMPDIR/bundles/$1.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines "$2" "$3")" ]
}

# Local runs 1 and 2 done: A then B sourced and recorded in turn.
reach_b_recorded() {
  make_project "$PROJECT" 2.2.0
  make_bundles
  source_ok A 2.2.0 "$BUILD_A"
  record_local 2.2.0 "$BUILD_A"
  source_ok B 2.2.0 "$BUILD_B"
  record_local 2.2.0 "$BUILD_B" 1700000300
}

# --- 1. local sync from a release -----------------------------------------------

@test "local sync from a release: the baseline is the release, the target comes from the cache and gh sees the baseline only" {
  make_project "$PROJECT" 2.2.0
  make_bundles
  write_release v2.2.0
  source_ok A 2.2.0 "$BUILD_A"
  run_local baseline
  [ "$status" -eq 0 ]
  [ "$output" = 'BASELINE_TAG=v2.2.0' ]
  run_preflight verify-bundles --baseline 2.2.0 --latest-tag "$TAG_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'VERIFIED v2.2.0\nVERIFIED_LOCAL %s\nBASELINE_DIR=%s/v2.2.0/tree\nLATEST_DIR=%s/%s/tree' "$TAG_A" "$CACHE_PREFIX" "$CACHE_PREFIX" "$TAG_A")" ]
  [ "$(cat "$GH_LOG")" = v2.2.0 ]
  [ "$(cat "$CACHE/$TAG_A/tree/.gaia/VERSION-dev")" = "$BUILD_A" ]
  record_local 2.2.0 "$BUILD_A"
  [ "$(cat "$PROJECT/.gaia/VERSION")" = 2.2.0 ]
  [ "$(cat "$PROJECT/.gaia/VERSION-dev")" = "$BUILD_A" ]
}

# --- 2. a second local build on the same version --------------------------------

@test "second local build on the same version proceeds, merges against the recorded build and never calls gh" {
  make_project "$PROJECT" 2.2.0
  make_bundles
  source_ok A 2.2.0 "$BUILD_A"
  record_local 2.2.0 "$BUILD_A"
  source_ok B 2.2.0 "$BUILD_B"
  run_local baseline
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'BASELINE_TAG=%s\nRECORDED_BUILD %s' "$TAG_A" "$BUILD_A")" ]
  run_preflight verify-bundles --baseline 2.2.0 --baseline-tag "$TAG_A" --latest-tag "$TAG_B"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'VERIFIED_LOCAL %s\nVERIFIED_LOCAL %s\nBASELINE_DIR=%s/%s/tree\nLATEST_DIR=%s/%s/tree' "$TAG_A" "$TAG_B" "$CACHE_PREFIX" "$TAG_A" "$CACHE_PREFIX" "$TAG_B")" ]
  [ ! -s "$GH_LOG" ]
  local diffs names
  diffs="$(diff -rq "$CACHE/$TAG_A/tree" "$CACHE/$TAG_B/tree" || true)"
  [ "$(printf '%s\n' "$diffs" | wc -l | tr -d ' ')" -eq 2 ]
  names="$(printf '%s\n' "$diffs" | sed -n "s|^Files $CACHE/$TAG_A/tree/\\(.*\\) and .* differ\$|\\1|p" | sort | tr '\n' ' ')"
  [ "$names" = '.gaia/VERSION-dev docs/shipped.md ' ]
}

@test "second local build: a bundle identical to the recorded one is not a second build (red twin of the proceed pin)" {
  make_project "$PROJECT" 2.2.0
  make_bundles
  source_ok A 2.2.0 "$BUILD_A"
  record_local 2.2.0 "$BUILD_A"
  run_local source --tarball "$BATS_TEST_TMPDIR/bundles/A.tar.gz"
  [ "$output" = "ALREADY_SYNCED $BUILD_A" ]
  run_local source --tarball "$BATS_TEST_TMPDIR/bundles/B.tar.gz"
  [ "$output" != "ALREADY_SYNCED $BUILD_B" ]
  [ "$output" = "$(six_lines 2.2.0 "$BUILD_B")" ]
}

# --- 3. the same bundle again ---------------------------------------------------

@test "the same bundle again is already synced and the cache is unchanged" {
  make_project "$PROJECT" 2.2.0
  make_bundles
  source_ok A 2.2.0 "$BUILD_A"
  record_local 2.2.0 "$BUILD_A"
  local before
  before="$(cache_listing)"
  [ "$before" = "$TAG_A " ]
  run_local source --tarball "$BATS_TEST_TMPDIR/bundles/A.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "ALREADY_SYNCED $BUILD_A" ]
  [ "$(cache_listing)" = "$before" ]
}

# --- 4. an older bundle ---------------------------------------------------------

@test "an older bundle is refused naming both versions and the cache is unchanged" {
  make_project "$PROJECT" 2.2.0
  make_bundles
  source_ok A 2.2.0 "$BUILD_A"
  record_local 2.2.0 "$BUILD_A"
  local before
  before="$(cache_listing)"
  run_local source --tarball "$BATS_TEST_TMPDIR/bundles/C.tar.gz"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'LOCAL_REFUSED older-than-project 2.1.0 2.2.0'
  printf '%s\n' "$output" | grep -q '^Next step:'
  [ "$(cache_listing)" = "$before" ]
  # Red twin: the same project accepts a same-version bundle.
  run_local source --tarball "$BATS_TEST_TMPDIR/bundles/B.tar.gz"
  [ "$status" -eq 0 ]
}

# --- 5. prune between runs ------------------------------------------------------

@test "prune between local runs keeps the recorded baseline and the target and drops the rest" {
  make_project "$PROJECT" 2.2.0
  make_bundles
  source_ok A 2.2.0 "$BUILD_A"
  record_local 2.2.0 "$BUILD_A"
  source_ok B 2.2.0 "$BUILD_B"
  mkdir -p "$CACHE/run" "$CACHE/v2.1.0"
  run_preflight prune --baseline 2.2.0 --latest-tag "$TAG_B" --baseline-tag "$TAG_A" --resume
  [ "$status" -eq 0 ]
  [ "$(cache_listing)" = "$TAG_A $TAG_B " ]
  # Red twin: without --baseline-tag the recorded baseline is not kept.
  run_preflight prune --baseline 2.2.0 --latest-tag "$TAG_B" --resume
  [ "$status" -eq 0 ]
  [ "$(cache_listing)" = "$TAG_B " ]
}

# --- 6. a deferral on a local sync ----------------------------------------------

# Run 2 (baseline A, target B) records a deferred entry and a resolved one, then
# reconciles; B is recorded and D sourced for run 3.
reach_run_three() {
  local report="$BATS_TEST_TMPDIR/report.json"
  make_project "$PROJECT" 2.2.0
  make_bundles
  source_ok A 2.2.0 "$BUILD_A"
  record_local 2.2.0 "$BUILD_A"
  source_ok B 2.2.0 "$BUILD_B"
  run_decisions record --file .gaia/update-decisions.json --path docs/shipped.md --decision deferred --tag "$TAG_B" --baseline-tag "$TAG_A"
  [ "$status" -eq 0 ]
  run_decisions record --file .gaia/update-decisions.json --path config.json --key theme --decision deferred --tag "$TAG_B" --baseline-tag "$TAG_A"
  [ "$status" -eq 0 ]
  printf '%s\n' '{"files":[{"path":"docs/shipped.md","status":"open"},{"path":"config.json","fieldMerge":{"applied":[{"key":"theme"}]}}]}' > "$report"
  run_decisions reconcile --file .gaia/update-decisions.json --tree "$CACHE_PREFIX/$TAG_A/tree" --latest-dir "$CACHE_PREFIX/$TAG_B/tree" --report "$report" --latest-tag "$TAG_B"
  [ "$status" -eq 0 ]
  record_local 2.2.0 "$BUILD_B" 1700000300
  source_ok D 2.2.0 "$BUILD_D"
}

@test "a deferral on a local sync keeps the run's baseline tag and the resolved entry rebases to the target build" {
  reach_run_three
  [ "$(jq -r '.decisions[] | select(.path == "config.json") | "\(.decision) \(.tag) \(.baselineTag)"' "$PROJECT/.gaia/update-decisions.json")" = "blend $TAG_B $TAG_B" ]
  [ "$(jq -r '.decisions[] | select(.path == "docs/shipped.md") | "\(.decision) \(.tag) \(.baselineTag)"' "$PROJECT/.gaia/update-decisions.json")" = "deferred $TAG_B $TAG_A" ]
  run_decisions deferred-tags --file .gaia/update-decisions.json
  [ "$status" -eq 0 ]
  [ "$output" = "$TAG_A" ]
}

@test "run 3: the deferred item's build resolves from the cache and its keep survives prune" {
  reach_run_three
  run_local baseline
  [ "$output" = "$(printf 'BASELINE_TAG=%s\nRECORDED_BUILD %s' "$TAG_B" "$BUILD_B")" ]
  run_preflight verify-bundles --baseline 2.2.0 --baseline-tag "$TAG_B" --latest-tag "$TAG_D" --extra-tag "$TAG_A"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "EXTRA_DIR=$TAG_A:$CACHE_PREFIX/$TAG_A/tree"
  printf '%s\n' "$output" | grep -qxF "BASELINE_DIR=$CACHE_PREFIX/$TAG_B/tree"
  printf '%s\n' "$output" | grep -qxF "LATEST_DIR=$CACHE_PREFIX/$TAG_D/tree"
  [ ! -s "$GH_LOG" ]
  run_preflight prune --baseline 2.2.0 --baseline-tag "$TAG_B" --latest-tag "$TAG_D" --keep-tag "$TAG_A"
  [ "$status" -eq 0 ]
  [ "$(cache_listing)" = "$TAG_A $TAG_B $TAG_D " ]
  # Red twin: without the keep, the deferred item's build is removed.
  run_preflight prune --baseline 2.2.0 --baseline-tag "$TAG_B" --latest-tag "$TAG_D"
  [ "$status" -eq 0 ]
  [ "$(cache_listing)" = "$TAG_B $TAG_D " ]
}

# --- 7 and 8. a release update after a local sync -------------------------------

@test "a release update after a local sync merges against the recorded build and removes the record last" {
  reach_b_recorded
  write_release v2.3.0
  run_local baseline
  [ "$output" = "$(printf 'BASELINE_TAG=%s\nRECORDED_BUILD %s' "$TAG_B" "$BUILD_B")" ]
  run_preflight verify-bundles --baseline 2.2.0 --baseline-tag "$TAG_B" --latest-tag v2.3.0
  [ "$status" -eq 0 ]
  [ "$(cat "$GH_LOG")" = v2.3.0 ]
  printf '%s\n' "$output" | grep -qxF "BASELINE_DIR=$CACHE_PREFIX/$TAG_B/tree"
  printf '%s\n' "$output" | grep -qxF "LATEST_DIR=$CACHE_PREFIX/v2.3.0/tree"
  run_preflight prune --baseline 2.2.0 --baseline-tag "$TAG_B" --latest-tag v2.3.0
  [ "$(cache_listing)" = "$TAG_B v2.3.0 " ]
  # Red twin: without the flag the recorded build is pruned.
  run_preflight prune --baseline 2.2.0 --latest-tag v2.3.0
  [ "$(cache_listing)" = 'v2.3.0 ' ]
  record_release 2.3.0
  [ ! -e "$PROJECT/.gaia/VERSION-dev" ]
  run_local baseline
  [ "$output" = 'BASELINE_TAG=v2.3.0' ]
}

# Adds a branch `$1` from main with `.gaia/VERSION` `$2` and the build record
# `$3` (`none` deletes it) committed at epoch `$4`, then removes its worktree.
add_update_branch() {
  local branch="$1" version="$2" build="$3" epoch="$4" holder="$BATS_TEST_TMPDIR/holder-${1//\//+}"
  git -C "$PROJECT" worktree add -q -b "$branch" "$holder" main
  printf '%s\n' "$version" > "$holder/.gaia/VERSION"
  if [ "$build" = none ]; then
    rm -f "$holder/.gaia/VERSION-dev"
  else
    printf '%s\n' "$build" > "$holder/.gaia/VERSION-dev"
  fi
  commit_in "$holder" "update on $branch" "$epoch"
  git -C "$PROJECT" worktree remove --force "$holder"
}

@test "a release update at the same version as the recorded build does not stop, and classifies on the build record" {
  reach_b_recorded
  write_release v2.2.0
  run_preflight verify-bundles --baseline 2.2.0 --baseline-tag "$TAG_B" --latest-tag v2.2.0
  [ "$status" -eq 0 ]
  [ "$(cat "$GH_LOG")" = v2.2.0 ]
  printf '%s\n' "$output" | grep -qxF "BASELINE_DIR=$CACHE_PREFIX/$TAG_B/tree"
  local release_branch='update/v2.2.0-2026-10-27-1000' dev_branch="update/$TAG_B-2026-10-27-1100"
  add_update_branch "$release_branch" 2.2.0 "$BUILD_B" 1700000400
  run_classify --tag v2.2.0 --latest 2.2.0
  [ "$status" -eq 0 ]
  [ "$output" = "RESUME_ADD_WORKTREE $release_branch" ]
  # The leftover local-sync branch is committed and newer; the release lookup skips it.
  add_update_branch "$dev_branch" 2.2.0 "$BUILD_B" 1700000500
  run_classify --tag v2.2.0 --latest 2.2.0
  [ "$output" = "RESUME_ADD_WORKTREE $release_branch" ]
  # Red twin: the dev tag's own lookup finds the dev branch.
  run_classify --tag "$TAG_B" --latest 2.2.0 --build "$BUILD_B"
  [ "$output" = "COMMITTED $dev_branch -" ]
}

@test "with only a local-sync branch present the release lookup finds nothing" {
  reach_b_recorded
  add_update_branch "update/$TAG_B-2026-10-27-1100" 2.2.0 "$BUILD_B" 1700000500
  run_classify --tag v2.2.0 --latest 2.2.0
  [ "$status" -eq 0 ]
  [ "$output" = NONE ]
}

# --- 9. an uncached recorded build ----------------------------------------------

@test "an uncached recorded build falls back to the plain release and the verify step uses the release tree" {
  reach_b_recorded
  write_release v2.2.0
  write_release v2.3.0
  rm -rf "${CACHE:?}/${TAG_B:?}"
  run_local baseline
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'BASELINE_TAG=v2.2.0\nBASELINE_FALLBACK %s' "$BUILD_B")" ]
  run_preflight verify-bundles --baseline 2.2.0 --latest-tag v2.3.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "BASELINE_DIR=$CACHE_PREFIX/v2.2.0/tree"
  # Red twin: the recorded build named as the baseline is a miss, not a fallback.
  run_preflight verify-bundles --baseline 2.2.0 --baseline-tag "$TAG_B" --latest-tag v2.3.0
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF "CACHE_MISSING $TAG_B"
}

# --- 10. the release path is untouched ------------------------------------------

# Runs the release sequence with the scripts of directory `$2` in project `$1`
# and prints its stdout and the resulting cache listing.
release_sequence() {
  local project="$1" scripts_dir="$2" script
  (
    cd "$project" || exit 99
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    bash "$scripts_dir/update-gaia-preflight.sh" verify-bundles --baseline 2.2.0 --latest-tag v2.3.0
    bash "$scripts_dir/update-gaia-preflight.sh" prune --baseline 2.2.0 --latest-tag v2.3.0
    bash "$scripts_dir/update-gaia-branch-state.sh" classify --tag v2.3.0 --latest 2.3.0
    for script in .gaia/local/cache/shared/update-gaia/*; do
      printf 'cache %s\n' "$(basename "$script")"
    done
  ) 2>/dev/null
}

prepare_release_projects() {
  [ -n "$MERGE_BASE" ] || skip 'origin/main is absent, so there is no merge base to compare against'
  write_release v2.2.0
  write_release v2.3.0
  make_project "$PROJECT" 2.2.0
  mkdir -p "$CACHE/v2.1.0" "$CACHE/run"
  add_update_branch update/v2.3.0-2026-10-27-1000 2.3.0 none 1700000400
  cp -R "$PROJECT" "$BATS_TEST_TMPDIR/project-merge-base"
}

@test "a release update on a project that never had a build file matches the scripts at the merge base" {
  prepare_release_projects
  local current baseline
  current="$(release_sequence "$PROJECT" "$SCRIPTS")"
  baseline="$(release_sequence "$BATS_TEST_TMPDIR/project-merge-base" "$MERGE_BASE_SCRIPTS")"
  [ -n "$current" ]
  [ "$current" = "$baseline" ]
  printf '%s\n' "$current" | grep -qxF 'COMMITTED update/v2.3.0-2026-10-27-1000 -'
  printf '%s\n' "$current" | grep -qxF 'VERIFIED v2.3.0'
  printf '%s\n' "$current" | grep -qxF 'cache v2.3.0'
  printf '%s\n' "$current" | grep -qxF 'cache v2.1.0' && return 1
  true
}

@test "the merge base comparison fails when the compared script's output differs" {
  prepare_release_projects
  local mutated="$BATS_TEST_TMPDIR/mutated/.gaia/scripts" current baseline
  mkdir -p "$mutated"
  cp "$MERGE_BASE_SCRIPTS"/*.sh "$mutated"/
  sed 's/echo "VERIFIED \$tag"/echo "OK $tag"/' "$MERGE_BASE_SCRIPTS/update-gaia-preflight.sh" > "$mutated/update-gaia-preflight.sh"
  current="$(release_sequence "$PROJECT" "$SCRIPTS")"
  baseline="$(release_sequence "$BATS_TEST_TMPDIR/project-merge-base" "$mutated")"
  [ -n "$baseline" ]
  [ "$current" != "$baseline" ]
}

# --- 11. mode 1 resume after the record step ------------------------------------

@test "mode 1 resume: the worktree holding the target record reaches the six lines and classifies applied, then committed" {
  make_project "$PROJECT" 2.2.0
  make_bundles
  source_ok A 2.2.0 "$BUILD_A"
  record_local 2.2.0 "$BUILD_A"
  local branch="update/$TAG_B-2026-10-27-1200" worktree="$BATS_TEST_TMPDIR/worktree" resolved
  git -C "$PROJECT" worktree add -q -b "$branch" "$worktree" main
  resolved="$(cd "$worktree" && pwd -P)"
  printf '%s\n' "$BUILD_B" > "$worktree/.gaia/VERSION-dev"
  # Red twin: without --resume the recorded target is already synced.
  run_script_from update-gaia-local.sh "$SCRIPTS" "$worktree" source --tarball "$BATS_TEST_TMPDIR/bundles/B.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "ALREADY_SYNCED $BUILD_B" ]
  run_script_from update-gaia-local.sh "$SCRIPTS" "$worktree" source --tarball "$BATS_TEST_TMPDIR/bundles/B.tar.gz" --resume
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0 "$BUILD_B")" ]
  run_script_from update-gaia-branch-state.sh "$SCRIPTS" "$worktree" classify --tag "$TAG_B" --latest 2.2.0 --build "$BUILD_B" --branch "$branch"
  [ "$output" = "APPLIED_UNCOMMITTED $branch $resolved" ]
  commit_in "$worktree" 'record the build' 1700000600
  run_script_from update-gaia-local.sh "$SCRIPTS" "$worktree" source --tarball "$BATS_TEST_TMPDIR/bundles/B.tar.gz" --resume
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0 "$BUILD_B")" ]
  run_script_from update-gaia-branch-state.sh "$SCRIPTS" "$worktree" classify --tag "$TAG_B" --latest 2.2.0 --build "$BUILD_B" --branch "$branch"
  [ "$output" = "COMMITTED $branch $resolved" ]
}
