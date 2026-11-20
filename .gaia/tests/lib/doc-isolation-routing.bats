#!/usr/bin/env bats
#
# Doc-pin: none of the update-deps and update-gaia files in UPDATE_FILES keeps
# an "on any other branch, work in place" arm.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # Update-command files that must keep no in-place arm.
  UPDATE_FILES=(
    ".claude/skills/update-deps/SKILL.md"
    ".claude/skills/update-deps/references/publish.md"
    ".claude/skills/update-deps/references/worktree.md"
    ".claude/skills/update-gaia/SKILL.md"
    ".claude/skills/update-gaia/references/claim-flow.md"
    ".claude/skills/update-gaia/references/pull-mode.md"
  )
}

# in_place_arms <file>: prints each line holding an in-place publish arm.
in_place_arms() {
  grep -nE 'On any other branch|Any other branch \(in-place|[Aa]ny other branch.*in place|[Ii]n place.*[Aa]ny other branch|already on a non-default branch|ride the current branch|apply in place|the run commits in place' "$1" || true
}

# check_update_commands <root>
check_update_commands() {
  local root="$1" file failed=0
  [ "${#UPDATE_FILES[@]}" -eq 6 ] || { printf 'update: expected 6 files, read %s\n' "${#UPDATE_FILES[@]}"; return 1; }
  for file in "${UPDATE_FILES[@]}"; do
    [ -f "$root/$file" ] || { printf 'update: %s missing\n' "$file"; failed=1; continue; }
    if [ -n "$(in_place_arms "$root/$file")" ]; then
      printf 'update: %s keeps an in-place arm:\n%s\n' "$file" "$(in_place_arms "$root/$file")"
      failed=1
    fi
  done
  return "$failed"
}

# bats test_tags=whole-tree
@test "neither update command keeps an in-place arm" {
  run check_update_commands "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
