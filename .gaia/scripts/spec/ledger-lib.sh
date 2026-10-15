# shellcheck shell=bash
# Shared pure helpers for the spec and plan status vocabulary and retention
# windows. Sourced, never run: it defines functions and nothing else, sources
# nothing itself, and locates no file (the notebook library owns that).
#
# Public functions:
#   gaia_ledger_kind_for_id <id>                  spec | plan, else nothing + 2
#   gaia_ledger_status_allowed <kind> <status>    0 when canonical for the kind
#   gaia_ledger_age_past_window <iso> <now_epoch> <retention_days>
#                                                 0 only for a parseable timestamp
#                                                 at least retention_days old

gaia_ledger_kind_for_id() {
  case "${1:-}" in
    SPEC-*[!0-9]* | PLAN-*[!0-9]* | SPEC- | PLAN-) return 2 ;;
    SPEC-*) printf 'spec' ;;
    PLAN-*) printf 'plan' ;;
    *) return 2 ;;
  esac
}

gaia_ledger_status_allowed() {
  case "${1:-}:${2:-}" in
    spec:draft | spec:ready | spec:merged | spec:abandoned) return 0 ;;
    plan:ready | plan:merged | plan:abandoned) return 0 ;;
    *) return 1 ;;
  esac
}

# A missing or unparseable timestamp never reads as infinitely old, so bad
# input keeps the folder rather than authorizing a delete.
gaia_ledger_age_past_window() {
  local iso="${1:-}" now_epoch="${2:-}" retention_days="${3:-}" stamped_epoch age_days
  [ -n "$iso" ] || return 1
  case "$now_epoch" in '' | *[!0-9]*) return 1 ;; esac
  case "$retention_days" in '' | *[!0-9]*) return 1 ;; esac
  [ "$now_epoch" -gt 0 ] || return 1
  stamped_epoch="$(jq -rn --arg iso_timestamp "$iso" '($iso_timestamp | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601)' 2>/dev/null || true)"
  case "$stamped_epoch" in '' | *[!0-9]*) return 1 ;; esac
  age_days=$(( (now_epoch - stamped_epoch) / 86400 ))
  [ "$age_days" -ge "$retention_days" ]
}
