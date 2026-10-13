#!/usr/bin/env bats
#
# The residue-sweep mode of .gaia/scripts/state-registry-lib.sh: list the
# .gaia/local paths a registry residue entry names, and with --apply delete
# exactly those. Every refusal (a live path, an unknown path, a symlink, a path
# outside .gaia/local, a missing jq, a successor not yet present) is paired with
# a positive control in the same run, so a survivor proves the refusal and not
# a sweep that deletes nothing.
#
# Each case builds a scratch repository holding a fixture registry beside copies
# of the lib, so the lib resolves that repository as its main checkout. The
# shipped registry's own residue rows are checked at the end against the real
# file.
#
# Run under bash 5: `.gaia/scripts/bats5.sh .gaia/scripts/tests/state-registry-residue-sweep.bats`.
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  REGISTRY="$REPO_ROOT/.gaia/state-registry.json"
  # shellcheck source=.gaia/tests/helpers/path.sh
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
}

teardown() {
  # A read-only fixture directory would otherwise block bats' temp cleanup.
  [ -n "${SWEEP_REPO:-}" ] && chmod -R u+w "$SWEEP_REPO" 2>/dev/null
  true
}

FIXTURE_REGISTRY='{
  "entries": [
    {"id": "live-marker", "path": "audit/*.ok", "match": "glob", "kind": "file"},
    {"id": "live-shared-cache", "path": "cache/shared/", "match": "prefix", "kind": "dir"},
    {"id": "live-renders", "path": "cache/*/renders.json", "match": "glob", "kind": "file"},
    {"id": "live-plans", "path": "plans/", "match": "prefix", "kind": "dir"},
    {"id": "live-codify", "path": "codify/", "match": "prefix", "kind": "dir"}
  ],
  "residue": [
    {"id": "r-carried", "path": "audit/*.carried", "match": "glob", "why": "dead carried marker"},
    {"id": "r-stale", "path": "cache/shared/stale.txt", "match": "exact", "why": "dead flag under a live prefix"},
    {"id": "r-plans-archived", "path": "plans/archived/", "match": "prefix", "why": "old archive layout"},
    {"id": "r-old", "path": "old/|older.json", "match": "prefix", "why": "retired feature"},
    {"id": "r-moved", "path": "harden/", "match": "prefix", "why": "renamed state", "successor": "codify/"},
    {"id": "r-outside", "path": "../outside.txt", "match": "exact", "why": "names a path outside .gaia/local"},
    {"id": "r-linked", "path": "linked/|linked-real/", "match": "prefix", "why": "retired directory"},
    {"id": "r-telemetry", "path": "telemetry/dead.jsonl", "match": "exact", "why": "retired log"}
  ]
}'

# make_sweep_repo: a scratch main checkout with the fixture registry and the
# lib copies. Sets SWEEP_REPO and LOCAL_ROOT.
make_sweep_repo() {
  SWEEP_REPO="$(mktemp -d "$BATS_TEST_TMPDIR/sweep.XXXXXX")"
  SWEEP_REPO="$(cd "$SWEEP_REPO" && pwd -P)"
  mkdir -p "$SWEEP_REPO/.gaia/scripts" "$SWEEP_REPO/.gaia/local"
  cp "$SCRIPT_DIRECTORY/state-registry-lib.sh" "$SCRIPT_DIRECTORY/main-root-lib.sh" "$SWEEP_REPO/.gaia/scripts/"
  printf '%s\n' "$FIXTURE_REGISTRY" >"$SWEEP_REPO/.gaia/state-registry.json"
  git -C "$SWEEP_REPO" init -q
  LOCAL_ROOT="$SWEEP_REPO/.gaia/local"
}

# put <relative path>: create a file under .gaia/local, parents included.
put() {
  mkdir -p "$(dirname "$LOCAL_ROOT/$1")"
  printf 'x\n' >"$LOCAL_ROOT/$1"
}

# sweep [args...]: run the mode from inside the scratch repository.
sweep() {
  run --separate-stderr "$BASH" -c 'cd "$1" && shift && "$BASH" .gaia/scripts/state-registry-lib.sh residue-sweep "$@"' _ "$SWEEP_REPO" "$@"
}

# section <heading word>: the indented lines under the heading starting with it.
section() {
  printf '%s\n' "$output" | awk -v heading="$1" '
    /^[^ ]/ { in_section = (index($0, heading) == 1); next }
    in_section && /^  / { sub(/^  /, ""); print }
  '
}

@test "list mode names each residue path with its why, lists unknowns apart, and changes nothing" {
  make_sweep_repo
  put audit/a1.carried
  put old/inner/file.txt
  put stray.txt
  sweep
  [ "$status" -eq 0 ]
  section Residue | grep -qx 'audit/a1.carried  (dead carried marker)'
  section Residue | grep -qx 'old  (retired feature)'
  section Unknown | grep -qx 'stray.txt'
  [ -f "$LOCAL_ROOT/audit/a1.carried" ]
  [ -f "$LOCAL_ROOT/old/inner/file.txt" ]
  [ -f "$LOCAL_ROOT/stray.txt" ]
}

@test "a subtree is listed once, at its top, never per child" {
  make_sweep_repo
  put old/a.txt
  put old/b/c.txt
  put mystery/one.txt
  put mystery/deep/two.txt
  sweep
  [ "$status" -eq 0 ]
  [ "$(section Residue | grep -c '^old')" -eq 1 ]
  [ "$(section Unknown)" = "mystery" ]
}

@test "--apply deletes the residue paths and nothing else" {
  make_sweep_repo
  put audit/a1.carried
  put old/inner/file.txt
  put older.json
  put plans/archived/p1/README.md
  put plans/PLAN-001/README.md
  sweep --apply
  [ "$status" -eq 0 ]
  [ ! -e "$LOCAL_ROOT/audit/a1.carried" ]
  [ ! -e "$LOCAL_ROOT/old" ]
  [ ! -e "$LOCAL_ROOT/older.json" ]
  [ ! -e "$LOCAL_ROOT/plans/archived" ]
  [ -f "$LOCAL_ROOT/plans/PLAN-001/README.md" ]
  printf '%s\n' "$output" | grep -qx 'Removed: plans/archived'
}

@test "refusal, live: a live path survives --apply while residue beside it under the same prefix goes" {
  make_sweep_repo
  put audit/k1.ok
  put cache/shared/keep.json
  put cache/shared/stale.txt
  sweep --apply
  [ "$status" -eq 0 ]
  [ -f "$LOCAL_ROOT/audit/k1.ok" ]
  [ -f "$LOCAL_ROOT/cache/shared/keep.json" ]
  [ ! -e "$LOCAL_ROOT/cache/shared/stale.txt" ]
}

@test "refusal, unknown: an unknown path is listed and survives --apply while residue goes" {
  make_sweep_repo
  put mystery/one.txt
  put stray.txt
  put audit/a1.carried
  sweep --apply
  [ "$status" -eq 0 ]
  section Unknown | grep -qx 'mystery'
  section Unknown | grep -qx 'stray.txt'
  [ -f "$LOCAL_ROOT/mystery/one.txt" ]
  [ -f "$LOCAL_ROOT/stray.txt" ]
  [ ! -e "$LOCAL_ROOT/audit/a1.carried" ]
}

@test "a directory whose child a live glob claims is not unknown" {
  make_sweep_repo
  put cache/1790000000-abc/renders.json
  sweep
  [ "$status" -eq 0 ]
  [ -z "$(section Unknown)" ]
}

@test "refusal, symlink: a residue-named symlink and anything behind one survive --apply; a real directory of the same shape goes" {
  make_sweep_repo
  local outside="$BATS_TEST_TMPDIR/outside-target"
  mkdir -p "$outside/linked" "$outside/telemetry"
  printf 'keep\n' >"$outside/linked/precious.txt"
  printf 'keep\n' >"$outside/telemetry/dead.jsonl"
  ln -s "$outside/linked" "$LOCAL_ROOT/linked"
  ln -s "$outside/telemetry" "$LOCAL_ROOT/telemetry"
  put linked-real/file.txt
  sweep --apply
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_ROOT/linked" ]
  [ -f "$outside/linked/precious.txt" ]
  [ -f "$outside/telemetry/dead.jsonl" ]
  [ ! -e "$LOCAL_ROOT/linked-real" ]
  section Symlinks | grep -qx 'linked'
}

@test "refusal, outside .gaia/local: a residue row naming a path above it never deletes that path" {
  make_sweep_repo
  printf 'keep\n' >"$SWEEP_REPO/.gaia/outside.txt"
  put older.json
  sweep --apply
  [ "$status" -eq 0 ]
  [ -f "$SWEEP_REPO/.gaia/outside.txt" ]
  [ ! -e "$LOCAL_ROOT/older.json" ]
}

@test "refusal, outside .gaia/local: a symlinked .gaia/local is refused before anything is read or deleted" {
  make_sweep_repo
  local elsewhere="$BATS_TEST_TMPDIR/elsewhere-local"
  mkdir -p "$elsewhere"
  printf 'keep\n' >"$elsewhere/older.json"
  rm -rf "$LOCAL_ROOT"
  ln -s "$elsewhere" "$LOCAL_ROOT"
  sweep --apply
  [ "$status" -eq 1 ]
  [ -f "$elsewhere/older.json" ]
  printf '%s\n' "$stderr" | grep -q 'symlink'
}

@test "refusal, missing jq: the sweep fails closed and deletes nothing; with jq the same tree is swept" {
  make_sweep_repo
  put older.json
  local without_jq
  without_jq="$(path_shim_without jq)"
  run --separate-stderr env PATH="$without_jq" "$BASH" -c 'cd "$1" && "$BASH" .gaia/scripts/state-registry-lib.sh residue-sweep --apply' _ "$SWEEP_REPO"
  [ "$status" -eq 1 ]
  [ -f "$LOCAL_ROOT/older.json" ]
  printf '%s\n' "$stderr" | grep -q 'jq'
  sweep --apply
  [ "$status" -eq 0 ]
  [ ! -e "$LOCAL_ROOT/older.json" ]
}

@test "refusal, successor absent: a renamed path waits for its one-time move, then goes" {
  make_sweep_repo
  put harden/reviewed.json
  sweep --apply
  [ "$status" -eq 0 ]
  [ -f "$LOCAL_ROOT/harden/reviewed.json" ]
  section Kept | grep -qx 'harden  (waits for codify/)'
  mkdir -p "$LOCAL_ROOT/codify"
  sweep --apply
  [ "$status" -eq 0 ]
  [ ! -e "$LOCAL_ROOT/harden" ]
}

@test "a delete that fails exits 3 and names the path" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory write permission"
  make_sweep_repo
  put audit/a1.carried
  put older.json
  chmod 555 "$LOCAL_ROOT/audit"
  sweep --apply
  [ "$status" -eq 3 ]
  [ -f "$LOCAL_ROOT/audit/a1.carried" ]
  [ ! -e "$LOCAL_ROOT/older.json" ]
  printf '%s\n' "$stderr" | grep -q 'audit/a1.carried'
}

@test "an unrecognized argument is a usage error that deletes nothing" {
  make_sweep_repo
  put older.json
  sweep --aply
  [ "$status" -eq 2 ]
  [ -f "$LOCAL_ROOT/older.json" ]
}

@test "no .gaia/local at all is nothing to sweep" {
  make_sweep_repo
  rm -rf "$LOCAL_ROOT"
  sweep --apply
  [ "$status" -eq 0 ]
}

# ========== the shipped registry ==========

# shipped_classify <relative path>: classify against this branch's registry from
# a scratch repository, never the main checkout's copy.
shipped_classify() {
  if [ -z "${SHIPPED_REPO:-}" ]; then
    SHIPPED_REPO="$(mktemp -d "$BATS_TEST_TMPDIR/shipped.XXXXXX")"
    mkdir -p "$SHIPPED_REPO/.gaia/scripts"
    cp "$SCRIPT_DIRECTORY/state-registry-lib.sh" "$SCRIPT_DIRECTORY/main-root-lib.sh" "$SHIPPED_REPO/.gaia/scripts/"
    cp "$REGISTRY" "$SHIPPED_REPO/.gaia/state-registry.json"
    git -C "$SHIPPED_REPO" init -q
  fi
  (cd "$SHIPPED_REPO" && bash .gaia/scripts/state-registry-lib.sh "${2:-classify}" "$1" ${3:+"$3"})
}

@test "shipped registry: every residue successor is a live directory, never itself residue" {
  local successors successor count=0
  successors="$(jq -r '.residue[] | select(has("successor")) | .successor' "$REGISTRY")"
  while IFS= read -r successor; do
    [ -n "$successor" ] || continue
    count=$((count + 1))
    shipped_classify "${successor%/}" recognizes d || { printf 'successor unrecognized: %s\n' "$successor" >&2; return 1; }
    [ "$(shipped_classify "${successor%/}")" != residue ] || { printf 'successor is residue: %s\n' "$successor" >&2; return 1; }
  done <<<"$successors"
  [ "$count" -eq "$(jq '[.residue[] | select(has("successor"))] | length' "$REGISTRY")" ]
  [ "$count" -gt 0 ]
}

@test "shipped registry: a 1.6.1 commit-keyed marker is residue, a 2.0.0 digest-keyed one is live" {
  local commit_key digest_key
  commit_key="$(printf 'c%.0s' $(seq 1 40))"
  digest_key="$(printf 'c%.0s' $(seq 1 64))"
  [ "$(shipped_classify "audit/$commit_key.ok")" = residue ]
  [ "$(shipped_classify "audit/$digest_key.ok")" = shared ]
  [ "$(shipped_classify "audit/$digest_key.code-audit-frontend.ok")" = shared ]
  [ "$(shipped_classify "audit/c1")" = residue ]
  [ "$(shipped_classify "audit/c1$digest_key.ok")" = shared ]
}
