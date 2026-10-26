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

bats_require_minimum_version 1.5.0

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

@test "source: a same-version bundle prints the six lines and fills the cache without touching gh" {
  project_at 2.2.0
  make_bundle b1 2.2.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0)" ]
  [ -f "$CACHE/v2.2.0-dev.$SHA/gaia-bundle-v2.2.0-dev.$SHA.tar.gz" ]
  [ "$(cat "$CACHE/v2.2.0-dev.$SHA/tree/.gaia/VERSION-dev")" = "dev.$SHA" ]
  [ "$(awk '{ print $2 }' "$CACHE/v2.2.0-dev.$SHA/gaia-bundle-v2.2.0-dev.$SHA.tar.gz.sha256")" = "gaia-bundle-v2.2.0-dev.$SHA.tar.gz" ]
  (cd "$CACHE/v2.2.0-dev.$SHA" && shasum -a 256 -c "gaia-bundle-v2.2.0-dev.$SHA.tar.gz.sha256" > /dev/null)
  [ ! -s "$GH_LOG" ]
  [ -z "$(ls -A "$SCRATCH_TMP")" ]
}

@test "source: a newer bundle core proceeds with that core" {
  project_at 2.2.0
  make_bundle b1 2.3.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.3.0)" ]
}

@test "source: the same version with a different build than the record proceeds" {
  project_at 2.2.0 dev.aaaaaaaaaaaa
  make_bundle b1 2.2.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0)" ]
}

@test "source: the recorded build is already synced and writes no cache; --resume skips only that check" {
  project_at 2.2.0 "dev.$SHA"
  make_bundle b1 2.2.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "ALREADY_SYNCED dev.$SHA" ]
  [ ! -e "$CACHE/v2.2.0-dev.$SHA" ]
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz" --resume
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0)" ]
  [ -d "$CACHE/v2.2.0-dev.$SHA/tree" ]
}

@test "source: --resume still refuses a bundle older than the project" {
  project_at 2.2.0 "dev.$SHA"
  make_bundle b1 2.1.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz" --resume
  assert_refused_clean "older-than-project 2.1.0 2.2.0"
}

@test "source: a bundle older than the project is refused and its same-core twin is not" {
  project_at 2.2.0
  make_bundle older 2.1.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/older.tar.gz"
  assert_refused_clean "older-than-project 2.1.0 2.2.0"
  make_bundle same 2.2.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/same.tar.gz"
  [ "$status" -eq 0 ]
}

@test "source: a bundle without .gaia/VERSION-dev is refused" {
  project_at 2.2.0
  make_bundle b1 2.2.0 -
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean build-id-missing
}

@test "source: a malformed bundle .gaia/VERSION is refused" {
  project_at 2.2.0
  local shape
  for shape in 2.2 2.2.0+dev; do
    rm -rf "$BATS_TEST_TMPDIR/trees"
    make_bundle b1 "$shape" "dev.$SHA"
    run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
    assert_refused_clean version-malformed
  done
}

@test "source: a malformed bundle build id is refused" {
  project_at 2.2.0
  local shape
  for shape in dev.XYZ dev.../../etc "dev.$SHA
dev.$SHA"; do
    rm -rf "$BATS_TEST_TMPDIR/trees"
    make_bundle b1 2.2.0 "$shape"
    run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
    assert_refused_clean build-id-malformed
  done
}

@test "source: a bundle without a manifest is refused" {
  project_at 2.2.0
  make_bundle b1 2.2.0 "dev.$SHA"
  rm "$BATS_TEST_TMPDIR/trees/b1/gaia-b1/.gaia/manifest.json"
  tar -czf "$BATS_TEST_TMPDIR/b1.tar.gz" -C "$BATS_TEST_TMPDIR/trees/b1" gaia-b1
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean manifest-missing
}

@test "source: two top-level directories and files at the archive root are refused as layout" {
  project_at 2.2.0
  make_bundle b1 2.2.0 "dev.$SHA"
  mkdir -p "$BATS_TEST_TMPDIR/trees/b1/other"
  tar -czf "$BATS_TEST_TMPDIR/two.tar.gz" -C "$BATS_TEST_TMPDIR/trees/b1" gaia-b1 other
  run_local source --tarball "$BATS_TEST_TMPDIR/two.tar.gz"
  assert_refused_clean "unsafe-entry layout"
  mkdir -p "$BATS_TEST_TMPDIR/rootfiles"
  printf '2.2.0\n' > "$BATS_TEST_TMPDIR/rootfiles/VERSION"
  tar -czf "$BATS_TEST_TMPDIR/rootfile.tar.gz" -C "$BATS_TEST_TMPDIR/rootfiles" VERSION
  run_local source --tarball "$BATS_TEST_TMPDIR/rootfile.tar.gz"
  assert_refused_clean "unsafe-entry layout"
  printf 'x\n' > "$BATS_TEST_TMPDIR/trees/b1/loose"
  tar -czf "$BATS_TEST_TMPDIR/loose.tar.gz" -C "$BATS_TEST_TMPDIR/trees/b1" gaia-b1 loose
  run_local source --tarball "$BATS_TEST_TMPDIR/loose.tar.gz"
  assert_refused_clean "unsafe-entry layout"
}

@test "source: absolute, parent, symlink and hardlink members are each refused by name" {
  project_at 2.2.0
  local kind word
  for kind in absolute:absolute-entry parent:parent-entry symlink:link-entry hardlink:link-entry; do
    make_hostile "hostile-${kind%%:*}" "${kind%%:*}"
    run_local source --tarball "$BATS_TEST_TMPDIR/hostile-${kind%%:*}.tar.gz"
    word="${kind##*:}"
    assert_refused_clean "unsafe-entry $word"
  done
  [ ! -e /tmp/gaia-evil ]
  [ ! -e "$PROJECT/gaia-evil" ]
}

@test "source: a directory, a missing path and an unreadable file are refused as tarball-unreadable" {
  project_at 2.2.0
  run_local source --tarball "$BATS_TEST_TMPDIR"
  assert_refused_clean tarball-unreadable
  run_local source --tarball "$BATS_TEST_TMPDIR/absent.tar.gz"
  assert_refused_clean tarball-unreadable
  if [ "$(id -u)" -eq 0 ]; then
    skip "chmod 000 does not make a file unreadable to root"
  fi
  make_bundle b1 2.2.0 "dev.$SHA"
  chmod 000 "$BATS_TEST_TMPDIR/b1.tar.gz"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  chmod 644 "$BATS_TEST_TMPDIR/b1.tar.gz"
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

@test "source: a matching sibling checksum is accepted and a wrong or foreign one is refused" {
  project_at 2.2.0
  make_bundle b1 2.2.0 "dev.$SHA"
  local hex
  hex="$(shasum -a 256 "$BATS_TEST_TMPDIR/b1.tar.gz" | awk '{ print $1 }')"
  printf '%s  b1.tar.gz\n' "$hex" > "$BATS_TEST_TMPDIR/b1.tar.gz.sha256"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  rm -rf "$CACHE"
  printf '%064d  b1.tar.gz\n' 0 > "$BATS_TEST_TMPDIR/b1.tar.gz.sha256"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean checksum-mismatch
  printf '%s  other.tar.gz\n' "$hex" > "$BATS_TEST_TMPDIR/b1.tar.gz.sha256"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean checksum-mismatch
}

@test "source: a traversal-shaped or multi-line project build record is refused and touches nothing outside" {
  make_bundle b1 2.2.0 "dev.$SHA"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/sentinel"
  printf '2.2.0\n' > "$PROJECT/.gaia/VERSION"
  printf 'dev.0/../../x\n' > "$PROJECT/.gaia/VERSION-dev"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean project-build-malformed
  printf 'dev.%s\ndev.%s\n' "$SHA" "$SHA" > "$PROJECT/.gaia/VERSION-dev"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean project-build-malformed
  [ "$(cat "$BATS_TEST_TMPDIR/sentinel")" = keep ]
}

@test "source: a malformed project version is refused" {
  printf '2.2\n' > "$PROJECT/.gaia/VERSION"
  make_bundle b1 2.2.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  assert_refused_clean project-version-malformed
}

@test "source: a cache entry with different tarball bytes conflicts and is left untouched" {
  project_at 2.2.0
  make_bundle b1 2.2.0 "dev.$SHA"
  local directory="$CACHE/v2.2.0-dev.$SHA"
  mkdir -p "$directory"
  printf 'different bytes\n' > "$directory/gaia-bundle-v2.2.0-dev.$SHA.tar.gz"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF "LOCAL_REFUSED cache-conflict v2.2.0-dev.$SHA"
  [ "$(cat "$directory/gaia-bundle-v2.2.0-dev.$SHA.tar.gz")" = "different bytes" ]
  [ -z "$(ls -A "$SCRATCH_TMP")" ]
}

@test "source: the same tarball bytes are reused, and a half-populated entry is repaired" {
  project_at 2.2.0
  make_bundle b1 2.2.0 "dev.$SHA"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  local directory="$CACHE/v2.2.0-dev.$SHA" name="gaia-bundle-v2.2.0-dev.$SHA.tar.gz"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  [ "$output" = "$(six_lines 2.2.0)" ]
  rm "$directory/$name.sha256"
  rm -rf "$directory/tree"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  (cd "$directory" && shasum -a 256 -c "$name.sha256" > /dev/null)
  [ -f "$directory/tree/.gaia/VERSION-dev" ]
}

@test "source: an entry holding only a checksum or only a tree is replaced whole" {
  project_at 2.2.0
  make_bundle b1 2.2.0 "dev.$SHA"
  local directory="$CACHE/v2.2.0-dev.$SHA" name="gaia-bundle-v2.2.0-dev.$SHA.tar.gz"
  mkdir -p "$directory"
  printf 'stale\n' > "$directory/$name.sha256"
  printf 'stale\n' > "$directory/leftover"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  [ -f "$directory/$name" ]
  [ ! -e "$directory/leftover" ]
  rm -rf "$CACHE"
  mkdir -p "$directory/tree/.gaia"
  printf 'stale\n' > "$directory/tree/.gaia/VERSION"
  run_local source --tarball "$BATS_TEST_TMPDIR/b1.tar.gz"
  [ "$status" -eq 0 ]
  [ -f "$directory/$name" ]
  [ "$(cat "$directory/tree/.gaia/VERSION")" = 2.2.0 ]
}

@test "source: bad usage exits 2 with the usage on stderr" {
  project_at 2.2.0
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$LOCAL_SCRIPT" frobnicate
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -q '^usage:'
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$LOCAL_SCRIPT" source --bogus
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -q '^usage:'
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$LOCAL_SCRIPT" source
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -q '^usage:'
}
