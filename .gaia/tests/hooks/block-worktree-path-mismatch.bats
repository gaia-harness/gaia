#!/usr/bin/env bats

# Tests for .claude/hooks/block-worktree-path-mismatch.sh.
#
# Regression coverage for tech-debt #841: once a session has switched into a
# linked worktree, an Edit/Write/MultiEdit call whose file_path resolves to a
# *different* git worktree (most often the main checkout) is a stale
# pre-switch path applied silently, no error, because both paths are real,
# valid files on disk. This guard denies that call deterministically. It is
# a no-op outside a linked-worktree session (feature-branch mode or a plain
# checkout), and fails open on anything it cannot resolve (a target
# directory that does not exist yet, a path outside any git repository).
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-worktree-path-mismatch.sh"
  SETTINGS_ABSOLUTE_PATH="${HOOKS_SOURCE_DIRECTORY%/hooks}/settings.json"
  MAIN_ROOT_LIBRARY="$(cd "$HOOKS_SOURCE_DIRECTORY/../.." && pwd)/.gaia/scripts/main-root-lib.sh"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${NONREPO:-}" ] && rm -rf "$NONREPO"
  [ -n "${SYMLINK_REPO:-}" ] && rm -f "$SYMLINK_REPO"
  return 0
}

# Canonicalize via `pwd -P` (mirrors .gaia/scripts/tests/link-worktree.bats):
# macOS resolves /var -> /private/var inside `git rev-parse`, and the hook
# compares its own git-derived paths against this raw REPO/NONREPO value, so a
# non-canonical tmp path would desync from what the hook reports and produce
# a false mismatch that has nothing to do with the guard under test.
make_repo() {
  REPO_RAW=$(mktemp -d -t gaia-wt-mismatch-repo-XXXXXX)
  REPO="$(cd "$REPO_RAW" && pwd -P)"
  git -C "$REPO" init -q --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  echo init >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
  write_registry
}

# The guard reads the exempt set from .gaia/state-registry.json via
# .gaia/scripts/state-registry-lib.sh (gaia_registry_recognizes,
# gaia_registry_classify), never a hardcoded list. Every test repo therefore
# needs a registry the reader can find at <main-root>/.gaia/state-registry.json.
# This is a minimal fixture, not the real registry, so the tests exercise the
# registry-read MECHANISM and stay decoupled from the shipped registry's exact
# contents. It carries the four symlinked shared dirs (audit, debt, telemetry,
# cache/shared) plus the symlinked setup-state.json file, three main-anchored
# dirs (the two real ledgers, plans and specs, plus a synthetic third,
# fixture-main-dir, that exists only to prove the guard's arm consumes the
# whole main-only-dir set rather than a hand-listed pair), one main-only FILE
# (cache/gh-artifact-pr.json) that must NOT exempt its cache/ segment, and one
# per-tree dir (forensics) representing the keyed entries the flip protects.
write_registry() {
  mkdir -p "$REPO/.gaia"
  cat >"$REPO/.gaia/state-registry.json" <<'JSON'
{
  "version": 1,
  "description": "block-worktree-path-mismatch test fixture",
  "entries": [
    { "id": "setup-state", "path": "setup-state.json", "match": "exact", "kind": "file", "scope": "shared" },
    { "id": "cache-shared", "path": "cache/shared/", "match": "prefix", "kind": "dir", "scope": "shared" },
    { "id": "audit", "path": "audit/*.ok", "match": "glob", "kind": "file", "scope": "shared" },
    { "id": "telemetry", "path": "telemetry/usage.jsonl", "match": "exact", "kind": "file", "scope": "shared" },
    { "id": "debt", "path": "debt/count.json", "match": "exact", "kind": "file", "scope": "shared" },
    { "id": "specs", "path": "specs/", "match": "prefix", "kind": "dir", "scope": "main-only" },
    { "id": "plans", "path": "plans/", "match": "prefix", "kind": "dir", "scope": "main-only" },
    { "id": "fixture-main-dir", "path": "fixture-main-dir/<name>/", "match": "prefix", "kind": "dir", "scope": "main-only" },
    { "id": "gh-cache", "path": "cache/gh-artifact-pr.json", "match": "exact", "kind": "file", "scope": "main-only" },
    { "id": "forensics", "path": "forensics/", "match": "prefix", "kind": "dir", "scope": "per-tree" }
  ],
  "residue": []
}
JSON
}

# The acting tree's own gaia_tree_key, computed via the real
# main-root-lib.sh (not fixture-specific; the resolver depends only on git
# layout, never on the registry). Used to construct a per-tree write the
# guard must recognize as this tree's own.
own_tree_key() {
  bash "$MAIN_ROOT_LIBRARY" --tree-key "$1"
}

# make_worktree <worktree_name> <branch>: a real linked worktree at
# <REPO>/.claude/worktrees/<worktree_name>, mirroring how GAIA creates plan/debt
# worktrees. Sets WORKTREE to the worktree's absolute path.
make_worktree() {
  local worktree_name="$1" branch_name="$2"
  git -C "$REPO" branch "$branch_name"
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/$worktree_name" "$branch_name"
  WORKTREE="$REPO/.claude/worktrees/$worktree_name"
}

# A payload path can carry quotes of its own, so delivery goes through
# `invoke_hook` (helpers/run-hook.sh) rather than any local variant.
run_hook_edit() {
  local tool="$1" path="$2"
  local json
  json=$(jq -n --arg tool_name "$tool" --arg file_path "$path" '{tool_name: $tool_name, tool_input: {file_path: $file_path}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# expect_verdict <label> allow|deny: the hook exited 0 and its verdict matches.
# Explicit returns, so a table row that calls it reports its own label.
expect_verdict() {
  local label="$1" verdict="$2"
  [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
  if grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
    [ "$verdict" = deny ] || { echo "case $label: denied, expected allow: $output"; return 1; }
  else
    [ "$verdict" = allow ] || { echo "case $label: allowed, expected deny"; return 1; }
  fi
}

# --- allowed: editing inside the current worktree ---

@test "an edit inside the current worktree is allowed (Edit, Write, MultiEdit)" {
  local row label tool target
  make_repo
  make_worktree "debt/1-foo" "debt/1-foo"
  mkdir -p "$WORKTREE/sub"
  cd "$WORKTREE"
  for row in \
    "edit-tracked|Edit|$WORKTREE/f" \
    "write-new-under-subdirectory|Write|$WORKTREE/sub/new.ts" \
    "multiedit-tracked|MultiEdit|$WORKTREE/f"; do
    label=${row%%|*}; row=${row#*|}; tool=${row%%|*}; target=${row#*|}
    run_hook_edit "$tool" "$target"
    expect_verdict "$label" allow || return 1
  done
}

# --- denied: the #841 regression, a stale path into a different checkout ---

# bats test_tags=protected
@test "Edit targeting the main checkout while the session is inside the worktree is denied" {
  make_repo
  make_worktree "debt/4-foo" "debt/4-foo"
  cd "$WORKTREE"
  run_hook_edit "Edit" "$REPO/f"
  assert_denied_by_json
}

@test "Write or MultiEdit targeting the main checkout while the session is inside the worktree is denied" {
  local row label tool target
  make_repo
  make_worktree "debt/5-foo" "debt/5-foo"
  cd "$WORKTREE"
  for row in \
    "write-new|Write|$REPO/new.ts" \
    "multiedit-tracked|MultiEdit|$REPO/f"; do
    label=${row%%|*}; row=${row#*|}; tool=${row%%|*}; target=${row#*|}
    run_hook_edit "$tool" "$target"
    expect_verdict "$label" deny || return 1
  done
}

# --- allowed: no linked-worktree session, nothing to guard ---

@test "Edit in the main checkout targeting a worktree's file is allowed (no worktree session active)" {
  make_repo
  make_worktree "debt/7-foo" "debt/7-foo"
  cd "$REPO"
  run_hook_edit "Edit" "$WORKTREE/f"
  assert_allowed_by_json
}

# Regression: both roots the guard compares are symlink-canonicalized (main_root
# through the shared resolver, current_root and file_root through `pwd -P`), so
# they stay on the same footing. Reaching the main checkout through a symlinked
# path (an external volume, a cloud-synced folder, or simply a macOS /tmp ->
# /private/tmp style path) resolves to the same physical root either way, so the
# guard does not mistake the main checkout for a linked worktree and deny a
# legitimate main-checkout edit.
@test "a main checkout reached via a symlinked path allows editing a worktree file" {
  make_repo
  make_worktree "debt/11-foo" "debt/11-foo"
  SYMLINK_REPO="${REPO}-symlink"
  ln -s "$REPO" "$SYMLINK_REPO"
  cd "$SYMLINK_REPO"
  run_hook_edit "Edit" "$WORKTREE/f"
  assert_allowed_by_json
}

# --- the shared .gaia/local tree ---

# link-worktree.sh deliberately symlinks a linked worktree's per-machine working
# state out to the main checkout, so audit markers and debt state are shared
# rather than forked. `git -C` resolves a symlink before computing
# --show-toplevel, so a write to the worktree's own .gaia/local/<shared dir>/
# reports file_root as the MAIN checkout and looks like a wrong-checkout write.
# It is the intended write: that tree is shared by construction, and nothing
# under it is a reviewed source surface, so the guard skips it. The exemption is
# registry-driven (gaia_registry_recognizes + gaia_registry_classify), so:
#
# - each symlinked shared dir (audit, debt, telemetry, cache/shared) and the
#   symlinked setup-state.json FILE are allowed; the file's target_dir is the
#   worktree's own real .gaia/local, so it never reaches the exemption and the
#   main-checkout test is what allows it;
# - cache/ is a recognized container (an ancestor of cache/shared/ and the
#   main-only cache/gh-artifact-pr.json entry) with no per-tree entry and no
#   worktree-side copy, so denying a write into it protects nothing;
# - fixture-main-dir/ is a synthetic third main-only directory, exempt through
#   gaia_registry_main_only_dirs like plans/ and specs/, proving that arm reads
#   the whole main-only-dir set rather than a hand-listed pair;
# - a shared dir newly added to the registry is exempted with no edit to the
#   hook, which keeps the guard and link-worktree.sh in lockstep off one
#   registry (this row edits the registry, so it runs last);
# - the exemption is a path-prefix test, so a `.gaia/localish` sibling stays
#   denied, and a .gaia/local tree the registry has never heard of stays denied
#   with a reason naming the registry rather than the stale-path advice:
#   re-resolving the root cannot move a path that reaches main through the one
#   .gaia/local symlink.
#
# Rows share one repository and worktree: each plants its own directory, and
# the verdict depends only on the row's target path.
@test "a worktree-mode write under .gaia/local follows the state registry (symlinked, shared, unknown, lookalike)" {
  local label
  make_repo
  make_worktree "debt/12-foo" "debt/12-foo"
  mkdir -p "$WORKTREE/.gaia/local/cache"
  for label in symlinked-audit lookalike-sibling symlinked-debt symlinked-telemetry \
    symlinked-cache-shared cache-container symlinked-setup-state main-anchored-fixture-dir \
    registry-unknown-tree registry-added-shared-dir; do
    cd "$WORKTREE"
    case "$label" in
      symlinked-audit)
        mkdir -p "$REPO/.gaia/local/audit"
        ln -s "$REPO/.gaia/local/audit" "$WORKTREE/.gaia/local/audit"
        run_hook_edit "Write" "$WORKTREE/.gaia/local/audit/issue-body-abc123.md"
        expect_verdict "$label" allow || return 1
        ;;
      lookalike-sibling)
        mkdir -p "$REPO/.gaia/localish"
        run_hook_edit "Write" "$REPO/.gaia/localish/notes.md"
        expect_verdict "$label" deny || return 1
        ;;
      symlinked-debt)
        mkdir -p "$REPO/.gaia/local/debt"
        ln -s "$REPO/.gaia/local/debt" "$WORKTREE/.gaia/local/debt"
        run_hook_edit "Write" "$WORKTREE/.gaia/local/debt/refresh-requested"
        expect_verdict "$label" allow || return 1
        ;;
      symlinked-telemetry)
        mkdir -p "$REPO/.gaia/local/telemetry"
        ln -s "$REPO/.gaia/local/telemetry" "$WORKTREE/.gaia/local/telemetry"
        run_hook_edit "Write" "$WORKTREE/.gaia/local/telemetry/tally.jsonl"
        expect_verdict "$label" allow || return 1
        ;;
      symlinked-cache-shared)
        mkdir -p "$REPO/.gaia/local/cache/shared"
        ln -s "$REPO/.gaia/local/cache/shared" "$WORKTREE/.gaia/local/cache/shared"
        run_hook_edit "Write" "$WORKTREE/.gaia/local/cache/shared/blob.json"
        expect_verdict "$label" allow || return 1
        ;;
      cache-container)
        mkdir -p "$REPO/.gaia/local/cache"
        run_hook_edit "Write" "$REPO/.gaia/local/cache/draft-SPEC-001.md"
        expect_verdict "$label" allow || return 1
        ;;
      symlinked-setup-state)
        mkdir -p "$REPO/.gaia/local"
        echo '{}' >"$REPO/.gaia/local/setup-state.json"
        ln -s "$REPO/.gaia/local/setup-state.json" "$WORKTREE/.gaia/local/setup-state.json"
        run_hook_edit "Write" "$WORKTREE/.gaia/local/setup-state.json"
        expect_verdict "$label" allow || return 1
        ;;
      main-anchored-fixture-dir)
        mkdir -p "$REPO/.gaia/local/fixture-main-dir/some-lock"
        run_hook_edit "Write" "$REPO/.gaia/local/fixture-main-dir/some-lock/lock"
        expect_verdict "$label" allow || return 1
        ;;
      registry-unknown-tree)
        mkdir -p "$REPO/.gaia/local/unregistered"
        run_hook_edit "Write" "$REPO/.gaia/local/unregistered/notes.md"
        expect_verdict "$label" deny || return 1
        grep -qF -- ".gaia/state-registry.json" <<<"$output" || { echo "case $label: the reason names no registry"; return 1; }
        grep -qF -- "git rev-parse --show-toplevel" <<<"$output" && { echo "case $label: the reason repeats the stale-path advice"; return 1; }
        ;;
      registry-added-shared-dir)
        jq '.entries += [{ "id": "newshared", "path": "newshared/", "match": "prefix", "kind": "dir", "scope": "shared" }]' \
          "$REPO/.gaia/state-registry.json" >"$REPO/.gaia/state-registry.json.tmp"
        mv "$REPO/.gaia/state-registry.json.tmp" "$REPO/.gaia/state-registry.json"
        mkdir -p "$REPO/.gaia/local/newshared"
        ln -s "$REPO/.gaia/local/newshared" "$WORKTREE/.gaia/local/newshared"
        run_hook_edit "Write" "$WORKTREE/.gaia/local/newshared/marker"
        expect_verdict "$label" allow || return 1
        ;;
    esac
  done
}

# link-worktree.sh symlinks the worktree's whole .gaia/local to main's
# own .gaia/local, so a write into ANY subpath of it -- forensics/ included --
# physically resolves to main and would otherwise look like the #841
# silent-wrong-write. forensics/ is per-tree scope, so its protection is "does
# the path carry the ACTING tree's own key" (gaia_tree_key,
# .gaia/scripts/main-root-lib.sh). The acting tree's own keyed subtree is the
# correct write and stays allowed; a peer tree's keyed subtree, or the bare
# unkeyed container, is exactly the #841-shaped mistake and stays denied.
#
# The peer refusal has to name the key, not repeat the generic stale-path
# advice: re-resolving the repository root does not move a path that reaches
# main through the one .gaia/local symlink, so the generic message would send
# the caller round a loop it cannot exit.
@test "a worktree-mode write to the keyed or unkeyed forensics subtree" {
  local own_key peer_key="deadbeefdeadbeef"
  make_repo
  make_worktree "debt/15-foo" "debt/15-foo"
  own_key="$(own_tree_key "$WORKTREE")"
  [ "$peer_key" != "$own_key" ] || { echo "the peer key collides with the own key"; return 1; }
  mkdir -p "$REPO/.gaia/local/forensics/$own_key" "$REPO/.gaia/local/forensics/$peer_key"
  cd "$WORKTREE"

  run_hook_edit "Write" "$REPO/.gaia/local/forensics/$own_key/2026-01-01-report.md"
  expect_verdict own-key allow || return 1

  run_hook_edit "Write" "$REPO/.gaia/local/forensics/$peer_key/2026-01-01-report.md"
  expect_verdict peer-key deny || return 1
  grep -qF -- "$own_key" <<<"$output" || { echo "case peer-key: the refusal does not name the own key"; return 1; }
  grep -qF -- "git rev-parse --show-toplevel" <<<"$output" && { echo "case peer-key: the refusal repeats the stale-path advice"; return 1; }

  run_hook_edit "Write" "$REPO/.gaia/local/forensics/2026-01-01-report.md"
  expect_verdict bare-container deny || return 1
}

# tech-debt #934. plan.md puts the plan folder in the main checkout by contract
# and has the worktree-mode orchestrator write PROGRESS.md back to it after
# every phase. A linked worktree holds no plans folder of its own, so the
# main-checkout path is the ONLY path that resolves to a real ledger: there is
# no valid twin, which is what the #841 silent-wrong-write requires. The
# spec-colocated arm is the same contract: a plan under
# .notebook/specs/<SPEC-ID>/plan/ writes its PROGRESS.md there. The carve-out is
# a path-segment match, so a `.notebookish` sibling stays denied. A write
# through the worktree's own .notebook symlink and one straight to the main
# checkout's notebook both land in main-only state and are allowed; the same
# payload aimed at an existing main-checkout directory outside it is denied,
# proving the hook ran against real directories rather than failing open on a
# missing one.
@test "a worktree-mode write to the main checkout's notebook" {
  local row label verdict target
  make_repo
  make_worktree "debt/31-foo" "debt/31-foo"
  mkdir -p "$REPO/.notebook/plans/PLAN-001" "$REPO/.notebook/specs/SPEC-009/plan" \
    "$REPO/.notebookish" "$REPO/.notebook/research/x" "$REPO/src"
  ln -s "$REPO/.notebook" "$WORKTREE/.notebook"
  cd "$WORKTREE"
  for row in \
    "plans-ledger|allow|$REPO/.notebook/plans/PLAN-001/PROGRESS.md" \
    "specs-ledger|allow|$REPO/.notebook/specs/SPEC-009/plan/PROGRESS.md" \
    "notebookish-lookalike|deny|$REPO/.notebookish/notes.md" \
    "through-worktree-symlink|allow|$WORKTREE/.notebook/research/x/a.md" \
    "main-notebook|allow|$REPO/.notebook/research/x/a.md" \
    "main-directory-outside-notebook|deny|$REPO/src/a.md"; do
    label=${row%%|*}; row=${row#*|}; verdict=${row%%|*}; target=${row#*|}
    run_hook_edit "Write" "$target"
    expect_verdict "$label" "$verdict" || return 1
  done
}

# Copies the shipped registry into the fixture repo, replacing the minimal
# fixture write_registry laid down. Only the real-registry cases use it: they
# must prove the shipped entries (not the fixture) are what let the writes
# through. GAIA_TEST_REGISTRY_SRC lets a mutation run point it at a scratch copy.
use_real_registry() {
  cp "${GAIA_TEST_REGISTRY_SRC:-$BATS_TEST_DIRNAME/../../../.gaia/state-registry.json}" \
    "$REPO/.gaia/state-registry.json"
}

# The execution doctrine writes .gaia/local/runs/<key>/STATE.md through Bash in
# the main checkout's shared store; the shipped registry registers runs/ as a
# shared prefix, and an unregistered runsx sibling with the same payload shape
# is denied, so the allow is not a blanket allow. The protected folder is
# recognized as an ancestor of its registered rows and its scope is not
# per-tree, so a worktree's write to a file directly under it lands in main's
# copy and is allowed here (refusing Claude's write to it is
# block-audit-loop-write.sh's job). With every protected row removed the same
# write is denied, so that allow is the registry's recognition and not a failed
# cd; that row edits the registry, so it runs last.
@test "a worktree-mode write under the registered runs and protected folders (real registry)" {
  local label
  make_repo
  use_real_registry
  make_worktree "feat/9-sample" "feat/9-sample"
  mkdir -p "$REPO/.gaia/local/runs/feat/9-sample" "$REPO/.gaia/local/runsx/feat/9-sample" "$REPO/.gaia/local/protected"
  echo state >"$REPO/.gaia/local/runs/feat/9-sample/STATE.md"
  echo state >"$REPO/.gaia/local/runsx/feat/9-sample/STATE.md"
  cd "$WORKTREE"
  for label in runs-folder runsx-sibling protected-unregistered-file protected-override-file protected-rows-removed; do
    case "$label" in
      runs-folder)
        run_hook_edit "Write" "$REPO/.gaia/local/runs/feat/9-sample/STATE.md"
        expect_verdict "$label" allow || return 1
        ;;
      runsx-sibling)
        run_hook_edit "Write" "$REPO/.gaia/local/runsx/feat/9-sample/STATE.md"
        expect_verdict "$label" deny || return 1
        grep -qF -- "no entry in .gaia/state-registry.json recognizes it" <<<"$output" \
          || { echo "case $label: the reason names no registry"; return 1; }
        ;;
      protected-unregistered-file)
        run_hook_edit "Write" "$REPO/.gaia/local/protected/new-state.json"
        expect_verdict "$label" allow || return 1
        ;;
      protected-override-file)
        run_hook_edit "Write" "$REPO/.gaia/local/protected/checkpoint-override.json"
        expect_verdict "$label" allow || return 1
        ;;
      protected-rows-removed)
        [ "$(jq '[.entries[] | select(.path | startswith("protected/"))] | length' "$REPO/.gaia/state-registry.json")" -gt 0 ] \
          || { echo "case $label: the shipped registry has no protected row"; return 1; }
        jq '.entries |= map(select(.path | startswith("protected/") | not))' \
          "$REPO/.gaia/state-registry.json" >"$REPO/.gaia/state-registry.json.new"
        mv "$REPO/.gaia/state-registry.json.new" "$REPO/.gaia/state-registry.json"
        run_hook_edit "Write" "$REPO/.gaia/local/protected/new-state.json"
        expect_verdict "$label" deny || return 1
        grep -qF -- "no entry in .gaia/state-registry.json recognizes it" <<<"$output" \
          || { echo "case $label: the reason names no registry"; return 1; }
        ;;
    esac
  done
}

# --- denied: a sibling worktree, the same wrong-checkout write as #841 ---

# The guard adjudicates one question: does the target resolve into the acting
# tree. A sibling worktree is a different, equally valid checkout, so a write
# from this worktree into a sibling's file is the same silent-wrong-write a stale
# main-checkout path is: a real, valid file in another checkout the edit tools
# apply with no error. The acting tree comes from the process cwd.
@test "an edit to a sibling worktree is denied while cwd sits in another worktree" {
  make_repo
  make_worktree "debt/14-a" "debt/14-a"
  SIBLING_WORKTREE="$WORKTREE"
  make_worktree "debt/14-b" "debt/14-b"
  cd "$WORKTREE"
  run_hook_edit "Edit" "$SIBLING_WORKTREE/f"
  assert_denied_by_json
}

# --- ignored: not our matcher ---

@test "a Read tool call is ignored" {
  make_repo
  make_worktree "debt/8-foo" "debt/8-foo"
  cd "$WORKTREE"
  run_hook_edit "Read" "$REPO/f"
  assert_allowed_by_json
}

# --- fail-open: anything the guard cannot resolve ---

# A process cwd outside every git repository leaves the hook with no checkout to
# adjudicate in, and that row's payload names none either, so there is nothing
# to fall back to and the call fails open.
#
# The dash row is the `dirname --` killer (tech-debt #944, see the defense in
# depth block below). A file_path whose leading component reads as an option
# stops at the `--` terminator and yields `-x`, which the following bare `cd`
# rejects, so the hook fails open the way it does for any unresolvable target.
# Drop the terminator and `dirname` itself option-parses, exiting non-zero under
# `set -e` and aborting the hook mid-adjudication: the status assertion, not the
# verdict, is what separates a clean fail-open from that crash.
@test "an unresolvable target fails open" {
  local row label tool session_cwd target
  make_repo
  make_worktree "debt/9-foo" "debt/9-foo"
  NONREPO=$(mktemp -d -t gaia-wt-mismatch-nonrepo-XXXXXX)
  for row in \
    "missing-target-directory|Write|$WORKTREE|/no-such-parent-dir-xyz/new.ts" \
    "target-outside-any-repository|Edit|$WORKTREE|$NONREPO/scratch.txt" \
    "session-cwd-outside-any-repository|Edit|$NONREPO|$REPO/f" \
    "dirname-leads-with-dash|Write|$WORKTREE|-x/f"; do
    label=${row%%|*}; row=${row#*|}; tool=${row%%|*}; row=${row#*|}
    session_cwd=${row%%|*}; target=${row#*|}
    cd "$session_cwd"
    run_hook_edit "$tool" "$target"
    expect_verdict "$label" allow || return 1
  done
}

# --- defense in depth: the file_path chain's own two guards ---

# tech-debt #944. `dirname --` and `CDPATH=''` on the target_dir/
# resolved_target_dir pair are unreachable in practice, because the Edit,
# Write and MultiEdit tools take file_path as an absolute path with no cwd
# resolution, and an absolute path defeats both. The CDPATH case below and the
# dash row of the fail-open table cover them anyway: that contract rests on an
# external convention the script cannot enforce, so if the harness ever emits a
# relative file_path, they are the only thing standing there, and without
# coverage a future edit dropping either one regresses in silence. Both cases
# are mutation-verified: each fails against a hook with its guard removed.

# CDPATH killer. With CDPATH honored, `cd inner` resolves through CDPATH into
# the exempt audit tree instead of through the worktree's own `inner` symlink,
# so the write is waved through as shared state while git still resolves it to
# the main checkout: a deny becomes an allow. The CDPATH hit lands on a
# SUBdirectory of the exempt tree deliberately. bash echoes the resolved path to
# stdout whenever cd consults CDPATH, so the mutant's capture is two lines; only
# a match one level below the arm's own directory leaves the trailing `*` free
# to absorb the second line, which is what makes the mutant reach the exemption.
@test "a relative file_path is resolved without CDPATH, so an exempt-tree decoy cannot mask it" {
  make_repo
  make_worktree "debt/34-foo" "debt/34-foo"
  mkdir -p "$REPO/.gaia/local/audit/inner"
  ln -s "$REPO" "$WORKTREE/inner"
  cd "$WORKTREE"
  export CDPATH="$REPO/.gaia/local/audit"
  run_hook_edit "Write" "inner/f"
  assert_denied_by_json
}

# --- structural ---

@test "block-worktree-path-mismatch.sh is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit")' block-worktree-path-mismatch.sh
}

# --- library-load degradation (gaia-react/gaia#1556) ------------------------
# These run a COPY of the hook staged inside the tmp repo, so the .gaia/scripts
# it resolves off BASH_SOURCE is one the test controls. Running $HOOK_ABSOLUTE_PATH would
# always resolve the real checkout's libs, where neither the absent nor the
# unparseable case can be expressed.
#
# Two ways a library goes unusable, and this fail-open guard must allow through
# both: it is gone, and it is present but does not parse (an unresolved merge
# conflict, a truncated write). Under `set -e` a failed `.` abandons the shell
# in both cases, at different cost: a file bash cannot open exits 1, an
# advisory that lets the edit through with a raw diagnostic on stderr, while
# one it cannot parse exits 2, the PreToolUse deny code, which turns this
# fail-open guard into one that blocks a legitimate edit.
#
# Both libraries get the pair, and state-registry-lib.sh is not the redundant
# half: it never fails open on its own. gaia_registry_recognizes is consulted
# from inside an `if` condition, so an undefined function reads as "no entry
# recognizes this path" and routes the write to the unregistered DENY arm.
#
# The controls are what give the degrade cases teeth: their assertions (exit 0,
# no output) are equally satisfied by a hook that adjudicates nothing at all, so
# each interpreter gets a control proving the same staging still DENIES.
#
# The degrade rows are pinned to stock /bin/bash, and it is the pin rather
# than the failure mode that decides. Both loads carried `|| exit 0` before this
# change, and bash 5 reaches that arm for a missing file AND for an unparseable
# one, so only 3.2 tells the parse check apart from the form it replaced.
# Measured both ways on this machine: 3.2.57 exits 1 (missing) and 2
# (unparseable) on the old form and 0 on the new, 5.3.15 exits 0 on both forms.
# On a bash-5 /bin/bash (Linux CI) the degrade rows pass either way. A /bin/bash row is
# passed over when /bin/bash is absent.
stage_hook_repo() {
  make_repo
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  STAGED_HOOK="$REPO/.claude/hooks/block-worktree-path-mismatch.sh"
  cp "$HOOK_ABSOLUTE_PATH" "$STAGED_HOOK"
  chmod +x "$STAGED_HOOK"
  # The jq-availability arm loads ahead of both libraries these cases degrade,
  # and refuses when it cannot find its own, so a staging without it answers
  # every case below with that refusal rather than the degrade under test.
  cp "${HOOK_ABSOLUTE_PATH%/*}/lib/jq-availability.sh" "$REPO/.claude/hooks/lib/"
  stage_usable_libraries
  make_worktree "debt/lib-degrade" "debt/lib-degrade"
}

# stage_usable_libraries: (re)copy both libraries the degrade rows break.
stage_usable_libraries() {
  cp "${MAIN_ROOT_LIBRARY%/*}/main-root-lib.sh" "${MAIN_ROOT_LIBRARY%/*}/state-registry-lib.sh" \
    "$REPO/.gaia/scripts/"
}

# run_staged_hook <path> <cwd> [interpreter]: runs the staged hook with its
# process cwd at <cwd>, which is what the acting tree now resolves from.
run_staged_hook() {
  local json interpreter="${3:-bash}"
  json=$(jq -n --arg file_path "$1" '{tool_name: "Edit", tool_input: {file_path: $file_path}}')
  run bash -c 'cd "$1" && printf %s "$2" | "$3" "$4"' _ "$2" "$json" "$interpreter" "$STAGED_HOOK"
}

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_library() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

# The registry reader loads at its point of use rather than beside the
# resolver, so reaching it takes a write under .gaia/local naming a path the
# registry does not recognize -- the arm that would otherwise DENY. A payload
# aimed anywhere else never loads the lib at all, and a case written that way
# would green against any spelling of this load, including no load whatsoever.
stage_unregistered_local_target() {
  UNREGISTERED_DIRECTORY="$REPO/.gaia/local/fixture-unregistered"
  mkdir -p "$UNREGISTERED_DIRECTORY"
}

# Rows share one staged repository; each row re-copies both libraries before it
# breaks one, so no row sees another's damage.
@test "a missing, conflicted or usable library: deny stays, fail-open is silent" {
  local row label interpreter target breakage expected
  stage_hook_repo
  stage_unregistered_local_target
  for row in \
    "control-bash|bash|cross-tree|none|deny" \
    "control-stock-bash|/bin/bash|cross-tree|none|deny" \
    "main-root-lib-absent|/bin/bash|cross-tree|absent:main-root-lib.sh|silent" \
    "registry-control-bash|bash|unregistered|none|deny" \
    "registry-control-stock-bash|/bin/bash|unregistered|none|deny" \
    "state-registry-lib-absent|/bin/bash|unregistered|absent:state-registry-lib.sh|silent" \
    "main-root-lib-conflicted|/bin/bash|cross-tree|conflicted:main-root-lib.sh|silent" \
    "state-registry-lib-conflicted|/bin/bash|unregistered|conflicted:state-registry-lib.sh|silent"; do
    label=${row%%|*}; row=${row#*|}; interpreter=${row%%|*}; row=${row#*|}
    target=${row%%|*}; row=${row#*|}; breakage=${row%%|*}; expected=${row#*|}
    [ "$interpreter" = bash ] || [ -x "$interpreter" ] || continue
    stage_usable_libraries
    case "$breakage" in
      absent:*) rm -f "$REPO/.gaia/scripts/${breakage#absent:}" ;;
      conflicted:*) write_conflicted_library "$REPO/.gaia/scripts/${breakage#conflicted:}" ;;
    esac
    case "$target" in
      cross-tree) run_staged_hook "$REPO/f" "$WORKTREE" "$interpreter" ;;
      unregistered) run_staged_hook "$UNREGISTERED_DIRECTORY/x" "$WORKTREE" "$interpreter" ;;
    esac
    case "$expected" in
      deny) expect_verdict "$label" deny || return 1 ;;
      silent)
        [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
        [ -z "$output" ] || { echo "case $label: not silent: $output"; return 1; }
        ;;
    esac
  done
}
