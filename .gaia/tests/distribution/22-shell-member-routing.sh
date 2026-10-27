#!/usr/bin/env bash
# 22-shell-member-routing.sh
#
# Proves the adopter shell member routes correctly on the release-scrubbed
# ADOPTER shape, where the maintainer members are stripped. The staged bundle
# becomes a git repository with a bare origin, so the staged
# resolve-audit-members.sh and audit-resolve-scope.sh resolve a base; every
# case runs on its own branch cut from main.
#
# Assertions, in order:
#   1. An adopter-authored shell script and bats suite changed on an ordinary
#      branch dispatch the shell member, and the member's membership list
#      holds both paths.
#   2. A release-applying branch (VERSION bumped) that edits an owned
#      .gaia/scripts file, an owned hook and an owned .github/audit script,
#      adds a script only the head manifest lists, and deletes a script only
#      the base manifest lists, dispatches no shell member. Each changed
#      path's owner equals the owner it gets from the staged roster with the
#      shell entry removed, and is never the shell member. A control branch
#      without the VERSION bump that adds .gaia/scripts/my-tool.sh gives that
#      path to the shell member.
#   3. A new hook and an adopter-authored composite-action script on an
#      ordinary branch are owned by the shell member, the action script not
#      by the frontend member.
#   4. A release branch that changes an adopter script and an owned
#      .gaia/scripts file dispatches the shell member, and its review lists
#      (membership and review scope) hold only the adopter script.
#   5. Hand-editing an owned hook on an ordinary branch dispatches the shell
#      member; the same edit on a branch that also bumps VERSION does not.
#   2b. Guard can fail (run on the assertion 2 branch): with the release skip disabled in a scratch roster
#      copy, the release branch of assertion 2 owns the owned paths again,
#      so the owner comparison is not vacuous.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_command jq "jq required for manifest edits"
require_command rsync "rsync required for staging build"

REPOSITORY="$(mktemp -d -t gaia-dist-shell-routing-XXXXXX)"
ORIGIN="$(mktemp -d -t gaia-dist-shell-routing-origin-XXXXXX)"
SCRATCH="$(mktemp -d -t gaia-dist-shell-routing-scratch-XXXXXX)"
trap 'rm -rf "$REPOSITORY" "$ORIGIN" "$SCRATCH"' EXIT

"$HERE/lib/build-staging.sh" "$REPOSITORY" \
  || { fail "build-staging failed"; exit 1; }

MANIFEST=".gaia/manifest.json"

# pick_owned PATTERN EXCLUDE: first owned manifest path matching the anchored
# extended-regex PATTERN and not the EXCLUDE one, chosen by class so no file
# name is hard-coded.
pick_owned() {
  jq -r '.files | to_entries[] | select(.value == "owned") | .key' "$REPOSITORY/$MANIFEST" \
    | grep -E "$1" | grep -vE "$2" | sort | head -n 1
}

# Files the resolver itself runs from, or that the dispatch machinery reads,
# are never edited or deleted so the edits cannot disturb the run.
MACHINERY='audit|resolve|scope|roster|manifest|provision'
OWNED_SCRIPT="$(pick_owned '^\.gaia/scripts/[^/]+\.sh$' "$MACHINERY")"
OWNED_HOOK="$(pick_owned '^\.claude/hooks/[^/]+\.sh$' "$MACHINERY")"
DELETED_SCRIPT="$(pick_owned '^\.gaia/scripts/[^/]+\.sh$' "$MACHINERY|$(basename "${OWNED_SCRIPT:-none}")")"
OWNED_AUDIT_SCRIPT="$(pick_owned '^\.github/audit/[^/]+\.sh$' 'zzz-no-exclusion')"
for picked in "$OWNED_SCRIPT" "$OWNED_HOOK" "$DELETED_SCRIPT" "$OWNED_AUDIT_SCRIPT"; do
  [ -n "$picked" ] || { fail "the staged manifest lacks an owned shell file of an expected class"; exit 1; }
done

git init -q -b main "$REPOSITORY" || { fail "git init failed"; exit 1; }
git -C "$REPOSITORY" config user.email "test@example.com"
git -C "$REPOSITORY" config user.name "Distribution Test"
git -C "$REPOSITORY" config commit.gpgsign false
git init -q --bare -b main "$ORIGIN" || { fail "bare origin init failed"; exit 1; }
git -C "$REPOSITORY" remote add origin "$ORIGIN"

mkdir -p "$REPOSITORY/scripts" "$REPOSITORY/tests"
printf '#!/usr/bin/env bash\necho deploy\n' > "$REPOSITORY/scripts/deploy.sh"
printf '#!/usr/bin/env bats\n@test "deploys" {\n  [ 1 -eq 1 ]\n}\n' > "$REPOSITORY/tests/deploy.bats"
git -C "$REPOSITORY" add -A >/dev/null
git -C "$REPOSITORY" commit -q -m "baseline" || { fail "baseline commit failed"; exit 1; }
git -C "$REPOSITORY" push -q origin main || { fail "push to origin failed"; exit 1; }
git -C "$REPOSITORY" remote set-head origin main >/dev/null 2>&1 \
  || git -C "$REPOSITORY" fetch -q origin

RESOLVE_MEMBERS="$REPOSITORY/.gaia/scripts/resolve-audit-members.sh"
RESOLVE_SCOPE="$REPOSITORY/.gaia/scripts/audit-resolve-scope.sh"
CLASSIFIER="$REPOSITORY/.claude/hooks/lib/audit-scope.sh"
ROSTER="$REPOSITORY/.gaia/audit-ci.yml"

start_branch() {
  git -C "$REPOSITORY" checkout -q main
  git -C "$REPOSITORY" checkout -q -b "$1"
}

commit_all() {
  git -C "$REPOSITORY" add -A >/dev/null
  git -C "$REPOSITORY" commit -q -m "$1"
}

append_line() {
  printf '# changed on branch\n' >> "$REPOSITORY/$1"
}

bump_version() {
  printf '2.99.0\n' > "$REPOSITORY/.gaia/VERSION"
}

dispatched_members() {
  bash "$RESOLVE_MEMBERS" --root "$REPOSITORY"
}

# scope_lines MEMBER KEY: the values the staged scope resolver prints for KEY.
scope_lines() {
  bash "$RESOLVE_SCOPE" --member "$1" --root "$REPOSITORY" 2>/dev/null \
    | awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print }'
}

# owners ROSTER_FILE ARM_BASE: reads paths on stdin, prints "<path>\t<owner|->"
# through the staged classifier, with the release context armed against
# ARM_BASE when it is non-empty.
owners() {
  (
    # shellcheck source=/dev/null
    . "$CLASSIFIER"
    audit_scope_init "$REPOSITORY" "$1" 2>/dev/null
    [ -z "$2" ] || audit_scope_release_context "$REPOSITORY" "$2"
    audit_owners_for_paths
  )
}

owner_of() {
  awk -F'\t' -v wanted="$2" '$1 == wanted { print $2 }' <<<"$1"
}

# Roster copy with the shell member's entry removed.
ROSTER_WITHOUT_SHELL="$SCRATCH/roster-without-shell.yml"
awk '
  /^  - name: code-audit-shell$/ { skipping = 1; next }
  skipping && /^    / { next }
  { skipping = 0; print }
' "$ROSTER" > "$ROSTER_WITHOUT_SHELL"
if grep -q 'code-audit-shell' "$ROSTER_WITHOUT_SHELL"; then
  fail "could not remove the shell entry from the roster copy"; exit 1
fi

# Roster copy with the release skip key disabled (assertion 6).
ROSTER_SKIP_DISABLED="$SCRATCH/roster-skip-disabled.yml"
sed 's/^    skip_gaia_release_changes: true$/    skip_gaia_release_changes: false/' "$ROSTER" > "$ROSTER_SKIP_DISABLED"
cmp -s "$ROSTER" "$ROSTER_SKIP_DISABLED" && { fail "roster copy with the skip disabled is identical to the roster"; exit 1; }

# --- Assertion 1: adopter shell and bats dispatch the shell member -----------
start_branch adopter-shell
append_line scripts/deploy.sh
append_line tests/deploy.bats
commit_all "edit adopter shell"
members="$(dispatched_members)"
grep -qxF code-audit-shell <<<"$members" \
  || { fail "adopter scripts/deploy.sh and tests/deploy.bats did not dispatch code-audit-shell (got: $members)"; exit 1; }
membership="$(scope_lines code-audit-shell FULL_CHANGED)"
for expected in scripts/deploy.sh tests/deploy.bats; do
  grep -qxF "$expected" <<<"$membership" \
    || { fail "FULL_CHANGED for code-audit-shell lacks $expected (got: $membership)"; exit 1; }
done

# --- Assertion 2: a release branch drops the owned paths ---------------------
start_branch release-applying
bump_version
append_line "$OWNED_SCRIPT"
append_line "$OWNED_HOOK"
append_line "$OWNED_AUDIT_SCRIPT"
printf '#!/usr/bin/env bash\n' > "$REPOSITORY/.gaia/scripts/new-gaia-tool.sh"
git -C "$REPOSITORY" rm -q "$DELETED_SCRIPT"
jq '.files[".gaia/scripts/new-gaia-tool.sh"] = "owned" | del(.files[$deleted])' --arg deleted "$DELETED_SCRIPT" \
  "$REPOSITORY/$MANIFEST" > "$SCRATCH/head-manifest.json"
cp "$SCRATCH/head-manifest.json" "$REPOSITORY/$MANIFEST"
commit_all "apply a release"
members="$(dispatched_members)"
if grep -qxF code-audit-shell <<<"$members"; then
  fail "release-applying branch dispatched code-audit-shell (got: $members)"; exit 1
fi
base_commit="$(git -C "$REPOSITORY" rev-parse origin/main)"
release_paths="$OWNED_SCRIPT
$OWNED_HOOK
$OWNED_AUDIT_SCRIPT
.gaia/scripts/new-gaia-tool.sh
$DELETED_SCRIPT"
armed_owners="$(printf '%s\n' "$release_paths" | owners "$ROSTER" "$base_commit")"
reference_owners="$(printf '%s\n' "$release_paths" | owners "$ROSTER_WITHOUT_SHELL" "")"
while IFS= read -r changed_path; do
  armed_owner="$(owner_of "$armed_owners" "$changed_path")"
  reference_owner="$(owner_of "$reference_owners" "$changed_path")"
  if [ "$armed_owner" = "code-audit-shell" ]; then
    fail "release branch path $changed_path is still owned by code-audit-shell"; exit 1
  fi
  if [ "$armed_owner" != "$reference_owner" ]; then
    fail "release branch path $changed_path owner '$armed_owner' differs from the shell-less roster owner '$reference_owner'"; exit 1
  fi
done <<<"$release_paths"

# --- Assertion 2b (on the same branch): the comparison can fail ----
disabled_owners="$(printf '%s\n' "$release_paths" | owners "$ROSTER_SKIP_DISABLED" "$base_commit")"
if [ "$(owner_of "$disabled_owners" "$OWNED_HOOK")" != "code-audit-shell" ]; then
  fail "guard-can-fail: with the release skip disabled the owned hook is not owned by code-audit-shell, so the owner comparison above proves nothing"; exit 1
fi

# Control: no VERSION bump, a new .gaia/scripts file belongs to the shell member.
start_branch ordinary-control
printf '#!/usr/bin/env bash\n' > "$REPOSITORY/.gaia/scripts/my-tool.sh"
commit_all "add an adopter tool under .gaia/scripts"
members="$(dispatched_members)"
grep -qxF code-audit-shell <<<"$members" \
  || { fail "control branch adding .gaia/scripts/my-tool.sh did not dispatch code-audit-shell (got: $members)"; exit 1; }
control_owner="$(owner_of "$(printf '.gaia/scripts/my-tool.sh\n' | owners "$ROSTER" "$(git -C "$REPOSITORY" rev-parse origin/main)")" ".gaia/scripts/my-tool.sh")"
[ "$control_owner" = "code-audit-shell" ] \
  || { fail "control path .gaia/scripts/my-tool.sh owner is '$control_owner', expected code-audit-shell"; exit 1; }

# --- Assertion 3: new hook and composite-action script ----------------------
start_branch new-hook-and-action
mkdir -p "$REPOSITORY/.github/actions/setup"
printf '#!/usr/bin/env bash\n' > "$REPOSITORY/.claude/hooks/my-guard.sh"
printf '#!/usr/bin/env bash\n' > "$REPOSITORY/.github/actions/setup/run.sh"
commit_all "add a hook and a composite-action script"
members="$(dispatched_members)"
grep -qxF code-audit-shell <<<"$members" \
  || { fail "a new hook and action script did not dispatch code-audit-shell (got: $members)"; exit 1; }
hook_action_owners="$(printf '%s\n' ".claude/hooks/my-guard.sh" ".github/actions/setup/run.sh" | owners "$ROSTER" "$(git -C "$REPOSITORY" rev-parse origin/main)")"
for adopter_path in .claude/hooks/my-guard.sh .github/actions/setup/run.sh; do
  [ "$(owner_of "$hook_action_owners" "$adopter_path")" = "code-audit-shell" ] \
    || { fail "$adopter_path owner is '$(owner_of "$hook_action_owners" "$adopter_path")', expected code-audit-shell"; exit 1; }
done

# --- Assertion 4: mixed release branch lists only the adopter script --------
start_branch release-mixed
bump_version
append_line scripts/deploy.sh
append_line "$OWNED_SCRIPT"
commit_all "release plus adopter edit"
members="$(dispatched_members)"
grep -qxF code-audit-shell <<<"$members" \
  || { fail "mixed release branch did not dispatch code-audit-shell (got: $members)"; exit 1; }
for list_key in FULL_CHANGED CHANGED; do
  listed="$(scope_lines code-audit-shell "$list_key")"
  [ "$listed" = "scripts/deploy.sh" ] \
    || { fail "$list_key for code-audit-shell on the mixed release branch is '$listed', expected only scripts/deploy.sh"; exit 1; }
done

# --- Assertion 5: hand-editing an owned hook ---------------------------------
start_branch hand-edit-hook
append_line "$OWNED_HOOK"
commit_all "hand-edit an owned hook"
members="$(dispatched_members)"
grep -qxF code-audit-shell <<<"$members" \
  || { fail "hand-editing $OWNED_HOOK on an ordinary branch did not dispatch code-audit-shell (got: $members)"; exit 1; }
start_branch hand-edit-hook-release
bump_version
append_line "$OWNED_HOOK"
commit_all "the same edit on a release branch"
members="$(dispatched_members)"
if grep -qxF code-audit-shell <<<"$members"; then
  fail "the same hook edit on a VERSION-bumping branch dispatched code-audit-shell (got: $members)"; exit 1
fi

pass "shell member routing holds on the staged adopter bundle, release skip included"
