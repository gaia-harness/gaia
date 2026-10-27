#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # stage globals are assigned and read across the resolver and its siblings
# resolve-audit-base-walk.sh: the resolver's candidate walk. One walk, two
# arms (the per-member arm and the whole-team floor), newest wins. Sourced by
# resolve-audit-base.sh, never executed; defines one function, which the
# parent calls after the pre-scan. Every assignment is a global the shared
# resolution and the per-member resolution read.
#
# Refusals, --member form: the newest member signal wins
#   The walk goes newest first, and the member arm stops at the first of the
#   member's own signals it meets. Per candidate tree a refusal is tested
#   before an earned clearance, so a refusal and a clearance recorded at the
#   same tree resolve as the refusal. A refusal of ANY recorded version is a
#   signal: it stops the member arm there, so the member never anchors on an
#   earned clearance older than its own refusal. A refusal recorded at HEAD's
#   own tree is the newest signal of all and cannot be an anchor (the diff
#   from it is empty), so it disables the member arm for the run.

# -----------------------------------------------------------------------------
# One walk, two arms, newest wins. Per candidate the per-member arm is tested
# first, so a member signal and a whole-team signal on the SAME commit resolve
# as the former; across candidates the newer of the two wins, which is why this
# is one walk and not two. Within the member arm a refusal is tested before an
# earned clearance at the same tree, and the first member signal met settles
# the arm. A refusal settles it only as a CANDIDATE: whether it anchors is
# decided after the walk, once line 3 (which keys the ledger) is known.
# -----------------------------------------------------------------------------

resolve_base_walk_candidates() {
  team_anchor=""
  team_winner=""
  winner=""
  winner_reason=""
  winner_tree=""
  refusal_candidate=""
  refusal_candidate_tree=""

  for sha in $candidates; do
    # HEAD itself can't be the base (an empty diff), and never carries a
    # *matching* signal anyway, a match would have skipped the run upstream.
    [ "$sha" = "$head_sha" ] && continue

    if [ "$member_arm" = "true" ] && [ -z "$winner" ] && [ -z "$refusal_candidate" ]; then
      candidate_tree="$(git -C "$repo_root" rev-parse "${sha}^{tree}" 2>/dev/null || true)"
      if [ -n "$candidate_tree" ]; then
        if grep -qxF -- "$candidate_tree" <<<"$refused_trees"; then
          refusal_candidate="$sha"
          refusal_candidate_tree="$candidate_tree"
        elif grep -qxF -- "$candidate_tree" <<<"$earned_trees"; then
          winner="$sha"
          winner_reason="member-clearance"
          winner_tree="$candidate_tree"
        fi
      fi
    fi

    # Only the first (newest) signal is the shared floor. Once it is found a
    # later signal is never read: the walk only continues for the member arm.
    if [ -z "$team_anchor" ]; then
      status_version="$(status_version_for "$sha")"
      if [ -n "$status_version" ] && [ "$status_version" = "$current_version" ]; then
        team_anchor="$sha"
      fi

      # Check (b): a member's earned full marker must record the signal's tree.
      # The shared floor keeps this signal either way, so line 3 of the member
      # form still equals the argument-less answer.
      if [ -n "$team_anchor" ] && [ "$member_form" = "true" ] && [ -z "$team_arm_refusal" ]; then
        scan_roster_depth
      fi
      if [ -n "$team_anchor" ] && [ "$member_form" = "true" ] && [ -z "$team_arm_refusal" ]; then
        signal_tree="$(git -C "$repo_root" rev-parse "${team_anchor}^{tree}" 2>/dev/null || true)"
        if [ -z "$signal_tree" ] || ! grep -qxF -- "$signal_tree" <<<"$full_trees"; then
          team_arm_refusal="no member holds a full-review clearance at the whole-team signal ${team_anchor}, so its review depth is unverifiable"
          echo "resolve-audit-base: ${team_arm_refusal}; whole-team anchoring disabled for ${member} this run." >&2
        fi
      fi
    fi

    # The team arm is the floor for BOTH forms, so the walk runs until it finds
    # one (or exhausts the range) even when the member arm already won. When the
    # member form refuses the team arm, only the member arm can still win, so
    # the walk goes on past the signal for an older full clearance of the member.
    # A refusal candidate met before the signal keeps the signal as its fallback.
    if [ -n "$team_anchor" ]; then
      if [ -z "$team_arm_refusal" ]; then
        if [ -z "$winner" ]; then
          team_winner="$sha"
        fi
        break
      fi
      if [ -n "$winner" ] || [ -n "$refusal_candidate" ] || [ "$member_arm" != "true" ]; then
        break
      fi
    fi
  done
}
