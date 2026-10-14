#!/usr/bin/env bats
# doc-grep coverage for the narrowing of /gaia-cleanse to memory and wiki
# curation. The playbook (.claude/skills/gaia/references/cleanse.md and its
# cleanse/*.md sub-references) is prose a model executes, so the narrowing is
# pinned as text: an instruction file that contradicts a wiki page is reported
# and never edited, and the store listing comes from the CLI.
#
# Every check is a function over a list of files. Each is run twice: green over
# the real playbook files, and red over the committed excerpt of the earlier
# playbook text (fixtures/cleanse-narrowing/pre-narrowing-excerpt.md), so a
# check that stopped being able to fail shows up as a green red-twin.
#
# Assertion style: .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES="$ROOT/.claude/skills/gaia/references"
  ENTRY="$REFERENCES/cleanse.md"
  EXCERPT="$BATS_TEST_DIRNAME/fixtures/cleanse-narrowing/pre-narrowing-excerpt.md"
  ROUTING="$BATS_TEST_DIRNAME/fixtures/cleanse-conflict-routing"

  [ -s "$ENTRY" ] || {
    echo "missing or empty $ENTRY" >&2
    return 1
  }
  [ -s "$EXCERPT" ] || {
    echo "missing or empty $EXCERPT" >&2
    return 1
  }

  SUB_REFERENCES=()
  local sub_reference
  for sub_reference in "$REFERENCES"/cleanse/*.md; do
    [ -f "$sub_reference" ] && SUB_REFERENCES+=("$sub_reference")
  done
  [ "${#SUB_REFERENCES[@]}" -gt 0 ] || {
    echo "no sub-references under $REFERENCES/cleanse/; the guard would pass over the entry alone" >&2
    return 1
  }
  PLAYBOOK_FILES=("$ENTRY" "${SUB_REFERENCES[@]}")
}

# anchored_lines <anchor_ERE> <file>...: every line matching the anchor, or a
# failure when none does, so a check scoped to an anchor cannot pass over a
# playbook that no longer holds it.
anchored_lines() {
  local anchor="$1" found
  shift
  found="$(grep -hE -- "$anchor" "$@")" || return 1
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

check_inventory_comes_from_the_cli() {
  grep -q -- 'gaia fitness inventory --json' "$@" || return 1
  grep -qE -- 'knowledge-inventory\.sh (list|counts)' "$@" && return 1
  true
}

# An instruction file contradicting a wiki page is reported, never edited: the
# routing sentence names all four file types and the out-of-scope section, and
# carries no editing verb.
check_instruction_file_conflict_is_report_only() {
  local routing
  routing="$(anchored_lines '^  - \*\*Cross-store, instruction file vs wiki page\*\*' "$@")" || return 1
  local term
  for term in 'rule' 'skill' 'command' 'CLAUDE\.md' '## Out-of-scope findings'; do
    grep -qE -- "$term" <<<"$routing" || return 1
  done
  grep -qiE -- '\b(replace|edit|delete|shrink|promote|rewrite)\b' <<<"$routing" && return 1
  grep -qE -- 'rules/\*\.md.*Emit a `replace`' "$@" && return 1
  true
}

# --- the shape of the split ---

@test "the entry and every sub-reference stay under 500 lines" {
  local file
  for file in "${PLAYBOOK_FILES[@]}"; do
    [ "$(wc -l <"$file")" -lt 500 ] || {
      echo "$file is 500 lines or more" >&2
      return 1
    }
  done
}

# --- conflict scope ---

@test "an instruction file contradicting a wiki page is routed to out-of-scope findings with no action" {
  check_instruction_file_conflict_is_report_only "${PLAYBOOK_FILES[@]}"
}

@test "red twin: the earlier cross-store text emitted a replace on a rules file" {
  run check_instruction_file_conflict_is_report_only "$EXCERPT"
  [ "$status" -eq 1 ]
}

@test "red twin: a routing sentence that proposes an edit is refused" {
  local scratch="$BATS_TEST_TMPDIR/routing.md"
  printf '%s\n' '  - **Cross-store, instruction file vs wiki page**: a rule, skill, command or CLAUDE.md file contradicts a wiki page. Record it in `## Out-of-scope findings` and edit the file to match.' >"$scratch"
  run check_instruction_file_conflict_is_report_only "$scratch"
  [ "$status" -eq 1 ]
}

@test "red twin: a routing sentence that omits a file type is refused" {
  local scratch="$BATS_TEST_TMPDIR/routing.md"
  printf '%s\n' '  - **Cross-store, instruction file vs wiki page**: a rule, skill or command contradicts a wiki page. Record it in `## Out-of-scope findings`.' >"$scratch"
  run check_instruction_file_conflict_is_report_only "$scratch"
  [ "$status" -eq 1 ]
}

# --- the CLI owns the inventory and the budgets ---

@test "the store inventory is read from the CLI and the script's list and counts are gone" {
  check_inventory_comes_from_the_cli "${PLAYBOOK_FILES[@]}"
}

@test "red twin: the earlier text read the inventory from the script" {
  local scratch="$BATS_TEST_TMPDIR/inventory.md"
  local script_call
  # Assembled at run time so no tracked file holds the retired call verbatim.
  script_call="$(printf 'bash .gaia/scripts/knowledge-inventory.sh %s' list)"
  printf 'Run `%s` and work from every row it lists.\n' "$script_call" >"$scratch"
  run check_inventory_comes_from_the_cli "$scratch"
  [ "$status" -eq 1 ]
  printf 'Run `.gaia/cli/gaia fitness inventory --json`, not `%s`.\n' "$script_call" >"$scratch"
  run check_inventory_comes_from_the_cli "$scratch"
  [ "$status" -eq 1 ]
}

@test "red twin: a playbook that never names the CLI inventory is refused" {
  run check_inventory_comes_from_the_cli "$EXCERPT"
  [ "$status" -eq 1 ]
}

# --- the given a model-run acceptance starts from ---

@test "the routing fixture holds a command and a skill that assert opposing facts" {
  grep -qF -- 'release notes stage runs on the opus model' "$ROUTING/.claude/commands/example-release.md"
  grep -qF -- 'release notes stage runs on the sonnet model' "$ROUTING/.claude/skills/example-release/SKILL.md"
}

@test "the routing fixture holds a skill that contradicts a wiki page" {
  grep -qF -- 'Production deploys run on Fridays' "$ROUTING/.claude/skills/example-deploy/SKILL.md"
  grep -qF -- 'Never deploy to production on a Friday' "$ROUTING/wiki/concepts/Deploy-Policy.md"
}

@test "the routing fixture holds a memory entry that duplicates a wiki page" {
  local memory_line wiki_line
  memory_line="$(grep -F -- 'Never deploy to production on a Friday' "$ROUTING/memory/deploy-window.md")"
  wiki_line="$(grep -F -- 'Never deploy to production on a Friday' "$ROUTING/wiki/concepts/Deploy-Policy.md")"
  [ -n "$memory_line" ]
  [ "$memory_line" = "$wiki_line" ]
}
