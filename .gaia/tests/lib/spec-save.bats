#!/usr/bin/env bats
#
# .gaia/scripts/spec/spec-save.sh behavior: it copies the working draft into the
# notebook's SPEC folder with today's `updated:` stamp, flips the catalog row to
# ready with the normalized intent, records research lineage on the row, clears
# the draft, gate-1, session and audit caches, and releases the session lock; it
# refuses before writing anything when the draft or the SPEC folder is missing,
# keeps saving when a best-effort step fails, writes into the main checkout from
# a linked worktree, and rejects malformed arguments. Shell level only.
#
# Each test builds its own tmp repo via helpers/tmp-notebook-repo.sh.
# Assertion style follows .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  SAVE=".gaia/scripts/spec/spec-save.sh"
  TODAY="$(date +%Y-%m-%d)"
  unset CLAUDE_CODE_SESSION_ID
  REPO=""
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO" "${REPO}.git" "${REPO}-wt"
  fi
}

_row_field() {
  jq -r --arg id "$2" --arg field "$3" \
    '[.items[] | select(.kind == "spec" and .id == $id)][0][$field] // "null"' "$1/.notebook/catalog.json"
}

# seed_draft <root> <id> <lineage>: a draft cache plus the gate-1, session-shape
# and audit caches step 9 clears.
seed_draft() {
  local id="$2" lineage="$3" cache="$1/.gaia/local/cache"
  mkdir -p "$cache/audit-$id/findings"
  cat >"$cache/draft-$id.md" <<EOF
---
spec_id: $id
status: ready
created: 2026-01-01
updated: 2026-01-02
intent: |
  Save the SPEC in one command. The rest of this intent is detail.
lineage: $lineage
---

# $id

updated: a body line that must keep its text
EOF
  printf '{}\n' >"$cache/gate1-$id.json"
  printf '{"question_count":3}\n' >"$cache/spec-session-$id.json"
  printf '[]\n' >"$cache/audit-$id/findings/self-review.json"
}

@test "the draft is saved with today's stamp, the row is readied with its intent and every cache is cleared" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  seed_draft "$REPO" SPEC-001 "[]"

  run bash "$REPO/$SAVE" "$REPO" SPEC-001
  [ "$status" -eq 0 ]
  spec="$REPO/.notebook/specs/SPEC-001/SPEC.md"
  [ "${lines[0]}" = "$spec" ]
  [ -f "$spec" ]
  grep -qx "updated: $TODAY" "$spec"
  grep -qx "created: 2026-01-01" "$spec"
  grep -qx "updated: a body line that must keep its text" "$spec"
  [ "$(_row_field "$REPO" SPEC-001 status)" = "ready" ]
  [ "$(_row_field "$REPO" SPEC-001 intent)" = "Save the SPEC in one command." ]
  [ ! -e "$REPO/.gaia/local/cache/draft-SPEC-001.md" ]
  [ ! -e "$REPO/.gaia/local/cache/gate1-SPEC-001.json" ]
  [ ! -e "$REPO/.gaia/local/cache/spec-session-SPEC-001.json" ]
  [ ! -e "$REPO/.gaia/local/cache/audit-SPEC-001" ]
}

@test "only the frontmatter's updated line changes; the rest of the draft is copied byte for byte" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  seed_draft "$REPO" SPEC-001 "[]"
  sed "s/^updated: 2026-01-02\$/updated: $TODAY/" "$REPO/.gaia/local/cache/draft-SPEC-001.md" >"$BATS_TEST_TMPDIR/expected.md"

  run bash "$REPO/$SAVE" "$REPO" SPEC-001
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/expected.md" "$REPO/.notebook/specs/SPEC-001/SPEC.md"
}

@test "research lineage entries are recorded on the row and issue entries are not" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  seed_draft "$REPO" SPEC-001 "[research:first-topic, issue:12, \"research:second-topic\"]"

  run bash "$REPO/$SAVE" "$REPO" SPEC-001
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.items[] | select(.id == "SPEC-001")][0].links.research' "$REPO/.notebook/catalog.json")" = '["first-topic","second-topic"]' ]
}

@test "an empty lineage leaves the row without research links" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  seed_draft "$REPO" SPEC-001 "[]"

  run bash "$REPO/$SAVE" "$REPO" SPEC-001
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.items[] | select(.id == "SPEC-001")][0].links.research // "none"' "$REPO/.notebook/catalog.json")" = '"none"' ]
}

@test "a missing draft refuses before anything is written" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"

  run bash "$REPO/$SAVE" "$REPO" SPEC-001
  [ "$status" -eq 1 ]
  [[ "$output" == *"no draft"* ]]
  [ ! -e "$REPO/.notebook/specs/SPEC-001" ]
  [ "$(_row_field "$REPO" SPEC-001 status)" = "draft" ]
}

@test "an unresolvable SPEC folder refuses and keeps every cache" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --legacy --seed-spec SPEC-001 draft)"
  seed_draft "$REPO" SPEC-001 "[]"

  run bash "$REPO/$SAVE" "$REPO" SPEC-001
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot resolve"* ]]
  [ ! -e "$REPO/.notebook/specs/SPEC-001/SPEC.md" ]
  [ -f "$REPO/.gaia/local/cache/draft-SPEC-001.md" ]
  [ -d "$REPO/.gaia/local/cache/audit-SPEC-001" ]
}

@test "a catalog flip that fails still saves the SPEC, names the skip and clears the caches" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh")"
  seed_draft "$REPO" SPEC-001 "[]"

  run bash "$REPO/$SAVE" "$REPO" SPEC-001
  [ "$status" -eq 0 ]
  [ -f "$REPO/.notebook/specs/SPEC-001/SPEC.md" ]
  [[ "$output" == *"catalog flip skipped"* ]]
  [ ! -e "$REPO/.gaia/local/cache/draft-SPEC-001.md" ]
}

@test "from a linked worktree the SPEC lands in the main checkout's notebook" {
  output_lines="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft --worktree wt)"
  REPO="$(printf '%s\n' "$output_lines" | sed -n 1p)"
  WORKTREE="$(printf '%s\n' "$output_lines" | sed -n 2p)"
  seed_draft "$REPO" SPEC-001 "[]"

  run bash "$WORKTREE/$SAVE" "$WORKTREE" SPEC-001
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$REPO/.notebook/specs/SPEC-001/SPEC.md" ]
  [ -f "$REPO/.notebook/specs/SPEC-001/SPEC.md" ]
  [ "$(_row_field "$REPO" SPEC-001 status)" = "ready" ]
}

@test "malformed arguments are usage errors" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"

  run bash "$REPO/$SAVE" "$REPO"
  [ "$status" -eq 2 ]
  run bash "$REPO/$SAVE" relative/root SPEC-001
  [ "$status" -eq 2 ]
  run bash "$REPO/$SAVE" "$REPO" "SPEC-001/../x"
  [ "$status" -eq 2 ]
  run bash "$REPO/$SAVE" "$REPO" SPEC-1
  [ "$status" -eq 2 ]
}
