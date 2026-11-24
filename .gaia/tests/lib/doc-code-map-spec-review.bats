#!/usr/bin/env bats
# Doc-conformance for how the spec review hands the code map to its fixer and
# keeps it from its critical refuter. Instruction-prose pins over audit.md.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AUDIT_MD="$ROOT/.claude/skills/gaia/references/spec/audit.md"
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

# map_paragraph
# Prints the fixer prompt paragraph that opens with the code map condition.
map_paragraph() {
  section_of "$AUDIT_MD" '## The fixer' | grep -F -- '> When `<CODE_MAP_PATH>` is named:'
}

@test "the fixer gets the map path with the read-only, never-justifies-a-fix wording and the preamble pointer" {
  local fixer paragraph
  fixer="$(section_of "$AUDIT_MD" '## The fixer')"
  [ -n "$fixer" ] || { echo "missing: fixer section" >&2; return 1; }
  grep -qF -- '`<CODE_MAP_PATH>` (when it is non-empty)' <<<"$fixer" || { echo "missing: input sentence names the slot" >&2; return 1; }
  paragraph="$(map_paragraph)"
  [ -n "$paragraph" ] || { echo "missing: conditional map paragraph" >&2; return 1; }
  grep -qF -- 'read-only' <<<"$paragraph" || { echo "missing: read-only" >&2; return 1; }
  grep -qF -- 'never justifies a fix on its own' <<<"$paragraph" || { echo "missing: never justifies a fix" >&2; return 1; }
  grep -qF -- '`spec/lens-dispatch.md` `## Shared preamble`' <<<"$paragraph" || { echo "missing: preamble pointer" >&2; return 1; }
}

@test "the critical refuter section names no code map" {
  local refuter
  refuter="$(section_of "$AUDIT_MD" '## The critical refuter')"
  [ -n "$refuter" ] || { echo "missing: refuter section" >&2; return 1; }
  grep -qE -- 'CODE-MAP|CODE_MAP' <<<"$refuter" && { echo "refuter names the code map" >&2; return 1; }
  true
}

@test "the fixer rejects as unverified a finding whose only evidence is the map, and weighs only the file it opens when a finding cites both" {
  local paragraph
  paragraph="$(map_paragraph)"
  [ -n "$paragraph" ] || { echo "missing: conditional map paragraph" >&2; return 1; }
  grep -qF -- 'cites `CODE-MAP.json` and no repo file and line is unverified' <<<"$paragraph" || { echo "missing: unverified refusal" >&2; return 1; }
  grep -qF -- 'route it `rejected`' <<<"$paragraph" || { echo "missing: rejected route" >&2; return 1; }
  grep -qF -- 'weigh only the file and line you open yourself' <<<"$paragraph" || { echo "missing: weigh only the file" >&2; return 1; }
}
