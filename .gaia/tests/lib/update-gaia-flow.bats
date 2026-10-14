#!/usr/bin/env bats
# The /update-gaia orchestrator order: download and verify before the Proceed
# question (SKILL.md Step 3c), migration notes from the verified target bundle
# (Step 3d), resume on the update branch (Step 3 and Step 4), the prune that
# keeps the verified bundles (Step 4b), setup drift (Step 9c), and the version
# written last (Step 9d). Each SKILL.md block runs extracted by its heading,
# against fixtures under $BATS_TEST_TMPDIR with stub `gh` and stub
# `.gaia/cli/gaia` executables. Every absence pin has a red twin: a fixture
# copy carrying the forbidden content, or missing the required content.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]]; POSIX [ ] and grep; `&& return 1` for a non-final absence.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SKILL="$REPO_ROOT/.claude/skills/update-gaia/SKILL.md"
  MERGE_EXECUTION="$REPO_ROOT/.claude/skills/update-gaia/references/merge-execution.md"
  SELECTOR="$REPO_ROOT/.gaia/scripts/select-migration-notes.sh"
  COMPARE_LIB="$REPO_ROOT/.gaia/scripts/lib/version-compare.awk"
}

# The fenced bash block that follows the heading line `$2` in file `$1`. The
# heading matches as a line prefix, so callers pass a full heading.
block_after_heading() {
  awk -v heading="$2" '
    index($0, heading) == 1 { seen = 1; next }
    seen && /^```bash$/ { inside = 1; next }
    seen && inside && /^```$/ { exit }
    seen && inside { print }
  ' "$1"
}

# The lines of the section headed `$2` in file `$1`, up to the next heading of
# level two or three.
section_of() {
  awk -v heading="$2" '
    index($0, heading) == 1 { inside = 1; print; next }
    inside && /^##+ / { exit }
    inside { print }
  ' "$1"
}

# Runs block text `$2` with `$1` as its working directory. Extra arguments are
# NAME=value pairs exported into the block's environment.
run_block_in() {
  local directory="$1" block="$2"
  shift 2
  run env "$@" bash -c 'cd "$1" || exit 99; eval "$2"' _ "$directory" "$block"
}

# --- Step 3c: download and verify ---------------------------------------------

STEP_3C='## Step 3c: Download and verify the bundles'

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

step_3c_setup() {
  export FIXTURE_RELEASES="$BATS_TEST_TMPDIR/releases"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GH_LOG"
  write_release v2.0.0
  write_release v2.1.0
  write_stub_gh
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT"
  CACHE="$PROJECT/.gaia/local/cache/shared/update-gaia"
  BLOCK_3C="$(block_after_heading "$SKILL" "$STEP_3C")"
  [ -n "$BLOCK_3C" ]
}

run_step_3c() {
  run_block_in "$PROJECT" "$BLOCK_3C" PATH="$BATS_TEST_TMPDIR/bin:$PATH" BASELINE=2.0.0 LATEST_TAG=v2.1.0
}

@test "Step 3c: fresh downloads verify and extract both bundles" {
  step_3c_setup
  run_step_3c
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.0.0'
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.1.0'
  printf '%s\n' "$output" | grep -qxF 'LATEST_DIR=.gaia/local/cache/shared/update-gaia/v2.1.0/tree'
  printf '%s\n' "$output" | grep -qxF 'BASELINE_DIR=.gaia/local/cache/shared/update-gaia/v2.0.0/tree'
  [ "$(cat "$CACHE/v2.0.0/tree/.gaia/VERSION")" = 2.0.0 ]
  [ "$(cat "$CACHE/v2.1.0/tree/.gaia/VERSION")" = 2.1.0 ]
  [ "$(grep -c . "$GH_LOG")" -eq 2 ]
}

@test "Step 3c: a freshly downloaded mismatched checksum stops with VERIFY_FAILED and removes the tag" {
  step_3c_setup
  printf '%064d  gaia-bundle-v2.1.0.tar.gz\n' 0 > "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256"
  run_step_3c
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFY_FAILED v2.1.0'
  [ -e "$CACHE/v2.1.0" ] && return 1
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.1.0' && return 1
  true
}

@test "Step 3c: a cached tarball that no longer matches its checksum stops with VERIFY_FAILED" {
  step_3c_setup
  run_step_3c
  [ "$status" -eq 0 ]
  printf 'tampered' >> "$CACHE/v2.0.0/gaia-bundle-v2.0.0.tar.gz"
  : > "$GH_LOG"
  run_step_3c
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFY_FAILED v2.0.0'
  [ -e "$CACHE/v2.0.0" ] && return 1
  # The cached pair was reused, not downloaded again.
  grep -qxF v2.0.0 "$GH_LOG" && return 1
  true
}

@test "Step 3c: a cached tree with an edited note or a stray file is replaced by a pristine extract" {
  step_3c_setup
  run_step_3c
  [ "$status" -eq 0 ]
  note="$CACHE/v2.1.0/tree/.gaia/migrations/2.1.0.md"
  printf 'edited\n' >> "$note"
  printf 'stray\n' > "$CACHE/v2.1.0/tree/.gaia/migrations/2.2.0.md"
  : > "$GH_LOG"
  run_step_3c
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.1.0'
  grep -qF edited "$note" && return 1
  [ -e "$CACHE/v2.1.0/tree/.gaia/migrations/2.2.0.md" ] && return 1
  grep -qF pristine "$note"
  # Reuse skipped only the download.
  [ ! -s "$GH_LOG" ]
}

@test "Step 3c: a legacy cache directory without a checksum is removed, downloaded and verified" {
  step_3c_setup
  mkdir -p "$CACHE/v2.0.0/.gaia"
  printf 'legacy\n' > "$CACHE/v2.0.0/.gaia/VERSION"
  cp "$FIXTURE_RELEASES/v2.0.0/gaia-bundle-v2.0.0.tar.gz" "$CACHE/v2.0.0/"
  run_step_3c
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFIED v2.0.0'
  grep -qxF v2.0.0 "$GH_LOG"
  [ -f "$CACHE/v2.0.0/gaia-bundle-v2.0.0.tar.gz.sha256" ]
  [ -e "$CACHE/v2.0.0/.gaia" ] && return 1
  true
}

@test "Step 3c: a release without the checksum asset stops with CHECKSUM_MISSING" {
  step_3c_setup
  rm -f "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256"
  run_step_3c
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'CHECKSUM_MISSING v2.1.0'
  [ -e "$CACHE/v2.1.0" ] && return 1
  true
}

@test "Step 3c: a checklist naming another file never vouches for the tarball" {
  step_3c_setup
  hex="$(shasum -a 256 "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256" | awk '{ print $1 }')"
  printf '%s  gaia-bundle-v2.1.0.tar.gz.sha256\n' "$hex" > "$BATS_TEST_TMPDIR/other.sha256"
  cp "$BATS_TEST_TMPDIR/other.sha256" "$FIXTURE_RELEASES/v2.1.0/gaia-bundle-v2.1.0.tar.gz.sha256"
  run_step_3c
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'VERIFY_FAILED v2.1.0'
}

# --- Step 3d: select migration notes ------------------------------------------

STEP_3D='## Step 3d: Select migration notes'

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

run_step_3d() {
  local block
  block="$(block_after_heading "$SKILL" "$STEP_3D")"
  [ -n "$block" ] || return 1
  run env LATEST_DIR="$BUNDLE" BASELINE="$1" LATEST="$2" bash -c "$block"
}

@test "Step 3d: after-merge notes print in version order with no BLOCKING" {
  make_bundle 2.2.0:after-merge 2.1.0:after-merge 2.0.0:after-merge
  run_step_3d 2.0.0 2.2.0
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "AFTER_MERGE 2.1.0 $BUNDLE/.gaia/migrations/2.1.0.md" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "AFTER_MERGE 2.2.0 $BUNDLE/.gaia/migrations/2.2.0.md" ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  printf '%s\n' "$output" | grep -qF BLOCKING && return 1
  true
}

@test "Step 3d: a blocking note names its path inside the bundle and lists the after-merge notes below it" {
  make_bundle 2.2.0:after-merge 2.3.0:blocking
  run_step_3d 2.1.0 2.3.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "AFTER_MERGE 2.2.0 $BUNDLE/.gaia/migrations/2.2.0.md"
  printf '%s\n' "$output" | grep -qxF "BLOCKING 2.3.0 $BUNDLE/.gaia/migrations/2.3.0.md"
}

@test "Step 3d: the first blocking note wins and later notes are left for the next run" {
  make_bundle 2.2.0:blocking 2.3.0:blocking 2.4.0:after-merge
  run_step_3d 2.1.0 2.4.0
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKING 2.2.0 $BUNDLE/.gaia/migrations/2.2.0.md" ]
}

@test "Step 3d: a malformed note stops with NOTES_FAILED and a next step" {
  make_bundle 2.2.0:after-merge
  printf 'no frontmatter\n' > "$BUNDLE/.gaia/migrations/2.3.0.md"
  run_step_3d 2.1.0 2.2.0
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF NOTES_FAILED
  printf '%s\n' "$output" | grep -qF "select-migration-notes: $BUNDLE/.gaia/migrations/2.3.0.md"
  printf '%s\n' "$output" | grep -qF 'Next step:'
  printf '%s\n' "$output" | grep -qF AFTER_MERGE && return 1
  true
}

# 0 when block text `$1` holds no git call, no rm, no .gaia/VERSION and no
# spawn.
block_is_read_only() {
  printf '%s\n' "$1" | grep -qF 'git ' && return 1
  printf '%s\n' "$1" | grep -qF 'rm ' && return 1
  printf '%s\n' "$1" | grep -qF '.gaia/VERSION' && return 1
  printf '%s\n' "$1" | grep -qiE 'spawn|Agent\(' && return 1
  return 0
}

@test "Step 3d: the block changes nothing, and a copy that writes the version is reported" {
  block="$(block_after_heading "$SKILL" "$STEP_3D")"
  [ -n "$block" ]
  block_is_read_only "$block"
  block_is_read_only "$block
echo x > .gaia/VERSION" && return 1
  block_is_read_only "$block
git switch main" && return 1
  block_is_read_only "$block
rm -rf .gaia-backup" && return 1
  true
}

# --- Step 3d and Step 4 prose ---------------------------------------------------

STEP_4='## Step 4: Show the release notes and confirm'

# 0 when the SKILL.md copy `$1` carries the blocking-note and Proceed pins.
prose_pins_hold() {
  local step_3d step_4
  step_3d="$(section_of "$1" "$STEP_3D")"
  step_4="$(section_of "$1" "$STEP_4")"
  printf '%s\n' "$step_3d" | grep -qF "as a note to follow after the blocking note's merge step and before its version write" || return 1
  printf '%s\n' "$step_3d" | grep -qF 'ask with `AskUserQuestion` whether to follow the blocking note in this session. On yes, read the note' || return 1
  printf '%s\n' "$step_4" | grep -qF 'name each `AFTER_MERGE` note (its version and its path) as a note this run follows after the merge' || return 1
  return 0
}

@test "Step 3d and Step 4 prose: the blocking stop and the Proceed question name the after-merge notes" {
  prose_pins_hold "$SKILL"
  local pin copy
  for pin in "before its version write" 'On yes, read the note' 'as a note this run follows after the merge'; do
    copy="$BATS_TEST_TMPDIR/skill-without-pin.md"
    grep -vF -- "$pin" "$SKILL" > "$copy"
    prose_pins_hold "$copy" && { echo "pin not enforced: $pin" >&2; return 1; }
  done
  true
}

# --- Step 4 and Step 9: the CHANGELOG range reaches the execution agent -------

# The release bundle withholds CHANGELOG.md, so Step 4's fetched range is the
# only copy Step 9's adopter-action suggestions can read.

STEP_9_ACTIONS='**Documented adopter actions (opt-in).**'

# A project holding the range walk, a verified-cache directory for v2.1.0, and
# stub curl and gh executables. The stub curl prints $CURL_FIXTURE, or fails
# when it is unset; the stub gh always fails.
step_4_setup() {
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
  BLOCK_4="$(block_after_heading "$SKILL" "$STEP_4")"
  [ -n "$BLOCK_4" ]
}

run_step_4() {
  run_block_in "$PROJECT" "$BLOCK_4" PATH="$BATS_TEST_TMPDIR/bin:$PATH" BASELINE=2.0.0 LATEST=2.1.0 LATEST_TAG=v2.1.0 "$@"
}

@test "Step 4: a fetched range is saved beside the verified target bundle" {
  step_4_setup
  run_step_4 CURL_FIXTURE="$BATS_TEST_TMPDIR/CHANGELOG.md"
  [ "$status" -eq 0 ]
  grep -qxF '## [2.1.0]' "$CACHE/v2.1.0/changelog-range.md"
  grep -qxF -- '- dropped `pnpm remove left-pad`' "$CACHE/v2.1.0/changelog-range.md"
  grep -qxF '## [2.0.0]' "$CACHE/v2.1.0/changelog-range.md" && return 1
  true
}

@test "Step 4: a failed fetch leaves no saved range, removing one an earlier run saved" {
  step_4_setup
  printf 'stale\n' > "$CACHE/v2.1.0/changelog-range.md"
  run_step_4
  [ -e "$CACHE/v2.1.0/changelog-range.md" ] && return 1
  true
}

run_step_9_actions() {
  local block
  block="$(block_after_heading "$MERGE_EXECUTION" "$STEP_9_ACTIONS")"
  [ -n "$block" ] || return 1
  run_block_in "$PROJECT" "$block" LATEST_DIR=.gaia/local/cache/shared/update-gaia/v2.1.0/tree BASELINE=2.0.0 LATEST=2.1.0
}

@test "Step 9: adopter actions read the range Step 4 saved, never a CHANGELOG inside the bundle" {
  step_4_setup
  run_step_4 CURL_FIXTURE="$BATS_TEST_TMPDIR/CHANGELOG.md"
  [ "$status" -eq 0 ]
  run_step_9_actions
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF -- '- dropped `pnpm remove left-pad`'
  section_of "$MERGE_EXECUTION" '### Step 9: Summary' | grep -qF 'LATEST_DIR/CHANGELOG.md' && return 1
  true
}

@test "Step 9: a missing saved range is announced, not read as an empty range" {
  step_4_setup
  run_step_9_actions
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'CHANGELOG_RANGE_UNAVAILABLE'
}

# --- Step 3d: the target bundle's own selector judges the notes ---------------

@test "Step 3d: a mode only the target's selector knows is accepted, while this repository's selector rejects it" {
  make_bundle
  awk '{ print } /^    "mode: after-merge"\) mode="after-merge" ;;$/ { print "    \"mode: future\") mode=\"future\" ;;" }' \
    "$SELECTOR" > "$BUNDLE/.gaia/scripts/select-migration-notes.sh"
  grep -qF '"mode: future"' "$BUNDLE/.gaia/scripts/select-migration-notes.sh"
  printf -- '---\nmode: future\n---\n\nnote\n' > "$BUNDLE/.gaia/migrations/2.1.0.md"
  run_step_3d 2.0.0 2.1.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "BLOCKING 2.1.0 $BUNDLE/.gaia/migrations/2.1.0.md"
  # Control: this repository's selector rejects the same folder.
  run bash "$SELECTOR" "$BUNDLE" 2.0.0 2.1.0
  [ "$status" -eq 1 ]
}

# --- Step 3 and Step 4: resume on the update branch ---------------------------

STEP_3='## Step 3: Compare versions'
STEP_4_BRANCH='### Step 4, on Proceed: the update branch'

# A fixture git repository on main with one commit.
make_repository() {
  REPOSITORY="$BATS_TEST_TMPDIR/repository"
  rm -rf "$REPOSITORY"
  mkdir -p "$REPOSITORY/.gaia/scripts"
  git -C "$REPOSITORY" init -q -b main
  git -C "$REPOSITORY" config user.email fixture@example.com
  git -C "$REPOSITORY" config user.name fixture
  git -C "$REPOSITORY" commit -q --allow-empty -m base
  cp "$REPO_ROOT/.gaia/scripts/branch-name-lib.sh" "$REPOSITORY/.gaia/scripts/"
  cp "$REPO_ROOT/.gaia/conventional-commits.json" "$REPOSITORY/.gaia/"
}

# Creates branch `$1` at a new commit dated `$2`.
branch_at_date() {
  git -C "$REPOSITORY" checkout -q -b "$1" main
  GIT_COMMITTER_DATE="$2" GIT_AUTHOR_DATE="$2" git -C "$REPOSITORY" commit -q --allow-empty -m "$1"
  git -C "$REPOSITORY" checkout -q main
}

@test "Step 3: an interrupted run's update branch is found by its prefix" {
  make_repository
  git -C "$REPOSITORY" branch update/v2.1.0-2020-01-01-0000
  block="$(block_after_heading "$SKILL" "$STEP_3")"
  [ -n "$block" ]
  run_block_in "$REPOSITORY" "$block" LATEST_TAG=v2.1.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'RESUME update/v2.1.0-2020-01-01-0000'
  printf '%s\n' "$output" | grep -qxF 'RESUME_UPDATE=true'
}

@test "Step 3: a branch for another tag is not a resume" {
  make_repository
  git -C "$REPOSITORY" branch update/v2.0.9-2020-01-01-0000
  block="$(block_after_heading "$SKILL" "$STEP_3")"
  run_block_in "$REPOSITORY" "$block" LATEST_TAG=v2.1.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF RESUME_UPDATE=false
  printf '%s\n' "$output" | grep -qE '^RESUME ' && return 1
  true
}

@test "Step 3: with two matching branches the more recently committed one wins" {
  make_repository
  branch_at_date update/v2.1.0-2020-06-01-0000 '2021-01-01T00:00:00Z'
  branch_at_date update/v2.1.0-2020-01-01-0000 '2022-01-01T00:00:00Z'
  block="$(block_after_heading "$SKILL" "$STEP_3")"
  run_block_in "$REPOSITORY" "$block" LATEST_TAG=v2.1.0
  printf '%s\n' "$output" | grep -qxF 'RESUME update/v2.1.0-2020-01-01-0000'
}

@test "Step 4: a resumed run on main switches to the update branch and creates none" {
  make_repository
  git -C "$REPOSITORY" branch update/v2.1.0-2020-01-01-0000
  before="$(git -C "$REPOSITORY" for-each-ref --format='%(refname)' refs/heads | sort)"
  block="$(block_after_heading "$SKILL" "$STEP_4_BRANCH")"
  [ -n "$block" ]
  run_block_in "$REPOSITORY" "$block" LATEST_TAG=v2.1.0 RESUME_UPDATE=true \
    UPDATE_BRANCH=update/v2.1.0-2020-01-01-0000 SHOULD_CREATE_BRANCH=true
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPOSITORY" branch --show-current)" = update/v2.1.0-2020-01-01-0000 ]
  [ "$(git -C "$REPOSITORY" for-each-ref --format='%(refname)' refs/heads | sort)" = "$before" ]
}

@test "Step 4: a fresh run on main creates the update branch" {
  make_repository
  block="$(block_after_heading "$SKILL" "$STEP_4_BRANCH")"
  printf '%s\n' "$block" | grep -qF 'git checkout -b'
  run_block_in "$REPOSITORY" "$block" LATEST_TAG=v2.1.0 RESUME_UPDATE=false \
    UPDATE_BRANCH='' SHOULD_CREATE_BRANCH=true
  [ "$status" -eq 0 ]
  case "$(git -C "$REPOSITORY" branch --show-current)" in
    update/v2.1.0-*) true ;;
    *) return 1 ;;
  esac
}

# --- Step 4b: prune --------------------------------------------------------------

STEP_4B='## Step 4b: Prune prior-run artifacts'

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

@test "Step 4b: the prune keeps the verified baseline and target and the populated merge folder" {
  block="$(block_after_heading "$SKILL" "$STEP_4B")"
  [ -n "$block" ]
  make_prune_fixture
  run_block_in "$PROJECT" "$block" BASELINE=2.0.0 LATEST_TAG=v2.1.0 RESUME_UPDATE=false
  [ "$status" -eq 0 ]
  [ "$(ls "$PROJECT/.gaia/local/cache/shared/update-gaia" | tr '\n' ' ')" = 'v2.0.0 v2.1.0 ' ]
  [ -e "$PROJECT/.gaia-backup" ] && return 1
  [ -f "$PROJECT/.gaia-merge/a.patch" ]
}

@test "Step 4b: a resumed run keeps .gaia-backup" {
  block="$(block_after_heading "$SKILL" "$STEP_4B")"
  make_prune_fixture
  run_block_in "$PROJECT" "$block" BASELINE=2.0.0 LATEST_TAG=v2.1.0 RESUME_UPDATE=true
  [ "$status" -eq 0 ]
  [ -d "$PROJECT/.gaia-backup/20200101-000000" ]
  [ "$(ls "$PROJECT/.gaia/local/cache/shared/update-gaia" | tr '\n' ' ')" = 'v2.0.0 v2.1.0 ' ]
}

# --- Step 9c: setup drift -------------------------------------------------------

STEP_9C='## Step 9c: Carry new setup features'

# A fixture project with a stub CLI. $DRIFT_JSON is what `setup drift` prints;
# $ADMIN_ANSWER is check-admin's `admin` value; $DRIFT_FAILS makes drift fail.
make_drift_fixture() {
  PROJECT="$BATS_TEST_TMPDIR/drift"
  rm -rf "$PROJECT"
  mkdir -p "$PROJECT/.gaia/cli"
  cat > "$PROJECT/.gaia/cli/gaia" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  'setup drift')
    [ -z "$DRIFT_FAILS" ] || { echo 'features list unreadable' >&2; exit 1; }
    printf '%s\n' "$DRIFT_JSON"
    ;;
  'setup detect-remote')
    printf '%s\n' '{"found":true,"host":"github.com","owner":"acme","repo":"app"}'
    ;;
  'setup check-admin')
    printf '{"admin":%s,"auth_status":"ok"}\n' "$ADMIN_ANSWER"
    ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$PROJECT/.gaia/cli/gaia"
}

DRIFT_FIXTURE='{"features":"x","recorded":{"project":1,"machine":1},"decided":{},"undecided":[
{"id":"A","scope":"project","required":true,"admin":false,"standalone":true,"reference":"ref/a.md","action":"apply"},
{"id":"B","scope":"machine","required":false,"admin":false,"standalone":true,"reference":"ref/b.md","action":"ask"},
{"id":"C","scope":"project","required":true,"admin":true,"standalone":true,"reference":"ref/c.md","action":"apply"},
{"id":"D","scope":"machine","required":true,"admin":false,"standalone":true,"reference":"ref/d.md","action":"apply"},
{"id":"W","scope":"project","required":true,"admin":true,"standalone":false,"reference":"ref/w.md","action":"setup"}]}'

@test "Step 9c: drift splits undecided features into apply, ask, owed-by-admin and setup" {
  block="$(block_after_heading "$SKILL" "$STEP_9C")"
  [ -n "$block" ]
  make_drift_fixture
  run_block_in "$PROJECT" "$block" LATEST_DIR=bundle DRIFT_JSON="$DRIFT_FIXTURE" ADMIN_ANSWER=false
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' 'APPLY A ref/a.md' 'ASK B ref/b.md' 'OWED_ADMIN C' 'APPLY D ref/d.md' 'SETUP W')"
  [ "$output" = "$expected" ]
}

@test "Step 9c: an admin applies the admin-gated feature" {
  block="$(block_after_heading "$SKILL" "$STEP_9C")"
  make_drift_fixture
  run_block_in "$PROJECT" "$block" LATEST_DIR=bundle DRIFT_JSON="$DRIFT_FIXTURE" ADMIN_ANSWER=true
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'APPLY C ref/c.md'
  printf '%s\n' "$output" | grep -qF OWED_ADMIN && return 1
  true
}

@test "Step 9c: a failing drift prints DRIFT_FAILED and never fails the update" {
  block="$(block_after_heading "$SKILL" "$STEP_9C")"
  make_drift_fixture
  run_block_in "$PROJECT" "$block" LATEST_DIR=bundle DRIFT_JSON='' ADMIN_ANSWER=false DRIFT_FAILS=1
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'DRIFT_FAILED features list unreadable'
}

# 0 when SKILL.md copy `$1` states that a failed apply records nothing and
# that the summary names every drift outcome by id.
drift_prose_holds() {
  section_of "$1" "$STEP_9C" | grep -qF 'A failed apply records nothing' || return 1
  section_of "$1" '## Step 9d: Record the update' |
    grep -qF 'the setup features applied, asked (with the answer), owed by an admin, failed, and handed to `/setup-gaia`, each by id' || return 1
  return 0
}

@test "Step 9c prose: a failed apply records nothing, and the summary names every outcome" {
  drift_prose_holds "$SKILL"
  local copy="$BATS_TEST_TMPDIR/skill-drift-prose.md" pin
  for pin in 'A failed apply records nothing' 'owed by an admin, failed, and handed to'; do
    grep -vF -- "$pin" "$SKILL" > "$copy"
    drift_prose_holds "$copy" && { echo "pin not enforced: $pin" >&2; return 1; }
  done
  true
}

# --- Prose order --------------------------------------------------------------

# The first line number in file `$1` holding fixed string `$2`; empty if none.
first_line() {
  grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

# 0 when the fixed strings `$2`, `$3`, ... first appear in file `$1` in that
# order, each present.
in_order() {
  local file="$1" previous=0 needle line
  shift
  for needle in "$@"; do
    line="$(first_line "$file" "$needle")"
    [ -n "$line" ] || { echo "missing: $needle" >&2; return 1; }
    [ "$line" -gt "$previous" ] || { echo "out of order: $needle" >&2; return 1; }
    previous="$line"
  done
}

SELECTOR_CALL='bash "$LATEST_DIR/.gaia/scripts/select-migration-notes.sh"'
PROCEED_QUESTION='"Update GAIA from v$BASELINE to $LATEST_TAG?"'

# 0 when SKILL.md copy `$1` keeps the orchestrator order.
skill_order_holds() {
  local file="$1" anchor
  for anchor in 'git checkout -b' 'git switch' 'rm -rf .gaia-backup' '## Model selection'; do
    in_order "$file" "$SELECTOR_CALL" "$PROCEED_QUESTION" "$anchor" || return 1
  done
  in_order "$file" '## Step 9b' 'gaia setup drift --json' 'GAIA_MANIFEST_WRITE=release cp' 'ping --event update' 'echo "$LATEST" > .gaia/VERSION' || return 1
  in_order "$file" '## Step 9d' '### Step 12' || return 1
  section_of "$file" '## Step 11 (orchestrator' | sed -n 3p | grep -qF "The execution agent's work ends at Step 9," || return 1
  return 0
}

# 0 when merge-execution.md copy `$1` holds none of the orchestrator's writes.
merge_execution_is_merge_only() {
  grep -qF 'gh release download' "$1" && return 1
  grep -qE '>[[:space:]]*\.gaia/VERSION' "$1" && return 1
  grep -qF 'GAIA_MANIFEST_WRITE=release cp' "$1" && return 1
  grep -qF 'ping --event update' "$1" && return 1
  return 0
}

@test "prose order: SKILL.md verifies and selects before Proceed, and writes the version last" {
  skill_order_holds "$SKILL"
}

@test "prose order: a reordered SKILL.md copy is reported" {
  local copy="$BATS_TEST_TMPDIR/skill-reordered.md"
  # The version write moved ahead of the ping.
  awk '
    /^\.gaia\/cli\/gaia ping --event update/ { held = $0; next }
    { print }
    /^echo "\$LATEST" > \.gaia\/VERSION$/ && held != "" { print held }
  ' "$SKILL" > "$copy"
  [ "$(first_line "$copy" 'ping --event update')" -gt "$(first_line "$copy" 'echo "$LATEST" > .gaia/VERSION')" ]
  skill_order_holds "$copy" && return 1
  # A branch created before the Proceed question.
  sed '/^## Step 3b: Refuse a 1.x baseline$/i\
git checkout -b early' "$SKILL" > "$copy"
  skill_order_holds "$copy" && return 1
  # Step 11 claiming the executor runs through Step 10.
  sed "s/The execution agent's work ends at Step 9,/The execution agent's work ends at Step 10,/" "$SKILL" > "$copy"
  skill_order_holds "$copy" && return 1
  true
}

@test "prose order: merge-execution.md downloads nothing and writes no version, manifest or ping" {
  merge_execution_is_merge_only "$MERGE_EXECUTION"
  local copy="$BATS_TEST_TMPDIR/merge-execution-readded.md" line
  for line in 'gh release download "$tag" --repo gaia-react/gaia' 'echo "$LATEST" > .gaia/VERSION' \
    'GAIA_MANIFEST_WRITE=release cp "$LATEST_DIR/.gaia/manifest.json" .gaia/manifest.json' \
    '.gaia/cli/gaia ping --event update --from "$BASELINE" --to "$LATEST" || true'; do
    { cat "$MERGE_EXECUTION"; printf '%s\n' "$line"; } > "$copy"
    merge_execution_is_merge_only "$copy" && { echo "not reported: $line" >&2; return 1; }
  done
  true
}

# --- Bundle-root pin ------------------------------------------------------------

# Prints every line of the given files naming .gaia/migrations/ other than
# through $LATEST_DIR/ or the refusal's bundled note path.
bare_migration_paths() {
  sed -e 's|\$LATEST_DIR/\.gaia/migrations/||g' \
    -e 's|\.gaia/local/cache/shared/migrate-2/v2\.0\.0/tree/\.gaia/migrations/2\.0\.0\.md||g' "$@" |
    grep -F '.gaia/migrations/' || true
}

# Prints every line of file `$1` naming the selector that is not a call of the
# target bundle's selector with the target bundle as its root. SKILL.md names
# the selector only where it calls it.
stray_selector_calls() {
  grep -F 'select-migration-notes.sh' "$1" |
    grep -vF 'bash "$LATEST_DIR/.gaia/scripts/select-migration-notes.sh" "$LATEST_DIR" ' || true
}

@test "bundle root: notes are selected and read only from the verified target bundle" {
  [ "$(grep -cF "$SELECTOR_CALL" "$SKILL")" -ge 1 ]
  [ -z "$(stray_selector_calls "$SKILL")" ]
  [ -z "$(bare_migration_paths "$SKILL" "$MERGE_EXECUTION")" ]
  local copy="$BATS_TEST_TMPDIR/skill-bare.md"
  { cat "$SKILL"; printf '%s\n' 'cat .gaia/migrations/2.1.0.md'; } > "$copy"
  [ -n "$(bare_migration_paths "$copy")" ]
  { cat "$SKILL"; printf '%s\n' 'selection="$(bash .gaia/scripts/select-migration-notes.sh . "$BASELINE" "$LATEST")"'; } > "$copy"
  [ -n "$(stray_selector_calls "$copy")" ]
}

# --- Every tracked note is well-formed -------------------------------------------

@test "every tracked migration note is well-formed and listed by the selector" {
  local root="$BATS_TEST_TMPDIR/tracked" relative tracked_count
  mkdir -p "$root/.gaia/migrations"
  tracked_count=0
  while IFS= read -r -d '' relative; do
    [ -n "$relative" ] || continue
    cp "$REPO_ROOT/$relative" "$root/$relative"
    tracked_count=$((tracked_count + 1))
  done < <(git -C "$REPO_ROOT" ls-files -z .gaia/migrations)
  [ "$tracked_count" -gt 0 ]
  run bash "$SELECTOR" "$root" 0.0.0 999.999.999
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq "$tracked_count" ]
  for relative in "$root"/.gaia/migrations/*; do
    printf '%s\n' "$output" | grep -qF -- "$relative" || return 1
  done
  # Failing state: one note's frontmatter broken.
  first_note="$(ls "$root"/.gaia/migrations/* | head -n 1)"
  sed '2s/.*/mode: sometimes/' "$first_note" > "$first_note.tmp"
  mv "$first_note.tmp" "$first_note"
  run bash "$SELECTOR" "$root" 0.0.0 999.999.999
  [ "$status" -eq 1 ]
}

# --- No migrate URL anywhere ----------------------------------------------------

# The URL-absence token, assembled so this suite never matches itself.
migrate_url_token() {
  printf '%s/%s' gaiareact.com migrate
}

@test "no tracked file names the migrate URL, and a planted one is reported" {
  run git -C "$REPO_ROOT" grep -n -F -- "$(migrate_url_token)"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  local planted="$BATS_TEST_TMPDIR/planted"
  mkdir -p "$planted"
  git -C "$planted" init -q
  printf 'see https://%s\n' "$(migrate_url_token)" > "$planted/page.md"
  git -C "$planted" add page.md
  run git -C "$planted" grep -n -F -- "$(migrate_url_token)"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'page.md:1:'
}
