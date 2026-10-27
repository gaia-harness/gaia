#!/usr/bin/env bash
# audit-write-clearance-accounting.sh: the clearance writer's audit-key
# derivation and its open-finding accounting gate (exit 3, before anything
# publishes), plus the ledger and sidecar readers the ledger phase reuses.
# audit-write-clearance.sh sources it from its own directory, before the ledger
# sibling, and calls the two phases in order; it is never run on its own. Every
# variable the phases set stays global for the later phases.
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2034,SC2154  # the phase globals cross files: the parent and the other siblings set and read them

# Audit key (the ledger, the findings sidecar, and the scope capture)
#   <key> = gaia_audit_key "$(git merge-base <KEY_REF> HEAD)" <root>, where
#   <KEY_REF> is the single line of the argument-less .github/audit/resolve-audit-base.sh,
#   run from the checkout root and resolved from this script's own location: the
#   branch's fork point, which a catch-up merge of the base never moves. The
#   merge-base it was built from is the KEY BASE. When that cannot be derived the
#   key falls back to the --base key (key base = the --base value); with neither,
#   nothing is located. The ledger records the key base as `.base_sha`, and both
#   staleness tests (the accounting read's and the ledger write's prior-ledger
#   test) compare against the key base, never against a differing --base: the
#   resolver links a refusal to the ledger only when `.base_sha` equals that
#   merge-base.
#
# Open-finding accounting (every write; GATING; before publish)
#   Each write, refused or earned (with or without --supersede-refusal), for a
#   member with open ledger entries must account for every one of them by
#   `entry_id`: the member's findings sidecar at the derived key either
#   re-reports it (a finding carrying that `entry_id`) or resolves it (a
#   `resolutions[]` record for that `entry_id` whose rationale is non-empty
#   after trimming). The check runs before anything publishes and fails closed:
#   an unaccounted entry, or open entries with an absent or unparseable
#   sidecar, exits 3 naming each unaccounted entry and the recovery step. It
#   applies regardless of --base, --scope-digest, or any sidecar flag, so
#   omitting a flag never skips it. On the supersede path it runs before the
#   refusal is removed, so an exit 3 leaves the `.refused` record in place.
#   The open set is the ledger's `remaining[]` entries for this member that
#   carry an `entry_id`; a ledger that does not parse, or whose branch or
#   `.base_sha` is not this tree's branch and key base, yields an empty open
#   set, EXCEPT when this member's scope capture recorded `base_reason`
#   `member-refusal`: the round then reviewed only the delta since the refusal,
#   so an unreadable or stale ledger is itself an exit 3 rather than an empty
#   set. A second exception covers a ledger written under an earlier key
#   derivation: with no ledger at the key, any ledger of this branch that holds
#   an open entry for this member under a base that is neither the key base nor
#   on HEAD's first-parent history is an exit 3 that lists each such ledger,
#   newest first, and prints the `jq` command re-keying the newest. No severity gate: re-reporting an open Critical or Major on an
#   earned write counts as accounted, exactly as on a refused write; whether an
#   earned marker is warranted stays the member protocol's precondition.
#
# -----------------------------------------------------------------------------
# Audit key derivation and open-finding accounting (before anything publishes).
#
# The key is derived here rather than taken from --base because the resolver
# links a refusal to the ledger by the merge-base it computes itself, and a
# member that dropped the flag passes no --base at all: a check keyed to
# the flag would be skippable by omitting it.
# -----------------------------------------------------------------------------

_write_clearance_derive_audit_key() {
  branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"

  key_base=""
  audit_key=""
  if [ -n "$_write_clearance_resolver" ] \
     && command -v gaia_audit_key >/dev/null 2>&1; then
    # The resolver reads its repository from the working directory, so it runs
    # from the checkout root; its stderr is a decision trace, not ours to print.
    _key_resolver_output="$( (cd "$_root_toplevel" && bash "$_write_clearance_resolver") 2>/dev/null || true)"
    _key_reference="${_key_resolver_output%%$'\n'*}"
    case "$_key_reference" in
      '' | -*) _key_reference="" ;;
    esac
    if [ -n "$_key_reference" ]; then
      key_base="$(git -C "$ROOT" merge-base "$_key_reference" HEAD 2>/dev/null || true)"
      if [ -n "$key_base" ]; then
        audit_key="$(gaia_audit_key "$key_base" "$ROOT" 2>/dev/null || true)"
      fi
    fi
    [ -n "$audit_key" ] || key_base=""
  fi
  if [ -z "$audit_key" ] && [ -n "$BASE" ] && command -v gaia_audit_key >/dev/null 2>&1; then
    audit_key="$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"
    if [ -n "$audit_key" ]; then
      key_base="$BASE"
    fi
  fi
}

# _current_ledger <path>: the ledger as compact JSON when it parses as one
# schema-1 object for this branch and key base, else `null`. The accounting
# read and the ledger write's prior-ledger test share it, so the two can never
# disagree about which ledger is live.
_current_ledger() {
  local ledger_path="$1" current
  [ -f "$ledger_path" ] || {
    printf 'null\n'
    return 0
  }
  current="$(jq -cs --arg branch "$branch" --arg base "$key_base" '
    if (length == 1) and ((.[0] | type) == "object") and (.[0].schema == 1)
       and (.[0].branch == $branch) and (.[0].base_sha == $base)
    then .[0] else null end' "$ledger_path" 2>/dev/null)" || current='null'
  [ -n "$current" ] || current='null'
  printf '%s\n' "$current"
}

# _orphaned_ledger_candidates: prints, newest first, the path of every re-run
# ledger of this branch that holds an open entry for this member under a base
# that is neither the current key base nor on HEAD's first-parent history.
#
# Why that test cannot misfire on an earlier round's ledger: the key base is the
# branch's fork point, and an incremental round keys on a past HEAD of this
# branch. The fork point and every past HEAD sit on HEAD's first-parent chain,
# and a catch-up merge adds to that chain without ever removing from it. A base
# off the chain is therefore a base tip a merge brought in (the key derivation
# before it was stable across catch-ups) or a commit a rebase or amend removed.
#
# Newest is by the committer date of the ledger's base; a base git cannot
# resolve sorts last.
_orphaned_ledger_candidates() {
  local branch_slug candidate candidate_base chain="" chain_loaded=0
  local committer_date rows="" newline=$'\n'
  branch_slug="$(gaia_branch_slug "$ROOT" 2>/dev/null)" || return 0
  [ -n "$branch_slug" ] || return 0
  for candidate in "${audit_directory}/"*".${branch_slug}.rerun.json"; do
    [ -f "$candidate" ] || continue
    [ "$candidate" != "$ledger" ] || continue
    candidate_base="$(jq -rs --arg branch "$branch" --arg member "$MEMBER" '
      if (length == 1) and ((.[0] | type) == "object") and (.[0].schema == 1)
         and (.[0].branch == $branch)
         and ((.[0].base_sha | type) == "string") and ((.[0].base_sha | length) > 0)
         and ((.[0].remaining | type) == "array")
         and any(.[0].remaining[]; type == "object" and .member == $member)
      then .[0].base_sha else empty end' "$candidate" 2>/dev/null)" || continue
    [ -n "$candidate_base" ] || continue
    [ "$candidate_base" != "$key_base" ] || continue
    if [ "$chain_loaded" -eq 0 ]; then
      chain="$(git -C "$ROOT" rev-list --first-parent HEAD 2>/dev/null)" || return 0
      chain="${newline}${chain}${newline}"
      chain_loaded=1
    fi
    case "$chain" in
      *"${newline}${candidate_base}${newline}"*) continue ;;
    esac
    committer_date=""
    case "$candidate_base" in
      *[!0-9a-f]*) ;;
      *) committer_date="$(git -C "$ROOT" log -1 --format=%ct "${candidate_base}^{commit}" 2>/dev/null || true)" ;;
    esac
    case "$committer_date" in
      '' | *[!0-9]*) rows="${rows}0000000000000"$'\t'"${candidate}"$'\n' ;;
      *) rows="${rows}$(printf '1%012d' "$committer_date")"$'\t'"${candidate}"$'\n' ;;
    esac
  done
  [ -n "$rows" ] || return 0
  printf '%s' "$rows" | LC_ALL=C sort -r | while IFS= read -r candidate; do
    printf '%s\n' "${candidate#*$'\t'}"
  done
}

# _findings_report <path>: the findings sidecar as compact JSON when it parses
# as one object, else `null`.
_findings_report() {
  local sidecar_path="$1" report
  [ -f "$sidecar_path" ] || {
    printf 'null\n'
    return 0
  }
  report="$(jq -cs 'if (length == 1) and ((.[0] | type) == "object") then .[0] else null end' \
    "$sidecar_path" 2>/dev/null)" || report='null'
  [ -n "$report" ] || report='null'
  printf '%s\n' "$report"
}

# _write_clearance_account_open_findings: the gating accounting read; exits 3
# on any open entry left unaccounted, before anything publishes.
_write_clearance_account_open_findings() {
  ledger=""
  findings_sidecar=""
  if [ -n "$audit_key" ]; then
    ledger="${audit_directory}/${audit_key}.rerun.json"
    findings_sidecar="${audit_directory}/${audit_key}.${MEMBER}.findings.json"
  fi

  accounting_protocol_pointer="The accounting step is documented in your own definition under '${_root_toplevel}/.claude/agents/'."
  # gaia:maintainer-only:start
  accounting_protocol_pointer="The accounting step is documented in '${_root_toplevel}/.claude/hooks/lib/audit-member-protocol.md' and in your own definition under '${_root_toplevel}/.claude/agents/'."
  # gaia:maintainer-only:end

  review_coverage_digest=""
  if [ -n "$audit_key" ]; then
    capture_file="${audit_directory}/${audit_key}.${MEMBER}.scope.json"
    capture_reason=""
    capture_digest=""
    capture_overridden="false"
    if [ -f "$capture_file" ]; then
      capture_reason="$(jq -r '.base_reason // "" | tostring' "$capture_file" 2>/dev/null || true)"
      capture_digest="$(jq -r '.scope_digest // "" | tostring' "$capture_file" 2>/dev/null || true)"
      capture_overridden="$(jq -r '.base_overridden == true' "$capture_file" 2>/dev/null || echo unreadable)"
    fi

    # The review-coverage proof: the refusal's own round reviewed the content
    # the refusal is keyed to, on the base the resolver chose.
    if [ "$PROVENANCE" = "refused" ] && [ -n "$capture_digest" ] \
       && [ "$capture_digest" = "$digest" ] && [ "$capture_overridden" = "false" ]; then
      review_coverage_digest="$digest"
    fi

    current_ledger="$(_current_ledger "$ledger")"

    # No ledger at the key is not yet "nothing open": a branch that caught up with
    # its base before the key stopped moving on a catch-up wrote its ledger under
    # the base tip it merged. Publishing now would read an empty open set and drop
    # that ledger's open entries for this member.
    if [ ! -f "$ledger" ]; then
      orphaned_ledgers="$(_orphaned_ledger_candidates)"
      if [ -n "$orphaned_ledgers" ]; then
        newest_orphaned_ledger="${orphaned_ledgers%%$'\n'*}"
        error "open-finding accounting failed: there is no re-run ledger at '$ledger', but this branch has ledger(s) with open entries for member '$MEMBER' keyed to a base that is not on this branch's history. The branch caught up with its base before the audit key stopped moving on a catch-up, or its history was rewritten; writing now would drop those open findings silently."
        error "Ledger(s), newest first:"
        while IFS= read -r orphaned_ledger_path; do
          printf 'audit-write-clearance:   %s\n' "$orphaned_ledger_path" >&2
        done <<EOF
$orphaned_ledgers
EOF
        if [ "$newest_orphaned_ledger" != "$orphaned_ledgers" ]; then
          error "The recovery below re-keys the newest of them; the others are older rounds of the same branch and stay where they are."
        fi
        error "Recovery: re-key the ledger to the current key base, then retry this write:"
        printf 'audit-write-clearance:   jq --arg base %q %s %q > %q\n' \
          "$key_base" "'.base_sha = \$base'" "$newest_orphaned_ledger" "$ledger" >&2
        error "$accounting_protocol_pointer"
        exit 3
      fi
    fi

    # A round resolved on member-refusal reviewed only the delta since the
    # refusal; its open findings live nowhere but the ledger, so a ledger that
    # cannot be read must refuse here, never read as "nothing open".
    if [ "$capture_reason" = "member-refusal" ] && [ "$current_ledger" = "null" ]; then
      error "open-finding accounting failed: this round's review scope was resolved on member-refusal, but the re-run ledger at '$ledger' is absent, unreadable, or stale, so the findings that refusal left open cannot be accounted for."
      error "Recovery: release the capture with audit-scope-digest.sh --release, re-run the scope resolver (it no longer anchors on the refusal, so it resolves an earlier base: the whole-team signal if one precedes the refusal, else full scope), review, and write again."
      error "$accounting_protocol_pointer"
      exit 3
    fi

    # No live ledger means an empty open set (the member-refusal case refused
    # above), so there is nothing to evaluate.
    unaccounted_entries=""
    findings_report="$(_findings_report "$findings_sidecar")"
    if [ "$current_ledger" != "null" ] && ! unaccounted_entries="$(jq -rn \
      --argjson ledger "$current_ledger" \
      --argjson report "$findings_report" \
      --arg member "$MEMBER" '
      def nonempty_string: type == "string" and length > 0;
      def array_or_empty: if type == "array" then . else [] end;
      ([($ledger.remaining // null | array_or_empty)[] | objects
        | select(.member == $member and (.entry_id | nonempty_string))])   as $open
      | ([($report.findings // null | array_or_empty)[] | objects
          | .entry_id | select(nonempty_string)]
         + [($report.resolutions // null | array_or_empty)[] | objects
            | select((.rationale | type) == "string"
                     and ((.rationale | gsub("^\\s+|\\s+$"; "")) | length) > 0)
            | .entry_id | select(nonempty_string)])                         as $accounted
      | $open[]
      | . as $entry
      | select(any($accounted[]; . == $entry.entry_id) | not)
      | [.entry_id, (.finding_class // "" | tostring), (.path // "" | tostring),
         (.line // "" | tostring)]
      | map(gsub("[\t\n\r\u001f]"; " "))
      | join("\u001f")
      ' 2>&1)"; then
      error "open-finding accounting failed: the ledger and sidecar could not be evaluated: $unaccounted_entries"
      error "$accounting_protocol_pointer"
      exit 3
    fi

    if [ -n "$unaccounted_entries" ]; then
      if [ "$findings_report" = "null" ]; then
        error "open-finding accounting failed: member '$MEMBER' has open re-run ledger entries and no readable findings sidecar at '$findings_sidecar'. Unaccounted entries:"
      else
        error "open-finding accounting failed: these open re-run ledger entries for member '$MEMBER' are neither re-reported nor resolved:"
      fi
      while IFS=$'\037' read -r entry_identifier entry_class entry_path entry_line; do
        [ -n "$entry_identifier" ] || continue
        printf 'audit-write-clearance:   %s  %s  %s:%s\n' \
          "$entry_identifier" "$entry_class" "$entry_path" "$entry_line" >&2
      done <<<"$unaccounted_entries"
      error "Recovery: re-check each entry at HEAD, then rewrite the findings sidecar with audit-write-findings.sh, re-reporting a still-present finding with its entry_id or passing --resolutions with {entry_id, rationale} for one that is fixed or acknowledged, and retry this write."
      error "$accounting_protocol_pointer"
      exit 3
    fi
  fi
}
