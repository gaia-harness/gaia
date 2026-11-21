#!/usr/bin/env bats
#
# Pins the `tools:` allowlist of every dedicated audit-path agent, and that no
# definition tells its agent to use a tool outside that allowlist.
#
# A dropped tool is invisible at run time until the agent reaches for it, so
# two things are checked per agent: the frontmatter `tools:` line equals the
# table row, and every line of the definition (for the frontend, also the
# refuter reference it Reads) that names a tool outside the allowlist is a
# prohibition or the description of a refusal, never an instruction.
#
# The named-tool matcher recognises a tool as a backticked name, as
# `<Name> tool`, `<Name> call` or `with <Name>`, and, for Grep and Glob, as a
# capitalized bare verb that opens an instruction. A matching line passes only
# when it also carries never, not, no, refus or cannot (case-insensitive). On
# the live files no line needed an exemption; a future line that is a
# legitimate non-prohibition needs rewording or a recorded exemption here.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AGENTS_DIRECTORY="$REPO_ROOT/.claude/agents"
  FRONTEND_REFUTER_REFERENCE="$REPO_ROOT/.claude/hooks/lib/audit-frontend-refuter.md"
  TOOL_VOCABULARY='Agent Bash Edit Glob Grep Monitor NotebookEdit Read SendMessage Skill TaskOutput TaskStop ToolSearch WebFetch WebSearch Write'
}

# tools_rows: one row per agent, `<agent> <tools line>`, the allowlist
# comma-separated in alphabetical order.
tools_rows() {
  cat <<'ROWS'
code-audit-frontend tools: Agent, Bash, Read, Write
code-audit-github-workflows tools: Bash, Read
code-audit-maintainer-node tools: Bash, Read
code-audit-maintainer-shell tools: Bash, Monitor, Read, WebFetch
code-audit-shell tools: Bash, Read
audit-loop-unit tools: Agent, Bash, Monitor, Read, SendMessage, Write
worthiness-evaluator tools: Bash, Read, Write
security-test-writer tools: Bash, Edit, Read, Write
audit-rule-specialist tools: Bash, Read
audit-refuter tools: Bash, Read
ROWS
}

# row_for <agent>: the agent's tools line from the table.
row_for() {
  local agent line
  while IFS= read -r line; do
    agent="${line%% *}"
    [ "$agent" = "$1" ] && { printf '%s\n' "${line#* }"; return 0; }
  done < <(tools_rows)
  return 1
}

# frontmatter <file>: the lines between the first two `---` lines.
frontmatter() {
  awk '
    $0 == "---" { count++; next }
    count == 1 { print }
    count >= 2 { exit }
  ' "$1"
}

# assert_row <agent> <definition file>: the frontmatter carries exactly one
# `tools:` line and it equals the agent's row.
assert_row() {
  local want actual count
  want="$(row_for "$1")" || { echo "no row for $1" >&2; return 1; }
  [ -f "$2" ] || { echo "$2 is missing" >&2; return 1; }
  count="$(frontmatter "$2" | grep -c '^tools:' || true)"
  [ "$count" -eq 1 ] || { echo "$2 carries $count tools: lines in its frontmatter" >&2; return 1; }
  actual="$(frontmatter "$2" | grep '^tools:')"
  [ "$actual" = "$want" ] || { echo "$2: want [$want] got [$actual]" >&2; return 1; }
  return 0
}

# assert_every_member_has_row <agents directory>: each code-audit-*.md file has
# a row in the table, and at least one exists.
assert_every_member_has_row() {
  local member_file member count=0
  for member_file in "$1"/code-audit-*.md; do
    [ -f "$member_file" ] || continue
    member="$(basename "$member_file" .md)"
    row_for "$member" >/dev/null || { echo "$member has no tools row; pin it" >&2; return 1; }
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || { echo "no code-audit definitions found in $1" >&2; return 1; }
  return 0
}

# assert_named_tools_are_prohibitions <agent> <file...>: every line of the
# files that names a tool outside the agent's allowlist carries a prohibition
# word.
assert_named_tools_are_prohibitions() {
  local agent="$1" row allowed tool pattern file hits
  shift
  row="$(row_for "$agent")" || { echo "no row for $agent" >&2; return 1; }
  allowed=" $(printf '%s' "${row#tools: }" | tr -d ',') "
  for file in "$@"; do
    [ -f "$file" ] || { echo "$file is missing" >&2; return 1; }
    for tool in $TOOL_VOCABULARY; do
      case "$allowed" in *" $tool "*) continue ;; esac
      pattern="\`$tool\`|$tool tool|$tool call|with $tool([^A-Za-z]|\$)"
      case "$tool" in
        Grep | Glob) pattern="$pattern|(^|[^\`A-Za-z])$tool (for|<|[a-z/])" ;;
      esac
      hits="$(grep -nE -- "$pattern" "$file" | grep -viE 'never|not|no |refus|cannot' || true)"
      [ -z "$hits" ] || { echo "$file names $tool, outside $agent's allowlist, outside a prohibition: $hits" >&2; return 1; }
    done
  done
  return 0
}

# --- frontmatter rows ---------------------------------------------------------

# bats test_tags=whole-tree
@test "each audit agent carries its pinned tools line" {
  local agent row
  assert_every_member_has_row "$AGENTS_DIRECTORY" || return 1
  while IFS= read -r row; do
    agent="${row%% *}"
    assert_row "$agent" "$AGENTS_DIRECTORY/$agent.md" || { echo "case failed: $agent" >&2; return 1; }
  done < <(tools_rows)
}

# --- named tools --------------------------------------------------------------

# bats test_tags=whole-tree
@test "no definition instructs a tool outside its allowlist except as a prohibition" {
  local agent row
  assert_named_tools_are_prohibitions code-audit-frontend "$AGENTS_DIRECTORY/code-audit-frontend.md" "$FRONTEND_REFUTER_REFERENCE" || { echo "case failed: code-audit-frontend and its refuter reference" >&2; return 1; }
  while IFS= read -r row; do
    agent="${row%% *}"
    [ "$agent" = code-audit-frontend ] && continue
    assert_named_tools_are_prohibitions "$agent" "$AGENTS_DIRECTORY/$agent.md" || { echo "case failed: $agent" >&2; return 1; }
  done < <(tools_rows)
}
