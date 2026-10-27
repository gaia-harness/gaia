#!/usr/bin/env bash
# pr-merge-audit-check-dispatch.sh: the member-set dispatch and the AND-aggregator that decides the merge.
#
# One contiguous span of the merge gate, moved here unchanged.
# pr-merge-audit-check.sh sources it from its own directory at the point the
# span stood, so it runs in the same order over the same globals; it is never
# run on its own. $root, the main checkout every marker path joins onto, is
# the one the parent derives through main-root-lib.sh (gaia_resolve_main_root).
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2034,SC2154  # the gate globals cross files: the parent and the other siblings set and read them

# --- Dispatch: resolve the Code Audit Team member set for this diff ---------
#
# Anchored on $tree_root, the ACTING tree: who must clear is a property of the
# content being merged. $root stays main-anchored, via gaia_resolve_main_root,
# for WHERE a clearance lives; the two roots answer different questions and
# neither substitutes for the other. Anchoring here never collapses that split,
# because it only pins the acting-tree half harder. Both the existence test and
# the invocation are anchored, since a cwd-relative path reports the resolver
# absent from any directory that is not the checkout root. The `cd` lives
# inside a command substitution, so it never persists into the rest of the hook
# chain (.claude/rules/shell-cwd.md).
#
# The exit status is captured separately from the output. Non-zero means the
# resolver could not answer, which is never "nothing owed": folding it into the
# empty-set branch below hands the legacy single-signal gate a diff whose
# dispatched members are unknown.
members=""
resolver_exit_status=0
if [ -x "${tree_root}/.gaia/scripts/resolve-audit-members.sh" ]; then
  members="$( cd "$tree_root" && bash .gaia/scripts/resolve-audit-members.sh 2>/dev/null )" \
    || resolver_exit_status=$?
fi

if [ "$resolver_exit_status" -ne 0 ]; then
  reason="PR merge gate: the Code Audit Team member resolver cannot answer for HEAD ${sha:0:12}.

.gaia/scripts/resolve-audit-members.sh exited ${resolver_exit_status} for the tree at
${tree_root}, so which members this diff dispatches is unknown. An unanswerable
member query is not an empty member set, and this gate denies rather than fall
back to the single-signal path and clear a diff a required auditor may never
have read.

To unblock:
  1. Run \`bash .gaia/scripts/resolve-audit-members.sh\` from the tree above and
     read its stderr; it names what it could not resolve.
  2. Fix what it names (an unreadable or non-checkout root, a broken git).
  3. Retry gh pr merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

  jq -n --arg reason "$reason$gate_arm_note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'

  exit 0
fi

if [ -z "$members" ]; then
  # Zero-match (entire diff out of scope) OR the resolver script is
  # absent/unusable: fall through to the legacy single-signal gate verbatim.
  # NOT an unconditional allow, the member roster's auditable-base set is strictly narrower
  # than check_out_of_scope_pr's denylist, so an ownerless-but-in-scope file
  # (root Makefile, frontend/public/**, ...) still denies here without a marker.
  #
  # The out-of-scope classification runs FIRST, ahead of every clearance
  # signal, because the bypass stamp depends on it whichever signal allows: a
  # wiki-only pull request cut from audited content still validates the old
  # marker (a path outside every member's set rotates no digest), so a gate that let the
  # marker answer first would allow it and never post the status branch
  # protection waits on. The price is the base resolution and diff on a run a
  # marker would have cleared without them.
  #
  # Neither bypass reads a branch-own digest, so both are decided before
  # gate_require_digests and its GitHub base lookup. Every path that sets
  # out_of_scope_pr has already bound the merge to the record's pull request
  # (check_out_of_scope_pr ends on that conjunct, and the empty-range arm routes
  # through gate_empty_is_decisive), so no permit-binding check follows here.
  out_of_scope_pr=0
  check_out_of_scope_pr && out_of_scope_pr=1

  if [ "$out_of_scope_pr" -eq 1 ]; then
    github_status_cleared any-digest || gate_post_bypass_stamp 'skipped: out of scope'
    exit 0
  fi

  if frontend_cleared; then
    gate_permit_binds_to_named_pr || exit 0
    if [ "$frontend_cleared_by" = chore-deps ]; then
      gate_post_bypass_stamp 'skipped: chore(deps) manifest-only'
    fi
    exit 0
  fi

  if [ "$out_of_scope_unbound" -eq 1 ]; then
    gate_deny_unbound_bypass 'every path it changes is outside audit scope'
    exit 0
  fi
  if [ "$chore_deps_unbound" -eq 1 ]; then
    gate_deny_unbound_bypass 'a chore(deps) pull request confined to dependency manifests'
    exit 0
  fi

  gate_require_digests

  # check_out_of_scope_pr above already populated the memo on every path that
  # reaches here; call it again anyway so the signal list below can never report
  # an empty provenance for a structural reason rather than a real one. The memo
  # makes the second call free.
  gate_resolve_base
  base_display="unresolved"
  [ -z "$gate_base" ] || base_display="${gate_base:0:12}"

  reason="PR merge gate: no code-audit-frontend signal for HEAD ${sha:0:12}.
${refusal_note}
None of the accepted signals is present:
  - Local marker:    ${marker} $(marker_state "$marker")
  - GitHub status:   absent or version/digest mismatch
  - chore(deps) PR:  PR title does not match \`chore(deps):\`/\`chore(deps-dev):\`, or the PR changes a path other than a dependency manifest
  - Out-of-scope:    PR changes at least one in-scope path (frontend/app/, frontend/test/, configs,
                     .github/workflows/), not a wiki/docs/.gaia-config-only diff
  - Diff base:       ${gate_trust:-unresolvable} provenance (anchor ${gate_anchor:-default-branch}, base ${base_display}); an empty
                     base-to-HEAD range clears this gate only on remote or supplied
                     provenance, with a pr-record anchor and HEAD at the pull
                     request's recorded head sha

To unblock:
  1. Dispatch the audit-loop-unit agent on HEAD
     (wiki/concepts/PR Merge Workflow.md, ## Dispatch the audit loop unit);
     it runs code-audit-frontend and fixes the findings.
  2. Let it push the fixes and write the marker on the new HEAD.
  3. Retry gh pr merge.

LOCAL-SYNC FAILURE NOTE: if a previous gh pr merge exited with
'fatal: main is already used by worktree at <path>', the GitHub-side merge
already succeeded. Verify with: bash .gaia/scripts/pr-wait-merge.sh --pr <N>
(it prints MERGED), do NOT retry the merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

  # --arg safely escapes $reason; never interpolate dynamic values directly into
  # the JSON template string.
  jq -n --arg reason "$reason$gate_arm_note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'

  exit 0
fi

# --- AND-aggregator: require every dispatched member's clearance ------------
#
# A non-empty dispatched set means at least one changed file is owned by a
# Code Audit Team member. Every dispatched member must clear:
# code-audit-frontend via frontend_cleared() above, each specialized member
# <m> via its own marker .gaia/local/audit/<digest>.<m>.ok, keyed to that
# member's OWN branch-own digest. A live refusal for a member's current digest
# is checked before its earned marker and is absolute.

all_cleared=1
report=""
# Set when the chore(deps) waiver, not an earned signal, cleared
# code-audit-frontend: the one member-aware allow that earns a bypass stamp.
frontend_chore_deps_waived=0
# Set when a member other than code-audit-frontend stays uncleared, which is
# what decides whether an unbound chore(deps) waiver alone blocks the merge.
other_member_uncleared=0

while IFS= read -r roster_member; do
  [ -n "$roster_member" ] || continue

  member_cleared=0
  if [ "$roster_member" = "code-audit-frontend" ]; then
    if frontend_cleared; then
      member_cleared=1
      [ "$frontend_cleared_by" != chore-deps ] || frontend_chore_deps_waived=1
    fi
    member_content_digest="$frontend_digest"
    member_refused="$frontend_refused"
  else
    gate_require_digests
    member_content_digest="$(member_digest "$roster_member")" || member_content_digest=""
    member_refused=0
    if [ -n "$member_content_digest" ] && clearance_member_refused "$root" "$member_content_digest" "$roster_member"; then
      member_refused=1
    fi
    if [ "$member_refused" -eq 0 ] && [ -n "$member_content_digest" ]; then
      clearance_member_cleared "$root" "$member_content_digest" "$roster_member" && member_cleared=1
    fi
  fi

  if [ "$member_cleared" -eq 1 ]; then
    report="${report}  - ${roster_member}: CLEARED
"
  else
    all_cleared=0
    [ "$roster_member" = "code-audit-frontend" ] || other_member_uncleared=1
    if [ "$member_refused" -eq 1 ]; then
      refused_path="$(clearance_refused_path "$root" "$member_content_digest" "$roster_member")"
      report="${report}  - ${roster_member}: REFUSED (a live refusal exists for this exact branch-own digest at ${refused_path}; a bare re-spawn does not clear it, the member must supersede it, see below)
"
    elif [ "$roster_member" = "code-audit-frontend" ]; then
      chore_deps_line="PR title does not match \`chore(deps):\`/\`chore(deps-dev):\`, or the PR changes a path other than a dependency manifest"
      [ "$chore_deps_unbound" -eq 0 ] \
        || chore_deps_line="the PR qualifies, but the merge command could not be bound to it; run \`gh pr merge <N>\` as its own command"
      report="${report}  - code-audit-frontend: PENDING
      Local marker:    ${marker} $(marker_state "$marker")
      GitHub status:   absent or version/digest mismatch
      chore(deps) PR:  ${chore_deps_line}
"
    else
      member_marker="$root/.gaia/local/audit/${member_content_digest:-<unavailable>}.${roster_member}.ok"
      report="${report}  - ${roster_member}: PENDING (marker ${member_marker} $(marker_state "$member_marker"))
"
    fi
  fi
done <<< "$members"

if [ "$all_cleared" -eq 1 ]; then
  gate_permit_binds_to_named_pr || exit 0
  [ "$frontend_chore_deps_waived" -eq 0 ] || gate_post_bypass_stamp 'skipped: chore(deps) manifest-only'
  exit 0
fi

if [ "$chore_deps_unbound" -eq 1 ] && [ "$other_member_uncleared" -eq 0 ]; then
  gate_deny_unbound_bypass 'a chore(deps) pull request confined to dependency manifests'
  exit 0
fi

gate_require_digests

reason="PR merge gate: not every dispatched Code Audit Team member has cleared HEAD ${sha:0:12} (tree ${tree:0:12}).

${report}
To unblock: run the audit loop unit on HEAD (dispatch the audit-loop-unit agent per
wiki/concepts/PR Merge Workflow.md, ## Dispatch the audit loop unit) so each PENDING member
writes its marker (code-audit-frontend writes ${root}/.gaia/local/audit/${frontend_digest}.ok; each
specialized member writes ${root}/.gaia/local/audit/<its-own-digest>.<member>.ok, NOT
the frontend digest), then retry gh pr merge. Markers are keyed to each
member's own branch-own digest (the branch's own patch on the paths it owns plus
the shared gate machinery), so a path outside that set, or content the base
branch brought in through a catch-up merge, never invalidates one.

A REFUSED member is not a PENDING one: its refusal outranks any earned marker
for the same digest, and an ordinary re-spawn does not clear it (a plain
earned write leaves the refusal on disk). Resolve the finding with an edit to
the branch's own patch on that member's paths, which rotates its digest and
retires the refusal with it (a fix that arrives only through a catch-up merge of
the base branch does not rotate it unless the base edited within three lines of a branch hunk); or, when the operator acknowledges a
Major with a stated reason and the digest does not move,
re-spawn the member so it writes its earned marker with
--supersede-refusal \"<reason>\", removing its own refusal as an explicit,
recorded act.

LOCAL-SYNC FAILURE NOTE: if a previous gh pr merge exited with
'fatal: main is already used by worktree at <path>', the GitHub-side merge
already succeeded. Verify with: bash .gaia/scripts/pr-wait-merge.sh --pr <N>
(it prints MERGED), do NOT retry the merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

jq -n --arg reason "$reason$gate_arm_note" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'

exit 0
