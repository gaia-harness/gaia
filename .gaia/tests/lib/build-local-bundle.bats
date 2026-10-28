#!/usr/bin/env bats
# The maintainer builder for a local GAIA bundle tarball
# (.gaia/tests/distribution/lib/build-local-bundle.sh): a release-shaped tarball
# plus the build record, refusals that leave nothing behind, the release
# pipeline guard and the release exclusion of the builder itself.
#
# Every build runs in a clone of the repository under test, from a directory
# other than the clone root, so the builder's own source-root working directory
# is exercised. Each pin has a red twin.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

# bats file_tags=whole-tree

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  export REPO_ROOT
  export PRISTINE_CLONE="$BATS_FILE_TMPDIR/pristine"
  clone_repository "$PRISTINE_CLONE"
  export PRISTINE_OUT="$BATS_FILE_TMPDIR/pristine-out"
  mkdir -p "$PRISTINE_OUT"
  (cd "$BATS_FILE_TMPDIR" && GAIA_LOCAL_BUNDLE_FRESHNESS_CHECK="$BATS_FILE_TMPDIR/fresh-stub.sh" \
    bash "$PRISTINE_CLONE/.gaia/tests/distribution/lib/build-local-bundle.sh" "$PRISTINE_OUT" \
    > "$BATS_FILE_TMPDIR/pristine-build.out" 2> "$BATS_FILE_TMPDIR/pristine-build.err") || true
}

# Clone the committed HEAD, then copy in every file the builder invokes that
# this branch adds or changes and that is not committed yet (the builder is new
# work until its commit, and an audit round's fix rebuilds the CLI bundle before
# it commits; once everything is committed each copy is a no-op). The copies are
# committed inside the clone, because the builder refuses a tree with
# uncommitted tracked changes.
clone_repository() {
  local destination="$1" relative_path copied=0
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_FILE_TMPDIR/fresh-stub.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_FILE_TMPDIR/stale-stub.sh"
  git clone --quiet "$REPO_ROOT" "$destination"
  for relative_path in \
    .gaia/tests/distribution/lib/build-local-bundle.sh \
    .gaia/tests/distribution/lib/build-staging.sh \
    .gaia/cli/gaia \
    .gaia/cli/gaia-maintainer; do
    if [ -f "$REPO_ROOT/$relative_path" ] \
      && ! cmp -s "$REPO_ROOT/$relative_path" "$destination/$relative_path"; then
      mkdir -p "$(dirname "$destination/$relative_path")"
      cp -p "$REPO_ROOT/$relative_path" "$destination/$relative_path"
      copied=1
    fi
  done
  if [ "$copied" -eq 1 ]; then
    commit_in "$destination" "uncommitted builder and bundle"
  fi
}

commit_in() {
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.com commit --quiet -m "$2"
}

# build <clone> <output-dir> [freshness-stub]: run from a foreign directory.
build() {
  local clone="$1" output_directory="$2" stub="${3:-$BATS_FILE_TMPDIR/fresh-stub.sh}"
  mkdir -p "$output_directory"
  cd "$BATS_TEST_TMPDIR" || return 1
  run env GAIA_LOCAL_BUNDLE_FRESHNESS_CHECK="$stub" \
    bash "$clone/.gaia/tests/distribution/lib/build-local-bundle.sh" "$output_directory"
}

pristine_tag() {
  sed -n 's/^TAG //p' "$BATS_FILE_TMPDIR/pristine-build.out"
}

pristine_tarball() {
  sed -n 's/^BUNDLE //p' "$BATS_FILE_TMPDIR/pristine-build.out"
}

extract_pristine() {
  EXTRACTED="$BATS_TEST_TMPDIR/extracted"
  mkdir -p "$EXTRACTED"
  tar -xzf "$(pristine_tarball)" -C "$EXTRACTED" --strip-components=1
}

@test "a clean build prints the tag and bundle and ships a release-shaped tarball" {
  [ -s "$BATS_FILE_TMPDIR/pristine-build.out" ] || { cat "$BATS_FILE_TMPDIR/pristine-build.err"; return 1; }
  local sha core tag tarball
  sha="$(git -C "$PRISTINE_CLONE" rev-parse --short=12 HEAD)"
  core="$(cat "$PRISTINE_CLONE/.gaia/VERSION")"
  tag="$(pristine_tag)"
  tarball="$(pristine_tarball)"
  [ "$tag" = "v${core}-dev.${sha}" ]
  [ -f "$tarball" ]
  [ "$(basename "$tarball")" = "gaia-bundle-${tag}.tar.gz" ]
  [ "$(tar -tzf "$tarball" | sed 's|/.*||' | sort -u)" = "gaia-${tag}" ]
  (cd "$PRISTINE_OUT" && shasum -a 256 -c "gaia-bundle-${tag}.tar.gz.sha256")
  extract_pristine
  [ "$(cat "$EXTRACTED/.gaia/VERSION-dev")" = "dev.${sha}" ]
  grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' "$EXTRACTED/.gaia/VERSION"
  # Red twin: the build never lands in the plain version file.
  grep -q 'dev' "$EXTRACTED/.gaia/VERSION" && return 1
  true
}

@test "the bundle equals the release staging tree plus the build record, with a fresh manifest" {
  extract_pristine
  local second="$BATS_TEST_TMPDIR/second-stage"
  mkdir -p "$second"
  (cd "$PRISTINE_CLONE" && bash .gaia/tests/distribution/lib/build-staging.sh "$second")
  run diff -r --exclude=manifest.json "$second" "$EXTRACTED"
  [ "$status" -eq 1 ]
  [ "$output" = "Only in $EXTRACTED/.gaia: VERSION-dev" ]
  local expected actual
  expected="$(cd "$PRISTINE_CLONE" && ./.gaia/cli/gaia-maintainer release manifest --stdout --allow-undecided | jq -S .files)"
  actual="$(jq -S .files "$EXTRACTED/.gaia/manifest.json")"
  [ -n "$expected" ]
  [ "$expected" = "$actual" ]
}

@test "scrub and runtime-deps pass on the tree that carries the record, and the scan is armed" {
  extract_pristine
  [ -f "$EXTRACTED/.gaia/VERSION-dev" ]
  (cd "$PRISTINE_CLONE" && ./.gaia/cli/gaia-maintainer release scrub "$EXTRACTED")
  (cd "$PRISTINE_CLONE" && ./.gaia/cli/gaia-maintainer release runtime-deps --staging "$EXTRACTED")
  # Red twin: a shipped script naming a release-excluded path trips the scan.
  local leaky="$BATS_TEST_TMPDIR/leaky"
  cp -R "$EXTRACTED" "$leaky"
  printf '#!/usr/bin/env bash\nsource .gaia/tests/lib/build-local-bundle.bats\n' > "$leaky/.gaia/scripts/leaky-probe.sh"
  cd "$PRISTINE_CLONE"
  run ./.gaia/cli/gaia-maintainer release runtime-deps --staging "$leaky"
  [ "$status" -ne 0 ]
}

@test "a shipped file added after the last release reaches the bundle manifest and tarball" {
  local clone="$BATS_TEST_TMPDIR/clone"
  clone_repository "$clone"
  printf 'A probe rule for the local bundle builder.\n' > "$clone/.claude/rules/local-bundle-probe.md"
  commit_in "$clone" "add probe"
  # Red twin: the committed manifest, which the old behavior would ship, lacks it.
  [ "$(jq -r '.files | has(".claude/rules/local-bundle-probe.md")' "$clone/.gaia/manifest.json")" = "false" ]
  build "$clone" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  local tarball
  tarball="$(printf '%s\n' "$output" | sed -n 's/^BUNDLE //p')"
  tar -tzf "$tarball" | grep -q '/\.claude/rules/local-bundle-probe\.md$'
  local top
  top="$(tar -tzf "$tarball" | sed -n '1s|/.*||p')"
  tar -xzOf "$tarball" "$top/.gaia/manifest.json" | jq -e '.files | has(".claude/rules/local-bundle-probe.md")'
}

@test "uncommitted tracked changes are refused with no tarball, an untracked file is not" {
  local clone="$BATS_TEST_TMPDIR/clone"
  clone_repository "$clone"
  printf '\nunsaved\n' >> "$clone/README.md"
  build "$clone" "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'commit first, any branch is fine'
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/out")" ]
  # A staged-but-uncommitted change is refused the same way.
  git -C "$clone" add README.md
  build "$clone" "$BATS_TEST_TMPDIR/out2"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'commit first, any branch is fine'
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/out2")" ]
}

@test "an untracked new file does not trigger the dirty refusal" {
  local clone="$BATS_TEST_TMPDIR/clone"
  clone_repository "$clone"
  printf 'untracked\n' > "$clone/untracked-probe.txt"
  build "$clone" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^TAG '
}

@test "a stale CLI bundle is refused with no tarball" {
  local clone="$BATS_TEST_TMPDIR/clone"
  clone_repository "$clone"
  build "$clone" "$BATS_TEST_TMPDIR/out" "$BATS_FILE_TMPDIR/stale-stub.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi 'stale'
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/out")" ]
}

@test "a source tree that tracks the build record fails the build and the manifest commands" {
  local clone="$BATS_TEST_TMPDIR/clone"
  clone_repository "$clone"
  cd "$clone"
  # Red twin first: without the tracked file the guard text is absent.
  run ./.gaia/cli/gaia-maintainer release manifest --check
  printf '%s\n' "$output" | grep -q '\.gaia/VERSION-dev is tracked' && return 1
  run ./.gaia/cli/gaia-maintainer release manifest --stdout --allow-undecided
  printf '%s\n' "$output" | grep -q '\.gaia/VERSION-dev is tracked' && return 1
  printf 'dev.abcdef1\n' > "$clone/.gaia/VERSION-dev"
  commit_in "$clone" "track record"
  cd "$clone"
  run ./.gaia/cli/gaia-maintainer release manifest --check
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q '\.gaia/VERSION-dev is tracked'
  run ./.gaia/cli/gaia-maintainer release manifest --stdout --allow-undecided
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q '\.gaia/VERSION-dev is tracked'
  build "$clone" "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q '\.gaia/VERSION-dev is tracked'
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/out")" ]
}

@test "the builder path is release-excluded and the update scripts are not" {
  cd "$REPO_ROOT"
  local patterns="$BATS_TEST_TMPDIR/exclude-regex.txt"
  ./.gaia/cli/gaia-maintainer release exclude-regex --exclude-file .gaia/release-exclude > "$patterns"
  [ -s "$patterns" ]
  printf '%s\n' .gaia/tests/distribution/lib/build-local-bundle.sh | grep -Eq -f "$patterns"
  printf '%s\n' .gaia/scripts/update-gaia-preflight.sh | grep -Eq -f "$patterns" && return 1
  true
}

@test "a second build at the same commit refuses and leaves the first tarball untouched" {
  local tarball before after
  tarball="$(pristine_tarball)"
  before="$(shasum -a 256 "$tarball")"
  build "$PRISTINE_CLONE" "$PRISTINE_OUT"
  [ "$status" -ne 0 ]
  after="$(shasum -a 256 "$tarball")"
  [ "$before" = "$after" ]
}
