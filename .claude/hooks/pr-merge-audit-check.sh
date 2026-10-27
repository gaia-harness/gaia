#!/bin/bash
# PreToolUse Bash hook: BLOCK `gh pr merge` until every dispatched Code Audit
# Team member has cleared HEAD. AND-aggregator: resolves the diff's dispatched
# member set (.gaia/scripts/resolve-audit-members.sh) and requires each
# member's own clearance, one cleared member can no longer satisfy the gate
# while a co-dispatched member withholds.
#
# Zero-match (the whole diff is out of audit scope) or the resolver script
# being absent both fall through to the LEGACY single-signal gate: the marker/
# marker/status/bypass logic below, unchanged, evaluated for
# code-audit-frontend alone. A non-empty dispatched set instead runs the
# member-aware gate further down: code-audit-frontend by the same signals,
# each SPECIALIZED member <m> by its own marker
# .gaia/local/audit/<digest>.<m>.ok (the sole clearance signal for maintainer
# members, which are local-only with no commit-status equivalent).
#
# Markers are keyed to each member's own BRANCH-OWN DIGEST: a sha256 over the
# branch's own patch against the PR's base branch, restricted to the paths that
# member owns plus the shared gate machinery (folding in the in-scope-but-
# ownerless paths for the default member) and bound to the branch. The recipe
# lives in .claude/hooks/lib/audit-branch-patch.sh and audit-digest.sh. A marker
# attests that a member audited the branch's own change to the paths its digest
# covers: a path outside that set rotates no member's digest, so every existing
# marker keeps validating with zero re-dispatch; a change to the branch's own
# patch on a path a member owns rotates only that member's digest; one on a
# gate-machinery path rotates every member's digest. Content the base branch
# brought in through a clean catch-up merge is not part of the branch's patch
# and rotates nothing, bar a base edit within three lines of a branch hunk
# on a covered path.
#
# The base is the one GitHub reports, never a local ref: the gate reads the PR's
# base branch name from the PR record and that branch's current tip through
# `gh`, requires the tip locally and a unique merge base, and denies naming the
# one next step otherwise. It is derived only once a signal needs a digest, so a
# bypass PR makes no base lookup.
#
# code-audit-frontend / legacy-gate signals:
#
#   1. Local marker file at .gaia/local/audit/<frontend-digest>.ok, written by
#      the audit agent at the end of a clean local review.
#
#   2. GAIA-Audit GitHub commit status on HEAD with state: success, description
#      "<version> <frontend-digest> <tree>", when both version and digest
#      match (the tree field is data only, never compared). post-audit-status.sh
#      posts it off a member marker, which is what lets a clearance earned on
#      one machine satisfy this gate on another. A non-success status on the
#      same context and SHA is not a cleared signal even when its description
#      matches. Queried via `gh api` using GH_TOKEN or the ambient gh auth
#      session.
#
#   3. chore(deps) PR bypass: PR title matches `^chore\(deps(-dev)?\):` and the
#      PR's recorded file list is confined to a dependency manifest. The
#      /update-deps wrapper runs the full quality gate locally before
#      pushing, so the audit signal is implicit for this PR class, but only
#      for the manifest bump itself; a dep-bump PR carrying a migration edit
#      or a rebuilt bundle runs the normal gate.
#
#   4. Out-of-scope bypass (legacy gate only, a non-empty dispatched set means
#      an in-scope file exists so this never applies there): every file the PR
#      changes lives on a surface outside audit scope, wiki, instruction files
#      (.claude), .gaia metadata, prose docs, and root-level
#      markdown. Evaluated fail-closed: any in-scope path (frontend/app/, frontend/test/,
#      configs, .github/workflows/) makes the marker mandatory again. An
#      in-scope-but-ownerless path (a root Makefile, frontend/public/**) is folded into
#      the frontend member's digest input set, so a stale marker computed for a
#      prior digest never matches such a change either; this bypass and that
#      digest fold close the same band from two directions.
#
# Signals 1-3 prove an audit ran against this content (or that none is
# needed); signal 4 proves there is nothing in audit scope to review at all. A
# refusal artifact (.gaia/local/audit/<digest>[.<member>].refused) for a
# member's current digest is checked BEFORE any earned signal and is
# absolute: it denies regardless of a same-digest earned marker, for both
# code-audit-frontend and every specialized member.
#
# BYPASS STAMP. A pull request allowed through signal 3 or 4 has no member
# marker, so nothing else posts the GAIA-Audit status that branch protection
# waits on. On those allows, and only those, this gate posts it itself
# (.claude/hooks/lib/audit-bypass-stamp.sh) with the description
# `skipped: out of scope` or `skipped: chore(deps) manifest-only`, immediately
# before the allow. Signal 4 is evaluated on every legacy-gate run, ahead of
# the other signals, so a wiki-only pull request a still-valid marker would
# clear first gets its stamp too; a head that already carries a cleared
# GAIA-Audit status (signal 2) is left alone. Never on a deny, never for a pull
# request this gate did not itself classify as a bypass, and never when local
# HEAD is not the pull request's recorded head, since the status would then
# attest content nobody classified.
#
# FORK REFUSAL. A cross-repository pull request is denied outright, before any
# marker, digest, scope, or base-provenance check, and before anything the
# acting tree carries (its roster, its member resolver, its dependency
# predicate) is read or run: once a fork head is checked out, that tree is the
# fork's. When gh cannot say whether the pull request is a fork, the gate
# denies as well. .claude/hooks/lib/cross-repo-refusal.sh holds the check and
# the message.
#
# Without every dispatched member's clearance, the hook denies the gh pr merge
# call. To unblock:
#   1. Dispatch the audit-loop-unit agent on the current branch; it runs the
#      pending members (code-audit-frontend for the default member; the
#      specialized member named in the deny reason otherwise).
#   2. The unit addresses the findings, commits and pushes, and re-runs the
#      members on the new HEAD until each writes its marker.
#   3. Retry gh pr merge.
#
# See wiki/concepts/PR Merge Workflow.md for the full contract.

# -e is intentionally omitted: we must not abort before writing the deny JSON.
# All error-prone commands are individually guarded (|| true, 2>/dev/null).
set -uo pipefail

input=$(cat)

# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literal below satisfies, live in .claude/hooks/lib/jq-availability.sh.
# No errexit bracket around the source, unlike the armed hooks that run under
# `set -e`: this one deliberately does not, per the header above.
#
# This gate is the sharpest instance of the class: it denies `gh pr merge` until
# every dispatched audit member has cleared, so standing down on a missing
# interpreter cleared the merge silently.
#
# The literal is `gh`, read off this gate's own arming predicate
# (`gate_verb_fragment` below, `gh[[:space:]]+pr[[:space:]]+merge`): every call this
# gate binds invokes `gh`, so the ABSENCE of `gh` from the command proves the
# call sits outside the remit and it is allowed, exactly as a parsed non-merge
# is. Presence is not proof of membership -- an ordinary command carrying `gh`
# inside a word satisfies it too -- and that over-deny is the safe direction.
# What it cannot reach is a spelling the shell assembles (`g\h pr merge`), which
# the arm's own header already names as the accepted residual.
_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: pr-merge-audit-check.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the PR merge audit gate' "$input" tool_input 'gh'

# shellcheck source=lib/hook-payload.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/hook-payload.sh" ] && . "$_jq_library_directory/hook-payload.sh" 2>/dev/null
if ! type gaia_hook_payload_read >/dev/null 2>&1; then
  printf 'BLOCKED: pr-merge-audit-check.sh cannot load lib/hook-payload.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_hook_payload_read "$input" || exit 0

tool_name=$GAIA_HOOK_TOOL_NAME
[ "$tool_name" = "Bash" ] || exit 0

# Note: avoid naming this `command`, it would shadow bash's `command` builtin
# and make any later `command -v ...` calls in this script silently misbehave.
command_line=$GAIA_HOOK_COMMAND

# Arm the gate when this tool call carries a `gh pr merge`, through the shared
# arming decision (.claude/hooks/lib/verb-arming.sh): the same raw start/sep
# match this gate always paid, re-tested against a same-length view that masks
# a heredoc body proven to be data, plus the first-command tokenizer arm. See
# that library's own header for the full three-pass contract and what it does
# not close; residual 1 still applies at this site: a quoted string carrying a
# separator before the verb still arms the gate, fail-closed, with no safe
# narrowing.
#
# Loaded from this hook's OWN on-disk location, never cwd: the bats suites run
# this hook by absolute path from a sandbox cwd with no .claude/, so a
# cwd-relative source would miss the lib and flip the arming answer.
#
# This runs BEFORE arming, ahead of even knowing whether the tool call is a
# merge, so an unloadable library denies every Bash tool call here, not merge
# attempts alone, unlike the library deny further down which only ever denies
# a merge once armed.
_hook_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
_verb_arming_ok=0
if [ -n "$_hook_library_directory" ] && [ -f "$_hook_library_directory/verb-arming.sh" ]; then
  # shellcheck source=/dev/null
  if . "$_hook_library_directory/verb-arming.sh" && type gaia_verb_armed >/dev/null 2>&1; then
    _verb_arming_ok=1
  fi
fi
if [ "$_verb_arming_ok" -ne 1 ]; then
  jq -n --arg reason "PR merge gate: cannot load the shared verb-arming decision (.claude/hooks/lib/verb-arming.sh must exist, be readable, and define gaia_verb_armed). This check runs before the gate knows whether the tool call is a gh pr merge at all, so it denies every Bash tool call rather than merge attempts alone. Restore .claude/hooks/lib/verb-arming.sh (it ships with the framework; a missing or corrupted checkout is the usual cause) and retry." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

gate_verb_fragment='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if gaia_verb_armed "$gate_verb_fragment" 'gh pr merge' "$command_line"; then
  : # armed
else
  exit 0
fi

# Appended to every deny below. Only a start or first-command arm is the call's
# own invocation; a separator or opener arm is also what a merge cited inside a
# body or a commit message produces, so the deny must not claim one was run.
gate_arm_note=""
if [ "$GAIA_VERB_ARM_KIND" = sep ]; then
  gate_arm_note="

This gate armed on a \`gh pr merge\` that follows a separator or a substitution opener inside the command, not on the command's own first word, and it cannot tell a merge the shell runs from one only cited in text the command carries (a pull-request or issue body, a commit message). If this call runs no merge, pass that text from a file instead (\`--body-file\`, \`git commit -F\`), which the gate does not read; if it does run one, the steps above apply."
fi

# Repo-scope: this gate enforces the home repo's audit contract only. A
# `gh pr merge` aimed at a different repo (e.g. a sibling project merged via
# `cd ../other && gh pr merge` or `gh pr merge -R owner/other`) has no bearing
# on this repo's audit markers, allow it. Rooted at this hook's own on-disk
# location, reusing the value resolved for the arming load above, for exactly
# the reason the clearance load below states: a cwd-relative source misses the
# lib from any directory that has no `.claude/`, and the `type` check that
# follows reads that as a library the checkout does not carry.
[ -n "$_hook_library_directory" ] && [ -f "$_hook_library_directory/repo-scope.sh" ] && . "$_hook_library_directory/repo-scope.sh"
if type command_targets_foreign_repo >/dev/null 2>&1 \
   && command_targets_foreign_repo "$command_line"; then
  exit 0
fi

# Load the shared clearance reader from this hook's OWN on-disk location
# (never cwd, never $repo_root). The bats suites run this hook by absolute
# path from a sandbox cwd that has no .claude/, so a cwd-relative source would
# miss the lib and flip every clearance check. Loaded lazily here, after the
# early exits above, because this hook fires on every Bash tool call.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
if [ -n "$_library_directory" ] && [ -f "$_library_directory/audit-clearance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_library_directory/audit-clearance.sh"
fi

# Load the shared main-root resolver the same guarded way, from this hook's
# own on-disk location. Backs the main-anchored `root` derivation below.
_repository_root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
if [ -n "$_repository_root_directory" ] && [ -f "$_repository_root_directory/.gaia/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$_repository_root_directory/.gaia/scripts/main-root-lib.sh"
fi

# Load the shared ownership classifier + machinery list + branch-own patch
# library + digest engine + base provenance resolver from the same on-disk
# location, together with the fork check and the bypass stamp.
# check_out_of_scope_pr() below depends on the classifier to know what a changed
# path is and on the provenance resolver to know what base it is reading a
# change set against, and every marker check below is keyed to a member's
# branch-own digest computed by the digest engine over the patch library; an
# absent or unreadable module means this gate cannot know what it is gating, so
# it denies rather than fall through to a degraded, uninformed gate. This is a
# deliberate fail-closed path distinct from every other guard in this hook
# (which fail OPEN on an unusable lookup).
#
# repo-scope.sh and its three siblings joined this list when the command-binding
# predicate stopped being a bypass relaxation and became a conjunct on EVERY clearance permit.
# Its absence makes gate_command_names_the_record_pr return 1 above the scanner
# run, which used to mean only "this relaxation does not fire" and now means
# every permit denies. Left out of this guard the denial surfaces through the
# binding's own spelling arm, which blames the command's spelling and closes by
# recommending the exact bare merge that just denied: the real cause is never
# named and no respelling reaches it. Naming the file here is what turns that
# into the same one early, honest denial its siblings already give.
#
# The fork check is on this list because a missing one must not read as "not a
# fork", and the stamp because a bypass allow without it leaves the pull
# request waiting forever on a status nothing posts.
_audit_scope_library="$_library_directory/audit-scope.sh"
_machinery_library="$_library_directory/audit-machinery.sh"
_digest_library="$_library_directory/audit-digest.sh"
_branch_patch_library="$_library_directory/audit-branch-patch.sh"
_version_library="$_library_directory/gaia-version.sh"
_provenance_library="$_library_directory/audit-base-provenance.sh"
_repo_scope_library="$_library_directory/repo-scope.sh"
_repo_scope_segment_library="$_library_directory/repo-scope-segment.sh"
_repo_scope_scan_library="$_library_directory/repo-scope-scan.sh"
_repo_scope_home_library="$_library_directory/repo-scope-home.sh"
_cross_repo_library="$_library_directory/cross-repo-refusal.sh"
_bypass_stamp_library="$_library_directory/audit-bypass-stamp.sh"
if [ -z "$_library_directory" ] || [ ! -f "$_audit_scope_library" ] || [ ! -f "$_machinery_library" ] || [ ! -f "$_digest_library" ] || [ ! -f "$_branch_patch_library" ] || [ ! -f "$_version_library" ] || [ ! -f "$_provenance_library" ] || [ ! -f "$_repo_scope_library" ] || [ ! -f "$_repo_scope_segment_library" ] || [ ! -f "$_repo_scope_scan_library" ] || [ ! -f "$_repo_scope_home_library" ] || [ ! -f "$_cross_repo_library" ] || [ ! -f "$_bypass_stamp_library" ]; then
  jq -n --arg reason "PR merge gate: cannot load the ownership classifier, the digest engine, the branch-own patch library, the version normalizer, the base provenance resolver, the command scanner, the fork check, or the bypass stamp (.claude/hooks/lib/audit-scope.sh, .claude/hooks/lib/audit-machinery.sh, .claude/hooks/lib/audit-digest.sh, .claude/hooks/lib/audit-branch-patch.sh, .claude/hooks/lib/gaia-version.sh, .claude/hooks/lib/audit-base-provenance.sh, .claude/hooks/lib/repo-scope.sh, .claude/hooks/lib/repo-scope-segment.sh, .claude/hooks/lib/repo-scope-scan.sh, .claude/hooks/lib/repo-scope-home.sh, .claude/hooks/lib/cross-repo-refusal.sh, and .claude/hooks/lib/audit-bypass-stamp.sh must all exist and be readable). Every marker check below is keyed to a member's branch-own digest and to a version literal this gate compares for equality against the stamped one; this gate's out-of-scope bypass depends on the classifier to know what a changed path is, and on the provenance resolver to know what base its change set is read against; every permit this gate issues is bound to the pull request the merge names, which it reads through the command scanner; a fork pull request is refused through the fork check; and a bypass allow posts its GAIA-Audit status through the stamp. So it denies rather than guess. Restore every file named above (they ship with the framework; a missing or corrupted checkout is the usual cause) and retry.${gate_arm_note}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi
# shellcheck source=/dev/null
. "$_repo_scope_library"
# shellcheck source=/dev/null
. "$_machinery_library"
# shellcheck source=/dev/null
. "$_branch_patch_library"
# shellcheck source=/dev/null
. "$_digest_library"
# shellcheck source=/dev/null
. "$_version_library"
# shellcheck source=/dev/null
. "$_provenance_library"
# shellcheck source=/dev/null
. "$_cross_repo_library"
# shellcheck source=/dev/null
. "$_bypass_stamp_library"

# The gate's checks live in siblings beside this file, each one contiguous span
# of the gate with its own header, sourced below in their original order:
#   pr-merge-audit-check-context.sh   fork refusal, HEAD and roots, roster parse, deny and digest helpers
#   pr-merge-audit-check-signals.sh   code-audit-frontend clearance signals and the review base
#   pr-merge-audit-check-binding.sh   whether the merge names the pull request its clearance is for
#   pr-merge-audit-check-bypass.sh    out-of-scope bypass, legacy predicates, bypass stamp
#   pr-merge-audit-check-dispatch.sh  member-set dispatch and the AND-aggregator
# None of them degrades: a gate missing one would decide a merge without the
# check it holds, and a bare exit (127, or 0 off the end of a cut-short file)
# reads as an allow. So every sibling must exist before any of them runs, each
# must define its last function once sourced (bash 3.2 can stop part way
# through a file it cannot parse and carry on), and the dispatch sibling, which
# exits on every path, must never return here. Each failure denies.
_gate_sibling_deny() {
  jq -n --arg reason "PR merge gate: cannot load the gate sibling $1, so it denies rather than decide a merge without the checks that file holds. Restore it (the siblings of .claude/hooks/pr-merge-audit-check.sh ship with the framework; a missing or corrupted checkout is the usual cause) and retry.${gate_arm_note}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}
_gate_sibling_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _gate_sibling_directory=''
_gate_sibling_spans='
  context:marker_state
  signals:gate_resolve_base
  binding:gate_empty_is_decisive
  bypass:gate_post_bypass_stamp
  dispatch:
'
for _gate_sibling_span in $_gate_sibling_spans; do
  _gate_sibling_file="${_gate_sibling_directory}/pr-merge-audit-check-${_gate_sibling_span%%:*}.sh"
  if [ -z "$_gate_sibling_directory" ] || [ ! -f "$_gate_sibling_file" ]; then
    _gate_sibling_deny "'$_gate_sibling_file': it is missing"
  fi
done
for _gate_sibling_span in $_gate_sibling_spans; do
  _gate_sibling_file="${_gate_sibling_directory}/pr-merge-audit-check-${_gate_sibling_span%%:*}.sh"
  # shellcheck source=/dev/null
  . "$_gate_sibling_file"
  _gate_sibling_last_function="${_gate_sibling_span#*:}"
  if [ -n "$_gate_sibling_last_function" ] && ! command -v "$_gate_sibling_last_function" >/dev/null 2>&1; then
    _gate_sibling_deny "'$_gate_sibling_file': it did not define $_gate_sibling_last_function"
  fi
done
_gate_sibling_deny "'$_gate_sibling_file': it returned without deciding the merge"
