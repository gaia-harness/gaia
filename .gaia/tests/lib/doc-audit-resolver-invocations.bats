#!/usr/bin/env bats
#
# Pins the scope-resolver command line each Code Audit Team member definition
# carries. Only the frontend member asks the resolver for its specialist
# triggers, so the `--specialists` flag appears in that one definition's line,
# once, at the end, and nowhere else under the agents directory or in the
# shared protocol. It also pins the dispatch tree on the protocol's earned
# write call, which must match the tree the resolver line captured with.
#
# Every assertion is about the tree as it stands (never a comparison with
# another revision's copy), so the suite holds on the default branch and on every later branch.
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
    code-audit-frontend) echo "<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-frontend --root <root> --dispatch-tree <expected-tree> --skip-full-base --eligibility --review-path '*.ts' --review-path '*.tsx' --specialists" ;;
    code-audit-github-workflows) echo "<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-github-workflows --root <root> --dispatch-tree <expected-tree>" ;;
    code-audit-maintainer-node) echo "<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-maintainer-node --root <root> --dispatch-tree <expected-tree>" ;;
    code-audit-maintainer-shell) echo "<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-maintainer-shell --root <root> --dispatch-tree <expected-tree>" ;;
    code-audit-shell) echo "<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-shell --root <root> --dispatch-tree <expected-tree>" ;;
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

# earned_write_block <protocol file>: the fenced writer call that carries
# `--provenance earned`, from its opening line to its last continuation line.
# Fails unless exactly one such call exists.
earned_write_block() {
  local block count
  block="$(awk '
    /^bash <root>\/\.gaia\/scripts\/audit-write-clearance\.sh / { collecting = 1; current = "" }
    collecting { current = current $0 "\n" }
    collecting && !/\\$/ { collecting = 0; if (current ~ /--provenance earned/) printf "%s\034", current }
  ' "$1")"
  count="$(tr -cd '\034' <<<"$block" | wc -c | tr -d ' ')"
  [ "$count" -eq 1 ] || { echo "$1 carries $count earned writer calls" >&2; return 1; }
  printf '%s' "${block%$'\034'}"
}

# --- live tree ----------------------------------------------------------------

# The member captures with a dispatch tree (its resolver line above), so its
# earned write must name the same tree: a write without it is refused and the
# capture is kept, so every re-dispatch on that tree is refused the same way.
@test "the protocol's earned write call passes --dispatch-tree '<expected-tree>'" {
  local block
  block="$(earned_write_block "$PROTOCOL")" || return 1
  grep -qE -- "^  --dispatch-tree '<expected-tree>'( \\\\)?$" <<<"$block" || { echo "case failed: $block" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "each definition's resolver line equals its row" {
  local member_file member count=0
  for member_file in "$AGENTS_DIRECTORY"/code-audit-*.md; do
    [ -f "$member_file" ] || continue
    member="$(basename "$member_file" .md)"
    assert_row "$member_file" "$member" || { echo "case failed: $member" >&2; return 1; }
    count=$((count + 1))
  done
  [ "$count" -ge 4 ] || { echo "only $count member definitions found" >&2; return 1; }
  # The roster this table covers: a definition that vanished must not shrink it silently.
  for member in code-audit-frontend code-audit-github-workflows code-audit-maintainer-node code-audit-maintainer-shell code-audit-shell; do
    [ -f "$AGENTS_DIRECTORY/$member.md" ] || { echo "case failed: $member.md is missing" >&2; return 1; }
  done
}

# bats test_tags=whole-tree
@test "only the frontend resolver line carries --specialists, once, last" {
  assert_frontend_ends_with_flag "$AGENTS_DIRECTORY/code-audit-frontend.md" || { echo "case failed: ends with the flag" >&2; return 1; }
  assert_flag_exactly_once "$AGENTS_DIRECTORY/code-audit-frontend.md" || { echo "case failed: flag exactly once" >&2; return 1; }
  assert_only_frontend_names_flag "$AGENTS_DIRECTORY" "$PROTOCOL" || { echo "case failed: no other file names the flag" >&2; return 1; }
}
