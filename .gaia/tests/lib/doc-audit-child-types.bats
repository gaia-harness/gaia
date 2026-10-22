#!/usr/bin/env bats
# Doc-conformance for the two child agent types the frontend Code Audit Team
# member dispatches (the rule specialist and the refuter) and for the
# branch-point reference holding the refutation machinery. The frontend member
# parses the refuter's three verdict tokens and the specialist's coverage line,
# so a drift in a type definition changes what the member reads without any
# error. Each assertion has a red twin built from a scratch copy with one line
# altered, proving the check can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SPECIALIST="$ROOT/.claude/agents/audit-rule-specialist.md"
  REFUTER="$ROOT/.claude/agents/audit-refuter.md"
  REFERENCE="$ROOT/.claude/hooks/lib/audit-frontend-refuter.md"
  FRONTEND="$ROOT/.claude/agents/code-audit-frontend.md"
  NOOP_SUITE="$ROOT/.gaia/tests/lib/doc-noop-terminal-contract.bats"
}

# frontmatter <file>: the lines between the first two `---` fences.
frontmatter() {
  awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$1"
}

# frontmatter_matches <file> <expected-lines>: the frontmatter, minus the
# free-text description line, equals the expected lines exactly.
frontmatter_matches() {
  local actual
  actual="$(frontmatter "$1" | grep -v '^description:')"
  [ "$actual" = "$2" ]
}

SPECIALIST_FRONTMATTER='name: audit-rule-specialist
model: haiku
tools: Bash, Read
omitClaudeMd: true'

REFUTER_FRONTMATTER='name: audit-refuter
model: sonnet
tools: Bash, Read'

# bats test_tags=whole-tree
@test "the specialist frontmatter is exactly the pinned lines" {
  frontmatter_matches "$SPECIALIST" "$SPECIALIST_FRONTMATTER"
}

# bats test_tags=whole-tree
@test "the refuter frontmatter is exactly the pinned lines, with no omitClaudeMd" {
  frontmatter_matches "$REFUTER" "$REFUTER_FRONTMATTER"
  frontmatter "$REFUTER" | grep -q '^omitClaudeMd' && return 1
  true
}

# bats test_tags=whole-tree
@test "red twin: a refuter copy carrying omitClaudeMd fails the frontmatter check" {
  local twin="$BATS_TEST_TMPDIR/audit-refuter.md"
  sed 's/^tools: Bash, Read$/tools: Bash, Read\nomitClaudeMd: true/' "$REFUTER" >"$twin"
  grep -q '^omitClaudeMd: true$' "$twin"
  frontmatter_matches "$twin" "$REFUTER_FRONTMATTER" && return 1
  true
}

# bats test_tags=whole-tree
@test "red twin: a specialist copy with a different model fails the frontmatter check" {
  local twin="$BATS_TEST_TMPDIR/audit-rule-specialist.md"
  sed 's/^model: haiku$/model: opus/' "$SPECIALIST" >"$twin"
  grep -q '^model: opus$' "$twin"
  frontmatter_matches "$twin" "$SPECIALIST_FRONTMATTER" && return 1
  true
}

# bats test_tags=whole-tree
@test "neither new type is named like a Code Audit Team member" {
  local file base name
  for file in "$SPECIALIST" "$REFUTER"; do
    base="$(basename "$file")"
    name="$(frontmatter "$file" | sed -n 's/^name: //p')"
    [ -n "$name" ]
    case "$base" in code-audit-*) return 1 ;; esac
    case "$name" in code-audit-*) return 1 ;; esac
  done
}

# bats test_tags=whole-tree
@test "the specialist body carries the reply contract, the role convention and each typescript rule anchor" {
  local anchor
  for anchor in \
    'Files reviewed: <n>' \
    'No violations found.' \
    'Role: <react-patterns | typescript | translation>' \
    'flag any `interface` declarations' \
    'No TypeScript enums' \
    '`z.literal()` not `z.enum()`' \
    'Exported functions must have explicit return types'; do
    grep -qF -- "$anchor" "$SPECIALIST" || {
      echo "specialist is missing: $anchor" >&2
      return 1
    }
  done
}

# bats test_tags=whole-tree
@test "red twin: a specialist copy without the coverage-line rule fails the anchor check" {
  local twin="$BATS_TEST_TMPDIR/audit-rule-specialist.md"
  sed 's/Files reviewed: <n>/Files seen: <n>/g' "$SPECIALIST" >"$twin"
  grep -qF -- 'Files reviewed: <n>' "$twin" && return 1
  true
}

# bats test_tags=whole-tree
@test "the refuter body and the reference dispatch prompt each carry the three verdict tokens" {
  local token file
  for file in "$REFUTER" "$REFERENCE"; do
    for token in 'REFUTED (cannot occur)' 'DOWNGRADE (occurs but smaller)' 'STANDS (no concrete counter-evidence found)'; do
      grep -qF -- "$token" "$file" || {
        echo "$file is missing: $token" >&2
        return 1
      }
    done
  done
}

# bats test_tags=whole-tree
@test "red twin: a refuter copy without the STANDS verdict fails the token check" {
  local twin="$BATS_TEST_TMPDIR/audit-refuter.md"
  sed 's/STANDS (no concrete counter-evidence found)/HOLDS/g' "$REFUTER" >"$twin"
  grep -qF -- 'STANDS (no concrete counter-evidence found)' "$twin" && return 1
  true
}

# bats test_tags=whole-tree
@test "the reference carries the no-op phrases, the typed dispatch and the unknown-type fallback" {
  local phrase
  for phrase in \
    'audit-noop-detect.sh' \
    'exactly one' \
    'inline fallback' \
    'second consecutive no-op' \
    'subagent_type: "audit-refuter"' \
    'Unknown agent type' \
    'relaunch Claude Code to load the new agent types'; do
    grep -qF -- "$phrase" "$REFERENCE" || {
      echo "reference is missing: $phrase" >&2
      return 1
    }
  done
}

# bats test_tags=whole-tree
@test "the reference spells no model or effort pin" {
  grep -qE '(model|effort):' "$REFERENCE" && return 1
  grep -qE '(haiku|sonnet|opus|fable)' -i "$REFERENCE" && return 1
  true
}

# bats test_tags=whole-tree
@test "red twin: a reference copy with a model pin fails the no-pin check" {
  local twin="$BATS_TEST_TMPDIR/audit-frontend-refuter.md"
  { cat "$REFERENCE"; printf 'model: sonnet\n'; } >"$twin"
  grep -qE '(model|effort):' "$twin"
}

# bats test_tags=whole-tree
@test "the reference sits outside every extension directory the frontend lists" {
  local directory
  grep -qF -- '.claude/agents/code-audit-frontend/*.md' "$FRONTEND"
  for directory in \
    "$ROOT/.claude/agents/code-audit-frontend/" \
    "$ROOT/frontend/.claude/agents/code-audit-frontend/"; do
    case "$REFERENCE" in "$directory"*) return 1 ;; esac
  done
  true
}

# bats test_tags=whole-tree
@test "red twin: a reference path inside the extension directory is caught" {
  local inside="$ROOT/.claude/agents/code-audit-frontend/audit-frontend-refuter.md"
  case "$inside" in "$ROOT/.claude/agents/code-audit-frontend/"*) return 0 ;; esac
  return 1
}

# bats test_tags=whole-tree
@test "the noop-terminal roster carries the reference path exactly once" {
  local count
  count="$(grep -cF -- "'.claude/hooks/lib/audit-frontend-refuter.md'" "$NOOP_SUITE")"
  [ "$count" -eq 1 ]
}
