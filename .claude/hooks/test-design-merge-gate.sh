#!/usr/bin/env bash
# PreToolUse Bash hook: DENY `gh pr merge` while an approved security row of the
# branch's test-design table is missing from the current table, has lost its
# flag, has no matching test on the branch, or has a matching test whose latest
# worthiness-ledger verdict is `fix` (hollow), unless the maintainer typed a
# grant naming that row (test-row-grant.sh records it). Whether the tests pass
# is CI's job; this gate checks only that each approved security row is still
# planned, still flagged, and still has a security-writer-authored test that is
# not hollow.
#
# The branch's table is found through its plan run's RUNNING sentinel
# (.gaia/scripts/test-design/plan-locate-lib.sh, which also holds the check, so
# post-audit-status.sh declines its success post on the same answer and a
# GitHub auto-merge cannot complete around this hook). No plan run, or a plan
# with no TEST-DESIGN marker, allows: an older plan has no approved security
# rows.
#
# Fail-closed, unlike worthiness-presence-check.sh beside it: this is the one
# backstop no fixer or evaluator can route around, so every error path denies
# with its reason and the next step. That covers an unloadable library, an
# unresolvable checkout or branch key, a missing node or test-drift-check.sh,
# two plan runs claiming the branch, a missing or unreadable table, and an
# approved copy that does not match the marker's hash. The one allow outside the
# check is a merge aimed at another repository (`-R`, or a leading `cd` into
# one), which has no bearing on this repository's plan runs.
#
# Honest limit: the branch is the checkout's, not the pull request's. A
# `gh pr merge <n>` run from the default branch's checkout finds no plan run
# and allows; the status post's check is what holds that path.

# -e is intentionally omitted: we must not abort before writing the deny JSON.
set -uo pipefail

input=$(cat)

# jq-availability arm. The literal is `gh`, read off this gate's own arming
# predicate below: every call it binds invokes `gh`. Contract:
# .claude/hooks/lib/jq-availability.sh.
_hook_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _hook_library_directory=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_hook_library_directory" ] && [ -f "$_hook_library_directory/jq-availability.sh" ] && . "$_hook_library_directory/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: test-design-merge-gate.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the security-row merge gate' "$input" tool_input 'gh'

# shellcheck source=lib/hook-payload.sh
[ -f "$_hook_library_directory/hook-payload.sh" ] && . "$_hook_library_directory/hook-payload.sh" 2>/dev/null
if ! type gaia_hook_payload_read >/dev/null 2>&1; then
  printf 'BLOCKED: test-design-merge-gate.sh cannot load lib/hook-payload.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_hook_payload_read "$input" || exit 0
[ "$GAIA_HOOK_TOOL_NAME" = "Bash" ] || exit 0
command=$GAIA_HOOK_COMMAND

deny_with_reason() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# The arming decision runs before the gate knows whether this is a merge, so an
# unloadable library denies every Bash call rather than merges alone.
_verb_arming_ok=0
if [ -f "$_hook_library_directory/verb-arming.sh" ]; then
  # shellcheck source=/dev/null
  if . "$_hook_library_directory/verb-arming.sh" && type gaia_verb_armed >/dev/null 2>&1; then
    _verb_arming_ok=1
  fi
fi
if [ "$_verb_arming_ok" -ne 1 ]; then
  deny_with_reason "Security-row merge gate: cannot load the shared verb-arming decision (.claude/hooks/lib/verb-arming.sh), so it denies every Bash tool call rather than merge attempts alone. Next step: restore .claude/hooks/lib/verb-arming.sh from the GAIA release and retry."
fi
gaia_verb_armed 'gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' 'gh pr merge' "$command" || exit 0

# A merge aimed at another repository allows. An unloadable repo-scope library
# leaves the merge enforced.
# shellcheck source=/dev/null
[ -f "$_hook_library_directory/repo-scope.sh" ] && . "$_hook_library_directory/repo-scope.sh"
if type command_targets_foreign_repo >/dev/null 2>&1 && command_targets_foreign_repo "$command"; then
  exit 0
fi

# Rooted at this hook's own location, never the process cwd, so a `cd` cannot
# move the gate onto libraries that are not there and turn every merge into a
# deny for the wrong reason, or onto a tree without the gate.
_gaia_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _gaia_root=''
plan_locate_library="$_gaia_root/.gaia/scripts/test-design/plan-locate-lib.sh"
# shellcheck source=/dev/null
[ -n "$_gaia_root" ] && [ -f "$plan_locate_library" ] && . "$plan_locate_library" 2>/dev/null
if ! type gaia_test_design_merge_verdict >/dev/null 2>&1 || ! type gaia_resolve_tree_root >/dev/null 2>&1; then
  deny_with_reason "Security-row merge gate: cannot load .gaia/scripts/test-design/plan-locate-lib.sh (or the main-root-lib.sh it loads), so the branch's approved security rows cannot be checked. Next step: restore the GAIA scripts from the release and retry."
fi

# The tree the merge acts on: a leading `cd <checkout> &&` in the command
# first, then the payload cwd, then this process's cwd only when the payload
# names nothing usable (payload cwd is measured, not contracted).
tree_root=""
if [[ "$GAIA_HOOK_CWD" == /* ]]; then
  tree_root="$(gaia_resolve_tree_root "$GAIA_HOOK_CWD" 2>/dev/null)" || tree_root=""
fi
if [ -n "${GAIA_REPO_SCOPE_LEAD_CD:-}" ] && candidate_root="$(gaia_resolve_tree_root "$GAIA_REPO_SCOPE_LEAD_CD" 2>/dev/null)"; then
  tree_root="$candidate_root"
fi
if [ -z "$tree_root" ]; then
  tree_root="$(gaia_resolve_tree_root "$PWD" 2>/dev/null)" ||
    deny_with_reason "Security-row merge gate: $PWD is not inside a git checkout, so the branch being merged is unknown. Next step: run gh pr merge from the checkout that holds the pull request branch."
fi

verdict_status=0
verdict="$(gaia_test_design_merge_verdict "$tree_root")" || verdict_status=$?
[ "$verdict_status" -eq 0 ] && exit 0
[ -n "$verdict" ] || verdict="Security-row merge gate: the check failed without a reason (exit $verdict_status). Next step: run bash .gaia/scripts/test-drift-check.sh security --root <checkout> --plan-dir <plan folder> and read its output."
deny_with_reason "$verdict"
