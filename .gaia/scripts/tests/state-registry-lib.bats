#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/state-registry-lib.sh, the state-registry
# reader (foundations task 2.3). Two kinds of test live here: functional tests
# of the reader lib's public API against the real, tracked
# .gaia/state-registry.json (this repo's own registry IS the fixture -- it is
# tracked machinery, not per-run test data), and structural/schema tests that
# assert the registry's own invariants directly with jq (no JSON Schema
# validator is a repo dependency, so schema conformance is checked by hand
# against those invariants directly).
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/state-registry-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIBRARY_SCRIPT="$SCRIPT_DIRECTORY/state-registry-lib.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  REGISTRY="$REPO_ROOT/.gaia/state-registry.json"
  # shellcheck source=.gaia/scripts/state-registry-lib.sh
  source "$LIBRARY_SCRIPT"
  OLD_OVERRIDE_RELATIVE=checkpoint-override.json
  OLD_STATE_RELATIVE=audit-loop/feat/x.json
}

# run_in_repo <fn> [args...]: runs a sourced-lib function with cwd = the real
# repo root, regardless of where bats itself was invoked from, so
# gaia_resolve_main_root (via main-root-lib.sh) resolves against this repo's
# own git layout.
run_in_repo() {
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    shift 2
    "$@"
  ' _ "$REPO_ROOT" "$LIBRARY_SCRIPT" "$@"
}

# make_registry_repo: a scratch repo holding this branch's registry (REGISTRY)
# beside copies of the lib, so the reader resolves the branch's rows, not the
# main checkout's. Sets REGISTRY_REPO.
make_registry_repo() {
  REGISTRY_REPO="$(mktemp -d "$BATS_TEST_TMPDIR/reg.XXXXXX")"
  REGISTRY_REPO="$(cd "$REGISTRY_REPO" && pwd -P)"
  mkdir -p "$REGISTRY_REPO/.gaia/scripts"
  cp "$SCRIPT_DIRECTORY/state-registry-lib.sh" "$SCRIPT_DIRECTORY/main-root-lib.sh" "$REGISTRY_REPO/.gaia/scripts/"
  cp "$REGISTRY" "$REGISTRY_REPO/.gaia/state-registry.json"
  git -C "$REGISTRY_REPO" init -q
}

# run_in_registry_repo <fn> [args...]: twin of run_in_repo against the scratch
# repo's copy of the lib and registry.
run_in_registry_repo() {
  make_registry_repo
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$1/.gaia/scripts/state-registry-lib.sh"
    shift
    "$@"
  ' _ "$REGISTRY_REPO" "$@"
}

# ========== structural ==========

@test "structural: state-registry-lib.sh is executable" {
  [ -x "$LIBRARY_SCRIPT" ]
}

@test "structural: sourcing the library defines all public functions with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_registry_path >/dev/null
    type gaia_registry_linkable_paths >/dev/null
    type gaia_registry_rm_whitelist >/dev/null
    type gaia_registry_recognizes >/dev/null
    type gaia_registry_classify >/dev/null
    type gaia_registry_residue_sweep >/dev/null
    echo OK
  ' _ "$LIBRARY_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "structural: the registry is valid JSON" {
  jq empty "$REGISTRY"
}

# ========== gaia_registry_path ==========

@test "gaia_registry_path: resolves to <main-root>/.gaia/state-registry.json" {
  # Anchored on the resolved MAIN root, never on $REPO_ROOT (this file's own
  # location). The two diverge whenever the suite runs from a linked worktree,
  # and main's is the correct answer, so a $REPO_ROOT comparison reds on which
  # checkout bats was invoked from rather than on anything the function does.
  # The sibling test below pins that divergence against a constructed fixture
  # whose main root is known without consulting this resolver.
  local main_root
  main_root="$(source "$SCRIPT_DIRECTORY/main-root-lib.sh" && gaia_resolve_main_root "$REPO_ROOT")"
  run_in_repo gaia_registry_path
  [ "$status" -eq 0 ]
  [ "$output" = "$main_root/.gaia/state-registry.json" ]
}

@test "gaia_registry_path: worktree-safe, resolves the MAIN checkout's registry from inside a linked worktree" {
  # Canonicalized via mktemp/pwd -P: macOS resolves /var -> /private/var inside
  # the resolver's own physical resolution, and the resolver's output is
  # compared byte-for-byte below, so a non-canonical tmp path would desync for
  # reasons that have nothing to do with the function under test (mirrors
  # main-root-lib.bats's own fixture-root note).
  mkdir -p "$BATS_TEST_TMPDIR/wtmain"
  main="$(cd "$BATS_TEST_TMPDIR/wtmain" && pwd -P)"
  mkdir -p "$main/.gaia"
  git init -q --initial-branch=main "$main"
  git -C "$main" config user.email t@example.com
  git -C "$main" config user.name "T"
  git -C "$main" config commit.gpgsign false
  echo '{"version":1,"description":"fixture","entries":[],"residue":[]}' \
    >"$main/.gaia/state-registry.json"
  git -C "$main" add -A
  git -C "$main" commit -q -m init
  git -C "$main" branch wt
  git -C "$main" worktree add -q "$main-wt" wt

  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    gaia_registry_path
  ' _ "$main-wt" "$LIBRARY_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "$main/.gaia/state-registry.json" ]
}

@test "gaia_registry_path: no jq on PATH fails with one stderr diagnostic, nothing on stdout" {
  # bats' `run` merges stdout and stderr into one $output (see
  # main-root-lib.bats's own note on this), so stdout and stderr are captured
  # separately here rather than through `run`.
  error_file="$BATS_TEST_TMPDIR/gaia_registry_path.stderr"
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  # gaia_registry_path is expected to fail here; set +e/-e brackets the call so
  # that expected failure doesn't trip the @test body's own `set -e` before
  # status_value can be captured (a plain, non-`local` assignment's exit status
  # IS the command substitution's, unlike the `local x=$(...)` masking case).
  set +e
  stdout_value="$(gaia_registry_path 2>"$error_file")"
  status_value=$?
  set -e
  PATH="$saved_path"
  [ "$status_value" -eq 1 ]
  [ -z "$stdout_value" ]
  [ -s "$error_file" ]
  [ "$(wc -l <"$error_file" | tr -d ' ')" -eq 1 ]
}

# ========== gaia_registry_linkable_paths ==========
# link-worktree.sh no longer calls this to build its own
# symlink set (a linked worktree's whole .gaia/local is one symlink to
# main's now). It stays as the regression guard the concurrency meter's
# cutover-risk scenarios run against the shipped registry: the concrete proof
# that a per-tree entry is genuinely not shared.

@test "gaia_registry_linkable_paths: prints exactly the 19 shared paths, each by name" {
  run_in_registry_repo gaia_registry_linkable_paths
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 19 ]
  local expected_path
  for expected_path in setup-state.json cache/shared/context cache cache/shared protected \
    settings.json audit audit/light telemetry telemetry/usage-sweep.lock.d debt codify runs \
    ports ports/tombstones ports/launches ports/sessions kept-worktrees.tsv worktree-occupancy; do
    grep -qxF -- "$expected_path" <<<"$output" || return 1
  done
  grep -qxF -- "$OLD_OVERRIDE_RELATIVE" <<<"$output" && return 1
  return 0
}

@test "gaia_registry_classify: the audit loop state and the override classify under protected" {
  run_in_registry_repo gaia_registry_classify protected/audit-loop/feat/x.json
  [ "$status" -eq 0 ]
  [ "$output" = "main-only" ]
  run_in_registry_repo gaia_registry_classify protected/checkpoint-override.json
  [ "$status" -eq 0 ]
  [ "$output" = "shared" ]
}

@test "gaia_registry_classify: a new file directly under protected has no row and classifies unknown" {
  run_in_registry_repo gaia_registry_classify protected/new-state.json
  [ "$output" = "unknown" ]
}

@test "gaia_registry_classify: the old override and state locations classify unknown" {
  run_in_registry_repo gaia_registry_classify "$OLD_OVERRIDE_RELATIVE"
  [ "$output" = "unknown" ]
  run_in_registry_repo gaia_registry_classify "$OLD_STATE_RELATIVE"
  [ "$output" = "unknown" ]
}

@test "gaia_registry_recognizes: protected is recognized as an ancestor with no row of its own" {
  run_in_registry_repo gaia_registry_recognizes protected d
  [ "$status" -eq 0 ]
}

@test "gaia_registry_linkable_paths: a per-tree entry (red-ledger) never appears" {
  run_in_repo gaia_registry_linkable_paths
  [ "$status" -eq 0 ]
  grep -qxF 'red-ledger' <<<"$output" && return 1
  return 0
}

@test "gaia_registry_classify: each port state path maps to its own entry's scope" {
  run_in_registry_repo gaia_registry_classify ports/slots.tsv
  [ "$status" -eq 0 ]
  [ "$output" = "shared" ]
  run_in_registry_repo gaia_registry_classify ports/tombstones/3.1700000000.tsv
  [ "$output" = "shared" ]
  run_in_registry_repo gaia_registry_classify ports/slots.lock
  [ "$output" = "ephemeral" ]
  run_in_registry_repo gaia_registry_classify ports/launches/123.tsv
  [ "$output" = "shared" ]
  run_in_registry_repo gaia_registry_classify ports/sessions/abc.tsv
  [ "$output" = "shared" ]
}

@test "gaia_registry_classify: an unregistered file under ports classifies unknown" {
  run_in_registry_repo gaia_registry_classify ports/other.tsv
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# ========== gaia_registry_rm_whitelist ==========

@test "gaia_registry_rm_whitelist: prints exactly the 9 rm-whitelist rows in registry order" {
  run_in_registry_repo gaia_registry_rm_whitelist
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 9 ]
  [ "${lines[0]}" = $'.notebook/plans\ttrue' ]
  [ "${lines[1]}" = $'.notebook/specs\ttrue' ]
  grep -qF '.gaia/local/specs' <<<"$output" && return 1
  grep -qF '.gaia/local/plans' <<<"$output" && return 1
  [ "${lines[2]}" = $'.gaia/local/audit\ttrue' ]
  [ "${lines[3]}" = $'.gaia/local/cleanse\ttrue' ]
  [ "${lines[4]}" = $'.gaia/local/cache\ttrue' ]
  [ "${lines[5]}" = $'.gaia/local/runs\ttrue' ]
  [ "${lines[6]}" = $'.gaia/local/setup-in-progress\tfalse' ]
  [ "${lines[7]}" = $'dist\tfalse' ]
  [ "${lines[8]}" = $'build\tfalse' ]
}

@test "gaia_registry_rm_whitelist: no jq on PATH returns 1 and prints nothing on stdout (a caller that cannot read the list treats every path as non-whitelisted)" {
  # Stdout and stderr are captured separately here rather than through `run`
  # (which merges them), because gaia_registry_path's own stderr diagnostic
  # would otherwise land in $output and fail the stdout-emptiness assertion
  # for a reason unrelated to this function's own contract.
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  set +e
  stdout_value="$(gaia_registry_rm_whitelist 2>/dev/null)"
  status_value=$?
  set -e
  PATH="$saved_path"
  [ "$status_value" -eq 1 ]
  [ -z "$stdout_value" ]
}

# ========== gaia_registry_recognizes ==========

@test "gaia_registry_recognizes: a known per-tree directory (red-ledger, type d) is recognized" {
  run_in_repo gaia_registry_recognizes "red-ledger" d
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a known residue file (mentorship.json, type f) is recognized" {
  run_in_repo gaia_registry_recognizes "mentorship.json" f
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a known shared glob family (audit clearance marker, type f) is recognized" {
  run_in_repo gaia_registry_recognizes "audit/abc123.ok" f
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a made-up unknown child is NOT recognized" {
  run_in_repo gaia_registry_recognizes "totally-made-up-thing.xyz" f
  [ "$status" -eq 1 ]
}

@test "gaia_registry_recognizes: jq unavailable fails SAFE (recognized, exit 0) rather than reaping the unknown" {
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  run gaia_registry_recognizes "totally-made-up-thing.xyz" f
  PATH="$saved_path"
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a bare container dir that holds classified children (audit) is recognized as their ancestor" {
  run_in_repo gaia_registry_recognizes "audit" d
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a nested container dir (audit/security) is recognized as an ancestor" {
  run_in_repo gaia_registry_recognizes "audit/security" d
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a made-up dir that is NOT an ancestor of any entry is unknown" {
  run_in_repo gaia_registry_recognizes "cache/adopter-owned-thing" d
  [ "$status" -eq 1 ]
}

@test "gaia_registry_recognizes: ancestor recognition is for directories only, a same-named FILE is not a container" {
  # A file cannot hold entries; `audit` as a type-f arg must not borrow the
  # directory's ancestor recognition.
  run_in_repo gaia_registry_recognizes "audit" f
  [ "$status" -eq 1 ]
}

# ========== gaia_registry_classify ==========

@test "gaia_registry_classify: red-ledger classifies as per-tree" {
  run_in_repo gaia_registry_classify "red-ledger"
  [ "$status" -eq 0 ]
  [ "$output" = "per-tree" ]
}

@test "gaia_registry_classify: mentorship.json classifies as residue" {
  run_in_repo gaia_registry_classify "mentorship.json"
  [ "$status" -eq 0 ]
  [ "$output" = "residue" ]
}

@test "gaia_registry_classify: an unknown child classifies as unknown" {
  run_in_repo gaia_registry_classify "totally-made-up-thing.xyz"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "gaia_registry_classify: a residue leaf nested under a live shared prefix wins over the containing prefix" {
  run_in_repo gaia_registry_classify "cache/shared/coaching-active.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "residue" ]
}

@test "gaia_registry_classify: jq unavailable prints nothing and returns 1 (not a reap gate, no fail-open contract)" {
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  run gaia_registry_classify "red-ledger"
  PATH="$saved_path"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ========== denominator spot-check (design success check 3, mechanized) ==========
# One representative relative_path per family from the top-level / audit/ / cache/
# inventory tables; every one must classify, never "unknown".

@test "denominator spot-check: a representative sample from every family classifies (none unknown)" {
  local -a cases=(
    "setup-state.json:shared"
    "cache/shared/update-check.json:shared"
    "audit/abc123.ok:shared"
    "audit/abc123.def456.findings.json:shared"
    "audit/security/deadbeef.md:shared"
    "telemetry/token-rates.override.json:shared"
    "debt/count.json:shared"
    "debt/refresh-requested:shared"
    "red-ledger/observations.jsonl:per-tree"
    "worthiness-ledger/worthiness.jsonl:per-tree"
    "forensics/2026-07-23-x.md:per-tree"
    "codify/declines.json:shared"
    "codify/reviewed.json:shared"
    "codify/review-tally.json:shared"
    "harden/declines.json:residue"
    "cache/gh-artifact-pr.treeA.json:main-only"
    ".project-id:main-only"
    "declined-updates.json:main-only"
    ".patched-statusline.sh:main-only"
    "dep-audit-baseline.json:main-only"
    "sandbox.json:main-only"
    "setup-in-progress:main-only"
    "cache/draft-SPEC-042.md:ephemeral"
    "cache/gate1-SPEC-042.json:ephemeral"
    "cache/spec-session-SPEC-042.json:ephemeral"
    "cache/audit-SPEC-042:ephemeral"
    "cache/mutation-scratch/abc123.work.code-audit-frontend:ephemeral"
    "cache/some-run/renders.json:ephemeral"
    "cleanse/KNOWLEDGE-2026-07-23.md:ephemeral"
    "cleanse/filing-outcomes-abc.jsonl:ephemeral"
    "cleanse/filing-retry/x.json:ephemeral"
    "audit/KNOWLEDGE-2026-07-23.md:residue"
    "audit/issue-body-abc.md:ephemeral"
    "mentorship.json:residue"
    "telemetry/cost"".jsonl:residue"
    "telemetry/token-rates.json:residue"
    "telemetry/token-rates.base.json:residue"
    "telemetry/token-rates.dist.json:residue"
    "telemetry/token-rates.feed-state.json:residue"
    "telemetry/token-rates.json.corrupt.1790000000.abc123:residue"
    "telemetry/.token-rates.json.tmp.AbC123:residue"
    "telemetry/.token-rates.feed-body.tmp.AbC123:residue"
    "telemetry/cloud/x.json:residue"
    "telemetry/analytics/x.json:residue"
    "cache/shared/coaching-active.txt:residue"
    "audit/abc123.carried:residue"
    ".mentorship-swept:residue"
    "plans/archived/PLAN-001:report-only"
    "specs/archived/SPEC-001:report-only"
    "handoff/2026-07-23-x.md:residue"
  )
  local case_line relative_path expected got
  for case_line in "${cases[@]}"; do
    relative_path="${case_line%%:*}"
    expected="${case_line##*:}"
    run_in_registry_repo gaia_registry_classify "$relative_path"
    got="$output"
    if [ "$got" = "unknown" ]; then
      echo "NOT COVERED: $relative_path (expected $expected)"
      return 1
    fi
    if [ "$got" != "$expected" ]; then
      echo "WRONG SCOPE: $relative_path got '$got' expected '$expected'"
      return 1
    fi
  done
}

# ========== roots ==========

@test "roots: a notebook-root path is recognized and classified main-only by the notebook root only" {
  run_in_registry_repo gaia_registry_recognizes specs/SPEC-001 d notebook
  [ "$status" -eq 0 ]
  run_in_registry_repo gaia_registry_classify specs/SPEC-001 notebook
  [ "$status" -eq 0 ]
  [ "$output" = "main-only" ]
  run_in_registry_repo gaia_registry_classify plans/PLAN-001 notebook
  [ "$output" = "main-only" ]
  run_in_registry_repo gaia_registry_classify research/topic-2026-10-01 notebook
  [ "$output" = "main-only" ]
  run_in_registry_repo gaia_registry_classify catalog.json notebook
  [ "$status" -eq 0 ]
  [ "$output" = "main-only" ]
}

@test "roots: the default local root judges the old roots by the report-only rows, never the moved rows" {
  run_in_registry_repo gaia_registry_classify specs/SPEC-001
  [ "$output" = "report-only" ]
  run_in_registry_repo gaia_registry_classify specs/SPEC-001 local
  [ "$output" = "report-only" ]
  run_in_registry_repo gaia_registry_classify catalog.json
  [ "$output" = "unknown" ]
  run_in_registry_repo gaia_registry_classify specs/archived/x
  [ "$output" = "report-only" ]
  run_in_registry_repo gaia_registry_recognizes research/topic-2026-10-01 d
  [ "$status" -eq 0 ]
}

@test "roots: a local-root path is not matched by a notebook query" {
  run_in_registry_repo gaia_registry_classify setup-state.json notebook
  [ "$output" = "unknown" ]
  run_in_registry_repo gaia_registry_recognizes setup-state.json f notebook
  [ "$status" -eq 1 ]
}

@test "roots: a fixture registry whose specs row lacks root makes the notebook query unknown" {
  make_registry_repo
  jq 'del(.report_only) | del(.entries[] | select(.id == "specs-main") | .root)' "$REGISTRY" >"$REGISTRY_REPO/.gaia/state-registry.json"
  run bash -c '
    cd "$1" || exit 1
    source "$1/.gaia/scripts/state-registry-lib.sh"
    gaia_registry_classify specs/SPEC-001 notebook
  ' _ "$REGISTRY_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
  run bash -c '
    cd "$1" || exit 1
    source "$1/.gaia/scripts/state-registry-lib.sh"
    gaia_registry_classify specs/SPEC-001
  ' _ "$REGISTRY_REPO"
  [ "$output" = "main-only" ]
}

@test "roots: the CLI verbs take the root as the last argument" {
  make_registry_repo
  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh classify catalog.json notebook' _ "$REGISTRY_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "main-only" ]
  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh recognizes catalog.json f notebook' _ "$REGISTRY_REPO"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh recognizes catalog.json f' _ "$REGISTRY_REPO"
  [ "$status" -eq 1 ]
}

@test "roots: linkable paths list local rows only" {
  run_in_registry_repo gaia_registry_linkable_paths
  [ "$status" -eq 0 ]
  grep -qxF 'specs' <<<"$output" && return 1
  grep -qxF 'catalog.json' <<<"$output" && return 1
  true
}

@test "roots: the notebook rows carry the notebook root and the catalog row is the library's" {
  [ "$(jq -r '[.entries[] | select(.id == "specs-main" or .id == "plans-main" or .id == "research-main") | .root] | join(",")' "$REGISTRY")" = "notebook,notebook,notebook" ]
  [ "$(jq -r '.entries[] | select(.id == "notebook-catalog") | [.root, .path, .match, .kind, .scope, .writer, .retention.class] | join(",")' "$REGISTRY")" = "notebook,catalog.json,exact,file,main-only,code,keep" ]
}

@test "integrity snapshot: the verb is gone and the registry block is retired" {
  run bash "$LIBRARY_SCRIPT" integrity-snapshot
  [ "$status" -eq 2 ]
  [ "$(jq -c '.integrity_snapshot' "$REGISTRY")" = "null" ]
}

# ========== schema-shaped structural invariants (no validator dependency; direct jq) ==========

@test "schema invariant: every scope==shared entry has a non-empty string keyed_by" {
  run jq -e '[.entries[] | select(.scope == "shared") | (.keyed_by | type == "string" and length > 0)] | all' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "schema invariant: every per-tree entry has a non-empty string keyed_by" {
  run jq -e '[.entries[] | select(.scope == "per-tree") | (.keyed_by | type == "string" and length > 0)] | all' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "schema invariant: every main-only or ephemeral entry has keyed_by == null" {
  run jq -e '[.entries[] | select(.scope == "main-only" or .scope == "ephemeral") | (.keyed_by == null)] | all' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "schema invariant: match/kind/scope/writer enums are all within the allowed set" {
  run jq -e '
    ([.entries[].match] | all(. as $match_type | ["exact","glob","prefix"] | index($match_type) != null))
    and ([.entries[].kind] | all(. as $kind | ["file","dir"] | index($kind) != null))
    and ([.entries[].scope] | all(. as $scope | ["shared","per-tree","main-only","ephemeral"] | index($scope) != null))
    and ([.entries[].writer] | all(. as $writer | ["code","hand-authored"] | index($writer) != null))
    and ([.residue[].match] | all(. as $match_type | ["exact","glob","prefix"] | index($match_type) != null))
    and ([.residue[].writer] | all(. == "none-residue"))
  ' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "schema invariant: no duplicate ids across entries and residue" {
  run jq -e '
    ([(.entries[].id), (.residue[].id)]) as $all
    | ($all | length) == ($all | unique | length)
  ' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "schema invariant: every entry and residue row carries all required fields" {
  run jq -e '
    (.entries | all(has("id") and has("path") and has("match") and has("kind") and has("scope") and has("keyed_by") and has("why") and has("writer") and has("retention") and (has("reaped_by") | not)))
    and (.residue | all(has("id") and has("path") and has("match") and has("why") and has("writer")))
  ' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# The light-review state and its maintainer-only routing log are shared state.
# The directory row precedes the audit-store glob rows, so a file under it is
# never claimed by a looser pattern first.

@test "gaia_registry_classify: light-review state and the routing log classify shared" {
  run_in_registry_repo gaia_registry_classify audit/light/route-record.json
  [ "$status" -eq 0 ]
  [ "$output" = "shared" ]
  run_in_registry_repo gaia_registry_classify audit/light/branch-ledger.json
  [ "$status" -eq 0 ]
  [ "$output" = "shared" ]
  run_in_registry_repo gaia_registry_classify telemetry/audit-light-routing.jsonl
  [ "$status" -eq 0 ]
  [ "$output" = "shared" ]
}

@test "gaia_registry_classify: a sibling of the routing log is not claimed by its row" {
  # The exact row cannot absorb a neighbor: this one has no row of its own
  # beyond the telemetry singletons, so it must not classify shared by accident.
  run_in_registry_repo gaia_registry_classify telemetry/audit-light-routing.jsonl.bak
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "gaia_registry_recognizes: the light-review directory is recognized, an unregistered sibling is not" {
  run_in_registry_repo gaia_registry_recognizes audit/light d
  [ "$status" -eq 0 ]
  run_in_registry_repo gaia_registry_recognizes audit/light-unregistered d
  [ "$status" -ne 0 ]
}

# ========== retired cost stores and the price override ==========
# The retired cost ledger and the seeded rate-table files stay on disk unread,
# so the registry keeps recognizing them as residue; the optional price override
# is live shared state. The names are assembled from parts so this file holds no
# retired name literally.

retired_cost_state_paths() {
  printf '%s\n' \
    "telemetry/cost"".jsonl" \
    "telemetry/token-rates.json" \
    "telemetry/token-rates.base.json" \
    "telemetry/token-rates.dist.json" \
    "telemetry/token-rates.feed-state.json" \
    "telemetry/token-rates.json.corrupt.*" \
    "telemetry/.token-rates*.tmp.*"
}

# retired_cost_state_violations <registry>: one line per way the registry
# departs from the retired-cost-state shape; empty when it conforms.
retired_cost_state_violations() {
  local retired_json
  retired_json="$(retired_cost_state_paths | jq -R . | jq -s .)"
  jq -r --argjson retired "$retired_json" '
    ([ $retired[] as $path
       | (select([.residue[] | select(.path == $path and .writer == "none-residue")] | length != 1) | "not residue: " + $path),
         (select([.entries[] | select(.path == $path)] | length != 0) | "still live: " + $path) ])
    + (if ([.entries[] | select(.path | test("audit-window"))] | length) != 0 then ["audit-window entry present"] else [] end)
    + (if ([.entries[] | select(.id == "telemetry-rate-override" and .path == "telemetry/token-rates.override.json" and .match == "exact" and .kind == "file" and .scope == "shared" and .writer == "hand-authored" and .retention.class == "keep")] | length) == 1 then [] else ["override entry missing or wrong"] end)
    | .[]
  ' "$1"
}

@test "registry: the retired cost stores are residue only, the audit-window entry is gone, the price override is live" {
  [ -n "$(retired_cost_state_paths)" ]
  [ -z "$(retired_cost_state_violations "$REGISTRY")" ]
}

@test "registry: a scratch registry restoring the audit-window entry is caught" {
  local scratch="$BATS_TEST_TMPDIR/restored-window.json"
  jq '.entries += [{"id":"audit-window-breadcrumb","path":"cache/audit-window-*.json","match":"glob","kind":"file","scope":"ephemeral","keyed_by":null,"why":"x","writer":"code","retention":{"class":"keep"}}]' "$REGISTRY" >"$scratch"
  retired_cost_state_violations "$scratch" | grep -qF "audit-window entry present"
}

@test "registry: a scratch registry with the cost ledger live again, or the override missing, is caught" {
  local scratch="$BATS_TEST_TMPDIR/live-ledger.json" ledger_path="telemetry/cost"".jsonl"
  jq --arg path "$ledger_path" '.entries += [{"id":"x","path":$path,"match":"exact","kind":"file","scope":"shared","keyed_by":"x","why":"x","writer":"code","retention":{"class":"keep"}}]' "$REGISTRY" >"$scratch"
  retired_cost_state_violations "$scratch" | grep -qF "still live: $ledger_path"
  jq 'del(.entries[] | select(.id == "telemetry-rate-override"))' "$REGISTRY" >"$scratch"
  retired_cost_state_violations "$scratch" | grep -qF "override entry missing or wrong"
  jq --arg path "$ledger_path" 'del(.residue[] | select(.path == $path))' "$REGISTRY" >"$scratch"
  retired_cost_state_violations "$scratch" | grep -qF "not residue: $ledger_path"
}

@test "gaia_registry_recognizes and classify: retired cost files are residue and the override is shared" {
  local retired_file
  for retired_file in "telemetry/cost"".jsonl" telemetry/token-rates.json telemetry/token-rates.base.json \
    telemetry/token-rates.dist.json telemetry/token-rates.feed-state.json \
    telemetry/token-rates.json.corrupt.1790000000.abc123 telemetry/.token-rates.json.tmp.AbC123; do
    run_in_registry_repo gaia_registry_recognizes "$retired_file" f
    [ "$status" -eq 0 ] || { echo "not recognized: $retired_file"; return 1; }
    run_in_registry_repo gaia_registry_classify "$retired_file"
    [ "$output" = "residue" ] || { echo "not residue: $retired_file got $output"; return 1; }
  done
  run_in_registry_repo gaia_registry_recognizes telemetry/token-rates.override.json f
  [ "$status" -eq 0 ]
  run_in_registry_repo gaia_registry_classify telemetry/token-rates.override.json
  [ "$output" = "shared" ]
}

# ------------------------------------------------------------------ retention
#
# Every entries[] row names how its state is pruned in a `retention` object.
# The cases below pin the class table row by row, the first-match order of the
# rows that overlap, and the field legality of every row.

# expected_retention_table: one row per entries[] id, fields separated by
# single spaces, "-" for an absent field. Columns: id, class, days, key,
# session_days, types (comma list), names (comma list).
expected_retention_table() {
  cat <<'TABLE'
setup-state keep - - - - -
context-readings age 7 - - file *.json,*.json.tmp.*
cache-shared-orphan-temps age 7 - - file -
cache-shared owned - - - - -
state-reaper-state owned - - - - -
checkpoint-override keep - - - - -
local-settings keep - - - - -
audit-light-review-ledger branch-spent 7 slug-glob - - -
audit-light-review-state age 30 - - - -
audit-clearance-markers age 30 - - - -
audit-findings-rerun-sidecars branch-spent 7 slug-dot-field - - -
audit-scope-digests branch-spent 7 slug-dot-field - - -
audit-review-diffs branch-spent 7 slug-dot-field - - -
audit-security-notes age 30 - - - -
telemetry-rate-override keep - - - - -
telemetry-usage-ledger keep - - - - -
telemetry-links-ledger keep - - - - -
telemetry-audit-light-routing keep - - - - -
telemetry-usage-cursor-cache keep - - - - -
telemetry-usage-branch-memo keep - - - - -
telemetry-usage-sweep-lock owned - - - - -
telemetry-usage-tmp age 7 - - file -
debt-count-and-refresh keep - - - - -
red-ledger tree-gone - - - - -
audit-worthiness-ledger tree-gone - - - - -
forensics tree-gone - - - - -
codify-declines keep - - - - -
codify-review-snapshot keep - - - - -
specs-main owned - - - - -
plans-main owned - - - - -
research-main owned - - - - -
notebook-catalog keep - - - - -
gh-artifact-pr-cache branch-spent 7 slug-glob - - -
residual-triage-caches keep - - - - -
audit-loop-state branch-spent 7 audit-loop - - -
harness-verify-pass branch-spent 7 normalized-file - - -
project-id keep - - - - -
declined-updates keep - - - - -
statusline-wrappers keep - - - - -
machine-markers keep - - - - -
spec-draft-and-gate1-scratch spec-finalized 30 - - - -
spec-session-scratch spec-finalized 30 - - - -
spec-session-lock spec-finalized 30 - - - -
spec-audit-scratch spec-finalized 30 - - - -
audit-mutation-scratch age 7 - - - -
react-perf-run-scratch age 7 - - - -
audit-scratch-files age 7 - - - -
cleanse-reports owned - - - - -
runs branch-spent 7 normalized-path 30 - -
ports-slot-ledger owned - - - - -
kept-worktrees-ledger owned - - - - -
worktree-occupancy owned - - - - -
ports-tombstones owned - - - - -
ports-slot-lock owned - - - - -
ports-launch-records owned - - - - -
ports-session-registry owned - - - - -
doctrine-injected-marker age 7 - - - -
context-checkpoint-markers age 7 - - file [!.]*,.*.*
context-checkpoint-agent-markers age 7 - - file [!.]*,.*.*
TABLE
}

# retention_table_actual REGISTRY: the registry's own rows in the table's shape.
retention_table_actual() {
  jq -r '.entries[] | [.id, .retention.class, (.retention.days // "-"), (.retention.key // "-"),
    (.retention.session_days // "-"), ((.retention.types // ["-"]) | join(",")),
    ((.retention.names // ["-"]) | join(","))] | join(" ")' "$1"
}

# retention_table_violations REGISTRY: empty when the registry's rows are exactly
# the expected table (same ids, same classes and parameters); otherwise a diff.
retention_table_violations() {
  diff <(expected_retention_table | sort) <(retention_table_actual "$1" | sort)
}

# bats test_tags=whole-tree
@test "registry: every entries row carries exactly the retention class and parameters the table names" {
  local expected_count
  expected_count="$(expected_retention_table | wc -l | tr -d ' ')"
  [ "$expected_count" -gt 0 ]
  [ "$(jq '.entries | length' "$REGISTRY")" -eq "$expected_count" ]
  run retention_table_violations "$REGISTRY"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "registry: a scratch registry with one row's class flipped fails the retention table" {
  local scratch="$BATS_TEST_TMPDIR/flipped-class.json"
  jq '(.entries[] | select(.id == "runs") | .retention.class) = "age"' "$REGISTRY" >"$scratch"
  run retention_table_violations "$scratch"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF "runs"
}

# first_match_row REGISTRY PATH KIND: the id of the first entries row (local root,
# in registry order) that claims PATH. Glob and exact rows match only a path of
# their own kind; prefix rows match any kind. Prints "none" when no row does.
first_match_row() {
  local registry="$1" candidate="$2" candidate_kind="$3" row_id row_match row_kind row_path
  while IFS=$'\t' read -r row_id row_match row_kind row_path; do
    if [ "$row_match" != prefix ] && [ "$row_kind" != "$candidate_kind" ]; then
      continue
    fi
    if _gaia_registry_pattern_matches "$candidate" "$row_path" "$row_match"; then
      printf '%s\n' "$row_id"
      return 0
    fi
  done < <(jq -r '.entries[] | select((.root // "local") == "local") | [.id, .match, .kind, .path] | @tsv' "$registry")
  printf 'none\n'
}

# bats test_tags=whole-tree
@test "registry: the rows that overlap resolve in first-match order" {
  local digest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  [ "${#digest}" -eq 64 ]
  [ "$(first_match_row "$REGISTRY" cache/shared/.updates.AbC123 file)" = cache-shared-orphan-temps ]
  [ "$(first_match_row "$REGISTRY" cache/shared/update-check.json file)" = cache-shared ]
  [ "$(first_match_row "$REGISTRY" cache/shared/.update-check.lock file)" = cache-shared ]
  [ "$(first_match_row "$REGISTRY" 'audit/light/fix%2Fy.reviews.jsonl' file)" = audit-light-review-ledger ]
  [ "$(first_match_row "$REGISTRY" "audit/light/$digest.code-audit-maintainer-shell.route.json" file)" = audit-light-review-state ]
}

# bats test_tags=whole-tree
@test "registry: a new row moved after its prefix row loses the first match" {
  local scratch="$BATS_TEST_TMPDIR/reordered.json"
  jq '.entries |= (map(select(.id != "cache-shared-orphan-temps" and .id != "audit-light-review-ledger"))
    + [$ARGS.named.rows[]])' --argjson rows "$(jq -c '[.entries[] | select(.id == "cache-shared-orphan-temps" or .id == "audit-light-review-ledger")]' "$REGISTRY")" "$REGISTRY" >"$scratch"
  [ "$(first_match_row "$scratch" cache/shared/.updates.AbC123 file)" = cache-shared ]
  [ "$(first_match_row "$scratch" 'audit/light/fix%2Fy.reviews.jsonl' file)" = audit-light-review-state ]
}

# retention_legality_violations REGISTRY: one "<row id>: <reasons>" line per
# entries row whose retention breaks the field table; empty when all conform.
retention_legality_violations() {
  jq -r '
    .entries[] | . as $row | .id as $id | (.retention // null) as $t
    | (if ($t | type) != "object" then ["retention is not an object"]
       else
         $t.class as $c
         | [ (if (["branch-spent", "tree-gone", "spec-finalized", "age", "owned", "keep"] | index($c)) == null then "unknown class" else empty end),
             (if (($t | keys) - ["class", "days", "key", "session_days", "types", "names", "owner"] | length) > 0 then "unknown field" else empty end),
             (if ($c | IN("branch-spent", "spec-finalized", "age"))
                then (if ($t.days | type == "number" and . > 0 and . == floor) then empty else "days must be a positive integer" end)
                else (if ($t | has("days")) then "days forbidden" else empty end) end),
             (if $c == "branch-spent"
                then (if ($t.key | IN("normalized-path", "normalized-file", "audit-loop", "slug-dot-field", "slug-glob")) then empty else "key missing or unknown" end)
                else (if ($t | has("key")) then "key forbidden" else empty end) end),
             (if ($t | has("session_days"))
                and ($c != "branch-spent" or $t.key != "normalized-path" or ($t.session_days | type != "number" or . <= 0 or . != floor))
                then "session_days illegal" else empty end),
             (if ($t | has("types"))
                and ($c != "age" or ($t.types | type) != "array" or ($t.types | length) == 0 or (($t.types - ["file", "dir"]) | length) > 0)
                then "types illegal" else empty end),
             (if ($t | has("names"))
                and ($c != "age" or ($t.names | type) != "array" or ($t.names | length) == 0 or ([$t.names[] | type == "string" and length > 0] | all | not))
                then "names illegal" else empty end),
             (if $c == "owned"
                then (if ($t.owner | type == "string" and length > 0) then empty else "owner missing" end)
                else (if ($t | has("owner")) then "owner forbidden" else empty end) end),
             (if ($row.path | test("^protected/")) and ($c != "keep" and ($c != "branch-spent" or $t.days != 7))
                then "protected row must be keep or branch-spent with days 7" else empty end)
           ]
       end)
    | select(length > 0) | $id + ": " + join("; ")
  ' "$1"
}

# bats test_tags=whole-tree
@test "registry: every entries row's retention satisfies the field table" {
  run retention_legality_violations "$REGISTRY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq '[.entries[] | select(.path | test("^protected/"))] | length' "$REGISTRY")" -gt 0 ]
}

# bats test_tags=whole-tree
@test "registry: a scratch registry with a forbidden retention field is caught" {
  local scratch="$BATS_TEST_TMPDIR/forbidden-field.json"
  jq '(.entries[] | select(.id == "setup-state") | .retention.days) = 7' "$REGISTRY" >"$scratch"
  run retention_legality_violations "$scratch"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "setup-state: days forbidden"
  jq '(.entries[] | select(.id == "audit-loop-state") | .retention.days) = 14' "$REGISTRY" >"$scratch"
  run retention_legality_violations "$scratch"
  printf '%s\n' "$output" | grep -qF "audit-loop-state: protected row must be keep or branch-spent with days 7"
}
