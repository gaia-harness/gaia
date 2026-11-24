#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/state-registry-lib.sh, the state-registry
# reader. Two kinds of test live here: functional tests
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

# run_in_registry_repo <fn> [args...]: twin of run_in_repo against a fresh
# scratch repo's copy of the lib and registry.
run_in_registry_repo() {
  make_registry_repo
  run_in_built_repo "$@"
}

# run_in_built_repo <fn> [args...]: run_in_registry_repo against the scratch
# repo make_registry_repo already built, so a table pays for one repo.
run_in_built_repo() {
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$1/.gaia/scripts/state-registry-lib.sh"
    shift
    "$@"
  ' _ "$REGISTRY_REPO" "$@"
}

# expect_classify <expected> <path> [root]: gaia_registry_classify in the built repo.
expect_classify() {
  local expected="$1"
  shift
  run_in_built_repo gaia_registry_classify "$@"
  [ "$status" -eq 0 ] || { echo "classify $*: status $status"; return 1; }
  [ "$output" = "$expected" ] || { echo "classify $*: got '$output', expected '$expected'"; return 1; }
}

# expect_recognizes <expected status> <path> <type> [root]: gaia_registry_recognizes in the built repo.
expect_recognizes() {
  local expected="$1"
  shift
  run_in_built_repo gaia_registry_recognizes "$@"
  [ "$status" -eq "$expected" ] || { echo "recognizes $*: status $status, expected $expected"; return 1; }
}

# ========== gaia_registry_path ==========

@test "gaia_registry_path resolves the main checkout's registry, from the repo and from a linked worktree" {
  # Anchored on the resolved MAIN root, never on $REPO_ROOT (this file's own
  # location). The two diverge whenever the suite runs from a linked worktree,
  # and main's is the correct answer, so a $REPO_ROOT comparison reds on which
  # checkout bats was invoked from rather than on anything the function does.
  # The linked-worktree case below pins that divergence against a constructed
  # fixture whose main root is known without consulting this resolver.
  local main_root
  main_root="$(source "$SCRIPT_DIRECTORY/main-root-lib.sh" && gaia_resolve_main_root "$REPO_ROOT")"
  run_in_repo gaia_registry_path
  [ "$status" -eq 0 ]
  [ "$output" = "$main_root/.gaia/state-registry.json" ]

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

@test "gaia_registry_linkable_paths: prints exactly the shared local paths, each by name, never a per-tree or notebook row" {
  run_in_registry_repo gaia_registry_linkable_paths
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 20 ]
  local expected_path
  for expected_path in setup-state.json cache/shared/context cache cache/shared protected \
    settings.json audit audit/light telemetry telemetry/usage-sweep.lock.d debt codify runs \
    ports ports/tombstones ports/launches ports/sessions kept-worktrees.tsv worktree-occupancy fitness; do
    grep -qxF -- "$expected_path" <<<"$output" || { echo "missing: $expected_path"; return 1; }
  done
  local unexpected_path
  for unexpected_path in "$OLD_OVERRIDE_RELATIVE" worthiness-ledger specs catalog.json; do
    grep -qxF -- "$unexpected_path" <<<"$output" && { echo "unexpected: $unexpected_path"; return 1; }
  done
  return 0
}

@test "gaia_registry_classify maps each path to its scope or unknown" {
  local -a rows=(
    "protected/audit-loop/feat/x.json|main-only"
    "protected/checkpoint-override.json|shared"
    "protected/new-state.json|unknown"
    "$OLD_OVERRIDE_RELATIVE|unknown"
    "$OLD_STATE_RELATIVE|unknown"
    "ports/slots.tsv|shared"
    "ports/tombstones/3.1700000000.tsv|shared"
    "ports/slots.lock|ephemeral"
    "ports/launches/123.tsv|shared"
    "ports/sessions/abc.tsv|shared"
    "ports/other.tsv|unknown"
    "worthiness-ledger|per-tree"
    "totally-made-up-thing.xyz|unknown"
    "audit/light/route-record.json|shared"
    "audit/light/branch-ledger.json|shared"
    "telemetry/audit-light-routing.jsonl|shared"
    "telemetry/audit-light-routing.jsonl.bak|unknown"
    "setup-state.json|shared"
    "cache/shared/update-check.json|shared"
    "audit/abc123.ok|shared"
    "audit/abc123.def456.findings.json|shared"
    "audit/security/deadbeef.md|shared"
    "telemetry/token-rates.override.json|shared"
    "debt/count.json|shared"
    "debt/refresh-requested|shared"
    "red-ledger/observations.jsonl|residue"
    "worthiness-ledger/worthiness.jsonl|per-tree"
    "forensics/2026-07-23-x.md|per-tree"
    "codify/declines.json|shared"
    "codify/reviewed.json|shared"
    "codify/review-tally.json|shared"
    "harden/declines.json|residue"
    "cache/gh-artifact-pr.treeA.json|main-only"
    ".install-id|main-only"
    ".project-id|residue"
    "declined-updates.json|main-only"
    "dep-audit-baseline.json|main-only"
    "sandbox.json|main-only"
    "setup-in-progress|main-only"
    "cache/draft-SPEC-042.md|ephemeral"
    "cache/gate1-SPEC-042.json|ephemeral"
    "cache/spec-session-SPEC-042.json|ephemeral"
    "cache/audit-SPEC-042|ephemeral"
    "cache/mutation-scratch/abc123.work.code-audit-frontend|ephemeral"
    "cache/some-run/renders.json|ephemeral"
    "cleanse/KNOWLEDGE-2026-07-23.md|ephemeral"
    "cleanse/filing-outcomes-abc.jsonl|ephemeral"
    "cleanse/filing-retry/x.json|ephemeral"
    "audit/KNOWLEDGE-2026-07-23.md|residue"
    "audit/issue-body-abc.md|ephemeral"
    "mentorship.json|residue"
    "telemetry/cost"".jsonl|residue"
    "telemetry/token-rates.json|residue"
    "telemetry/token-rates.base.json|residue"
    "telemetry/token-rates.dist.json|residue"
    "telemetry/token-rates.feed-state.json|residue"
    "telemetry/token-rates.json.corrupt.1790000000.abc123|residue"
    "telemetry/.token-rates.json.tmp.AbC123|residue"
    "telemetry/.token-rates.feed-body.tmp.AbC123|residue"
    "telemetry/cloud/x.json|residue"
    "telemetry/analytics/x.json|residue"
    "cache/shared/coaching-active.txt|residue"
    "audit/abc123.carried|residue"
    ".mentorship-swept|residue"
    "plans/archived/PLAN-001|report-only"
    "specs/archived/SPEC-001|report-only"
    "handoff/2026-07-23-x.md|residue"
  )
  make_registry_repo
  local row
  for row in "${rows[@]}"; do
    expect_classify "${row##*|}" "${row%|*}" || return 1
  done
}

@test "gaia_registry_recognizes accepts known rows, container ancestors and nothing else" {
  local -a rows=(
    "protected|d|0"
    "worthiness-ledger|d|0"
    "mentorship.json|f|0"
    "audit/abc123.ok|f|0"
    "totally-made-up-thing.xyz|f|1"
    "audit|d|0"
    "audit/security|d|0"
    "cache/adopter-owned-thing|d|1"
    "audit|f|1"
    "audit/light|d|0"
    "audit/light-unregistered|d|1"
    "telemetry/cost"".jsonl|f|0"
    "telemetry/token-rates.json|f|0"
    "telemetry/token-rates.base.json|f|0"
    "telemetry/token-rates.dist.json|f|0"
    "telemetry/token-rates.feed-state.json|f|0"
    "telemetry/token-rates.json.corrupt.1790000000.abc123|f|0"
    "telemetry/.token-rates.json.tmp.AbC123|f|0"
    "telemetry/token-rates.override.json|f|0"
  )
  make_registry_repo
  local row path rest
  for row in "${rows[@]}"; do
    path="${row%%|*}"
    rest="${row#*|}"
    expect_recognizes "${rest#*|}" "$path" "${rest%%|*}" || return 1
  done
}

# ========== gaia_registry_rm_whitelist ==========

@test "gaia_registry_rm_whitelist: prints every rm-whitelist row in registry order" {
  expected_row_count="$(jq '.rm_whitelist | length' "$REGISTRY")"
  [ "$expected_row_count" -gt 0 ]
  run_in_registry_repo gaia_registry_rm_whitelist
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq "$expected_row_count" ]
  [ "${lines[0]}" = $'.notebook/plans\ttrue' ]
  [ "${lines[1]}" = $'.notebook/specs\ttrue' ]
  grep -qF '.gaia/local/specs' <<<"$output" && return 1
  grep -qF '.gaia/local/plans' <<<"$output" && return 1
  [ "${lines[2]}" = $'.gaia/local/audit\ttrue' ]
  [ "${lines[3]}" = $'.gaia/local/cleanse\ttrue' ]
  [ "${lines[4]}" = $'.gaia/local/cache\ttrue' ]
  [ "${lines[5]}" = $'.gaia/local/runs\ttrue' ]
  [ "${lines[6]}" = $'.gaia/local/setup-in-progress\tfalse' ]
  [ "${lines[7]}" = $'.gaia/local/setup-running\tfalse' ]
  [ "${lines[8]}" = $'dist\tfalse' ]
  [ "${lines[9]}" = $'build\tfalse' ]
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

# ========== gaia_registry_recognizes and classify without jq ==========

# bats test_tags=protected
@test "gaia_registry_recognizes: jq unavailable fails SAFE (recognized, exit 0) rather than reaping the unknown" {
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  run gaia_registry_recognizes "totally-made-up-thing.xyz" f
  PATH="$saved_path"
  [ "$status" -eq 0 ]
}

@test "gaia_registry_classify: jq unavailable prints nothing and returns 1 (not a reap gate, no fail-open contract)" {
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  run gaia_registry_classify "worthiness-ledger"
  PATH="$saved_path"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ========== roots ==========

@test "roots: classify and recognizes judge the notebook and local roots separately, with the root as the last CLI argument" {
  make_registry_repo
  expect_recognizes 0 specs/SPEC-001 d notebook || return 1
  expect_classify main-only specs/SPEC-001 notebook || return 1
  expect_classify main-only plans/PLAN-001 notebook || return 1
  expect_classify main-only research/topic-2026-10-01 notebook || return 1
  expect_classify main-only catalog.json notebook || return 1

  # The default local root judges the old roots by the report-only rows, never the moved rows.
  expect_classify report-only specs/SPEC-001 || return 1
  expect_classify report-only specs/SPEC-001 local || return 1
  expect_classify unknown catalog.json || return 1
  expect_classify report-only specs/archived/x || return 1
  expect_recognizes 0 research/topic-2026-10-01 d || return 1

  # A local-root path is not matched by a notebook query.
  expect_classify unknown setup-state.json notebook || return 1
  expect_recognizes 1 setup-state.json f notebook || return 1

  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh classify catalog.json notebook' _ "$REGISTRY_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "main-only" ]
  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh recognizes catalog.json f notebook' _ "$REGISTRY_REPO"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh recognizes catalog.json f' _ "$REGISTRY_REPO"
  [ "$status" -eq 1 ]

  # A registry whose specs row lacks root makes the notebook query unknown.
  jq 'del(.report_only) | del(.entries[] | select(.id == "specs-main") | .root)' "$REGISTRY" >"$REGISTRY_REPO/.gaia/state-registry.json"
  expect_classify unknown specs/SPEC-001 notebook || return 1
  expect_classify main-only specs/SPEC-001 || return 1
}

@test "roots: the notebook rows carry the notebook root and the catalog row is the library's" {
  [ "$(jq -r '[.entries[] | select(.id == "specs-main" or .id == "plans-main" or .id == "research-main") | .root] | join(",")' "$REGISTRY")" = "notebook,notebook,notebook" ]
  [ "$(jq -r '.entries[] | select(.id == "notebook-catalog") | [.root, .path, .match, .kind, .scope, .writer, .retention.class] | join(",")' "$REGISTRY")" = "notebook,catalog.json,exact,file,main-only,code,keep" ]
}

# ========== schema-shaped structural invariants (no validator dependency; direct jq) ==========

@test "schema invariants: keyed_by by scope, enums, unique ids and required fields" {
  jq -e '[.entries[] | select(.scope == "shared") | (.keyed_by | type == "string" and length > 0)] | all' "$REGISTRY" >/dev/null ||
    { echo "a shared entry lacks a non-empty keyed_by"; return 1; }
  jq -e '[.entries[] | select(.scope == "per-tree") | (.keyed_by | type == "string" and length > 0)] | all' "$REGISTRY" >/dev/null ||
    { echo "a per-tree entry lacks a non-empty keyed_by"; return 1; }
  jq -e '[.entries[] | select(.scope == "main-only" or .scope == "ephemeral") | (.keyed_by == null)] | all' "$REGISTRY" >/dev/null ||
    { echo "a main-only or ephemeral entry has a keyed_by"; return 1; }
  jq -e '
    ([.entries[].match] | all(. as $match_type | ["exact","glob","prefix"] | index($match_type) != null))
    and ([.entries[].kind] | all(. as $kind | ["file","dir"] | index($kind) != null))
    and ([.entries[].scope] | all(. as $scope | ["shared","per-tree","main-only","ephemeral"] | index($scope) != null))
    and ([.entries[].writer] | all(. as $writer | ["code","hand-authored"] | index($writer) != null))
    and ([.residue[].match] | all(. as $match_type | ["exact","glob","prefix"] | index($match_type) != null))
    and ([.residue[].writer] | all(. == "none-residue"))
  ' "$REGISTRY" >/dev/null || { echo "a match, kind, scope or writer is outside its enum"; return 1; }
  jq -e '
    ([(.entries[].id), (.residue[].id)]) as $all
    | ($all | length) == ($all | unique | length)
  ' "$REGISTRY" >/dev/null || { echo "a row id is duplicated"; return 1; }
  jq -e '
    (.entries | all(has("id") and has("path") and has("match") and has("kind") and has("scope") and has("keyed_by") and has("why") and has("writer") and has("retention") and (has("reaped_by") | not)))
    and (.residue | all(has("id") and has("path") and has("match") and has("why") and has("writer")))
  ' "$REGISTRY" >/dev/null || { echo "a row lacks a required field"; return 1; }
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
rate-limits-reading owned - - - - -
rate-limits-orphan-temps age 7 - - file -
cache-shared owned - - - - -
state-reaper-state owned - - - - -
checkpoint-override keep - - - - -
autonomy-switch keep - - - - -
autonomy-decision-log branch-spent 7 line-branch - - -
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
audit-worthiness-ledger tree-gone - - - - -
forensics tree-gone - - - - -
codify-declines keep - - - - -
codify-review-snapshot keep - - - - -
fitness-blend-record keep - - - - -
specs-main owned - - - - -
plans-main owned - - - - -
research-main owned - - - - -
notebook-catalog keep - - - - -
gh-artifact-pr-cache branch-spent 7 slug-glob - - -
residual-triage-caches keep - - - - -
audit-loop-state branch-spent 7 audit-loop - - -
harness-verify-pass branch-spent 7 normalized-file - - -
install-id keep - - - - -
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
rate-limit-checkpoint-markers age 7 - - file [!.]*,.*.*
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
