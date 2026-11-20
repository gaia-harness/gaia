#!/usr/bin/env bats
#
# Doc-conformance suite for the split of `/gaia-plan`'s playbook:
# .claude/skills/gaia/references/plan.md is the entry file, and every
# sub-reference under .claude/skills/gaia/references/plan/ is read only when a
# line routes a run to it.
#
# The invariants:
#   b. every plan/*.md is named in plan.md by its repo path and listed in the
#      /gaia-plan command, so a sub-reference no line routes to cannot exist;
#   c. every plan/<name>.md either file names exists.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES_RELATIVE='.claude/skills/gaia/references'
  COMMAND_RELATIVE='.claude/commands/gaia-plan.md'
}

# --- b. every sub-reference is routed and listed ----------------------------

# every_sub_reference_listed <root>: the set comes from the directory, and an
# independent count catches a glob that read fewer files than exist; an empty
# set fails rather than passing vacuously.
every_sub_reference_listed() {
  local root="$1" plan_md command file name path count=0 expected
  plan_md="$root/$REFERENCES_RELATIVE/plan.md"
  command="$root/$COMMAND_RELATIVE"
  expected="$(find "$root/$REFERENCES_RELATIVE/plan" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$expected" -ge 1 ] || { printf 'no plan/*.md files found\n' >&2; return 1; }
  for file in "$root/$REFERENCES_RELATIVE"/plan/*.md; do
    [ -f "$file" ] || continue
    name="$(basename "$file")"
    path="$REFERENCES_RELATIVE/plan/$name"
    count=$((count + 1))
    grep -qF -- "\`$path\`" "$plan_md" || { printf 'plan.md does not name %s\n' "$path" >&2; return 1; }
    grep -qE -- "^- \`$path\`" "$command" || { printf 'gaia-plan.md does not list %s\n' "$path" >&2; return 1; }
  done
  [ "$count" -eq "$expected" ] || { printf 'read %s of %s files\n' "$count" "$expected" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "every plan/*.md is named in plan.md and listed in the command" {
  every_sub_reference_listed "$REPO_ROOT"
}

# --- c. no route to a missing file ------------------------------------------

no_orphan_route() {
  local root="$1" names name
  names="$(cat "$root/$REFERENCES_RELATIVE/plan.md" "$root/$COMMAND_RELATIVE" |
    grep -oE -- 'references/plan/[A-Za-z0-9_-]+\.md' | sed 's|^references/plan/||' | sort -u)"
  [ -n "$names" ] || { printf 'neither file names a plan/*.md\n' >&2; return 1; }
  while IFS= read -r name; do
    [ -f "$root/$REFERENCES_RELATIVE/plan/$name" ] || { printf 'route to missing plan/%s\n' "$name" >&2; return 1; }
  done <<<"$names"
}

# bats test_tags=whole-tree
@test "every plan/<name>.md that plan.md or the command names exists" {
  no_orphan_route "$REPO_ROOT"
}
