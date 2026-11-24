#!/usr/bin/env bats
#
# Lifetime of the SPEC folder's code map (CODE-MAP.json) and its record
# (CODE-MAP.sha256): both live beside SPEC.md in the main-anchored SPEC folder,
# survive the save and the post-merge close, are reaped only with the folder, and
# are removed by the step-2 discard of a draft so a later run never inherits a
# discarded attempt's map. Shell level; the discard test runs the real fenced
# block from resume.md rather than a retyped copy of it.
#
# Each test builds its own tmp repo via helpers/tmp-notebook-repo.sh.
# Assertion style follows .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  RESUME_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/resume.md"
  LIFECYCLE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/lifecycle.md"
  WIKI_PAGE="$REPO_ROOT/wiki/concepts/GAIA Spec.md"
  unset CLAUDE_CODE_SESSION_ID
  REPO=""
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO" "${REPO}.git" "${REPO}-wt"
  fi
}

@test "spec-save.sh run on a fixture SPEC folder holding the map and its record leaves both byte-unchanged, the save text and the post-merge close keep them, and the wiki points to the close" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  folder="$REPO/.notebook/specs/SPEC-001"
  mkdir -p "$folder" "$REPO/.gaia/local/cache"
  printf '{"entries":[{"path":"a.sh"}]}\n' >"$folder/CODE-MAP.json"
  printf 'abc123  CODE-MAP.json\n' >"$folder/CODE-MAP.sha256"
  cp "$folder/CODE-MAP.json" "$BATS_TEST_TMPDIR/map.before"
  cp "$folder/CODE-MAP.sha256" "$BATS_TEST_TMPDIR/record.before"
  cat >"$REPO/.gaia/local/cache/draft-SPEC-001.md" <<'DRAFT'
---
spec_id: SPEC-001
status: ready
created: 2026-01-01
updated: 2026-01-02
intent: |
  Keep the map beside the SPEC.
---

# SPEC-001
DRAFT

  run bash "$REPO/.gaia/scripts/spec/spec-save.sh" "$REPO" SPEC-001
  [ "$status" -eq 0 ]

  echo "case: the save leaves the map and its record byte-unchanged"
  cmp "$folder/CODE-MAP.json" "$BATS_TEST_TMPDIR/map.before"
  cmp "$folder/CODE-MAP.sha256" "$BATS_TEST_TMPDIR/record.before"

  echo "case: the post-merge close names both files as left in place"
  close="$(awk '/^## Post-merge close/{f=1;next} f&&/^## /{exit} f' "$LIFECYCLE_MD")"
  left_paragraph="$(grep -F '`REQUIREMENTS.md`, when the SPEC folder holds one, is left in place beside `SUMMARY.md`' <<<"$close")"
  grep -qF 'CODE-MAP.json' <<<"$left_paragraph"
  grep -qF 'CODE-MAP.sha256' <<<"$left_paragraph"
  rm_line="$(grep -F 'rm <SPEC folder>/SPEC.md <SPEC folder>/AUDIT.md' <<<"$close")"
  grep -qF 'CODE-MAP' <<<"$rm_line" && return 1

  echo "case: the wiki points to the close and lists no kept file"
  deleted="$(awk '/^## When a SPEC folder is deleted/{f=1;next} f&&/^## /{exit} f' "$WIKI_PAGE")"
  grep -qF '.claude/skills/gaia/references/spec/lifecycle.md` `## Post-merge close`' <<<"$deleted"
  grep -qF 'the never-edited `REQUIREMENTS.md`' <<<"$deleted" && return 1
  true
}

@test "a confirmed discard removes the map and its record from the resolved SPEC folder, so a later run's first research dispatch creates the map fresh" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  folder="$REPO/.notebook/specs/SPEC-001"
  mkdir -p "$folder"
  printf '{}\n' >"$folder/CODE-MAP.json"
  printf 'abc123  CODE-MAP.json\n' >"$folder/CODE-MAP.sha256"
  printf 'requirements\n' >"$folder/REQUIREMENTS.md"

  block="$(awk '
    /^[[:space:]]*```/ {
      if (in_block) { if (hit) { printf "%s", buffer; exit } in_block = 0; buffer = ""; hit = 0 }
      else { in_block = 1 }
      next
    }
    in_block { buffer = buffer $0 "\n"; if (index($0, "CODE-MAP.json")) hit = 1 }
  ' "$RESUME_MD")"
  [ -n "$block" ]
  printf '%s\n' "$block" | sed 's|<from allocator>|SPEC-001|' >"$BATS_TEST_TMPDIR/discard.sh"

  echo "case: the discard block removes the map and its record and leaves REQUIREMENTS.md"
  run bash -c 'cd "$1" && bash "$2"' _ "$REPO" "$BATS_TEST_TMPDIR/discard.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$folder/CODE-MAP.json" ]
  [ ! -e "$folder/CODE-MAP.sha256" ]
  [ -f "$folder/REQUIREMENTS.md" ]

  echo "case: an unresolvable SPEC folder stops before any removal"
  printf '{}\n' >"$folder/CODE-MAP.json"
  sed 's|SPEC-001|not-a-spec-id|' "$BATS_TEST_TMPDIR/discard.sh" >"$BATS_TEST_TMPDIR/discard-bad.sh"
  run bash -c 'cd "$1" && bash "$2"' _ "$REPO" "$BATS_TEST_TMPDIR/discard-bad.sh"
  [ "$status" -ne 0 ]
  [ -f "$folder/CODE-MAP.json" ]
}
