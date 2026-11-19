#!/usr/bin/env bats
# audit-shell-member.bats: the adopter shell member's roster entry, its routing
# against the maintainer shell member, and its settings lens.
#
# Routing is first-match, so the adopter entry sits after the maintainer-only
# block: this repository's own shell stays on the maintainer member, and an
# adopter clone (block stripped) routes the same paths to the adopter member.
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCOPE_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  ROSTER="${SHELL_MEMBER_ROSTER:-$REPO_ROOT/.gaia/audit-ci.yml}"
  DEFINITION="${SHELL_MEMBER_DEFINITION:-$REPO_ROOT/.claude/agents/code-audit-shell.md}"
}

# owner_of <roster> <path>: the member the classifier assigns the path.
owner_of() {
  bash -c '
    . "$1" || exit 9
    audit_scope_init "$2" "$3" || exit 9
    printf "%s\n" "$4" | audit_owners_for_paths | cut -f2
  ' _ "$SCOPE_LIBRARY" "$REPO_ROOT" "$1" "$2"
}

# adopter_roster: prints the path of the roster with the maintainer-only block
# stripped, as an adopter clone carries it.
adopter_roster() {
  awk '
    index($0, "# gaia:maintainer-only:start") { inside = 1; next }
    index($0, "# gaia:maintainer-only:end") { inside = 0; next }
    !inside { print }
  ' "$ROSTER" > "$BATS_TEST_TMPDIR/adopter.yml"
  printf '%s\n' "$BATS_TEST_TMPDIR/adopter.yml"
}

@test "shell routes to the right member: the maintainer member in this repository, the adopter member in an adopter clone" {
  local adopter row roster roster_file path expected owner
  adopter="$(adopter_roster)"
  local rows=(
    "own|code-audit-maintainer-shell|.gaia/tests/verify-harness.sh"
    "own|code-audit-maintainer-shell|.gaia/scripts/tests/audit-scope-lib.bats"
    "own|code-audit-maintainer-shell|.claude/hooks/audit-loop-bound.sh"
    "own|code-audit-maintainer-shell|.githooks/pre-commit"
    "own|code-audit-maintainer-shell|.claude/hooks/lib/audit-member-protocol.md"
    "own|code-audit-maintainer-shell|.github/actions/x/run.sh"
    "adopter|code-audit-shell|scripts/build.sh"
    "adopter|code-audit-shell|tests/shell/a.bats"
    "adopter|code-audit-shell|.claude/hooks/x.sh"
    "adopter|code-audit-shell|.githooks/pre-commit"
    "adopter|code-audit-shell|.github/actions/x/run.sh"
    "adopter|code-audit-shell|apps/web/app/x.sh"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r roster expected path <<<"$row"
    roster_file="$ROSTER"
    if [ "$roster" = adopter ]; then roster_file="$adopter"; fi
    owner="$(owner_of "$roster_file" "$path")"
    [ "$owner" = "$expected" ] || { echo "$path -> $owner" >&2; return 1; }
  done
}

@test "the frontend member claims no composite-action script in either list" {
  local frontend
  frontend="$(awk '/^  - name: code-audit-frontend$/ { inside = 1; next } inside && /^  - name:/ { exit } inside { print }' "$ROSTER")"
  [ -n "$frontend" ]
  grep -qF '.github/actions/**/*.sh' <<<"$frontend" && return 1
  true
}

@test "the shell entry carries the release-skip key and the hook, git hook and bats hard-full globs" {
  local entry
  entry="$(awk '/^  - name: code-audit-shell$/ { inside = 1; print; next } inside && /^  - name:/ { exit } inside && /^[a-z]/ { exit } inside { print }' "$ROSTER")"
  [ -n "$entry" ]
  grep -qx '    skip_gaia_release_changes: true' <<<"$entry" || return 1
  grep -qx '    audience: adopter' <<<"$entry" || return 1
  grep -qF '".githooks/**"' <<<"$entry" || return 1
  grep -qF '"**/*.bats"' <<<"$entry" || return 1
}

@test "the shell entry claims the Claude settings file and leaves it off the hard-full list" {
  local entry globs_block hard_full_block
  entry="$(awk '/^  - name: code-audit-shell$/ { inside = 1; print; next } inside && /^  - name:/ { exit } inside && /^[a-z]/ { exit } inside { print }' "$ROSTER")"
  [ -n "$entry" ]
  globs_block="$(awk '/^    globs:$/ { inside = 1; next } inside && /^    [a-z_]+:/ { exit } inside { print }' <<<"$entry")"
  hard_full_block="$(awk '/^    light_hard_full:$/ { inside = 1; next } inside && /^    [a-z_]+:/ { exit } inside { print }' <<<"$entry")"
  [ -n "$globs_block" ]
  [ -n "$hard_full_block" ]
  grep -qF '".claude/settings.json"' <<<"$globs_block" || return 1
  grep -qF '".claude/settings.json"' <<<"$hard_full_block" && return 1
  true
}

# settings_lens_complete FILE: succeeds when FILE carries the settings lens,
# wired into its Contents line and methodology, with the review requirements.
settings_lens_complete() {
  local file="$1" section topic
  grep -qE '^## Conditional settings lens' "$file" || return 1
  grep -qxF 'This lens activates only for `.claude/settings.json`.' "$file" || return 1
  grep -E '^Contents:' "$file" | grep -qF 'Conditional settings lens' || return 1
  grep -E '^[0-9]+\. ' "$file" | grep 'settings lens' | grep -qF '.claude/settings.json' || return 1
  section="$(awk '/^## Conditional settings lens/ { inside = 1; next } inside && /^## / { exit } inside { print }' "$file")"
  [ -n "$section" ] || return 1
  for topic in 'removes' 'weakens' 're-scopes' 'permissions.deny' 'permissions.ask' 'permissions.allow' 'hook registration' 'found none'; do
    grep -qF -- "$topic" <<<"$section" || return 1
  done
  return 0
}

# bats test_tags=protected
@test "the definition carries the settings lens, its activation sentence, Contents entry and methodology step" {
  settings_lens_complete "$DEFINITION"
}
