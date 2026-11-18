#!/usr/bin/env bats
# Doc-conformance for the cross-file mode of /gaia-cleanse. The playbook is
# prose a model executes, so two of its guarantees are pinned as text:
#   - a copy that disagrees with its owner is reported, never edited: the
#     bold-labelled routing line in cleanse/cross-file.md names the out-of-scope
#     section and carries no edit verb (the suggested-fix line after it names
#     the human's later fix and is deliberately not scanned);
#   - the arm that lets the cleanse edit a GAIA-shipped file exists only in the
#     GAIA source repo: every `owner: maintainer` in research.md and apply.md
#     sits inside a maintainer-only block, which the release scrub strips, so
#     no adopter bundle carries it.
#
# Each check is a function over files, run green on the real files and red on
# a scratch copy in the same test. Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLEANSE="$ROOT/.claude/skills/gaia/references/cleanse"
  CROSS_FILE="$CLEANSE/cross-file.md"
  RESEARCH="$CLEANSE/research.md"
  APPLY="$CLEANSE/apply.md"
  DISAGREE_ANCHOR='^- \*\*Disagree\*\*:'
}

# check_disagree_is_report_only <file>...: the `- **Disagree**:` routing line
# exists, names the out-of-scope section, and carries no edit verb.
check_disagree_is_report_only() {
  local routing
  routing="$(grep -hE -- "$DISAGREE_ANCHOR" "$@")" || return 1
  [ -n "$routing" ] || return 1
  grep -qF -- '## Out-of-scope findings' <<<"$routing" || return 1
  grep -qiE -- '\b(replace|edit|delete|shrink|promote|rewrite)\b' <<<"$routing" && return 1
  true
}

# check_maintainer_owner_inside_blocks <file>...: every line carrying
# `owner: maintainer` sits between a maintainer-only start and end marker, and
# each file carries at least one, so a file that lost the arm cannot pass.
# Prints each offending file:line on stderr.
check_maintainer_owner_inside_blocks() {
  awk '
    FNR == 1 { inside = 0; files[FILENAME] = 0 }
    /gaia:maintainer-only:start/ { inside = 1; next }
    /gaia:maintainer-only:end/ { inside = 0; next }
    index($0, "owner: maintainer") {
      files[FILENAME]++
      if (!inside) { print FILENAME ":" FNR " sits outside a maintainer-only block" > "/dev/stderr"; outside++ }
    }
    END {
      for (file in files) {
        if (files[file] == 0) { print file " carries no owner: maintainer" > "/dev/stderr"; outside++ }
      }
      exit (outside > 0) ? 1 : 0
    }' "$@"
}

@test "a copy that disagrees with its owner is routed to out-of-scope findings with no action" {
  check_disagree_is_report_only "$CROSS_FILE"

  local scratch="$BATS_TEST_TMPDIR/cross-file.md"
  grep -vE -- "$DISAGREE_ANCHOR" "$CROSS_FILE" >"$scratch"
  run check_disagree_is_report_only "$scratch"
  [ "$status" -eq 1 ]

  sed -E "s/^(${DISAGREE_ANCHOR#^}.*)\$/\\1 and replace the copy/" "$CROSS_FILE" >"$scratch"
  cmp -s "$CROSS_FILE" "$scratch" && { echo "the scratch edit changed nothing" >&2; return 1; }
  run check_disagree_is_report_only "$scratch"
  [ "$status" -eq 1 ]
}

@test "the GAIA-shipped edit arm sits only inside maintainer-only blocks" {
  check_maintainer_owner_inside_blocks "$RESEARCH" "$APPLY"

  # Move the first occurrence out of its block, to the end of the file.
  local scratch="$BATS_TEST_TMPDIR/research.md"
  awk '
    !moved && index($0, "owner: maintainer") { held = $0; moved = 1; next }
    { print }
    END { if (moved) print held }' "$RESEARCH" >"$scratch"
  cmp -s "$RESEARCH" "$scratch" && { echo "the scratch move changed nothing" >&2; return 1; }
  run check_maintainer_owner_inside_blocks "$scratch" "$APPLY"
  [ "$status" -eq 1 ]

  # A file that carries the arm nowhere fails too.
  grep -vF -- 'owner: maintainer' "$APPLY" >"$BATS_TEST_TMPDIR/apply.md"
  run check_maintainer_owner_inside_blocks "$RESEARCH" "$BATS_TEST_TMPDIR/apply.md"
  [ "$status" -eq 1 ]
}
