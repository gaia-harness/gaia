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
# Each helper takes the file it reads so a scratch copy proves a case can fail.
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
audit-loop-unit tools: Agent, Bash, Monitor, Read, SendMessage, Write
worthiness-evaluator tools: Bash, Read, Write
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

# --- the table ----------------------------------------------------------------

@test "the tools table has exactly the eight agents, each once" {
  [ "$(tools_rows | grep -c '')" -eq 8 ]
  [ "$(tools_rows | cut -d' ' -f1 | sort -u | grep -c '')" -eq 8 ]
}

# bats test_tags=whole-tree
@test "every code-audit definition has a row in the tools table" {
  assert_every_member_has_row "$AGENTS_DIRECTORY"
}

# --- frontmatter rows ---------------------------------------------------------

# bats test_tags=whole-tree
@test "code-audit-frontend carries its pinned tools line" {
  assert_row code-audit-frontend "$AGENTS_DIRECTORY/code-audit-frontend.md"
}

# bats test_tags=whole-tree
@test "code-audit-github-workflows carries its pinned tools line" {
  assert_row code-audit-github-workflows "$AGENTS_DIRECTORY/code-audit-github-workflows.md"
}

# bats test_tags=whole-tree
@test "code-audit-maintainer-node carries its pinned tools line" {
  assert_row code-audit-maintainer-node "$AGENTS_DIRECTORY/code-audit-maintainer-node.md"
}

# bats test_tags=whole-tree
@test "code-audit-maintainer-shell carries its pinned tools line" {
  assert_row code-audit-maintainer-shell "$AGENTS_DIRECTORY/code-audit-maintainer-shell.md"
}

# bats test_tags=whole-tree
@test "audit-loop-unit carries its pinned tools line" {
  assert_row audit-loop-unit "$AGENTS_DIRECTORY/audit-loop-unit.md"
}

# bats test_tags=whole-tree
@test "worthiness-evaluator carries its pinned tools line" {
  assert_row worthiness-evaluator "$AGENTS_DIRECTORY/worthiness-evaluator.md"
}

# bats test_tags=whole-tree
@test "audit-rule-specialist carries its pinned tools line" {
  assert_row audit-rule-specialist "$AGENTS_DIRECTORY/audit-rule-specialist.md"
}

# bats test_tags=whole-tree
@test "audit-refuter carries its pinned tools line" {
  assert_row audit-refuter "$AGENTS_DIRECTORY/audit-refuter.md"
}

# --- named tools --------------------------------------------------------------

# bats test_tags=whole-tree
@test "the frontend definition and its refuter reference name no tool outside the allowlist except as a prohibition" {
  assert_named_tools_are_prohibitions code-audit-frontend "$AGENTS_DIRECTORY/code-audit-frontend.md" "$FRONTEND_REFUTER_REFERENCE"
}

# bats test_tags=whole-tree
@test "the other seven definitions name no tool outside their allowlist except as a prohibition" {
  local agent
  for agent in code-audit-github-workflows code-audit-maintainer-node code-audit-maintainer-shell audit-loop-unit worthiness-evaluator audit-rule-specialist audit-refuter; do
    assert_named_tools_are_prohibitions "$agent" "$AGENTS_DIRECTORY/$agent.md" || return 1
  done
}

# --- red twins: scratch copies, each helper must fail -------------------------

@test "red twin: a frontend copy telling the agent to Glob fails the named-tool rule" {
  local scratch="$BATS_TEST_TMPDIR/frontend.md"
  { cat "$AGENTS_DIRECTORY/code-audit-frontend.md"; printf '\nGlob <root>/.claude/rules/extensions/*.md for the extension rules.\n'; } >"$scratch"
  run assert_named_tools_are_prohibitions code-audit-frontend "$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: a workflows copy telling the agent to Grep fails the named-tool rule" {
  local scratch="$BATS_TEST_TMPDIR/workflows.md"
  { cat "$AGENTS_DIRECTORY/code-audit-github-workflows.md"; printf '\nGrep for where the workflow is invoked.\n'; } >"$scratch"
  run assert_named_tools_are_prohibitions code-audit-github-workflows "$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: a unit copy without SendMessage in its tools line fails its row" {
  local scratch="$BATS_TEST_TMPDIR/unit.md"
  sed 's/^tools: Agent, Bash, Monitor, Read, SendMessage, Write$/tools: Agent, Bash, Monitor, Read, Write/' "$AGENTS_DIRECTORY/audit-loop-unit.md" >"$scratch"
  cmp -s "$AGENTS_DIRECTORY/audit-loop-unit.md" "$scratch" && { echo "twin was not built" >&2; return 1; }
  run assert_row audit-loop-unit "$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: a workflows copy with an extra Write tool fails its row" {
  local scratch="$BATS_TEST_TMPDIR/workflows.md"
  sed 's/^tools: Bash, Read$/tools: Bash, Read, Write/' "$AGENTS_DIRECTORY/code-audit-github-workflows.md" >"$scratch"
  grep -qx 'tools: Bash, Read, Write' "$scratch" || { echo "twin was not built" >&2; return 1; }
  run assert_row code-audit-github-workflows "$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: a shell copy without its tools line fails its row" {
  local scratch="$BATS_TEST_TMPDIR/shell.md"
  sed '/^tools:/d' "$AGENTS_DIRECTORY/code-audit-maintainer-shell.md" >"$scratch"
  run assert_row code-audit-maintainer-shell "$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: an agents directory holding an extra code-audit definition fails the coverage test" {
  local scratch="$BATS_TEST_TMPDIR/agents"
  mkdir -p "$scratch"
  cp "$AGENTS_DIRECTORY"/code-audit-*.md "$scratch/"
  cp "$AGENTS_DIRECTORY/code-audit-maintainer-node.md" "$scratch/code-audit-x.md"
  run assert_every_member_has_row "$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: an empty agents directory fails the coverage test" {
  local scratch="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$scratch"
  run assert_every_member_has_row "$scratch"
  [ "$status" -ne 0 ]
}
