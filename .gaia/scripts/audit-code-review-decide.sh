# shellcheck shell=bash
# The review record's decisions: whether a record still belongs to this branch,
# whether the branch is a GAIA update, and which of none, quick-first, run or
# deliver the audit unit does next. Sourced by audit-code-review-record.sh, never
# executed; does no work at source time. Bash 3.2 compatible. Never `cd`s.
#
# It runs in the record script's shell, on that script's record helpers, and every
# write goes through them, so the record keeps its one writer.

# Whether a record still belongs to this branch's current history: a reused or
# re-cut branch name reads as no record and gets its own review.
gaia_review_record_is_current() {
  local root="$1" pull_request="$2" recorded_base recorded_head fork_point
  [ "$(field '.pr // empty')" = "$pull_request" ] || return 1
  recorded_base="$(field '.base // empty')"
  recorded_head="$(field '.head // empty')"
  if [ -n "$recorded_base" ]; then
    fork_point="$(gaia_review_fork_point "$root")"
    [ -n "$fork_point" ] || return 1
    git -C "$root" merge-base --is-ancestor "$recorded_base" "$fork_point" 2>/dev/null || return 1
  fi
  if [ -n "$recorded_head" ]; then
    git -C "$root" merge-base --is-ancestor "$recorded_head" HEAD 2>/dev/null || return 1
  fi
  return 0
}

gaia_review_fork_point() {
  local provenance
  # shellcheck source=/dev/null
  . "$SCRIPT_DIRECTORY/../../.claude/hooks/lib/audit-base-provenance.sh"
  provenance="$(audit_resolve_base_provenance "$1" default-branch)" || provenance=""
  printf '%s\n' "${provenance##*$'\t'}"
}

# A GAIA update branch is one whose .gaia/VERSION blob differs from its fork
# point's. Read here rather than through the scope library's release context,
# whose state accessor is documented as off limits to consumers. An unresolved
# base or an absent blob is no signal, and a later run records the base itself.
gaia_review_release_signal() {
  local root="$1" fork_point base_blob head_blob
  fork_point="$(gaia_review_fork_point "$root")"
  [ -n "$fork_point" ] || return 1
  base_blob="$(git -C "$root" rev-parse --verify --quiet "$fork_point:.gaia/VERSION" 2>/dev/null)" || return 1
  head_blob="$(git -C "$root" rev-parse --verify --quiet "HEAD:.gaia/VERSION" 2>/dev/null)" || return 1
  [ -n "$base_blob" ] && [ -n "$head_blob" ] && [ "$base_blob" != "$head_blob" ]
}

# The loop's own hard cap, read from where its script defines it: a literal here
# would drift from the bound it stands for. Empty when the source fails, which
# leaves the unit window's closing flag as the only reading.
loop_hard_cap() {
  (
    set +eu
    # shellcheck source=/dev/null
    . "$SCRIPT_DIRECTORY/audit-loop-eval.sh" >/dev/null 2>&1
    printf '%s' "${_GAIA_LOOP_HARD_CAP:-}"
  )
}

# decide_write <fresh|existing> <reason> [outcome]: a decide row that records. A
# record whose attempt is still alive is left as found, whichever row asked.
decide_write() {
  local source_kind="$1" new_reason="$2" new_outcome="${3:-not run}"
  if [ "$(record_state)" = ok ] && any_open_attempt_alive; then
    return 0
  fi
  write_outcome "$source_kind" "$new_outcome" "$new_reason" ""
}

# cmd_decide <root> <pull-request> <routes>
cmd_decide() {
  local root="$1" pull_request="$2" routes="$3"
  case "$routes" in all-light | mixed) ;; *) die_usage "--routes must be all-light or mixed" ;; esac

  local state record_kind=none round_history window closing used cap source_kind outcome_now
  state="$(record_state)"
  if [ "$state" = unreadable ]; then
    printf 'none\n'
    return 0
  fi
  if [ "$state" = ok ] && gaia_review_record_is_current "$root" "$pull_request"; then
    record_kind=current
  fi
  source_kind=fresh
  [ "$record_kind" = none ] || source_kind=existing

  # A state file that cannot be read means the rounds are unknown, and starting a
  # paid review on an unknown history is the wrong direction to fail in.
  if ! round_history="$(bash "$SCRIPT_DIRECTORY/audit-loop-eval.sh" round-history --root "$root" 2>/dev/null)"; then
    printf 'audit-code-review-record: cannot read the audit round history; no review decided\n' >&2
    printf 'none\n'
    return 0
  fi
  window="$(bash "$SCRIPT_DIRECTORY/audit-loop-eval.sh" unit-window --root "$root" 2>/dev/null)" || window=""
  closing="${window##* }"
  used="$(printf '%s' "$round_history" | jq 'length')"
  cap="$(loop_hard_cap)"
  local closing_or_cap=no
  if [ "$closing" = true ] || { [ -n "$cap" ] && [ "$used" -ge "$cap" ]; }; then
    closing_or_cap=yes
  fi

  if [ "$record_kind" = current ]; then
    outcome_now="$(field .outcome)"
    case "$outcome_now" in
      pending)
        if [ "$closing_or_cap" = yes ] || [ "$(field '.attempts | length')" -ge 2 ]; then
          decide_write existing 'interrupted'
          printf 'none\n'
        else
          printf 'run\n'
        fi
        return 0
        ;;
      ran | ran,* | 'not run')
        if [ "$(field .handover)" != open ]; then
          printf 'none\n'
        elif [ "$closing_or_cap" = yes ]; then
          jq '.handover = "closed" | .findings |= map(if .state == null then .state = "unaccounted" else . end)' \
            "$RECORD_FILE" | install_record
          printf 'none\n'
        else
          printf 'deliver\n'
        fi
        return 0
        ;;
    esac
  fi

  if gaia_review_release_signal "$root"; then
    if [ "$record_kind" != current ] || [ "$(field .outcome)" != 'not needed' ] || [ "$(field '.reason // empty')" != 'release branch' ]; then
      decide_write "$source_kind" 'release branch' 'not needed'
    fi
    printf 'none\n'
    return 0
  fi

  if [ "$record_kind" = none ] && [ "$used" -gt 0 ]; then
    decide_write fresh 'audit already under way'
    printf 'none\n'
    return 0
  fi

  # A memberless reopened round does not count here, so a quick-cleared branch
  # that later gets one keeps its review.
  if [ "$record_kind" = current ] && { [ "$closing_or_cap" = yes ] || printf '%s' "$round_history" \
    | jq -e 'any(.[]; (.members | length) > 0 or .closing == true)' >/dev/null; }; then
    decide_write existing 'audit already under way'
    printf 'none\n'
    return 0
  fi

  if [ "$routes" = all-light ]; then printf 'quick-first\n'; else printf 'run\n'; fi
}
