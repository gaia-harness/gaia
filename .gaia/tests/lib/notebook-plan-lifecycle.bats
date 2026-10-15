#!/usr/bin/env bats
# Plan lifecycle on the notebook catalog, driven through the real scripts in a
# throwaway fixture from helpers/tmp-notebook-repo.sh: allocate a plan, stamp
# its merge, reduce its folder, reap it after the retention window, and never
# reuse its number. Also the cross-tree cases (a reap from a linked worktree
# acts on main's notebook only) and the not-yet-moved refusals across the four
# plan scripts. Per-script behavior cases live in plan-allocator.bats,
# plan-reconcile.bats, plan-archive-merged.bats and plan-archive.bats.
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  # shellcheck source=helpers/usage-gate.sh
  . "$HELPERS/usage-gate.sh"
  export GAIA_SPEC_RETENTION_DAYS=0
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
  if [ -n "${LINKED:-}" ]; then
    rm -rf "$LINKED"
  fi
}

_catalog() {
  printf '%s' "$REPO/.notebook/catalog.json"
}

_row_field() {
  jq -r --arg id "$1" --arg field_name "$2" \
    '.items[] | select(.kind == "plan" and .id == $id) | .[$field_name] // "none"' "$(_catalog)"
}

# _write_summary <folder>: a well-formed consolidated SUMMARY.md.
_write_summary() {
  cat > "$1/SUMMARY.md" <<EOF
---
wiki_promote_default: ask
wiki_promote_targets: []
---
# Lifecycle plan

Consolidated summary body.
EOF
}

# _age_merged_at <plan_id>: stamps a merged_at far enough in the past to clear
# any retention window.
_age_merged_at() {
  local temporary_file
  temporary_file="$(mktemp)"
  jq --arg id "$1" \
    '.items |= map(if .kind == "plan" and .id == $id then . + {merged_at: "2026-01-02T00:00:00Z"} else . end)' \
    "$(_catalog)" > "$temporary_file"
  mv "$temporary_file" "$(_catalog)"
}

# _snapshot: every path under the fixture except git's own store, with file
# sums, for a before/after comparison that sees any change.
_snapshot() {
  find "$REPO" -path "$REPO/.git" -prune -o -type f -exec cksum {} + | LC_ALL=C sort
  find "$REPO" -path "$REPO/.git" -prune -o -print | LC_ALL=C sort
}

@test "a plan runs allocate, merge stamp, reduce, reap; its number is never reused" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh")"

  run bash "$REPO/.gaia/scripts/spec/plan-allocator.sh" next "$REPO" "lifecycle plan"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-001" ]
  [ "$(_row_field PLAN-001 status)" = "ready" ]

  mkdir -p "$REPO/.notebook/plans/PLAN-001/.work"
  _write_summary "$REPO/.notebook/plans/PLAN-001"
  printf 'progress\n' > "$REPO/.notebook/plans/PLAN-001/PROGRESS.md"
  : > "$REPO/.notebook/plans/PLAN-001/RUNNING"
  seed_close_row "$REPO/.gaia/local/telemetry" plan:PLAN-001 gaia-plan

  run bash "$REPO/.gaia/scripts/spec/plan-reconcile.sh" "$REPO" PLAN-001 2601
  [ "$status" -eq 0 ]
  [ "$(_row_field PLAN-001 status)" = "merged" ]
  [ "$(_row_field PLAN-001 pr_number)" = "2601" ]

  run bash -c 'cd "$1" && bash .gaia/scripts/plan-archive.sh .notebook/plans/PLAN-001' _ "$REPO"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.notebook/plans/PLAN-001/SUMMARY.md" ]
  [ ! -e "$REPO/.notebook/plans/PLAN-001/RUNNING" ]
  [ ! -e "$REPO/.notebook/plans/PLAN-001/PROGRESS.md" ]

  _age_merged_at PLAN-001
  run bash "$REPO/.gaia/scripts/spec/plan-archive-merged.sh" "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.notebook/plans/PLAN-001" ]
  [ "$(jq -r '.items[] | select(.id == "PLAN-001") | .reap.by' "$(_catalog)")" = "plan-archive-merged" ]

  run bash "$REPO/.gaia/scripts/spec/plan-allocator.sh" next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-002" ]
}

@test "a merged plan is reaped from main's notebook, run from main or from a linked worktree; a same-named old-location folder survives" {
  for origin in main linked; do
    if [ "$origin" = main ]; then
      REPO="$("$HELPERS/tmp-notebook-repo.sh")"
      runner="$REPO"
    else
      fixture="$("$HELPERS/tmp-notebook-repo.sh" --worktree w)"
      REPO="$(printf '%s\n' "$fixture" | sed -n 1p)"
      LINKED="$(printf '%s\n' "$fixture" | sed -n 2p)"
      runner="$LINKED"
    fi
    run bash "$REPO/.gaia/scripts/spec/plan-allocator.sh" next "$REPO"
    [ "$status" -eq 0 ]
    [ "$output" = "PLAN-001" ]
    mkdir -p "$REPO/.notebook/plans/PLAN-001"
    _write_summary "$REPO/.notebook/plans/PLAN-001"
    seed_close_row "$REPO/.gaia/local/telemetry" plan:PLAN-001 gaia-plan
    run bash "$REPO/.gaia/scripts/spec/plan-reconcile.sh" "$REPO" PLAN-001 2601
    [ "$status" -eq 0 ]
    _age_merged_at PLAN-001
    mkdir -p "$REPO/.gaia/local/plans/PLAN-001"
    printf 'decoy\n' > "$REPO/.gaia/local/plans/PLAN-001/SUMMARY.md"

    run bash "$runner/.gaia/scripts/spec/plan-archive-merged.sh" "$runner"
    [ "$status" -eq 0 ]
    grep -qF "Deleted 1 merged plan folder(s): PLAN-001" <<<"$output"
    [ ! -e "$REPO/.notebook/plans/PLAN-001" ]
    [ "$(jq -r '.items[] | select(.id == "PLAN-001") | has("reap")' "$(_catalog)")" = "true" ]
    [ "$(cat "$REPO/.gaia/local/plans/PLAN-001/SUMMARY.md")" = "decoy" ]
    if [ "$origin" = linked ]; then
      # The worktree's notebook is the link to main's, never a folder of its own.
      [ -L "$LINKED/.notebook" ]
    fi
    rm -rf "$REPO" "${LINKED:-}"
    REPO="" LINKED=""
  done
}

@test "not yet moved: the allocator and the reaper exit 3 with the move command and change nothing; the reconcile and archive scripts stay advisory" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --legacy \
    --seed-plan-folder PLAN-001 ready)"
  seed_close_row "$REPO/.gaia/local/telemetry" plan:PLAN-001 gaia-plan
  before="$(_snapshot)"

  run --separate-stderr bash "$REPO/.gaia/scripts/spec/plan-allocator.sh" next "$REPO"
  [ "$status" -eq 3 ]
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$stderr"

  run --separate-stderr bash "$REPO/.gaia/scripts/spec/plan-archive-merged.sh" "$REPO"
  [ "$status" -eq 3 ]
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$stderr"

  run --separate-stderr bash "$REPO/.gaia/scripts/spec/plan-reconcile.sh" "$REPO" PLAN-001 2601
  [ "$status" -eq 0 ]
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$stderr"

  run --separate-stderr bash -c 'cd "$1" && bash .gaia/scripts/plan-archive.sh .notebook/plans/PLAN-001' _ "$REPO"
  [ "$status" -eq 0 ]
  grep -qF "bash .gaia/scripts/notebook/move.sh run" <<<"$stderr"

  [ "$(_snapshot)" = "$before" ]
}
