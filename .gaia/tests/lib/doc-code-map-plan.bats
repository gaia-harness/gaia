#!/usr/bin/env bats
# Doc-conformance for how the plan side receives the code map: the planner
# clause, the one owner section and its pointers, the test stage wording and the
# plan step's re-verify. Instruction-prose pins.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_MD="$ROOT/.claude/skills/gaia/references/plan/planner.md"
  PLAN_MD="$ROOT/.claude/skills/gaia/references/plan.md"
  RESEARCH_MD="$ROOT/.claude/skills/gaia/references/spec/research.md"
  LENS_MD="$ROOT/.claude/skills/gaia/references/spec/lens-dispatch.md"
  TEST_STAGE_MD="$ROOT/.claude/skills/gaia/references/test-stage.md"
  WIKI_MD="$ROOT/wiki/concepts/Test Stage.md"
  VERIFY_LIB="$ROOT/.gaia/scripts/spec/plan-verify-lib.sh"
}

# section_of <file> <heading line>
# Prints the section from its heading through the line before the next `## `.
section_of() {
  awk -v heading="$2" '
    $0 == heading { inside = 1; print; next }
    inside && /^## / { exit }
    inside { print }
  ' "$1"
}

# planner_paragraph
# Prints the planner Inputs paragraph that opens with the code map clause.
planner_paragraph() {
  grep -F -- '**Code map:**' "$PLANNER_MD"
}

# step_1a_item
# Prints the numbered step 1a item that applies the code map test.
step_1a_item() {
  grep -E -- '^[0-9]+\. When `\$\{SPEC_DIR\}/CODE-MAP\.json` exists' "$PLAN_MD"
}

# planner_dispatch
# Prints the fenced planner dispatch block of plan.md step 4.
planner_dispatch() {
  awk '
    /^### 4\. Spawn planning agent/ { inside = 1; next }
    inside && /^### / { exit }
    inside && /^```/ { fence++; next }
    inside && fence == 1 { print }
  ' "$PLAN_MD"
}

@test "the planner reads a usable map beside the SPEC as an index with no new placeholder or dispatch line" {
  local paragraph word placeholders dispatch
  paragraph="$(planner_paragraph)"
  [ -n "$paragraph" ] || { echo "missing: planner code map paragraph" >&2; return 1; }
  [ "$(grep -cF -- '**Code map:**' "$PLANNER_MD")" = 1 ] || { echo "expected exactly one code map paragraph" >&2; return 1; }
  grep -qF -- 'When `SPEC_PATH` is set and a usable `CODE-MAP.json` sits beside it' <<<"$paragraph" || { echo "missing: condition on SPEC path and usable map" >&2; return 1; }
  for word in 'beside' 'index' 'may be stale or incomplete' 'read-only' 'untrusted data' 'never the source of a contract value'; do
    grep -qF -- "$word" <<<"$paragraph" || { echo "missing: $word" >&2; return 1; }
  done
  # No brace token in the clause other than the SPEC path token the neighbors use.
  placeholders="$(grep -oE '\{[A-Za-z_]+\}' <<<"$paragraph" | sort -u)"
  [ "$placeholders" = '{SPEC_PATH}' ] || { echo "unexpected brace tokens in the clause: $placeholders" >&2; return 1; }
  # The verifier's placeholder list stays the four tokens the plan check flags.
  grep -qF -- "for placeholder in '{PLAN_DIR}' '{SPEC_PATH}' '{AUDIT_PATH}' '{BRANCH_ID}'; do" "$VERIFY_LIB" || { echo "missing: placeholder list is not the four" >&2; return 1; }
  # The planner dispatch gains no line and still ends on the yield handoff.
  dispatch="$(planner_dispatch)"
  [ -n "$dispatch" ] || { echo "missing: planner dispatch block" >&2; return 1; }
  grep -qE -- 'CODE.MAP' <<<"$dispatch" && { echo "dispatch names the code map" >&2; return 1; }
  [ "$(tail -n 1 <<<"$dispatch" | cut -d: -f1)" = 'Yield handoff' ] || { echo "dispatch last line is not Yield handoff" >&2; return 1; }
}

@test "the code map section is the one owner of the entry keys, limits and duplicate-question rule, and the 5e prompt, the lens preamble bullet and the planner clause each point to it restating no key list" {
  local owner five_e bullet paragraph key
  owner="$(section_of "$RESEARCH_MD" '## The code map')"
  [ -n "$owner" ] || { echo "missing: owner section" >&2; return 1; }
  for key in '`q`' '`question`' '`commit`' '`files`' '`path`' '`lines`' '`excerpt`' '`answer`' 'at most 5 objects' 'at most 3 verbatim lines' 'at most two sentences'; do
    grep -qF -- "$key" <<<"$owner" || { echo "owner missing: $key" >&2; return 1; }
  done
  grep -qF -- 'Two entries with the same `question`' <<<"$owner" || { echo "owner missing: duplicate-question rule" >&2; return 1; }
  grep -qF -- 'both kept' <<<"$owner" || { echo "owner missing: both kept" >&2; return 1; }

  five_e="$(grep -F -- 'Spawn one `general-purpose` Agent per clarify question.' "$RESEARCH_MD")"
  bullet="$(grep -F -- 'The code map at `<CODE_MAP_PATH>`' "$LENS_MD")"
  paragraph="$(planner_paragraph)"
  [ -n "$five_e" ] || { echo "missing: 5e prompt paragraph" >&2; return 1; }
  [ -n "$bullet" ] || { echo "missing: lens preamble bullet" >&2; return 1; }
  [ -n "$paragraph" ] || { echo "missing: planner clause" >&2; return 1; }
  grep -qF -- '`## The code map`' <<<"$five_e" || { echo "5e prompt does not point to the owner" >&2; return 1; }
  grep -qF -- '`## The code map`' <<<"$bullet" || { echo "lens bullet does not point to the owner" >&2; return 1; }
  grep -qF -- '`## The code map`' <<<"$paragraph" || { echo "planner clause does not point to the owner" >&2; return 1; }
  for key in '`commit`' '`excerpt`' '`q`' 'at most 5' 'at most 3'; do
    grep -qF -- "$key" <<<"$five_e" && { echo "5e prompt restates: $key" >&2; return 1; }
    grep -qF -- "$key" <<<"$bullet" && { echo "lens bullet restates: $key" >&2; return 1; }
    grep -qF -- "$key" <<<"$paragraph" && { echo "planner clause restates: $key" >&2; return 1; }
  done
  true
}

@test "test-stage.md and the Test Stage wiki page say expected behaviors come only from the SPEC and the map only locates existing tests" {
  local inputs checks
  inputs="$(section_of "$TEST_STAGE_MD" '## Trigger and inputs')"
  checks="$(section_of "$TEST_STAGE_MD" '## Checks')"
  [ -n "$inputs" ] || { echo "missing: inputs section" >&2; return 1; }
  [ -n "$checks" ] || { echo "missing: checks section" >&2; return 1; }
  grep -qF -- '`CODE-MAP.json` beside the SPEC' <<<"$inputs" || { echo "inputs missing: map beside the SPEC" >&2; return 1; }
  grep -qF -- '/spec/research.md` `## The code map`' <<<"$inputs" || { echo "inputs missing: owner pointer" >&2; return 1; }
  grep -qF -- 'only to locate existing test files' <<<"$inputs" || { echo "inputs missing: only to locate" >&2; return 1; }
  grep -qF -- 'never to derive an expected behavior' <<<"$inputs" || { echo "inputs missing: never derive" >&2; return 1; }
  grep -qF -- 'the SPEC'"'"'s behaviors stay the only source of expected outcomes' <<<"$inputs" || { echo "inputs missing: behaviors the only source" >&2; return 1; }
  grep -qF -- 'test-stage column' <<<"$checks" || { echo "checks missing: test-stage column" >&2; return 1; }
  grep -qF -- '`<CODE_MAP_PATH>`' <<<"$checks" || { echo "checks missing: slot" >&2; return 1; }
  grep -qF -- 'uses it only to locate existing test files and never derives an expected behavior from it' <<<"$checks" || { echo "checks missing: TST clause" >&2; return 1; }
  grep -qF -- 'confirms every listed test proves a behavior the SPEC states' <<<"$checks" || { echo "checks lost the TST focus" >&2; return 1; }
  grep -qF -- 'expected behaviors come only from those; when the SPEC folder holds a code map, it serves only to locate existing tests' "$WIKI_MD" || { echo "wiki missing: expected behaviors and map clause" >&2; return 1; }
  grep -qF -- 'and the stage reads those, never the code' "$WIKI_MD" && { echo "wiki keeps the old clause" >&2; return 1; }
  true
}

@test "each append writes a one-line entry-count and sha256 record with the Write tool and reads it back, the usable check follows that record from any directory, and the plan step shows the mismatch notice and rewrites neither file" {
  local record usable item
  record="$(grep -F -- '**Record.**' "$RESEARCH_MD")"
  usable="$(section_of "$RESEARCH_MD" '## The code map' | grep -F -A8 -- '**Usable.**')"
  [ -n "$record" ] || { echo "missing: record paragraph" >&2; return 1; }
  [ -n "$usable" ] || { echo "missing: usable paragraph" >&2; return 1; }
  grep -qF -- 'Right after each append'"'"'s read-back' <<<"$record" || { echo "record missing: after each append" >&2; return 1; }
  grep -qF -- '`CODE-MAP.sha256` beside the map with the Write tool' <<<"$record" || { echo "record missing: Write tool" >&2; return 1; }
  grep -qF -- 'then reads it back' <<<"$record" || { echo "record missing: read back" >&2; return 1; }
  grep -qF -- 'one line, `<entries> <sha256>`' <<<"$record" || { echo "record missing: one-line shape" >&2; return 1; }
  grep -qF -- 'the map'"'"'s `jq length`' <<<"$record" || { echo "record missing: entry count" >&2; return 1; }
  grep -qF -- 'RECORD="$(dirname "$MAP")/CODE-MAP.sha256"' <<<"$usable" || { echo "usable missing: record found beside the absolute map" >&2; return 1; }
  grep -qF -- 'MAP=<absolute path of CODE-MAP.json>' <<<"$usable" || { echo "usable missing: absolute path" >&2; return 1; }
  grep -qF -- '"$RECORDED_COUNT" = "$(jq length "$MAP")"' <<<"$usable" || { echo "usable missing: count compare" >&2; return 1; }
  grep -qF -- 'sha256sum "$MAP"' <<<"$usable" || { echo "usable missing: hash compare" >&2; return 1; }

  item="$(step_1a_item)"
  [ -n "$item" ] || { echo "missing: step 1a code map item" >&2; return 1; }
  [ "$(step_1a_item | wc -l | tr -d ' ')" = 1 ] || { echo "expected exactly one step 1a code map item" >&2; return 1; }
  grep -qF -- '`.claude/skills/gaia/references/spec/research.md` `## The code map`' <<<"$item" || { echo "item missing: owner pointer" >&2; return 1; }
  grep -qF -- 'The code map no longer matches its record; the plan runs without it.' <<<"$item" || { echo "item missing: notice" >&2; return 1; }
  grep -qF -- 'and continue' <<<"$item" || { echo "item missing: continue" >&2; return 1; }
  grep -qF -- 'Nothing here rewrites the map or its record.' <<<"$item" || { echo "item missing: rewrites nothing" >&2; return 1; }
  grep -qE -- '(^|[^a-z])(rm|cp|mv) ' <<<"$item" && { echo "item runs a write command" >&2; return 1; }
  true
}

@test "the usable check accepts a valid map whose one-line record has no trailing newline" {
  local dir block hash
  dir="$(mktemp -d)"
  printf '[]' >"$dir/CODE-MAP.json"
  hash="$( { shasum -a 256 "$dir/CODE-MAP.json" 2>/dev/null || sha256sum "$dir/CODE-MAP.json"; } | cut -d' ' -f1)"
  printf '0 %s' "$hash" >"$dir/CODE-MAP.sha256"
  block="$(section_of "$RESEARCH_MD" '## The code map' | awk '/^MAP=<absolute/ { on = 1 } on && /^```/ { exit } on')"
  [ -n "$block" ] || { echo "missing: usable block" >&2; return 1; }
  block="${block/MAP=<absolute path of CODE-MAP.json>/MAP=\"$dir/CODE-MAP.json\"}"
  run bash -c "$block"
  [ "$status" -eq 0 ] || { echo "usable check refused a record with no trailing newline: $output" >&2; return 1; }
}
