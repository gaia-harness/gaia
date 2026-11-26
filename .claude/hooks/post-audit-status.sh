#!/usr/bin/env bash
# post-audit-status.sh, post the GAIA-Audit commit status on HEAD.
#
# Purpose
#   Two callers, on the local (Claude-driven merge) path, neither of them a
#   Code Audit Team member's own agent: a clean pass no longer posts its own
#   success here (see wiki/concepts/PR Merge Workflow.md, "Posting the status
#   last"). The orchestrating session calls this, once, after every dispatched
#   member holds an earned marker for the current tree and every finding from
#   every round is fixed or recorded, passing any one current member's own
#   marker path. Posts a GAIA-Audit commit status of state=success on HEAD, but
#   only once EVERY member dispatched against HEAD's diff has cleared, so the
#   server-side required-check gate is satisfied, letting the github.com
#   button and the required-check verification clear. The passed marker file is a literal precondition
#   for the call; the member-aware gate (lib/post-audit-status-gates.sh) is
#   the precondition for the POST itself.
#
#   The second caller is the shared clearance writer itself
#   (.gaia/scripts/audit-write-clearance.sh), which makes this call the moment
#   it records a REFUSAL, on the local path, with no orchestrator step needed.
#   Handed a REFUSAL it posts state=failure and skips the member-aware gate.
#   That arm is what gives refusal precedence a server-side signal: the local
#   merge hook honors a refusal over any same-digest earned marker, but
#   GitHub's auto-merge merges on the required status alone and never runs that
#   hook, so without a compensating post a refusal written after a success
#   status already landed for this head (the orchestrator's own earlier post)
#   leaves that success standing. The writer making this call itself
#   is what makes the signal a mechanism rather than a step anyone has to
#   remember.
#
#   Honest limit: the pushed-head guards (lib/post-audit-status-gates.sh)
#   apply to both states, so a refusal written against work that is not what the pull request head carries
#   declines rather than posting. That is the fail-safe direction (the local
#   gate still denies the merge, and an un-audited pushed head carries no
#   success to retract), and it keeps this hook from ever posting about content
#   the caller did not audit.
#
# Invocation
#   .claude/hooks/post-audit-status.sh <marker-path>
#
#   <marker-path>  A clearance artifact on disk for the current tree
#                  (.gaia/local/audit/<digest>.ok for code-audit-frontend,
#                  .gaia/local/audit/<digest>.<member>.ok for a specialized
#                  member, <digest> the member's own 64-hex branch-own digest;
#                  the same two names with a .refused extension for a refusal).
#                  Its existence gates this call. On the success path the
#                  orchestrator passes any one current member's own marker
#                  path, since the member-aware gate resolves the rest
#                  of the roster itself; on the refusal path the clearance
#                  writer passes the refusal it just wrote.
#
# Behavior
#   Best-effort and fail-safe-asymmetric: when gh is absent or unauthenticated,
#   or, on the SUCCESS arm, when a dispatched member other than the caller
#   hasn't cleared yet, the POST is skipped (the button stays blocked) but the
#   clearance the caller already wrote is untouched. With the resolver present, a SUCCESS status is never
#   posted without every dispatched member's marker present (an absent or
#   non-executable resolver falls back to the caller's own marker) and none of them
#   holding a live refusal, save a code-audit-frontend marker the chore(deps)
#   manifest-only waiver excuses (a frontend refusal is never excused), and an
#   absent status never inverts into a cleared gate. The caller may hand in
#   any one current member's own marker path;
#   the member-aware gate evaluates the whole roster regardless of
#   which member's marker was passed, so the call is order-independent with
#   respect to the roster even though there is now exactly one caller (the
#   orchestrator) rather than one call per member.
#
#   The SUCCESS arm also declines while audit-gate-owed.sh reports owed work or
#   cannot answer; the REFUSAL arm reads neither.
#
#   The SUCCESS arm also declines while the PR's review record is incomplete
#   (an undecided finding, an unfixed fix finding, a review that did not run,
#   or a PR body section out of step with the record): GitHub auto-merge never
#   runs the merge hook, so this status is the only place it can be held. The
#   REFUSAL arm never reads the review record.
#
#   The REFUSAL arm skips the member-aware gate by design (see Purpose above),
#   so none of the roster conditions above bound it. Re-arming that gate here
#   would be a regression rather than a tightening: it would withhold the
#   retraction on exactly the state the retraction exists for, since a refusal
#   is itself the reason the roster is not clear.
#
#   Order-independence rests on the DIGEST key. Markers are named for the
#   member's own branch-own digest, not its commit sha, so a commit that leaves
#   the branch's own patch unchanged (an empty commit, or a clean catch-up
#   merge of the base that edits nothing within three lines of a branch hunk)
#   rotates no member's digest and does not orphan a
#   sibling member's marker. Keyed to the commit, such a commit would
#   invalidate every marker written before it, and the member that finished
#   last would find the others' markers gone and decline forever. The POST
#   itself still targets the commit sha: a GitHub commit status has nowhere
#   else to land.
#
#   The SUCCESS arm measures that digest against a trusted base: the PR's base
#   branch name and its current tip come from GitHub through gh, the tip must
#   exist locally, and the branch must have a unique merge base with it. A base
#   that cannot be verified declines, naming the one next step, rather than
#   falling back to a local ref the branch could have forged. The REFUSAL arm
#   never verifies the base: a refusal must always be able to retract an
#   earlier success, and it names the digest its caller already holds.
#
# Exit codes
#   0 , Posted successfully OR declined (precondition failed). One stdout
#        marker line is always emitted; the audit caller surfaces it. Lines:
#          status: posted GAIA-Audit success <short-sha>
#          status: posted GAIA-Audit failure <short-sha>
#        Decline lines (prefix "status: declined: "): see the emit_decline
#        calls in this file and in lib/post-audit-status-gates.sh for the
#        full set.
#   1 , The status posted but the draft flip did not (see Draft flip). One
#        stderr line names the manual `gh pr ready` command; the status is
#        never rolled back.
#   2 , Usage error (no marker path argument). Stderr.
#
# Draft flip
#   Pull requests open as drafts. Once a status has posted, this hook flips the
#   draft: `gh pr ready` after a success, `gh pr ready --undo` after a failure
#   (a refusal converts the pull request back to draft). The flip always comes
#   second, so a reviewer is notified only after the status that justifies it
#   exists. A success flips only a pull request that is a draft, and an undo
#   GitHub refuses because the repository does not support drafts is not a
#   failure: the refusal status already landed. It targets the pull request of the current branch, the same one the
#   `gh pr view` in lib/post-audit-status-gates.sh resolves the head sha from,
#   and is skipped when that read found no pull request.
#
# References
#   Audit-marker handshake: .claude/agents/code-audit-*.md members via .claude/hooks/lib/audit-member-protocol.md "Gate handshake (per-member marker)"
#   Dispatch resolver:      .gaia/scripts/resolve-audit-members.sh
#   State-aware readers:    .claude/hooks/pr-merge-audit-check.sh
#
# Notes
#   - Bash 3.2 compatible (macOS-default bash).
#   - Never changes its own shell directory (per .claude/rules/shell-cwd.md);
#     the only `cd`s sit inside command-substitution subshells (locating the
#     libraries and the repo root, and anchoring gh and the resolver on
#     $repo_root). Resolves the repo root via git rev-parse
#     and uses repo-relative paths from there.
#   - The success description "<version> <frontend-digest> <tree-sha>" (three
#     positional fields; field 2 is the digest) matches what every
#     state-aware GAIA-Audit reader accepts as cleared, and state=success
#     distinguishes it from a pending status.
#     The refusal description carries neither shape, for the same reason.

set -euo pipefail

# Load the shared clearance reader + digest engine from this hook's OWN
# on-disk location (never cwd, never $repo_root), per the frozen library
# resolution basis.
# Bracketed in `set +e` because errexit is armed above: a module that is present
# but unparseable abandons the shell AT the load, so an `-f` test ahead of it
# proves nothing and no caller can guard it from outside -- `bash -n` does not
# recurse into what a file sources. What degrades once the shell survives is
# each consumer, here and in lib/post-audit-status-gates.sh, on its own terms:
# the digest and version readers gate on `type` / `command -v`, the gates
# library itself on the `command -v` probe at its call site, while `clearance_acceptable` is called bare inside an
# `if` condition, where a 127 is errexit-exempt and falls through to the same
# decline an unreadable marker takes -- correct, but noisier, since it prints a
# `command not found` beside a decline whose message blames the marker.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || true
set +e
# shellcheck source=/dev/null
if [ -n "$_library_directory" ]; then
  [ -f "$_library_directory/audit-clearance.sh" ] && . "$_library_directory/audit-clearance.sh" 2>/dev/null
  [ -f "$_library_directory/audit-branch-patch.sh" ] && . "$_library_directory/audit-branch-patch.sh" 2>/dev/null
  [ -f "$_library_directory/audit-base-provenance.sh" ] && . "$_library_directory/audit-base-provenance.sh" 2>/dev/null
  [ -f "$_library_directory/audit-digest.sh" ] && . "$_library_directory/audit-digest.sh" 2>/dev/null
  [ -f "$_library_directory/gaia-version.sh" ] && . "$_library_directory/gaia-version.sh" 2>/dev/null
  [ -f "$_library_directory/post-audit-status-gates.sh" ] && . "$_library_directory/post-audit-status-gates.sh" 2>/dev/null
fi
set -e

# Load the shared main-root resolver the same guarded way, from this hook's
# own on-disk location. Backs the main-anchored `repo_root` derivation below.
_repository_root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || true
set +e
# shellcheck source=/dev/null
[ -n "$_repository_root_directory" ] && [ -f "$_repository_root_directory/.gaia/scripts/main-root-lib.sh" ] \
  && . "$_repository_root_directory/.gaia/scripts/main-root-lib.sh" 2>/dev/null
set -e

emit_posted() {
  printf 'status: posted GAIA-Audit success %s\n' "$1"
}

emit_posted_failure() {
  printf 'status: posted GAIA-Audit failure %s\n' "$1"
}

emit_decline() {
  printf 'status: declined: %s\n' "$1"
}

emit_error() {
  printf 'post-audit-status: %s\n' "$1" >&2
}

marker="${1:-}"
if [ -z "$marker" ]; then
  emit_error "usage: post-audit-status.sh <marker-path>"
  exit 2
fi

# Marker-first: the marker the caller wrote is the literal precondition.
if [ ! -f "$marker" ]; then
  emit_decline "marker absent"
  exit 0
fi

# The gate accepts only a writer-produced clearance. Derive the member and
# digest from the marker filename and require a writer-shaped body: a present
# but legacy or hand-written marker is not a clearance and must not clear the
# POST. Only two provenance extensions exist (there is no carried family), so
# strip either (only one ever matches a given filename); the stem before the
# first remaining dot is the 64-hex digest, the remainder is the member infix.
marker_base="$(basename "$marker")"
marker_stem="$marker_base"
marker_stem="${marker_stem%.ok}"
marker_stem="${marker_stem%.refused}"
marker_digest="${marker_stem%%.*}"
marker_member_part="${marker_stem#"$marker_digest"}"
if [ -z "$marker_member_part" ]; then
  marker_member="code-audit-frontend"
else
  marker_member="${marker_member_part#.}"
fi
# Two modes, decided by the artifact named at the marker path, and nothing
# else is a clearance. An EARNED marker posts success, gated in
# lib/post-audit-status-gates.sh on every dispatched member having cleared. A REFUSAL posts failure, and skips that
# gate: the refusal IS the member's answer, so waiting for a roster to clear
# before reporting it would be waiting for the condition it contradicts.
#
# The failure post exists because the local merge hook is not the only merge
# path. GitHub's auto-merge consults the required GAIA-Audit status alone and
# never reaches the hook that honors refusal precedence, so a refusal written
# after a success status already landed for this head (the orchestrator's own
# earlier post) would leave that success standing and the pull
# request merging over a live refusal. Posting failure for the same head
# retracts it; the latest status for a context wins, and a later success post
# once the orchestrator's own preconditions are met again overwrites this in
# turn, so a refusal can never strand a pull request it no longer applies to.
post_state=""
if clearance_acceptable "$marker" "$marker_member" "$marker_digest"; then
  post_state="success"
elif command -v clearance_refusal_acceptable >/dev/null 2>&1 \
     && clearance_refusal_acceptable "$marker" "$marker_member" "$marker_digest"; then
  post_state="failure"
else
  emit_decline "marker not a valid clearance"
  exit 0
fi

# gh must be present and authenticated; otherwise skip the POST (fail-safe
# asymmetry: the marker stays, the button stays blocked, never inverts).
if ! command -v gh >/dev/null 2>&1; then
  emit_decline "gh absent"
  exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
  emit_decline "gh unauthenticated"
  exit 0
fi

# TWO roots, mirroring pr-merge-audit-check.sh, because this script spans two
# different questions and one root cannot answer both.
#
#   repo_root   The ACTING tree. Everything this script measures is a property
#               of the tree being audited and pushed: the .gaia/VERSION it
#               stamps into the status description, the branch-own digests it
#               derives, the HEAD/upstream/tree shas it compares against the
#               PR head, and the roster resolver it runs. Main-anchoring these
#               reads main's HEAD tree while head_sha comes from the acting
#               tree's PR, so from a linked worktree the "audited tree not on
#               pushed head" guard (lib/post-audit-status-gates.sh) declines
#               on every run and the GAIA-Audit status can never post -- leaving branch protection
#               blocked with no way to clear it.
#   store_root  WHERE a clearance lives. Resolved to the MAIN checkout: marker
#               state is main-anchored shared state (.gaia/state-registry.json
#               scope=shared, the symlinked audit/ store), not a property of
#               whichever tree this script happens to run in. Falls back to
#               repo_root when the resolver is unavailable or fails -- the same
#               fail-open direction the original CWD-anchored derivation had.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

store_root=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  store_root="$(gaia_resolve_main_root 2>/dev/null)" || store_root=""
fi
[ -n "$store_root" ] || store_root="$repo_root"

# Every remaining precondition, in its fixed order, lives in
# lib/post-audit-status-gates.sh; it emits its own decline line. An absent or
# unloadable library declines on both arms: the pushed-head guards it carries
# bound the refusal arm too, so neither arm may post without them.
if ! command -v post_audit_status_gates >/dev/null 2>&1; then
  emit_decline "precondition library unavailable (lib/post-audit-status-gates.sh)"
  exit 0
fi
post_audit_status_gates || exit 0

# Description: three positional fields "<version> <frontend-digest>
# <tree>". Every dispatched member's clearance is earned (there is no
# carried provenance), so the shape is fixed: no branch, no CLI flag.
#
# The refusal description deliberately does NOT carry that cleared shape (its
# field 1 is a fixed word that can never be a version, field 2 a member name
# that can never be a 64-hex digest), so it cannot pass for a cleared status:
# defense in depth behind the state-aware readers, which already reject any
# non-success state. It names the refusing member and the exact branch-own
# digest, which is what an operator needs to find the artifact on disk.
if [ "$post_state" = "failure" ]; then
  status_description="refused by ${marker_member} ${marker_digest}"
else
  # shellcheck disable=SC2154  # post_audit_status_gates sets version, frontend_digest and tree_sha
  status_description="${version} ${frontend_digest} ${tree_sha}"
fi

# Anchored for the same reason as the head read in
# lib/post-audit-status-gates.sh, and with the same limits: a subdirectory
# normalization, not a cross-tree guarantee.
repo=$( cd "$repo_root" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true )
if [ -z "$repo" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

# shellcheck disable=SC2154  # post_audit_status_gates sets head_sha
if gh api "repos/${repo}/statuses/${head_sha}" \
  --method POST \
  --field state="${post_state}" \
  --field context=GAIA-Audit \
  --field description="${status_description}" >/dev/null 2>&1; then
  # Surface the sha we POSTed to, head_sha, which the sha guard in the gates
  # library has already established IS local HEAD: nothing reaches this POST while the two name
  # different commits, so the surfaced sha and the POSTed sha are one commit.
  # Assert the surfaced short sha re-resolves to head_sha; on a mismatch surface
  # the full head_sha and warn.
  posted_short="$(git -C "$repo_root" rev-parse --short "$head_sha" 2>/dev/null || echo "$head_sha")"
  if [ "$(git -C "$repo_root" rev-parse "$posted_short" 2>/dev/null || true)" != "$(git -C "$repo_root" rev-parse "$head_sha" 2>/dev/null || true)" ]; then
    emit_error "posted-sha mismatch: surfaced ${posted_short} does not resolve to POSTed ${head_sha}"
    posted_short="$head_sha"
  fi
  if [ "$post_state" = "failure" ]; then
    emit_posted_failure "$posted_short"
  else
    emit_posted "$posted_short"
  fi
  # Draft flip, strictly after the status (see the header). `gh pr ready`
  # resolves the pull request from the current branch exactly as the head read
  # in the gates library did, so it needs no number; with no pull request
  # resolved there is nothing to flip.
  if [ -n "$pr_view" ]; then
    flip_undo=""
    flip_manual="gh pr ready"
    if [ "$post_state" = "failure" ]; then
      flip_undo="--undo"
      flip_manual="gh pr ready --undo"
    fi
    # A success flips only a draft: a pull request opened ready (a private
    # repository where GitHub refuses drafts) has nothing to flip, and an
    # unreadable draft state falls through to the flip so a failure is reported.
    flip_needed=1
    if [ "$post_state" != "failure" ]; then
      pr_is_draft="$( cd "$repo_root" && gh pr view --json isDraft --jq .isDraft 2>/dev/null </dev/null || true )"
      [ "$pr_is_draft" != "false" ] || flip_needed=0
    fi
    if [ "$flip_needed" = 1 ]; then
      flip_output=""
      if ! flip_output="$( cd "$repo_root" && gh pr ready ${flip_undo:+"$flip_undo"} 2>&1 </dev/null )"; then
        # A refusal on a repository that does not support drafts has no draft
        # to restore; its failure status already landed, so that is not a
        # failed flip.
        if [ "$post_state" = "failure" ] && grep -qiE 'draft.*(not supported|unsupported)|(not supported|unsupported).*draft' <<<"$flip_output"; then
          exit 0
        fi
        emit_error "the GAIA-Audit ${post_state} status posted but the draft flip failed; run it by hand: ${flip_manual}"
        exit 1
      fi
    fi
  fi
  exit 0
fi

emit_decline "post failed"
exit 0
