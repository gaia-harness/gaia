#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # stage globals are assigned and read across the resolver and its siblings
# resolve-audit-base-scan.sh: the resolver's per-member pre-scan. Reads this
# member's earned clearances and refusals out of the local audit store, and
# sets up the whole-roster review-depth check the walk runs at the first
# whole-team signal. Sourced by resolve-audit-base.sh, never executed; defines
# functions only, which the parent calls in order. Every assignment outside a
# `local` is a global the walk and the refusal link read.
#
# Per-member anchor: what a clearance proves, and what it does not
#   A candidate is a per-member anchor when the member holds an earned
#   clearance carrying `review: full` whose recorded TREE equals the
#   candidate's tree and which the merge gate itself would accept: its
#   recorded version equals the current one, and no live refusal of this
#   member exists for that clearance's own digest (a re-run-until-pass
#   clearance beside its own refusal never anchors). A
#   `review: light` marker, and a marker whose body lacks the field, is never
#   an anchor: it was written from a delta or before the field existed, and a
#   later full review must start from the last full clearance. The tree rather than the commit
#   sha is the matching field because an amend or a rebase rewrites the sha a
#   moments-old clearance recorded while preserving the tree; matching on the
#   sha would lose the anchor on exactly the rounds that earned it. No member digest is ever recomputed at a candidate: the
#   ownership classifier reads the working tree's roster rather than the
#   candidate commit's, so a recomputed digest can name a value that never
#   existed at that commit.
#
#   CHAINED TRUST, a documented assumption rather than a proof. A clearance
#   body records the member, the digest, the version, the write-time HEAD
#   commit, and the tree, but never the RANGE the member reviewed. So a
#   clearance at commit C attests a branch-own digest over that member's owned
#   paths at C; that it covers everything up to C holds only by chaining,
#   each clearance inheriting the coverage of the ones before it. A single
#   vacuous clearance would therefore propagate forward invisibly. The
#   clearance validity predicate this arm leans on is likewise a
#   well-formedness and change-detection key, NOT an anti-forgery defence:
#   anyone who can write the store can already write the working tree.
#   Repairing either property is a human's decision, not this file's.
#
# Team-signal arm and review depth, --member form only
#   The status is light-blind by design: it attests that no
#   dispatched member is pending, not how deep any review was. So the --member
#   form anchors on a whole-team signal S only when the local marker store
#   shows no non-full marker among the in-range candidate trees, scanned
#   across the whole roster and not only the resolving member: (a) no
#   candidate in range may carry a tree holding any member's non-full earned
#   marker (light, or a body without the field, at any version), and (b) some
#   member's earned `review: full` marker must record S's tree. Check (a)
#   matches a marker by the tree it recorded, so a non-full marker whose tree
#   left the range (a content amend or a rebase rewrites the commit trees
#   while the marker stays valid by branch-own digest) is not found and does not
#   disable the arm; the reviewed delta of that member can then fall before
#   the anchor. Either failing check disables the
#   arm for the run and logs why; the walk still continues, so the per-member
#   arm can win on an older full clearance of the resolving member, and with
#   none in range the answer is no-anchor, the full-branch base.
#   Documented boundary and its cost: the store is gitignored, so CI and a
#   fresh clone have no markers, (b) is never met, and the arm refuses there.
#   A --member resolution from such a run scopes the whole branch rather than
#   the delta since the last team signal: wider (more tokens), never narrower.
#   CI-side marker validation is out of scope. Line 3 and the argument-less
#   form are unaffected: they still carry the whole-team floor and only KEY
#   artifacts, so none of them scopes a member's review.

# -----------------------------------------------------------------------------
# Per-member pre-scan: the trees at which this member holds a gate-accepted
# earned clearance, and every refusal record it holds. Only the --member form
# reads the store, and only when the clearance reader loaded.
# -----------------------------------------------------------------------------

# scan_field <clearance_scan line> <n> prints the n-th tab-separated field.
# `cut` rather than `read` under a tab IFS: tab is IFS whitespace, so `read`
# collapses the empty version or sha an old body can record and shifts every
# later field, the review column included.
scan_field() {
  printf '%s\n' "$1" | cut -f"$2"
}


resolve_base_scan_member_records() {
  member_arm="false"
  earned_trees=""
  refused_trees=""
  # One line per refusal record: <tree>\t<version>\t<digest>\t<path>.
  refused_records=""
  non_full_trees=""
  non_full_owners=""
  full_trees=""
  team_arm_refusal=""

  if [ "$member_form" = "true" ] && command -v clearance_scan >/dev/null 2>&1; then
    # An unreadable / empty store is not a degradation: it is the ordinary CI
    # condition, where the whole-team floor is sound and both tiers stay
    # evaluable. Fall back to the floor, never narrow on an absent record.
    earned_scan="$(clearance_scan "$repo_root" "$member" earned 2>/dev/null || true)"
    refused_scan="$(clearance_scan "$repo_root" "$member" refused 2>/dev/null || true)"

    # Empty fields are excluded explicitly: the clearance writer applies no
    # empty-guard to the fields it records, so an empty recorded value must
    # never match an empty candidate value.
    if [ -n "$earned_scan" ]; then
      while IFS= read -r scan_line; do
        [ -n "$scan_line" ] || continue
        recorded_tree="$(scan_field "$scan_line" 1)"
        recorded_version="$(scan_field "$scan_line" 2)"
        recorded_review="$(scan_field "$scan_line" 4)"
        [ -n "$recorded_tree" ] || continue
        [ "$recorded_version" = "$current_version" ] || continue
        # Only a `review: full` marker anchors. A light clearance was written by
        # a reviewer that read a delta, so a later full review must start from
        # the last full one; a body lacking the field (a legacy marker) is not
        # full either.
        [ "$recorded_review" = "full" ] || continue
        # The recorded digest is not compared with any recipe's output, so a
        # marker earned under the earlier whole-tree recipe still anchors on its
        # version and tree: that recipe attested the full content at the tree, a
        # superset of the branch's own change. The merge gate is what refuses it.
        # The digest comes from the record body, never from the scan's sha
        # column; clearance_scan has already checked it equals the filename stem.
        recorded_digest="$(clearance_field "$(scan_field "$scan_line" 5)" digest)"
        [ -n "$recorded_digest" ] || continue
        # The merge gate refuses a clearance beside a live refusal for its own
        # digest, so such a clearance is no signal here either.
        if clearance_member_refused "$repo_root" "$recorded_digest" "$member"; then
          continue
        fi
        earned_trees="${earned_trees}${recorded_tree}
"
      done <<EOF
$earned_scan
EOF
    fi

    # Every version is kept: an older-version refusal cannot anchor, but it still
    # stops the member arm, so the member never anchors past it.
    if [ -n "$refused_scan" ]; then
      while IFS= read -r scan_line; do
        [ -n "$scan_line" ] || continue
        recorded_tree="$(scan_field "$scan_line" 1)"
        recorded_version="$(scan_field "$scan_line" 2)"
        recorded_path="$(scan_field "$scan_line" 5)"
        [ -n "$recorded_tree" ] || continue
        recorded_digest="$(clearance_field "$recorded_path" digest)"
        refused_trees="${refused_trees}${recorded_tree}
"
        refused_records="${refused_records}${recorded_tree}${TAB}${recorded_version}${TAB}${recorded_digest}${TAB}${recorded_path}
"
      done <<EOF
$refused_scan
EOF
    fi

    if [ -n "$earned_trees" ] || [ -n "$refused_trees" ]; then
      member_arm="true"
    fi
  fi

  # Without a working jq the store reads as empty, so a refusal it holds is
  # invisible rather than linked; say so instead of resolving silently.
  if [ "$member_form" = "true" ] && ! jq -n 'true' >/dev/null 2>&1; then
    echo "resolve-audit-base: jq is unavailable, so ${member}'s records cannot be read and no refused content can be linked to an open-finding record; per-member anchoring disabled for this run." >&2
  fi

  # A refusal at HEAD's own tree is the newest signal of all and cannot be an
  # anchor (the diff from it is empty), so nothing older may anchor either. The
  # walk still runs for the whole-team floor.
  if [ "$member_arm" = "true" ] && [ -n "$refused_trees" ]; then
    head_tree="$(git -C "$repo_root" rev-parse "${head_sha}^{tree}" 2>/dev/null || true)"
    if [ -n "$head_tree" ] && grep -qxF -- "$head_tree" <<<"$refused_trees"; then
      echo "resolve-audit-base: ${member} refused content at HEAD ${head_sha}; a refusal at HEAD leaves an empty diff to anchor on, so per-member anchoring is disabled for this run." >&2
      member_arm="false"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Team-arm review-depth check, --member form only. The status
# is light-blind by design: it attests that every dispatched member holds a
# clearance, not how deep any review was, so only the local marker store can say
# whether a signal stands on full reviews. The scan therefore covers EVERY
# roster member's earned markers, not only the resolving member's.
#   (a) any candidate in range whose tree carries a non-full earned marker of
#       any member (light, or a body lacking the field, at any version)
#       disables the team arm for the run;
#   (b) at the signal commit itself, some member's earned `review: full` marker
#       must record that commit's tree (checked in the walk).
# An empty store (CI, a fresh clone), an absent clearance reader, an unreadable
# roster, and a marker the reader cannot parse all leave (b) unmet, so the arm
# refuses to anchor: it cannot verify, and the cost of refusing is scope width
# (the full-branch base), never narrower scope.
# -----------------------------------------------------------------------------

# record_roster_scan <roster member> <clearance_scan output>: sorts one member's
# earned markers into the full-tree and non-full-tree sets.
record_roster_scan() {
  local roster_member="$1" roster_scan="$2" scan_line recorded_tree
  [ -n "$roster_scan" ] || return 0
  while IFS= read -r scan_line; do
    [ -n "$scan_line" ] || continue
    recorded_tree="$(scan_field "$scan_line" 1)"
    [ -n "$recorded_tree" ] || continue
    if [ "$(scan_field "$scan_line" 4)" = "full" ]; then
      full_trees="${full_trees}${recorded_tree}
"
    else
      non_full_trees="${non_full_trees}${recorded_tree}
"
      non_full_owners="${non_full_owners}${recorded_tree}${TAB}${roster_member}
"
    fi
  done <<EOF
$roster_scan
EOF
}

# scan_roster_depth: the whole-roster scan and check (a). The walk calls it once,
# at the first whole-team signal, because nothing else reads its result and a
# store scan costs seconds per member; the resolving member's scan is the one
# already captured above, not repeated.
scan_roster_depth() {
  local roster_member roster_includes_member="false" candidate_tree non_full_owner candidate_sha
  while IFS= read -r roster_member; do
    [ -n "$roster_member" ] || continue
    if [ "$roster_member" = "$member" ]; then
      roster_includes_member="true"
      record_roster_scan "$roster_member" "$earned_scan"
    else
      record_roster_scan "$roster_member" "$(clearance_scan "$repo_root" "$roster_member" earned 2>/dev/null || true)"
    fi
  done <<EOF
$roster_members
EOF
  [ "$roster_includes_member" = "true" ] || record_roster_scan "$member" "$earned_scan"
  if [ -n "$non_full_trees" ]; then
    for candidate_sha in $candidates; do
      candidate_tree="$(git -C "$repo_root" rev-parse "${candidate_sha}^{tree}" 2>/dev/null || true)"
      [ -n "$candidate_tree" ] || continue
      if grep -qxF -- "$candidate_tree" <<<"$non_full_trees"; then
        non_full_owner="$(grep -F -- "${candidate_tree}${TAB}" <<<"$non_full_owners" | head -n 1 | cut -f2 || true)"
        team_arm_refusal="${non_full_owner:-a member} holds a non-full clearance at ${candidate_sha}, so the whole-team signal may stand on content no full review read"
        echo "resolve-audit-base: ${team_arm_refusal}; whole-team anchoring disabled for ${member} this run." >&2
        break
      fi
    done
  fi
}

resolve_base_read_roster() {
  roster_members=""
  if [ "$member_form" = "true" ]; then
    if ! command -v clearance_scan >/dev/null 2>&1; then
      team_arm_refusal="the clearance reader is unavailable, so review depth at the whole-team signal cannot be verified"
    else
      roster_members="$(audit_roster_member_names "${repo_root}/.gaia/audit-ci.yml" 2>/dev/null || true)"
      if [ -z "$roster_members" ]; then
        team_arm_refusal="the audit roster is unreadable, so review depth at the whole-team signal cannot be verified"
      fi
    fi
    if [ -n "$team_arm_refusal" ]; then
      echo "resolve-audit-base: ${team_arm_refusal}; whole-team anchoring disabled for ${member} this run." >&2
    fi
  fi
}
