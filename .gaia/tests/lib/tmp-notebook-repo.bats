#!/usr/bin/env bats
# Proves helpers/tmp-notebook-repo.sh: every seed flag writes the catalog row
# and the on-disk shape it names, the shape flags build the right repo, and the
# remote flags build the origin and tag state a reservation test needs.
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HELPER="$HELPERS/tmp-notebook-repo.sh"
  OLD_STAMP="2026-01-01T00:00:00Z"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO" "${REPO}.git" "${REPO}-x" "${REPO}-y" "${CLONE:-}"
  fi
}

_run_helper() {
  bash "$HELPER" "$@"
}

# Build a fixture; the first stdout line is the repo path.
_build() {
  local built
  built="$(_run_helper "$@")"
  REPO="$(printf '%s\n' "$built" | sed -n 1p)"
  SECOND_PATH="$(printf '%s\n' "$built" | sed -n 2p)"
}

_row() {
  jq -c --arg id "$1" '.items[] | select(.id == $id)' "$REPO/.notebook/catalog.json"
}

@test "a plain build commits an ignored notebook with an empty catalog carrying move_complete" {
  _build
  [ -d "$REPO/.git" ]
  jq -e '.version == 1 and (.items | length == 0) and (.move_complete.at | type == "string")' "$REPO/.notebook/catalog.json"
  grep -qxF '.notebook' "$REPO/.gitignore"
  grep -qxF '.notebook.bak.*' "$REPO/.gitignore"
  grep -qxF '.gaia/local' "$REPO/.gitignore"
  grep -qxF '.gaia/local.bak.*' "$REPO/.gitignore"
  [ -z "$(git -C "$REPO" status --porcelain)" ]
  run git -C "$REPO" check-ignore -q .notebook
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/telemetry/usage.jsonl" ]
  [ ! -s "$REPO/.gaia/local/telemetry/usage.jsonl" ]
}

@test "scripts are copied as real files, not symlinks" {
  _build
  local script_path
  for script_path in .gaia/scripts/main-root-lib.sh .gaia/scripts/branch-name-lib.sh \
      .gaia/scripts/plan-archive.sh .gaia/scripts/usage.sh .gaia/scripts/spec/spec-allocator.sh \
      .gaia/scripts/spec/with-ledger-lock.sh; do
    [ -f "$REPO/$script_path" ]
    [ ! -L "$REPO/$script_path" ]
  done
}

@test "the audit libraries are present and the copied state library defines the interactivity check" {
  _build
  [ -f "$REPO/.gaia/scripts/audit-loop-state-lib.sh" ]
  [ -f "$REPO/.gaia/scripts/audit-key-lib.sh" ]
  run bash -c '. "$1/.gaia/scripts/audit-loop-state-lib.sh" && declare -F gaia_loop_session_is_interactive' _ "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *gaia_loop_session_is_interactive* ]]
}

@test "the notebook scripts are copied when the real directory exists, and a missing one is named on stderr" {
  if [ -d "$BATS_TEST_DIRNAME/../../scripts/notebook" ]; then
    _build
    [ -d "$REPO/.gaia/scripts/notebook" ]
    [ ! -L "$REPO/.gaia/scripts/notebook" ]
  else
    run --separate-stderr bash "$HELPER"
    [ "$status" -eq 0 ]
    REPO="$output"
    [[ "$stderr" == *"skipped copy of .gaia/scripts/notebook"* ]]
  fi
}

@test "a missing notebook directory is skipped with a stderr note and the repo still builds" {
  # The helper finds the real repo through git, so a scratch checkout holding
  # a copy of the scripts without a notebook directory simulates its absence.
  local scratch="$BATS_TEST_TMPDIR/real"
  mkdir -p "$scratch/.gaia/tests/lib"
  cp -R "$HELPERS" "$scratch/.gaia/tests/lib/helpers"
  cp -R "$BATS_TEST_DIRNAME/../../scripts" "$scratch/.gaia/scripts"
  rm -rf "$scratch/.gaia/scripts/notebook"
  git -C "$scratch" init --quiet
  run --separate-stderr bash "$scratch/.gaia/tests/lib/helpers/tmp-notebook-repo.sh"
  [ "$status" -eq 0 ]
  REPO="$output"
  [[ "$stderr" == *"skipped copy of .gaia/scripts/notebook: directory not found"* ]]
  [ -f "$REPO/.notebook/catalog.json" ]
}

@test "--seed-spec writes a row with the old stamp and no folder" {
  _build --seed-spec SPEC-001 draft
  run _row SPEC-001
  jq -e --arg stamp "$OLD_STAMP" '.kind == "spec" and .status == "draft" and .path == "specs/SPEC-001" and .created_at == $stamp and .status_changed_at == $stamp' <<<"$output"
  [ ! -e "$REPO/.notebook/specs/SPEC-001" ]
}

@test "--seed-spec merged carries merged_at equal to the stamp, and --at overrides it for the next seed only" {
  _build --seed-spec SPEC-001 merged --at 2025-05-05T00:00:00Z --seed-spec SPEC-002 merged --seed-spec SPEC-003 merged
  run _row SPEC-001
  jq -e --arg stamp "$OLD_STAMP" '.merged_at == $stamp and .status_changed_at == $stamp' <<<"$output"
  run _row SPEC-002
  jq -e '.merged_at == "2025-05-05T00:00:00Z" and .created_at == "2025-05-05T00:00:00Z" and .status_changed_at == "2025-05-05T00:00:00Z"' <<<"$output"
  run _row SPEC-003
  jq -e --arg stamp "$OLD_STAMP" '.merged_at == $stamp' <<<"$output"
}

@test "--seed-plan abandoned carries abandoned_at, --seed-plan ready carries neither stamp" {
  _build --seed-plan PLAN-001 abandoned --seed-plan PLAN-002 ready
  run _row PLAN-001
  jq -e --arg stamp "$OLD_STAMP" '.kind == "plan" and .path == "plans/PLAN-001" and .abandoned_at == $stamp' <<<"$output"
  run _row PLAN-002
  jq -e 'has("abandoned_at") or has("merged_at") | not' <<<"$output"
}

@test "--seed-spec-folder writes the row and a SPEC.md with spec_id, status and immutable" {
  _build --seed-spec-folder SPEC-004 ready
  run _row SPEC-004
  jq -e '.status == "ready"' <<<"$output"
  grep -qxF 'spec_id: SPEC-004' "$REPO/.notebook/specs/SPEC-004/SPEC.md"
  grep -qxF 'status: ready' "$REPO/.notebook/specs/SPEC-004/SPEC.md"
  grep -qxF 'immutable: true' "$REPO/.notebook/specs/SPEC-004/SPEC.md"
}

@test "--seed-spec-merged-folder writes a merged row, SPEC.md and a consolidated SUMMARY.md" {
  _build --seed-spec-merged-folder SPEC-005
  run _row SPEC-005
  jq -e --arg stamp "$OLD_STAMP" '.status == "merged" and .merged_at == $stamp' <<<"$output"
  [ -f "$REPO/.notebook/specs/SPEC-005/SPEC.md" ]
  grep -qF 'wiki_promote_default' "$REPO/.notebook/specs/SPEC-005/SUMMARY.md"
}

@test "--seed-spec-abandoned-folder carries abandoned_at and the folder holds only AUDIT.md" {
  _build --seed-spec-abandoned-folder SPEC-006
  run _row SPEC-006
  jq -e --arg stamp "$OLD_STAMP" '.status == "abandoned" and .abandoned_at == $stamp' <<<"$output"
  [ "$(ls -A "$REPO/.notebook/specs/SPEC-006")" = "AUDIT.md" ]
}

@test "--seed-spec-provisional carries reservation and subject, with and without a subject, and no folder" {
  _build --seed-spec-provisional SPEC-002 x --seed-spec-provisional SPEC-003
  run _row SPEC-002
  jq -e '.status == "draft" and .reservation == "provisional" and .subject == "x"' <<<"$output"
  run _row SPEC-003
  jq -e '.reservation == "provisional" and .subject == "SPEC-003"' <<<"$output"
  [ ! -e "$REPO/.notebook/specs/SPEC-002" ]
}

@test "--seed-spec-file writes the bare file and no row" {
  _build --seed-spec-file SPEC-007
  [ -f "$REPO/.notebook/specs/SPEC-007.md" ]
  grep -qxF 'status: in-progress' "$REPO/.notebook/specs/SPEC-007.md"
  run _row SPEC-007
  [ -z "$output" ]
}

@test "--seed-row lands its object unchanged" {
  local object='{"kind":"spec","id":"SPEC-008","status":"in-progress","pr_number":42,"links":{"pr":42},"reap":{"at":null,"by":"pre-catalog"}}'
  _build --seed-row "$object"
  run _row SPEC-008
  [ "$(jq -S . <<<"$output")" = "$(jq -S . <<<"$object")" ]
}

@test "--seed-row refuses a non-object" {
  run bash "$HELPER" --seed-row '[1]'
  [ "$status" -ne 0 ]
}

@test "--seed-plan-folder, --seed-research, --seed-research-folder-only and --seed-research-loose write their shapes" {
  _build --seed-plan-folder PLAN-003 ready --seed-research topic-a active \
    --seed-research-folder-only topic-b --seed-research-loose notes.txt
  [ -f "$REPO/.notebook/plans/PLAN-003/PROGRESS.md" ]
  run _row PLAN-003
  jq -e '.kind == "plan" and .status == "ready"' <<<"$output"
  [ -f "$REPO/.notebook/research/topic-a/README.md" ]
  run _row topic-a
  jq -e '.kind == "research" and .status == "active" and .path == "research/topic-a"' <<<"$output"
  [ -f "$REPO/.notebook/research/topic-b/README.md" ]
  run _row topic-b
  [ -z "$output" ]
  [ -f "$REPO/.notebook/research/notes.txt" ]
  [ ! -d "$REPO/.notebook/research/notes.txt" ]
}

@test "a mix of every seed flag leaves a valid catalog" {
  _build --seed-spec SPEC-001 merged --seed-spec-folder SPEC-002 ready \
    --seed-spec-merged-folder SPEC-003 --seed-spec-abandoned-folder SPEC-004 \
    --seed-spec-provisional SPEC-005 y --seed-spec-file SPEC-006 \
    --seed-row '{"kind":"spec","id":"SPEC-007","status":"draft"}' \
    --seed-plan PLAN-001 abandoned --seed-plan-folder PLAN-002 ready \
    --seed-research r-one pending --seed-research-folder-only r-two --seed-research-loose loose.md
  jq -e '.version == 1 and (.items | length == 9)' "$REPO/.notebook/catalog.json"
}

@test "red twin: deleting a seeded row makes the row check come back empty" {
  _build --seed-spec-folder SPEC-001 ready
  run _row SPEC-001
  [ -n "$output" ]
  local temporary_file="$BATS_TEST_TMPDIR/catalog.json"
  jq '.items |= map(select(.id != "SPEC-001"))' "$REPO/.notebook/catalog.json" > "$temporary_file"
  mv "$temporary_file" "$REPO/.notebook/catalog.json"
  run _row SPEC-001
  [ -z "$output" ]
  [ -f "$REPO/.notebook/specs/SPEC-001/SPEC.md" ]
}

@test "without --legacy move_complete is present and no old specs root exists" {
  _build --seed-spec SPEC-001 draft
  jq -e 'has("move_complete")' "$REPO/.notebook/catalog.json"
  [ ! -e "$REPO/.gaia/local/specs" ]
}

@test "--legacy writes the legacy ledger and a catalog without move_complete" {
  _build --legacy
  jq -e '.specs == [] and .version == 1' "$REPO/.gaia/local/specs/ledger.json"
  jq -e 'has("move_complete") | not' "$REPO/.notebook/catalog.json"
}

@test "--no-catalog leaves no notebook path at all" {
  _build --no-catalog
  [ ! -e "$REPO/.notebook" ]
  [ ! -L "$REPO/.notebook" ]
}

@test "--no-catalog with --legacy keeps the legacy ledger and still no notebook" {
  _build --no-catalog --legacy
  [ -f "$REPO/.gaia/local/specs/ledger.json" ]
  [ ! -e "$REPO/.notebook" ]
}

@test "--no-catalog refuses a seed flag" {
  run bash "$HELPER" --no-catalog --seed-spec SPEC-001 draft
  [ "$status" -ne 0 ]
}

@test "--worktree yields a listed linked worktree whose notebook and local links resolve to the repo" {
  _build --worktree x
  [ "$SECOND_PATH" = "${REPO}-x" ]
  git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $SECOND_PATH"
  [ -L "$SECOND_PATH/.notebook" ]
  [ "$(cd "$SECOND_PATH/.notebook" && pwd -P)" = "$(cd "$REPO/.notebook" && pwd -P)" ]
  [ "$(cd "$SECOND_PATH/.gaia/local" && pwd -P)" = "$(cd "$REPO/.gaia/local" && pwd -P)" ]
}

@test "--worktree-bare yields a listed linked worktree with neither link" {
  _build --worktree-bare y
  [ "$SECOND_PATH" = "${REPO}-y" ]
  git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $SECOND_PATH"
  [ ! -e "$SECOND_PATH/.notebook" ]
  [ ! -L "$SECOND_PATH/.notebook" ]
  [ ! -e "$SECOND_PATH/.gaia/local" ]
  [ ! -L "$SECOND_PATH/.gaia/local" ]
}

@test "--with-origin and --seed-remote-tag put the tag in the origin and none in the repo" {
  _build --with-origin --seed-remote-tag spec/007 t
  git -C "${REPO}.git" tag -l 'spec/*' | grep -qxF 'spec/007'
  [ -z "$(git -C "$REPO" tag -l)" ]
}

@test "--origin-reject-spec-tags rejects a spec tag push and accepts a branch push" {
  _build --with-origin --origin-reject-spec-tags
  git -C "$REPO" tag spec/008
  run git -C "$REPO" push --quiet origin refs/tags/spec/008
  [ "$status" -ne 0 ]
  git -C "$REPO" branch side
  git -C "$REPO" push --quiet origin side
}

@test "clone-spec-repo.sh clones the origin" {
  _build --with-origin
  CLONE="$(bash "$HELPERS/clone-spec-repo.sh" "${REPO}.git")"
  [ -f "$CLONE/.gaia/scripts/main-root-lib.sh" ]
  [ -f "$CLONE/.gitignore" ]
}

@test "--seed-remote-tag without --with-origin fails" {
  run bash "$HELPER" --seed-remote-tag spec/009
  [ "$status" -ne 0 ]
}

@test "seed_close_row is available after sourcing the helper, and sourcing builds nothing" {
  run bash -c '. "$1" && declare -F seed_close_row' _ "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *seed_close_row* ]]
}
