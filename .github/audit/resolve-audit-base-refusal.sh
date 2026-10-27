#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # stage globals are assigned and read across the resolver and its siblings
# resolve-audit-base-refusal.sh: the refusal link, which decides whether the
# refusal candidate the walk stopped at may anchor the --member answer.
# Sourced by resolve-audit-base.sh, never executed; defines one function,
# which the parent calls after the shared resolution.
#
# Refusal anchors, --member form
#   The refusal the walk stops at becomes the anchor, reason member-refusal
#   with line 4 carrying the refusal's recorded tree, only when every link
#   below holds; any failure falls back to the whole-team anchor the walk
#   found, else to no-anchor, never to the degraded reason, and logs the
#   cause on a line naming the refused content:
#     version   the refusal was recorded under the current version. The
#               version match applies only to anchoring AT a refusal; an
#               older-version refusal still stops the arm.
#     coverage  the refusal record carries a review-coverage proof: its
#               review_coverage.scope_digest equals its own digest, which the
#               clearance writer records only when the member's captured
#               review scope matched the write-time digest without an
#               override, so the refusal really reviewed the tree it records.
#     ledger    the re-run ledger at this branch's audit key (built from the
#               merge-base of line 3 and HEAD, through audit-key-lib.sh)
#               parses, is schema 1, and names this branch and that
#               merge-base; its per-member provenance for this member names
#               this refusal's digest, its tree, and the current version; and
#               it holds at least one open entry for this member.
#   The ledger is read only through `jq --arg`, for presence and the
#   provenance fields. Without jq or
#   the key library the link fails rather than degrading. Every reset in the
#   parent's per-member resolution applies to a refusal anchor exactly as
#   to a clearance anchor.
#
#   Trust boundary. The link is a completeness tripwire, not an anti-forgery
#   defence: it proves the store holds a writer-shaped record of this
#   refusal's open findings, which the member's next clearance write must
#   account for, and anyone who can write the store can write the ledger too.
#
#   An earned clearance NEWER than a refusal still anchors. That rests on the
#   chained-trust assumption (resolve-audit-base-scan.sh), not on a proof: the clearance attests the
#   content at its own tree, and the clearance writer made it account for
#   every open entry the refusal left. The whole-team floor likewise still
#   runs past a refusal: the status is posted only
#   when no dispatched member is pending, and a member holding a live refusal
#   IS pending, so a whole-team signal newer than the refused commit is
#   evidence that the refusal was already resolved (superseded by its author
#   or retired by a digest rotation). That reasoning inherits the posting
#   hook's member-pending check, which sits inside a guard with no else arm
#   and posts anyway in a degraded environment; the floor is therefore
#   sound in the normal case and fail-open in a degraded one.

# -----------------------------------------------------------------------------
# The refusal link. A refusal candidate anchors only when the store provably
# holds this member's open findings FROM THAT REFUSAL, and the refusal provably
# reviewed the tree it records. Evaluated here, after the shared resolution,
# because the ledger is keyed by the merge-base of line 3 and HEAD.
# -----------------------------------------------------------------------------

# refusal_link_holds: exit 0 iff the refusal at refusal_candidate_tree links;
# otherwise sets link_failure_cause and returns 1.
refusal_link_holds() {
  local record_line versioned_records="" proven_records="" coverage_digest
  local key_base ledger_key ledger_path current_branch provenance_line
  local provenance_digest provenance_tree provenance_version digest_matched="false"

  if ! jq -n 'true' >/dev/null 2>&1; then
    link_failure_cause="jq is unavailable, so the re-run ledger cannot be read"
    return 1
  fi
  if ! command -v gaia_audit_key >/dev/null 2>&1; then
    link_failure_cause="the audit key library (audit-key-lib.sh) is unavailable, so the re-run ledger cannot be located"
    return 1
  fi

  while IFS= read -r record_line; do
    [ -n "$record_line" ] || continue
    [ "$(scan_field "$record_line" 1)" = "$refusal_candidate_tree" ] || continue
    [ "$(scan_field "$record_line" 2)" = "$current_version" ] || continue
    versioned_records="${versioned_records}${record_line}
"
  done <<EOF
$refused_records
EOF
  if [ -z "$versioned_records" ]; then
    link_failure_cause="version mismatch: no refusal at this tree was recorded under the current version ${current_version}"
    return 1
  fi

  while IFS= read -r record_line; do
    [ -n "$record_line" ] || continue
    coverage_digest="$(jq -r '(.review_coverage | objects | .scope_digest | strings) // empty' \
      "$(scan_field "$record_line" 4)" 2>/dev/null || true)"
    [ -n "$coverage_digest" ] || continue
    [ "$coverage_digest" = "$(scan_field "$record_line" 3)" ] || continue
    proven_records="${proven_records}${record_line}
"
  done <<EOF
$versioned_records
EOF
  if [ -z "$proven_records" ]; then
    link_failure_cause="no review-coverage proof: the refusal record does not show its review covered the digest it records"
    return 1
  fi

  key_base="$(git -C "$repo_root" merge-base "$shared_base" HEAD 2>/dev/null || true)"
  ledger_key=""
  if [ -n "$key_base" ]; then
    ledger_key="$(gaia_audit_key "$key_base" "$repo_root" 2>/dev/null || true)"
  fi
  if [ -z "$ledger_key" ]; then
    link_failure_cause="the re-run ledger key is undeterminable"
    return 1
  fi
  ledger_path="${repo_root}/.gaia/local/audit/${ledger_key}.rerun.json"
  if [ ! -f "$ledger_path" ]; then
    link_failure_cause="no linked open-finding record: the re-run ledger is absent"
    return 1
  fi
  if ! jq -e 'type == "object"' "$ledger_path" >/dev/null 2>&1; then
    link_failure_cause="no linked open-finding record: the re-run ledger does not parse"
    return 1
  fi
  current_branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
  if ! jq -e --arg branch "$current_branch" --arg base "$key_base" \
    '(.schema == 1) and (.branch == $branch) and (.base_sha == $base)' \
    "$ledger_path" >/dev/null 2>&1; then
    link_failure_cause="stale re-run ledger: its schema, branch, or base does not match this checkout"
    return 1
  fi
  if ! jq -e --arg member "$member" \
    '[.remaining[]? | select(type == "object" and .member == $member)] | length > 0' \
    "$ledger_path" >/dev/null 2>&1; then
    link_failure_cause="no linked open-finding record: the re-run ledger holds no open entry for ${member}"
    return 1
  fi
  if ! jq -e --arg member "$member" \
    '(.member_provenance | type == "object") and (.member_provenance[$member] | type == "object")' \
    "$ledger_path" >/dev/null 2>&1; then
    link_failure_cause="no linked open-finding record: the re-run ledger holds no provenance for ${member}"
    return 1
  fi

  provenance_line="$(jq -r --arg member "$member" \
    '.member_provenance[$member] | [.refusal_digest, .refusal_tree, .version]
      | map(if type == "string" then . else "" end) | join("\t")' \
    "$ledger_path" 2>/dev/null || true)"
  provenance_digest="$(scan_field "$provenance_line" 1)"
  provenance_tree="$(scan_field "$provenance_line" 2)"
  provenance_version="$(scan_field "$provenance_line" 3)"
  if [ "$provenance_version" != "$current_version" ]; then
    link_failure_cause="version mismatch: the ledger provenance for ${member} was recorded under a different version"
    return 1
  fi

  while IFS= read -r record_line; do
    [ -n "$record_line" ] || continue
    [ -n "$provenance_digest" ] || continue
    [ "$(scan_field "$record_line" 3)" = "$provenance_digest" ] || continue
    digest_matched="true"
    if [ "$provenance_tree" = "$(scan_field "$record_line" 1)" ]; then
      return 0
    fi
  done <<EOF
$proven_records
EOF
  if [ "$digest_matched" = "true" ]; then
    link_failure_cause="no linked open-finding record: the ledger provenance records a different tree for this refusal"
  else
    link_failure_cause="no linked open-finding record: the ledger provenance names a different refusal of ${member}"
  fi
  return 1
}
