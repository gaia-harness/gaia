#!/usr/bin/env bats
#
# Pins the scope-resolver command line each Code Audit Team member definition
# carries. Only the frontend member asks the resolver for its specialist
# triggers, so the `--specialists` flag appears in that one definition's line,
# once, at the end, and nowhere else under the agents directory or in the
# shared protocol.
#
# Every assertion is about the tree as it stands (never a comparison with
# another revision's copy), so the suite holds on the default branch and on every later branch.
# Each helper takes the file or directory it reads so a scratch copy proves a
# case can fail.
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AGENTS_DIRECTORY="$REPO_ROOT/.claude/agents"
  PROTOCOL="$REPO_ROOT/.claude/hooks/lib/audit-member-protocol.md"
}

# expected_line <member>: the literal resolver command line the member's
# definition carries.
expected_line() {
  case "$1" in
    code-audit-frontend) echo "<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-frontend --root <root> --skip-full-base --eligibility --review-path '*.ts' --review-path '*.tsx' --specialists" ;;
    code-audit-github-workflows) echo "<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-github-workflows --root <root>" ;;
    code-audit-maintainer-node) echo "<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-maintainer-node --root <root>" ;;
    code-audit-maintainer-shell) echo "<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-maintainer-shell --root <root>" ;;
    *) return 1 ;;
  esac
}

# live_line <definition file>: the one resolver command line the definition
# carries, a line that starts with the root placeholder. Fails unless exactly
# one such line exists.
live_line() {
  local matches count
  matches="$(grep -E -- '^<root>/\.gaia/scripts/audit-resolve-scope\.sh --member ' "$1" || true)"
  [ -n "$matches" ] || { echo "$1 carries no resolver command line" >&2; return 1; }
  count="$(grep -c '' <<<"$matches")"
  [ "$count" -eq 1 ] || { echo "$1 carries $count resolver command lines" >&2; return 1; }
  printf '%s\n' "$matches"
}

# assert_row <definition file> <member>: the live line equals the member's row.
assert_row() {
  local actual want
  actual="$(live_line "$1")" || return 1
  want="$(expected_line "$2")" || { echo "no row for $2" >&2; return 1; }
  [ "$actual" = "$want" ] || { echo "$1: want [$want] got [$actual]" >&2; return 1; }
  return 0
}

# assert_frontend_ends_with_flag <definition file>
assert_frontend_ends_with_flag() {
  local actual
  actual="$(live_line "$1")" || return 1
  case "$actual" in
    *' --specialists') return 0 ;;
    *) echo "$1: line does not end with --specialists: $actual" >&2; return 1 ;;
  esac
}

# assert_flag_exactly_once <definition file>
assert_flag_exactly_once() {
  local actual stripped flag='--specialists'
  actual="$(live_line "$1")" || return 1
  stripped="${actual//"$flag"/}"
  [ $(( ${#actual} - ${#stripped} )) -eq "${#flag}" ] || {
    echo "$1: --specialists is not present exactly once: $actual" >&2
    return 1
  }
  return 0
}

# assert_only_frontend_names_flag <agents directory> <protocol file>: no other
# definition and not the protocol contains the flag.
assert_only_frontend_names_flag() {
  local agent_file hits
  for agent_file in "$1"/*.md; do
    [ -f "$agent_file" ] || continue
    [ "$(basename "$agent_file")" = "code-audit-frontend.md" ] && continue
    hits="$(grep -n -- '--specialists' "$agent_file" || true)"
    [ -z "$hits" ] || { echo "$agent_file: $hits" >&2; return 1; }
  done
  hits="$(grep -n -- '--specialists' "$2" || true)"
  [ -z "$hits" ] || { echo "$2: $hits" >&2; return 1; }
  return 0
}

# --- live tree ----------------------------------------------------------------

# bats test_tags=whole-tree
@test "the frontend definition's resolver line equals its row" {
  assert_row "$AGENTS_DIRECTORY/code-audit-frontend.md" code-audit-frontend
}

# bats test_tags=whole-tree
@test "the workflows definition's resolver line equals its row" {
  assert_row "$AGENTS_DIRECTORY/code-audit-github-workflows.md" code-audit-github-workflows
}

# bats test_tags=whole-tree
@test "the node definition's resolver line equals its row" {
  assert_row "$AGENTS_DIRECTORY/code-audit-maintainer-node.md" code-audit-maintainer-node
}

# bats test_tags=whole-tree
@test "the shell definition's resolver line equals its row" {
  assert_row "$AGENTS_DIRECTORY/code-audit-maintainer-shell.md" code-audit-maintainer-shell
}

# bats test_tags=whole-tree
@test "every code-audit definition has a resolver row" {
  local member_file member
  local count=0
  for member_file in "$AGENTS_DIRECTORY"/code-audit-*.md; do
    [ -f "$member_file" ] || continue
    member="$(basename "$member_file" .md)"
    expected_line "$member" >/dev/null || { echo "$member has no resolver row" >&2; return 1; }
    count=$((count + 1))
  done
  [ "$count" -ge 4 ] || { echo "only $count member definitions found" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "the frontend resolver line ends with --specialists" {
  assert_frontend_ends_with_flag "$AGENTS_DIRECTORY/code-audit-frontend.md"
}

# bats test_tags=whole-tree
@test "the frontend resolver line contains --specialists exactly once" {
  assert_flag_exactly_once "$AGENTS_DIRECTORY/code-audit-frontend.md"
}

# bats test_tags=whole-tree
@test "no other agent definition and not the protocol contains --specialists" {
  assert_only_frontend_names_flag "$AGENTS_DIRECTORY" "$PROTOCOL"
}

# --- red twins: scratch copies, each helper must fail -------------------------

@test "red twin: a frontend copy without --specialists fails its row" {
  local scratch="$BATS_TEST_TMPDIR/agents"
  mkdir -p "$scratch"
  sed 's/ --specialists$//' "$AGENTS_DIRECTORY/code-audit-frontend.md" >"$scratch/code-audit-frontend.md"
  run assert_row "$scratch/code-audit-frontend.md" code-audit-frontend
  [ "$status" -ne 0 ]
}

@test "red twin: a frontend copy without --specialists fails the ends-with test" {
  local scratch="$BATS_TEST_TMPDIR/agents"
  mkdir -p "$scratch"
  sed 's/ --specialists$//' "$AGENTS_DIRECTORY/code-audit-frontend.md" >"$scratch/code-audit-frontend.md"
  run assert_frontend_ends_with_flag "$scratch/code-audit-frontend.md"
  [ "$status" -ne 0 ]
}

@test "red twin: a frontend copy with --specialists doubled fails the exactly-once test" {
  local scratch="$BATS_TEST_TMPDIR/agents"
  mkdir -p "$scratch"
  sed 's/ --specialists$/ --specialists --specialists/' "$AGENTS_DIRECTORY/code-audit-frontend.md" >"$scratch/code-audit-frontend.md"
  run assert_flag_exactly_once "$scratch/code-audit-frontend.md"
  [ "$status" -ne 0 ]
}

@test "red twin: a node copy carrying --specialists fails the only-frontend test" {
  local scratch="$BATS_TEST_TMPDIR/agents"
  mkdir -p "$scratch"
  cp "$AGENTS_DIRECTORY/code-audit-frontend.md" "$scratch/code-audit-frontend.md"
  sed 's/--root <root>$/--root <root> --specialists/' "$AGENTS_DIRECTORY/code-audit-maintainer-node.md" >"$scratch/code-audit-maintainer-node.md"
  grep -qF -- '--specialists' "$scratch/code-audit-maintainer-node.md" || { echo "twin was not built" >&2; return 1; }
  run assert_only_frontend_names_flag "$scratch" "$PROTOCOL"
  [ "$status" -ne 0 ]
}
