#!/usr/bin/env bash
# audit-write-clearance-ledger.sh: the clearance writer's best-effort re-run
# carry-forward ledger write, as one function. audit-write-clearance.sh sources
# it from its own directory, after the accounting sibling whose _current_ledger
# and _findings_report it calls, and runs it after the marker publishes; it is
# never run on its own.
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2154  # the key, ledger and marker globals come from the parent and the other siblings

# Ledger write (armed by --base; best-effort, after publish)
#   Path: <root>/.gaia/local/audit/<key>.rerun.json, at the derived key (accounting sibling).
#   Shape: schema 1, as `.claude/hooks/lib/audit-member-protocol.md` ("Re-run
#   carry-forward ledger") defines it, plus a `member` field and a
#   writer-assigned `entry_id` on each entry, and a top-level
#   `member_provenance` object. One ledger serves the
#   whole dispatched set (its key is the base, not a digest), so without the
#   `member` field a second member's write would silently clobber the first's
#   remaining work.
#
#   refused: this member's `remaining[]` entries are rebuilt from its findings
#     sidecar (.gaia/local/audit/<key>.<member>.findings.json), which already
#     carries each finding's path, line, title, failure_mode and suggested_fix.
#     Severity carries over unchanged; a token outside critical, major, minor
#     is recorded as major, failing toward the gating tier. A finding that
#     echoes an open `entry_id` keeps that id and its `first_seen_round` (its line may
#     move); every other finding gets a new id `r<round>-<n>`, unique within the
#     ledger. An open entry the sidecar resolves moves to `fixed_last_round[]`
#     carrying its `entry_id` and the rationale as `resolution`. The accounting
#     check has already refused any open entry that is neither. `round`
#     increments from a valid same-branch same-key-base ledger, else starts at
#     1. `member_provenance[<member>]` records this refusal's digest, tree, sha,
#     and version, the link the resolver checks before anchoring the member on
#     it. Other members' entries and provenance pass through untouched.
#   earned: once this member's own refusal is gone, its `remaining[]` entries
#     are retired (a surviving refusal leaves the ledger untouched): each moves
#     to `fixed_last_round[]` stamped with the current HEAD sha, its
#     `entry_id`, and its resolution rationale when the sidecar
#     resolved it, and `member_provenance[<member>]` is removed. The FILE is
#     removed only when no member has anything left, matching the documented
#     clean-pass cleanup without discarding a co-dispatched member's still-open
#     work.
#   The accounting READ (accounting sibling) gates and fails closed; this WRITE does not. No
#   sidecar, an unresolvable key, or a `jq` failure here means no ledger work,
#   and a failure here never fails a record that already published.
#
# -----------------------------------------------------------------------------
# Re-run carry-forward ledger (only with --base).
#
# Runs AFTER the marker is durably published, and every failure path below is a
# warning that still exits 0. The ordering and the fail-open are both
# deliberate: the marker is the gate artifact and the ledger is a briefing, so a
# problem WRITING the ledger must never fail a record that already landed. The
# gating read of the same ledger ran before publish, in the accounting block.
#
# This is the step that makes a refusal self-describing. Without it a refusal is
# an opaque blocking artifact: it cannot be repaired by an operator who does not
# know what it found, and it cannot be superseded either, since supersession
# requires stating a reason the operator is not in a position to state.
# -----------------------------------------------------------------------------

_write_clearance_write_ledger() {
  if [ -n "$BASE" ]; then
    if [ -z "$audit_key" ]; then
      error "warning: --base given but the audit key does not resolve; no ledger written"
    else
      # A prior ledger counts only when it is for THIS branch and key base;
      # anything else is stale and is replaced rather than extended (the reader
      # contract's own staleness rule, applied at the writer so a stale file
      # never briefs).
      prior="$(_current_ledger "$ledger")"
      # Deliberately NOT named `sidecar`: that name already holds the marker
      # body's boolean flag the parent builds.
      sidecar_report="$(_findings_report "$findings_sidecar")"

      ledger_body=""
      if [ "$PROVENANCE" = "refused" ]; then
        if [ ! -f "$findings_sidecar" ]; then
          error "warning: refusal recorded with no findings sidecar at '$findings_sidecar'; the ledger cannot brief the repair"
        elif [ "$sidecar_report" = "null" ]; then
          error "warning: cannot build the carry-forward ledger: the findings sidecar at '$findings_sidecar' does not parse"
        else
          # remaining[] for THIS member is rebuilt from its sidecar every round.
          # The accounting check has already refused any open entry the sidecar
          # neither re-reports nor resolves, so each one is either carried by its
          # entry_id (keeping first_seen_round, taking the re-reported line) or
          # moved to fixed_last_round with its resolution. An id echoed twice is
          # claimed by its first finding only, so ids stay unique. Other members'
          # entries and provenance pass through untouched.
          # Every `as` binding is fully parenthesized because jq versions disagree
          # on how far left one reaches: jq 1.7 reads `a + 1 as $r | body` as
          # `a + (1 as $r | body)`, jq 1.8 as `(a + 1) as $r | body`, and `//`
          # splits the same way. jq's stderr is captured rather than discarded --
          # a silently-swallowed program error here would look exactly like "there
          # was nothing to write".
          if ! ledger_body="$(jq -n \
            --argjson prior "$prior" \
            --argjson report "$sidecar_report" \
            --arg member "$MEMBER" \
            --arg base "$key_base" \
            --arg branch "$branch" \
            --arg head "$sha" \
            --arg now "$audited_at" \
            --arg digest "$digest" \
            --arg tree "$tree" \
            --arg version "$version" \
            '
            def ledger_severity:
              if IN("critical", "major", "minor") then . else "major" end;
            def nonempty_string: type == "string" and length > 0;
            def array_or_empty: if type == "array" then . else [] end;
            ((($prior.round // 0) + 1)                                        as $round
            | (($prior.remaining // null | array_or_empty))                   as $previous_entries
            | ([$previous_entries[] | select(.member != $member)])            as $others
            | ([$previous_entries[] | objects
                | select(.member == $member and (.entry_id | nonempty_string))]) as $open
            | (($report.findings // null | array_or_empty))                   as $found
            | ([($report.resolutions // null | array_or_empty)[] | objects
                | select((.entry_id | nonempty_string)
                         and ((.rationale | type) == "string")
                         and (((.rationale | gsub("^\\s+|\\s+$"; "")) | length) > 0))]) as $resolutions
            | (reduce $found[] as $finding ({claimed: [], pairs: []};
                ((if ($finding.entry_id | nonempty_string) then $finding.entry_id else null end) as $echo
                 | ((if ($echo != null) and (any(.claimed[]; . == $echo) | not)
                     then (first($open[] | select(.entry_id == $echo)) // null)
                     else null end) as $was
                    | .claimed += (if $was != null then [$echo] else [] end)
                    | .pairs += [{finding: $finding, was: $was}]))))          as $matched
            | ((reduce $matched.pairs[] as $pair ({count: 0, entries: []};
                (if $pair.was == null then .count += 1 else . end)
                | ((if $pair.was != null then $pair.was.entry_id
                    else "r\($round)-\(.count)" end) as $entry_identifier
                   | ((if $pair.was != null then ($pair.was.first_seen_round // $round)
                       else $round end) as $first_seen
                      | ($pair.finding) as $finding
                      | .entries += [{member: $member,
                                      entry_id: $entry_identifier,
                                      finding_class: $finding.finding_class,
                                      severity: ($finding.severity | ledger_severity),
                                      path: $finding.path,
                                      line: $finding.line,
                                      title: $finding.title,
                                      failure_mode: $finding.failure_mode,
                                      verified_by: $finding.verified_by,
                                      suggested_fix: $finding.suggested_fix,
                                      first_seen_round: $first_seen,
                                      escalated: false}])))).entries)          as $mine
            | ($matched.claimed)                                              as $rereported
            | ([$open[]
                | . as $entry
                | select(any($rereported[]; . == $entry.entry_id) | not)
                | ((first($resolutions[] | select(.entry_id == $entry.entry_id)) // null) as $resolution
                   | select($resolution != null)
                   | {member, entry_id, finding_class, path, line, title,
                      fixed_in_sha: $head, resolution: $resolution.rationale})]) as $resolved
            | {schema: 1,
               base_sha: $base,
               branch: $branch,
               round: $round,
               head_sha: $head,
               updated_at: $now,
               remaining: ($others + $mine),
               fixed_last_round: ([($prior.fixed_last_round // null | array_or_empty)[]
                                   | select(.member != $member)] + $resolved),
               notes: ($prior.notes // ""),
               member_provenance:
                 ((if ($prior.member_provenance | type) == "object"
                   then $prior.member_provenance else {} end)
                  + {($member): {refusal_digest: $digest, refusal_tree: $tree,
                                 refusal_sha: $head, version: $version}})})
            ' 2>&1)"; then
            error "warning: cannot build the carry-forward ledger: $ledger_body"
            ledger_body=""
          fi
        fi
      else
        # An earned write ends this member's loop, so its open entries are retired
        # rather than left to misbrief the next round: each moves into
        # fixed_last_round stamped with the sha that closed it, its entry_id, and
        # the rationale of the resolution that accounted for it, if any. The
        # member's provenance goes with them: nothing of its refusal is left to
        # anchor on.
        #
        # Gated on this member's own refusal being gone. A plain earned write never
        # clears a live refusal (that is the anti-gaming rule: only --supersede-refusal
        # retires one, and the publish phase removes the file, before this block).
        # So a refusal surviving here means the merge is still blocked on findings
        # that are still open, and retiring them would stamp fixed_in_sha on a repair
        # no commit made, then delete the very briefing needed to clear the block.
        # Skipping leaves ledger_body empty, which writes nothing and removes
        # nothing, so the briefing survives intact.
        if [ "$prior" != "null" ] && [ ! -f "$refused_path" ]; then
          if ! ledger_body="$(jq -n \
            --argjson prior "$prior" \
            --argjson report "$sidecar_report" \
            --arg member "$MEMBER" \
            --arg head "$sha" \
            --arg now "$audited_at" \
            '
            def nonempty_string: type == "string" and length > 0;
            def array_or_empty: if type == "array" then . else [] end;
            ((($prior.remaining // null | array_or_empty))                   as $previous_entries
            | ([$previous_entries[] | select(.member == $member)])             as $closed
            | ([($report.resolutions // null | array_or_empty)[] | objects
                | select((.entry_id | nonempty_string)
                         and ((.rationale | type) == "string")
                         and (((.rationale | gsub("^\\s+|\\s+$"; "")) | length) > 0))]) as $resolutions
            | $prior
              + {updated_at: $now,
                 head_sha: $head,
                 remaining: [$previous_entries[] | select(.member != $member)],
                 fixed_last_round:
                   ([($prior.fixed_last_round // null | array_or_empty)[]
                     | select(.member != $member)]
                    + [$closed[]
                       | . as $entry
                       | ((first($resolutions[] | select(.entry_id == $entry.entry_id)) // null) as $resolution
                          | {member, finding_class, path, line, title, fixed_in_sha: $head}
                            + (if ($entry.entry_id | nonempty_string)
                               then {entry_id: $entry.entry_id} else {} end)
                            + (if $resolution != null
                               then {resolution: $resolution.rationale} else {} end))])}
            | (if (.member_provenance | type) == "object"
               then .member_provenance |= del(.[$member]) else . end))
            ' 2>&1)"; then
            error "warning: cannot update the carry-forward ledger: $ledger_body"
            ledger_body=""
          fi
        fi
      fi

      if [ -n "$ledger_body" ]; then
        # Clean-pass cleanup: the file goes away only when NO member has anything
        # left, so a co-dispatched member's still-open work is never discarded by
        # another member's clean pass.
        if [ "$PROVENANCE" = "earned" ] \
           && [ "$(printf '%s' "$ledger_body" | jq -r '(.remaining | length) == 0' 2>/dev/null)" = "true" ]; then
          rm -f "$ledger" || error "warning: could not remove the spent ledger '$ledger'"
        else
          ledger_temporary_file="$(mktemp "${audit_directory}/.audit-rerun-ledger.XXXXXX" 2>/dev/null || true)"
          if [ -z "$ledger_temporary_file" ]; then
            error "warning: cannot create a temp file for the ledger in '$audit_directory'"
          elif ! printf '%s\n' "$ledger_body" > "$ledger_temporary_file"; then
            rm -f "$ledger_temporary_file"
            error "warning: cannot stage the ledger"
          elif ! mv -f "$ledger_temporary_file" "$ledger"; then
            rm -f "$ledger_temporary_file"
            error "warning: cannot publish the ledger to '$ledger'"
          fi
        fi
      fi
    fi
  fi
}
