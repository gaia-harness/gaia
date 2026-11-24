#!/usr/bin/env bats
# Flow test: a code-map line never becomes a cited fact. Walks the evidence
# path: the lens preamble owns the never-evidence wording, and the fixer's map
# paragraph routes to that owner by path and heading. The refusal wording
# itself is owned by the build phases' suites and is not repeated here.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned text carries backticks as literal Markdown, so single quotes are
# the point.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LENS_DISPATCH="$ROOT/.claude/skills/gaia/references/spec/lens-dispatch.md"
  AUDIT="$ROOT/.claude/skills/gaia/references/spec/audit.md"
}

# section <file> <start_ERE>: the lines from the heading to the next `## `.
section() {
  awk -v re="$2" '
    $0 ~ re { on = 1; print; next }
    on && /^## / { exit }
    on { print }
  ' "$1"
}

@test "a lens receives the code map through the shared preamble bullet that owns never citing it" {
  local preamble bullet
  preamble="$(section "$LENS_DISPATCH" '^## Shared preamble')"
  [ -n "$preamble" ]
  bullet="$(grep -F -- '<CODE_MAP_PATH>' <<<"$preamble")"
  [ -n "$bullet" ]
  grep -qF -- 'Never cite `CODE-MAP.json`' <<<"$bullet"
}

@test "the fixer's map paragraph routes to the shared preamble and that heading resolves" {
  local fixer paragraph
  fixer="$(section "$AUDIT" '^## The fixer')"
  [ -n "$fixer" ]
  paragraph="$(grep -F -- 'When `<CODE_MAP_PATH>` is named:' <<<"$fixer")"
  [ -n "$paragraph" ]
  grep -qF -- '`spec/lens-dispatch.md` `## Shared preamble`' <<<"$paragraph"
  grep -qE '^## Shared preamble$' "$LENS_DISPATCH"
}
