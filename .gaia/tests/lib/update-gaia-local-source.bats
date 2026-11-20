#!/usr/bin/env bats
# .gaia/scripts/update-gaia-local.sh `source`: validates a locally built bundle
# tarball, refuses a downgrade or an unsafe archive, reports an already-synced
# build, and otherwise places the bundle in the update cache under its dev tag.
# Fixtures live under $BATS_TEST_TMPDIR; the script runs from a fixture project
# root with a stub `gh` first on PATH that logs and fails, so any network
# attempt is visible. Every refusal is driven into its failing state and also
# asserts that no cache entry and no scratch directory remain.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  LOCAL_SCRIPT="$REPO_ROOT/.gaia/scripts/update-gaia-local.sh"
  PROJECT="$BATS_TEST_TMPDIR/project"
  CACHE="$PROJECT/.gaia/local/cache/shared/update-gaia"
  SCRATCH_TMP="$BATS_TEST_TMPDIR/scratch-tmp"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  SHA=0123456789ab
  mkdir -p "$PROJECT/.gaia" "$SCRATCH_TMP" "$BATS_TEST_TMPDIR/bin"
  : > "$GH_LOG"
  printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 1\n' "$GH_LOG" > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export GH_LOG
}

# Runs update-gaia-local.sh from the project root with the stubs on PATH and a
# test-owned TMPDIR.
run_local() {
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" TMPDIR="$SCRATCH_TMP" \
    bash -c 'cd "$1" || exit 99; shift; bash "$@"' _ "$PROJECT" "$LOCAL_SCRIPT" "$@"
}

project_at() {
  printf '%s\n' "$1" > "$PROJECT/.gaia/VERSION"
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2" > "$PROJECT/.gaia/VERSION-dev"
  fi
}

# make_bundle <name> <core> <build-file-content-or--> [skip]: writes a bundle
# tree under $BATS_TEST_TMPDIR/trees/<name>/gaia-<name>/ and packs
# $BATS_TEST_TMPDIR/<name>.tar.gz. A `-` build means no .gaia/VERSION-dev.
make_bundle() {
  local name="$1" core="$2" build="$3" top
  top="$BATS_TEST_TMPDIR/trees/$name/gaia-$name"
  mkdir -p "$top/.gaia"
  printf '%s\n' "$core" > "$top/.gaia/VERSION"
  [ "$build" = - ] || printf '%s\n' "$build" > "$top/.gaia/VERSION-dev"
  printf '{}\n' > "$top/.gaia/manifest.json"
  tar -czf "$BATS_TEST_TMPDIR/$name.tar.gz" -C "$BATS_TEST_TMPDIR/trees/$name" "gaia-$name"
}

# Writes a hostile archive of kind $2 (absolute, parent, symlink, hardlink)
# to $BATS_TEST_TMPDIR/$1.tar.gz.
make_hostile() {
  local name="$1" kind="$2"
  cat > "$BATS_TEST_TMPDIR/hostile.py" <<'PYTHON'
import io, sys, tarfile
out, kind = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:gz") as archive:
    directory = tarfile.TarInfo("gaia-x")
    directory.type = tarfile.DIRTYPE
    directory.mode = 0o755
    archive.addfile(directory)
    for name, body in ((".gaia/VERSION", b"2.2.0\n"), (".gaia/VERSION-dev", b"dev.0123456789ab\n"), (".gaia/manifest.json", b"{}\n")):
        member = tarfile.TarInfo("gaia-x/" + name)
        member.size = len(body)
        archive.addfile(member, io.BytesIO(body))
    if kind == "absolute":
        member = tarfile.TarInfo("/tmp/gaia-evil")
        member.size = 1
        archive.addfile(member, io.BytesIO(b"x"))
    elif kind == "parent":
        member = tarfile.TarInfo("gaia-x/../gaia-evil")
        member.size = 1
        archive.addfile(member, io.BytesIO(b"x"))
    elif kind == "symlink":
        member = tarfile.TarInfo("gaia-x/link")
        member.type = tarfile.SYMTYPE
        member.linkname = "/etc/passwd"
        archive.addfile(member)
    elif kind == "hardlink":
        member = tarfile.TarInfo("gaia-x/hard")
        member.type = tarfile.LNKTYPE
        member.linkname = "gaia-x/.gaia/VERSION"
        archive.addfile(member)
PYTHON
  python3 -I "$BATS_TEST_TMPDIR/hostile.py" "$BATS_TEST_TMPDIR/$name.tar.gz" "$kind"
}

six_lines() {
  printf '%s\n' "LOCAL_SOURCE unverified" "LOCAL_TAG=v$1-dev.$SHA" "LOCAL_CORE=$1" "LOCAL_BUILD=dev.$SHA" "LOCAL_COMMIT=$SHA" "LATEST_DIR=.gaia/local/cache/shared/update-gaia/v$1-dev.$SHA/tree"
}

assert_refused_clean() {
  local reason="$1"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF "LOCAL_REFUSED $reason"
  printf '%s\n' "$output" | grep -q '^Next step:'
  [ ! -e "$CACHE" ] || [ -z "$(ls -A "$CACHE")" ]
  [ -z "$(ls -A "$SCRATCH_TMP")" ]
  [ ! -s "$GH_LOG" ]
}

# Empties the fixture project, its cache and the gh log between table cases.
reset_project() {
  rm -rf "$PROJECT"
  mkdir -p "$PROJECT/.gaia"
  : > "$GH_LOG"
}

@test "source proceeds, reports already-synced, or refuses a downgrade by version and build" {
  make_bundle same 2.2.0 "dev.$SHA"
  make_bundle newer 2.3.0 "dev.$SHA"
  make_bundle older 2.1.0 "dev.$SHA"

  echo "case: a same-version bundle prints the six lines and fills the cache without touching gh"
  project_at 2.2.0
  run_local source --tarball "$BATS_TEST_TMPDIR/same.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0)" ]
  [ -f "$CACHE/v2.2.0-dev.$SHA/gaia-bundle-v2.2.0-dev.$SHA.tar.gz" ]
  [ "$(cat "$CACHE/v2.2.0-dev.$SHA/tree/.gaia/VERSION-dev")" = "dev.$SHA" ]
  [ "$(awk '{ print $2 }' "$CACHE/v2.2.0-dev.$SHA/gaia-bundle-v2.2.0-dev.$SHA.tar.gz.sha256")" = "gaia-bundle-v2.2.0-dev.$SHA.tar.gz" ]
  (cd "$CACHE/v2.2.0-dev.$SHA" && shasum -a 256 -c "gaia-bundle-v2.2.0-dev.$SHA.tar.gz.sha256" > /dev/null)
  [ ! -s "$GH_LOG" ]
  [ -z "$(ls -A "$SCRATCH_TMP")" ]

  echo "case: a newer bundle core proceeds with that core"
  reset_project
  project_at 2.2.0
  run_local source --tarball "$BATS_TEST_TMPDIR/newer.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.3.0)" ]

  echo "case: the same version with a different build than the record proceeds"
  reset_project
  project_at 2.2.0 dev.aaaaaaaaaaaa
  run_local source --tarball "$BATS_TEST_TMPDIR/same.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0)" ]

  echo "case: the recorded build is already synced and writes no cache"
  reset_project
  project_at 2.2.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/same.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "ALREADY_SYNCED dev.$SHA" ]
  [ ! -e "$CACHE/v2.2.0-dev.$SHA" ]
  echo "case: --resume skips only the already-synced check"
  run_local source --tarball "$BATS_TEST_TMPDIR/same.tar.gz" --resume
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0)" ]
  [ -d "$CACHE/v2.2.0-dev.$SHA/tree" ]

  echo "case: --resume still refuses a bundle older than the project"
  reset_project
  project_at 2.2.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/older.tar.gz" --resume
  assert_refused_clean "older-than-project 2.1.0 2.2.0"

  echo "case: a bundle older than the project is refused and its same-core twin is not"
  reset_project
  project_at 2.2.0
  run_local source --tarball "$BATS_TEST_TMPDIR/older.tar.gz"
  assert_refused_clean "older-than-project 2.1.0 2.2.0"
  run_local source --tarball "$BATS_TEST_TMPDIR/same.tar.gz"
  [ "$status" -eq 0 ]
}

# bats test_tags=protected
@test "source refuses a bundle missing its build id, manifest or with a malformed version or build id" {
  project_at 2.2.0

  echo "case: a bundle without .gaia/VERSION-dev is refused"
  make_bundle no-build 2.2.0 -
  run_local source --tarball "$BATS_TEST_TMPDIR/no-build.tar.gz"
  assert_refused_clean build-id-missing

  local shape index=0
  for shape in 2.2 2.2.0+dev; do
    echo "case: a malformed bundle .gaia/VERSION '$shape' is refused"
    index=$((index + 1))
    make_bundle "bad-version-$index" "$shape" "dev.$SHA"
    run_local source --tarball "$BATS_TEST_TMPDIR/bad-version-$index.tar.gz"
    assert_refused_clean version-malformed
  done

  for shape in dev.XYZ dev.../../etc "dev.$SHA
dev.$SHA"; do
    echo "case: a malformed bundle build id '$shape' is refused"
    index=$((index + 1))
    make_bundle "bad-build-$index" 2.2.0 "$shape"
    run_local source --tarball "$BATS_TEST_TMPDIR/bad-build-$index.tar.gz"
    assert_refused_clean build-id-malformed
  done

  echo "case: a bundle without a manifest is refused"
  make_bundle no-manifest 2.2.0 "dev.$SHA"
  rm "$BATS_TEST_TMPDIR/trees/no-manifest/gaia-no-manifest/.gaia/manifest.json"
  tar -czf "$BATS_TEST_TMPDIR/no-manifest.tar.gz" -C "$BATS_TEST_TMPDIR/trees/no-manifest" gaia-no-manifest
  run_local source --tarball "$BATS_TEST_TMPDIR/no-manifest.tar.gz"
  assert_refused_clean manifest-missing
}

# bats test_tags=protected
@test "source refuses an unsafe archive layout or member by name" {
  project_at 2.2.0
  make_bundle b1 2.2.0 "dev.$SHA"

  echo "case: two top-level directories are refused as layout"
  mkdir -p "$BATS_TEST_TMPDIR/trees/b1/other"
  tar -czf "$BATS_TEST_TMPDIR/two.tar.gz" -C "$BATS_TEST_TMPDIR/trees/b1" gaia-b1 other
  run_local source --tarball "$BATS_TEST_TMPDIR/two.tar.gz"
  assert_refused_clean "unsafe-entry layout"
  echo "case: a file alone at the archive root is refused as layout"
  mkdir -p "$BATS_TEST_TMPDIR/rootfiles"
  printf '2.2.0\n' > "$BATS_TEST_TMPDIR/rootfiles/VERSION"
  tar -czf "$BATS_TEST_TMPDIR/rootfile.tar.gz" -C "$BATS_TEST_TMPDIR/rootfiles" VERSION
  run_local source --tarball "$BATS_TEST_TMPDIR/rootfile.tar.gz"
  assert_refused_clean "unsafe-entry layout"
  echo "case: a loose file beside the top directory is refused as layout"
  printf 'x\n' > "$BATS_TEST_TMPDIR/trees/b1/loose"
  tar -czf "$BATS_TEST_TMPDIR/loose.tar.gz" -C "$BATS_TEST_TMPDIR/trees/b1" gaia-b1 loose
  run_local source --tarball "$BATS_TEST_TMPDIR/loose.tar.gz"
  assert_refused_clean "unsafe-entry layout"

  local kind word
  for kind in absolute:absolute-entry parent:parent-entry symlink:link-entry hardlink:link-entry; do
    echo "case: a ${kind%%:*} member is refused by name"
    make_hostile "hostile-${kind%%:*}" "${kind%%:*}"
    run_local source --tarball "$BATS_TEST_TMPDIR/hostile-${kind%%:*}.tar.gz"
    word="${kind##*:}"
    assert_refused_clean "unsafe-entry $word"
  done
  [ ! -e /tmp/gaia-evil ]
  [ ! -e "$PROJECT/gaia-evil" ]
}

# bats test_tags=protected
@test "source refuses an unreadable tarball or a wrong or foreign checksum" {
  project_at 2.2.0
  echo "case: a directory is refused as tarball-unreadable"
  run_local source --tarball "$BATS_TEST_TMPDIR"
  assert_refused_clean tarball-unreadable
  echo "case: a missing path is refused as tarball-unreadable"
  run_local source --tarball "$BATS_TEST_TMPDIR/absent.tar.gz"
  assert_refused_clean tarball-unreadable

  make_bundle b1 2.2.0 "dev.$SHA"
  local hex
  hex="$(shasum -a 256 "$BATS_TEST_TMPDIR/b1.tar.gz" | awk '{ print $1 }')"
  echo "case: a matching sibling checksum is accepted"
  printf '%s  b1.tar.gz\n' "$hex" > "$BATS_TEST_TMPDIR/b1.tar.gz.sha256"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  rm -rf "$CACHE"
  echo "case: a wrong sibling checksum is refused"
  printf '%064d  b1.tar.gz\n' 0 > "$BATS_TEST_TMPDIR/b1.tar.gz.sha256"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean checksum-mismatch
  echo "case: a sibling checksum naming another file is refused"
  printf '%s  other.tar.gz\n' "$hex" > "$BATS_TEST_TMPDIR/b1.tar.gz.sha256"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean checksum-mismatch

  # Last, because the root skip ends the test.
  if [ "$(id -u)" -eq 0 ]; then
    skip "chmod 000 does not make a file unreadable to root"
  fi
  echo "case: an unreadable file is refused as tarball-unreadable"
  make_bundle unreadable 2.2.0 "dev.$SHA"
  chmod 000 "$BATS_TEST_TMPDIR/unreadable.tar.gz"
  run_local source --tarball "$BATS_TEST_TMPDIR/unreadable.tar.gz"
  chmod 644 "$BATS_TEST_TMPDIR/unreadable.tar.gz"
  assert_refused_clean tarball-unreadable
}

@test "source: a relative tarball path resolves against the working directory" {
  project_at 2.2.0
  make_bundle b1 2.2.0 "dev.$SHA"
  cp "$BATS_TEST_TMPDIR/b1.tar.gz" "$PROJECT/local.tar.gz"
  run_local source --tarball local.tar.gz
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0)" ]
}

# bats test_tags=protected
@test "source refuses a malformed project version or build record and touches nothing outside" {
  make_bundle b1 2.2.0 "dev.$SHA"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/sentinel"
  printf '2.2.0\n' > "$PROJECT/.gaia/VERSION"
  echo "case: a traversal-shaped project build record is refused"
  printf 'dev.0/../../x\n' > "$PROJECT/.gaia/VERSION-dev"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean project-build-malformed
  echo "case: a multi-line project build record is refused"
  printf 'dev.%s\ndev.%s\n' "$SHA" "$SHA" > "$PROJECT/.gaia/VERSION-dev"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean project-build-malformed
  [ "$(cat "$BATS_TEST_TMPDIR/sentinel")" = keep ]
  echo "case: a malformed project version is refused"
  rm "$PROJECT/.gaia/VERSION-dev"
  printf '2.2\n' > "$PROJECT/.gaia/VERSION"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean project-version-malformed
}

# bats test_tags=protected
@test "source reuses, repairs or replaces a cache entry and refuses a conflicting one" {
  project_at 2.2.0
  make_bundle b1 2.2.0 "dev.$SHA"
  local directory="$CACHE/v2.2.0-dev.$SHA" name="gaia-bundle-v2.2.0-dev.$SHA.tar.gz"

  echo "case: a cache entry with different tarball bytes conflicts and is left untouched"
  mkdir -p "$directory"
  printf 'different bytes\n' > "$directory/$name"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF "LOCAL_REFUSED cache-conflict v2.2.0-dev.$SHA"
  [ "$(cat "$directory/$name")" = "different bytes" ]
  [ -z "$(ls -A "$SCRATCH_TMP")" ]

  echo "case: the same tarball bytes are reused"
  rm -rf "$CACHE"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0)" ]
  echo "case: a half-populated entry is repaired"
  rm "$directory/$name.sha256"
  rm -rf "$directory/tree"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  (cd "$directory" && shasum -a 256 -c "$name.sha256" > /dev/null)
  [ -f "$directory/tree/.gaia/VERSION-dev" ]

  echo "case: an entry holding only a checksum is replaced whole"
  rm -rf "$CACHE"
  mkdir -p "$directory"
  printf 'stale\n' > "$directory/$name.sha256"
  printf 'stale\n' > "$directory/leftover"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  [ -f "$directory/$name" ]
  [ ! -e "$directory/leftover" ]
  echo "case: an entry holding only a tree is replaced whole"
  rm -rf "$CACHE"
  mkdir -p "$directory/tree/.gaia"
  printf 'stale\n' > "$directory/tree/.gaia/VERSION"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  [ -f "$directory/$name" ]
  [ "$(cat "$directory/tree/.gaia/VERSION")" = 2.2.0 ]
}
