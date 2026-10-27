#!/usr/bin/env bash
# audit-write-clearance-publish.sh: the clearance writer's atomic marker publish
# (with the supersede removal of the sibling refusal) and its refusal-only
# compensating status signal, as two functions. audit-write-clearance.sh sources
# it from its own directory and calls the publish before the ledger write and
# the signal after it; it is never run on its own.
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2154  # the marker fields and paths come from the parent and the other siblings

# Atomic write: temp file in the SAME directory as the target, then mv. A torn
# marker would clear the existence-testing merge gate while failing the
# reader's stricter body check, so the publish must be a single rename.
_write_clearance_publish_marker() {
  temporary_file="$(mktemp "${audit_directory}/.audit-write-clearance.XXXXXX" 2>/dev/null || true)"
  if [ -z "$temporary_file" ]; then
    error "cannot create temp file in '$audit_directory'"
    exit 2
  fi

  # Body built by `jq -n`, never a hand-assembled template: every value is
  # escaped by construction, so a field carrying a `"` or `\` can never emit
  # malformed JSON. `-c` keeps the compact single-line shape the marker's
  # consumers read. A jq failure must not publish an empty or partial marker.
  jq -cn \
    --arg version "$version" \
    --argjson schema 4 \
    --arg member "$MEMBER" \
    --arg provenance "$PROVENANCE" \
    --arg digest "$digest" \
    --arg tree "$tree" \
    --arg sha "$sha" \
    --arg audited_at "$audited_at" \
    --argjson sidecar "$sidecar" \
    --arg review "$REVIEW" \
    --argjson do_supersede "$do_supersede" \
    --arg supersede_reason "$SUPERSEDE_REASON" \
    --arg review_coverage "$review_coverage_digest" \
    '{version: $version, schema: $schema, member: $member,
      provenance: $provenance, digest: $digest, tree: $tree, sha: $sha,
      audited_at: $audited_at, sidecar: $sidecar}
     + (if $provenance == "earned" then {review: $review} else {} end)
     + (if $provenance == "refused" and $review_coverage != ""
        then {review_coverage: {scope_digest: $review_coverage}}
        else {} end)
     + (if $do_supersede
        then {supersedes: {provenance: "refused", reason: $supersede_reason,
                           superseded_at: $audited_at}}
        else {} end)' \
    > "$temporary_file" || {
    rm -f "$temporary_file"
    error "cannot build the marker body"
    exit 2
  }

  mv -f "$temporary_file" "$target" || {
    rm -f "$temporary_file"
    error "cannot publish marker to '$target'"
    exit 2
  }

  # Order is load-bearing: the earned .ok is published above FIRST, the sibling
  # refusal is removed here SECOND. A crash between the two leaves BOTH markers on
  # disk, and the merge gate checks the refusal family first, so it stays shut
  # (fail-safe). Removing the refusal first would open a window where neither an
  # earned nor a refused marker exists. If the removal itself fails, the earned
  # marker is already durably published, so warn and still exit 0 rather than
  # reporting a false failure; the stale refusal keeps the gate shut until the
  # next supersede attempt, never falsely opens it. This runs inside the writer
  # subprocess, not as a Claude Bash tool call, so the destructive-command guard
  # does not intercept it.
  if [ "$do_supersede" = "true" ]; then
    rm -f "$refused_path" || error "warning: superseded but could not remove '$refused_path'"
  fi
}

# -----------------------------------------------------------------------------
# Compensating server-side signal on a refusal (LOCAL path only).
#
# A refusal blocks the merge path that runs .claude/hooks/pr-merge-audit-check.sh
# and only that one. GitHub's auto-merge fires on the required GAIA-Audit status
# alone, so a refusal written after a sibling member's clean pass already posted
# `success` leaves that success standing and the pull request merges over a live
# refusal, with the artifact on disk and no diagnostic anywhere. Posting
# `failure` for the same head retracts it, which is why this call belongs to the
# writer rather than to an agent's instructions: the one moment a refusal is
# guaranteed to be recorded is the moment it is written.
#
# Runs LAST, after both the refusal and the ledger are durably on disk. This is
# the only step here that touches the network, and `gh` has no bound of its own,
# so a hung call must not sit in front of the briefing a refusal exists to
# produce. It never affects either write: `|| true` absorbs every failure, and
# the hook's own output goes to stderr so stdout stays the marker path this
# script contracts to print. A post that cannot happen (no gh, an un-pushed
# head) leaves the refusal on disk, where the local gate still denies the merge.
#
# Anchored on $_root_toplevel, the absolute checkout root already derived and
# validated in the argument phase, rather than on $ROOT: the subshell `cd` re-bases every
# relative path inside it, so a caller passing a relative --root from a
# subdirectory would resolve the hook one way for the `[ -x ]` test and another
# way for the run. $target has the same exposure, since audit_directory is built from
# $ROOT, so the marker is re-derived here against the absolute root. Both paths
# name the same files either way: the argument phase's validation proves $ROOT and
# $_root_toplevel are one physical directory.
#
# The `cd` itself is load-bearing and cannot be dropped: the hook derives its
# repo root, and `gh` its repository and branch, from the ambient working
# directory, so the call has to be anchored on the audited tree.
#
# The window this closes: a wave posts once, so a later wave's refusal can
# arrive behind an earlier wave's success, and the refusal must flip the status
# to failure whatever the environment.
# -----------------------------------------------------------------------------
_write_clearance_post_refusal_status() {
  if [ "$PROVENANCE" = "refused" ]; then
    status_hook="${_root_toplevel}/.claude/hooks/post-audit-status.sh"
    status_marker="${_root_toplevel}/.gaia/local/audit/${target##*/}"
    if [ -x "$status_hook" ]; then
      ( cd "$_root_toplevel" && bash "$status_hook" "$status_marker" ) >&2 || true
    fi
  fi
}
