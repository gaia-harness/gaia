#!/usr/bin/env bats
# Tests for the Code Audit Team roster arm of .githooks/pre-commit: a staged
# roster, member definition or machinery list runs
# .gaia/scripts/verify-audit-roster.sh, and a failing check refuses the commit.
#
# Each test commits through the real hook in a sandbox copy of the tracked tree,
# so the arm is exercised with every other arm of the hook around it.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup_file() {
  local this_directory repository_root
  this_directory="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  repository_root="$(cd "$this_directory/../../.." && pwd)"
  export BASE_SANDBOX="$BATS_FILE_TMPDIR/base"
  mkdir -p "$BASE_SANDBOX"
  git -C "$repository_root" ls-files -z | rsync -a --from0 --files-from=- "$repository_root/" "$BASE_SANDBOX/"
  git -C "$BASE_SANDBOX" init -q
  git -C "$BASE_SANDBOX" config user.email test@example.invalid
  git -C "$BASE_SANDBOX" config user.name test
  git -C "$BASE_SANDBOX" add -A
  git -C "$BASE_SANDBOX" -c core.hooksPath=/dev/null commit -qm "chore: base"
  # The commit-msg hook fails closed when commitlint cannot run, and the sandbox
  # has no node_modules, so a runner without a global commitlint would refuse
  # every commit before the arm under test is reached.
  rm -f "$BASE_SANDBOX/.githooks/commit-msg"
}

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  cp -R "$BASE_SANDBOX" "$SANDBOX"
  git -C "$SANDBOX" checkout -qb roster-arm
}

commit_through_hook() {
  run git -C "$SANDBOX" -c core.hooksPath=.githooks commit -qm "chore: roster arm"
}

@test "a staged roster edit that keeps the roster valid runs the check and commits" {
  printf '# a reviewed comment\n' >> "$SANDBOX/.gaia/audit-ci.yml"
  git -C "$SANDBOX" add .gaia/audit-ci.yml
  commit_through_hook
  [ "$status" -eq 0 ]
  grep -qF "roster clean" <<<"$output"
}

@test "a staged roster edit that breaks an invariant refuses the commit and names the finding" {
  sed -e 's/name: code-audit-github-workflows/name: workflows-reviewer/' "$SANDBOX/.gaia/audit-ci.yml" > "$SANDBOX/roster.tmp"
  mv "$SANDBOX/roster.tmp" "$SANDBOX/.gaia/audit-ci.yml"
  git -C "$SANDBOX" add .gaia/audit-ci.yml
  commit_through_hook
  [ "$status" -ne 0 ]
  grep -qF "member-name-prefix" <<<"$output"
  grep -qF "roster check failed" <<<"$output"
}

@test "a staged member definition whose remit drifted refuses the commit with the repair" {
  local definition="$SANDBOX/.claude/agents/code-audit-github-workflows.md"
  awk '
    $0 == "<!-- gaia:audit-remit:start -->" { in_region = 1; print; next }
    $0 == "<!-- gaia:audit-remit:end -->" { in_region = 0 }
    in_region && /^- `/ && !dropped { dropped = 1; next }
    { print }
  ' "$definition" > "$SANDBOX/definition.tmp"
  mv "$SANDBOX/definition.tmp" "$definition"
  git -C "$SANDBOX" add .claude/agents/code-audit-github-workflows.md
  commit_through_hook
  [ "$status" -ne 0 ]
  grep -qF "remit-glob-missing" <<<"$output"
  grep -qF "bash .gaia/scripts/write-audit-remits.sh" <<<"$output"
}

@test "a broken roster left unstaged does not run the check for an unrelated commit" {
  sed -e 's/name: code-audit-github-workflows/name: workflows-reviewer/' "$SANDBOX/.gaia/audit-ci.yml" > "$SANDBOX/roster.tmp"
  mv "$SANDBOX/roster.tmp" "$SANDBOX/.gaia/audit-ci.yml"
  printf 'unrelated\n' > "$SANDBOX/notes.txt"
  git -C "$SANDBOX" add notes.txt
  commit_through_hook
  [ "$status" -eq 0 ]
  grep -qF "verify-audit-roster" <<<"$output" && return 1
  true
}
