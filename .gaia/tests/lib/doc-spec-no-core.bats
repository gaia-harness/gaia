#!/usr/bin/env bats
#
# Doc-conformance suite: /gaia-spec runs as one explicit, script-driven
# workflow with no dependency on a spec-kit core install. Step 3 carries the
# allocate, anchor, and stamp duties itself, step 10 runs the lint script
# directly.
#
# Tokens the removed-automation guard forbids anywhere in the tree are built at
# runtime (concatenation) so this file never carries one contiguously.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"
  TEMPLATE="$REPO_ROOT/.claude/skills/gaia/references/spec/spec-template.md"
  ALLOCATOR="$REPO_ROOT/.gaia/scripts/spec/spec-allocator.sh"
  LINT="$REPO_ROOT/.gaia/scripts/spec/lint.sh"

  slash_command_prefix="/spec""kit-"
}

_anchor_line() {
  grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1
}

# Text between two fixed-string anchors in a file: [start_anchor, end_anchor).
# Both anchors are checked so a moved heading fails legibly instead of
# emptying the range and letting every absence assertion pass.
range_between() {
  local file="$1" start_pattern="$2" end_pattern="$3" start_line end_line
  start_line="$(_anchor_line "$file" "$start_pattern")"
  end_line="$(_anchor_line "$file" "$end_pattern")"
  [ -n "$start_line" ] || { printf 'start anchor not found in %s: %s\n' "$file" "$start_pattern" >&2; return 1; }
  [ -n "$end_line" ] || { printf 'end anchor not found in %s: %s\n' "$file" "$end_pattern" >&2; return 1; }
  sed -n "${start_line},$((end_line - 1))p" "$file"
}

step3_range() {
  range_between "$SPEC_MD" '### 3. Initial draft (allocate, anchor, stamp)' '### 4. Gate 1'
}

@test "a filled template lints clean" {
  filled="$BATS_TEST_TMPDIR/filled.md"
  sed 's/SPEC-NNN/SPEC-001/;s/UAT-NNN/UAT-001/' "$TEMPLATE" > "$filled"

  run bash "$LINT" "$filled"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

@test "step 3 carries the absorbed duties" {
  range="$(step3_range)"
  [ -n "$range" ]

  # shellcheck disable=SC2016  # needles are literal fence text, not expansions
  for needle in \
    'spec-allocator.sh next "$PWD"' \
    'SPEC_ID' \
    'main-root-lib.sh' \
    'mkdir -p "${MAIN_ROOT}/.gaia/local/specs/${SPEC_ID}"' \
    'references/spec/spec-template.md' \
    'draft-' \
    'spec_id' 'type' 'status' 'immutable' 'wiki_promote_default' 'chain_trigger' 'created' 'updated'; do
    if ! printf '%s\n' "$range" | grep -qF -- "$needle"; then
      printf 'step 3 is missing: %s\n' "$needle" >&2
      return 1
    fi
  done
  true
}

@test "step 10 runs the lint script directly" {
  range="$(range_between "$SPEC_MD" '### 10. Immutability lint' '### 11.')"
  [ -n "$range" ]
  if ! printf '%s\n' "$range" | grep -qF -- 'bash .gaia/scripts/spec/lint.sh'; then
    printf 'step 10 does not run lib/lint.sh directly\n' >&2
    return 1
  fi
  true
}
