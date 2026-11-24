#!/usr/bin/env bats
#
# The shared lens preamble owns the code map's index wording; the spec audit,
# the plan review, the test stage, the fixer and the planner fill or point at
# it. Doc-conformance over those files: the one bullet and its slot row, the
# map treated as absent when it is not usable, the never-cite rule with the
# grounding paragraphs held byte-identical, and the read-only rule.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFS="$REPO_ROOT/.claude/skills/gaia/references"
  LENS="$REFS/spec/lens-dispatch.md"
  AUDIT="$REFS/spec/audit.md"
  DECOMP="$REFS/plan/decomposition-audit.md"
  PLANNER="$REFS/plan/planner.md"
  TEST_STAGE="$REFS/test-stage.md"
}

# The one preamble bullet that names the code map.
map_bullet() {
  grep -E '^> - The code map at `<CODE_MAP_PATH>`' "$LENS"
}

# The text of the `## The fixer` section of the spec audit.
fixer_section() {
  awk '/^## The fixer/{on=1; next} /^## /{on=0} on' "$AUDIT"
}

@test "the shared preamble carries one code map bullet with the index wording and the caller slot row, and the spec audit, plan review 4.6a and test-stage Checks each fill the slot" {
  local bullet phrase file
  [ "$(map_bullet | wc -l | tr -d ' ')" = 1 ]
  bullet="$(map_bullet)"
  for phrase in 'an index of where to look first' 'may be stale or incomplete' 'research time' 'only when' 'to locate code' 'only before citing it' '`lines` range' 'clarify-loop.md` `## The code map`'; do
    grep -qF -- "$phrase" <<<"$bullet" || { printf 'bullet lacks: %s\n' "$phrase" >&2; return 1; }
  done
  grep -qE '^\| Code map \(`<CODE_MAP_PATH>`\) \|' "$LENS"
  for file in "$AUDIT" "$DECOMP" "$TEST_STAGE"; do
    grep -qF '<CODE_MAP_PATH>' "$file" || { printf 'no slot fill in %s\n' "$file" >&2; return 1; }
  done
}

@test "an absent or non-array map is not usable: the caller drops the whole bullet, the fixer gets no map paragraph, and the planner reads none and reports nothing" {
  grep -qF 'drops the whole code-map bullet' "$LENS"
  grep -qF 'clarify-loop.md` `## The code map`' "$LENS"
  fixer_section | grep -qF 'CODE-MAP.json'
  fixer_section | grep -qiE 'usable|absent|non-empty|is empty|no map'
  grep -qF 'CODE-MAP.json' "$PLANNER"
  grep -qiE 'usable|absent|no map|without' "$PLANNER"
}

@test "the preamble bullet forbids citing the map as evidence, the FG and CG grounding paragraphs match their sha256 pinned from f7bf66cb (pinned in the test, never read by git show), and the fixer's map never justifies a fix on its own" {
  local fg_pinned cg_pinned fg_now cg_now
  # Pinned from the paragraphs at f7bf66cb.
  fg_pinned=9023546fe0e013056131ebd6c2d9897fffd38430067a5d5e17623e46534f3bce
  cg_pinned=34c9acc9ab9612d97019523cf6f42815ba42c4aa0798c2f205e967f97defcbc6
  map_bullet | grep -qF 'Never cite `CODE-MAP.json` or any line of it as evidence; cite the file and line you opened.'
  fg_now="$(awk '/^#### FG: Factual grounding/{on=1; next} on && NF{print; exit}' "$AUDIT" | shasum -a 256 | cut -d' ' -f1)"
  cg_now="$(grep -E '^- \*\*Contract grounding \(id prefix' "$DECOMP" | shasum -a 256 | cut -d' ' -f1)"
  [ "$fg_now" = "$fg_pinned" ]
  [ "$cg_now" = "$cg_pinned" ]
  fixer_section | grep -qiE 'never justif'
}

@test "every consumer of the map calls it read-only and none names a write to it" {
  local file bad
  for file in "$LENS" "$AUDIT" "$PLANNER" "$TEST_STAGE"; do
    grep -qF 'read-only' <<<"$(grep -F 'CODE-MAP' "$file"; map_bullet)" || { printf 'not read-only: %s\n' "$file" >&2; return 1; }
  done
  fixer_section | grep -qF 'read-only'
  for file in "$LENS" "$AUDIT" "$DECOMP" "$PLANNER" "$TEST_STAGE"; do
    bad="$(grep -F 'CODE-MAP' "$file" | grep -iE '\b(write|writes|edit|edits|append|appends|rewrite|overwrite|update|updates)\b' | grep -viE 'never|not |no |read-only' || true)"
    [ -z "$bad" ] || { printf 'names a write in %s: %s\n' "$file" "$bad" >&2; return 1; }
  done
}
