#!/usr/bin/env bash
# research-reaper.sh: propose which closed research folders to delete, and
# carry out the human's answer. Run by the pre-flight sweep of /gaia-spec and
# /gaia-plan (.claude/skills/gaia/references/spec/lifecycle.md).
#
# Research piles up with no owner to clean it, so the notebook catalog gives
# each research folder a status and this reaper turns "closed, aged, uncited,
# unsnoozed" into a proposal. It never decides alone: `list` only reads, and
# `apply` deletes or snoozes only what the keep rules still allow at that
# moment, and only in an interactive session. An unattended run never reaps
# research.
#
# Usage:
#   research-reaper.sh [list]
#   research-reaper.sh apply [--reap <slug>]... [--snooze <slug>]...
#
# list prints one JSON object:
#   {"citation_query": {"answered": bool, "reason": string|null},
#    "eligible": [{"slug": .., "verdict": "landed|not landed|no evidence"}],
#    "recommended": "reap|snooze|none",
#    "reported": {"untagged": [..], "rowless": [..], "loose_files": [..]},
#    "kept": [{"slug": .., "rule": ..}]}
# `recommended` is reap only when every eligible folder is landed, snooze when
# any is not, none when nothing is eligible. A verdict that could not be
# confirmed (GitHub did not answer for a linked pull request) reads as
# "not landed", so a guess never recommends deletion.
# Untagged folders, folders with no catalog row and loose files are reported
# for a human, never reaped. The keep rules and the landed verdict are
# documented in notebook-lib-research.sh.
#
# apply reads the GitHub citations once, before taking the catalog write lock,
# then re-checks every keep rule per slug under the lock. A reaped folder is
# removed and its row records the reap; a snoozed folder stays and its row
# records a snooze one window ahead. A slug that is not eligible at that
# moment is refused on stderr and nothing about it changes.
#
# Exit: 0 ok; 2 usage; 3 not ready (the one-time move is pending); 7 refused
# because the session is not an interactive CLI session (nothing changed);
# 8 one or more slugs refused as not eligible (each named on stderr); other
# non-zero statuses come from the notebook library.
set -uo pipefail

_reaper_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/notebook-lib-research.sh
. "$_reaper_directory/notebook-lib-research.sh" || {
  echo "research-reaper: cannot load the notebook library" >&2
  exit 1
}

_usage() {
  echo "usage: research-reaper.sh [list | apply [--reap <slug>]... [--snooze <slug>]...]" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || {
  echo "research-reaper: jq is required" >&2
  exit 1
}

mode="list"
reap_slugs=()
snooze_slugs=()
if [ "$#" -gt 0 ]; then
  mode="$1"
  shift
fi
case "$mode" in
  list)
    [ "$#" -eq 0 ] || _usage
    ;;
  apply)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reap | --snooze)
          [ "$#" -ge 2 ] && [ -n "$2" ] || _usage
          if [ "$1" = "--reap" ]; then reap_slugs+=("$2"); else snooze_slugs+=("$2"); fi
          shift 2
          ;;
        *) _usage ;;
      esac
    done
    [ "${#reap_slugs[@]}" -gt 0 ] || [ "${#snooze_slugs[@]}" -gt 0 ] || _usage
    for reap_slug in ${reap_slugs[@]+"${reap_slugs[@]}"}; do
      for snooze_slug in ${snooze_slugs[@]+"${snooze_slugs[@]}"}; do
        if [ "$reap_slug" = "$snooze_slug" ]; then
          echo "research-reaper: '$reap_slug' cannot be both reaped and snoozed" >&2
          exit 2
        fi
      done
    done
    ;;
  *) _usage ;;
esac

# Readiness comes before every other gate, the interactivity check included,
# so a not-ready machine is told to run the move whatever kind of session asks.
gaia_notebook_require_ready
ready_status=$?
[ "$ready_status" -eq 0 ] || exit "$ready_status"

_pending_citations='{"answered":false,"reason":"pending","counts":{}}'

_list() {
  local folders loose rows slug rule verdict candidates="" candidate_slugs=() eligible_lines="" kept_lines=""
  local citation_query untagged_json rowless_json loose_json eligible_json kept_json recommended
  local landed_count=0 eligible_count=0
  rows="$(gaia_notebook_rows research)" || return $?
  folders="$(gaia_notebook_folders research)" || return $?
  loose="$(gaia_notebook_loose_files research)" || return $?

  _GAIA_RESEARCH_CITATIONS_JSON="$_pending_citations"
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    rule="$(gaia_notebook_research_eligibility "$slug")" || return $?
    if [ "$rule" = "kept citation-query-unanswered" ]; then
      candidate_slugs+=("$slug")
    else
      kept_lines="${kept_lines}${slug}"$'\t'"${rule#kept }"$'\n'
    fi
  done <<EOF
$folders
EOF

  if [ "${#candidate_slugs[@]}" -gt 0 ]; then
    gaia_notebook_research_prefetch_citations ${candidate_slugs[@]+"${candidate_slugs[@]}"}
    citation_query="$(printf '%s' "$_GAIA_RESEARCH_CITATIONS_JSON" | jq -c '{answered, reason}')"
    for slug in ${candidate_slugs[@]+"${candidate_slugs[@]}"}; do
      rule="$(gaia_notebook_research_eligibility "$slug")" || return $?
      if [ "$rule" = "eligible" ]; then
        candidates="${candidates}${slug}"$'\n'
      else
        kept_lines="${kept_lines}${slug}"$'\t'"${rule#kept }"$'\n'
      fi
    done
  else
    citation_query='{"answered":true,"reason":null}'
  fi

  if [ -n "$candidates" ]; then
    gaia_notebook_research_prefetch_pull_requests
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      verdict="$(gaia_notebook_research_landed "$slug")" || verdict="unknown"
      [ "$verdict" = "unknown" ] && verdict="not landed"
      [ "$verdict" = "landed" ] && landed_count=$((landed_count + 1))
      eligible_count=$((eligible_count + 1))
      eligible_lines="${eligible_lines}${slug}"$'\t'"${verdict}"$'\n'
    done <<EOF
$candidates
EOF
  fi

  if [ "$eligible_count" -eq 0 ]; then
    recommended="none"
  elif [ "$landed_count" -eq "$eligible_count" ]; then
    recommended="reap"
  else
    recommended="snooze"
  fi

  eligible_json="$(printf '%s' "$eligible_lines" | jq -R 'select(length > 0) | split("\t") | {slug: .[0], verdict: .[1]}' | jq -cs .)"
  kept_json="$(printf '%s' "$kept_lines" | jq -R 'select(length > 0) | split("\t") | {slug: .[0], rule: .[1]}' | jq -cs .)"
  untagged_json="$(printf '%s' "$rows" | jq -c '[.[] | select(.status == "untagged") | .id] | sort')"
  rowless_json="$(printf '%s\n' "$folders" | jq -R 'select(length > 0)' | jq -cs --argjson rows "$rows" \
    '[.[] | select(. as $slug | any($rows[]; .id == $slug) | not)] | sort')"
  loose_json="$(printf '%s\n' "$loose" | jq -R 'select(length > 0)' | jq -cs 'sort')"
  jq -n --argjson citation_query "$citation_query" --argjson eligible "$eligible_json" \
    --argjson kept "$kept_json" --argjson untagged "$untagged_json" --argjson rowless "$rowless_json" \
    --argjson loose "$loose_json" --arg recommended "$recommended" '
    {citation_query: $citation_query,
     eligible: $eligible,
     recommended: $recommended,
     reported: {untagged: $untagged, rowless: $rowless, loose_files: $loose},
     kept: $kept}'
}

# Prints the transcript of this session, or nothing. The projects directory
# and the per-tree subfolders come from the usage scripts' own resolvers.
_session_transcript() {
  local session_id="${CLAUDE_CODE_SESSION_ID:-}" projects_root main candidate_directory candidate
  case "$session_id" in '' | *[!A-Za-z0-9._-]*) return 0 ;; esac
  projects_root="$(gaia_usage_projects_root "")"
  main="$(gaia_resolve_main_root "${GAIA_NOTEBOOK_TREE:-}")" || main=""
  if [ -n "$main" ]; then
    while IFS= read -r candidate_directory; do
      [ -n "$candidate_directory" ] || continue
      if [ -f "$candidate_directory/$session_id.jsonl" ]; then
        printf '%s\n' "$candidate_directory/$session_id.jsonl"
        return 0
      fi
    done < <(gaia_usage_candidate_directories "$projects_root" "$main")
  fi
  for candidate in "${projects_root%/}"/*/"$session_id.jsonl"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 0
}

_require_interactive() {
  local transcript
  # shellcheck source=SCRIPTDIR/../usage-lib.sh
  . "$_reaper_directory/../usage-lib.sh" 2>/dev/null || return 1
  # shellcheck source=SCRIPTDIR/../audit-loop-state-lib.sh
  . "$_reaper_directory/../audit-loop-state-lib.sh" 2>/dev/null || return 1
  transcript="$(_session_transcript)"
  gaia_loop_session_is_interactive "$transcript"
}

# _apply_locked: runs under the catalog write lock. Returns 8 when any slug
# was refused, 1 when a delete or write failed, else 0. State cannot be handed
# back from a locked block (the lock may run it in a subshell), so the return
# status is the report.
# shellcheck disable=SC2329  # invoked by name through gaia_notebook_with_catalog_lock
_apply_locked() {
  local slug rule folder action refused=0 failed=0 snooze_until now_epoch window_days
  window_days="$(gaia_notebook_research_retention_days)"
  for action in ${reap_slugs[@]+"${reap_slugs[@]/#/reap:}"} ${snooze_slugs[@]+"${snooze_slugs[@]/#/snooze:}"}; do
    slug="${action#*:}"
    rule="$(gaia_notebook_research_eligibility "$slug")" || { failed=1; continue; }
    if [ "$rule" != "eligible" ]; then
      printf 'research-reaper: refused %s: not eligible now (%s)\n' "'$slug'" "${rule#kept }" >&2
      refused=1
      continue
    fi
    if [ "${action%%:*}" = "reap" ]; then
      if ! folder="$(gaia_notebook_item_directory research "$slug")" || [ -z "$folder" ]; then
        printf 'research-reaper: refused %s: no safe folder path\n' "'$slug'" >&2
        refused=1
        continue
      fi
      if ! rm -rf "${folder:?}"; then
        printf 'research-reaper: could not delete the folder for %s\n' "'$slug'" >&2
        failed=1
        continue
      fi
      if ! gaia_notebook_record_reap research "$slug" research-reaper; then
        printf 'research-reaper: deleted the folder for %s but could not record the reap\n' "'$slug'" >&2
        failed=1
        continue
      fi
      printf 'reaped %s\n' "$slug"
    else
      now_epoch="$(date -u +%s)"
      snooze_until="$(jq -rn --argjson epoch "$((now_epoch + window_days * 86400))" '$epoch | strftime("%Y-%m-%dT%H:%M:%SZ")')"
      if ! gaia_notebook_snooze "$slug" "$snooze_until"; then
        printf 'research-reaper: could not snooze %s\n' "'$slug'" >&2
        failed=1
        continue
      fi
      printf 'snoozed %s until %s\n' "$slug" "$snooze_until"
    fi
  done
  [ "$refused" -eq 0 ] || return 8
  return "$failed"
}

_apply() {
  local slug requested=()
  if ! _require_interactive; then
    echo "research-reaper: refused: this is not an interactive CLI session, and research is only ever reaped in one. Nothing changed." >&2
    return 7
  fi
  for slug in ${reap_slugs[@]+"${reap_slugs[@]}"} ${snooze_slugs[@]+"${snooze_slugs[@]}"}; do
    # An id that could climb out of the research folder is never queried.
    gaia_notebook_valid_id research "$slug" 2>/dev/null && requested+=("$slug")
  done
  if [ "${#requested[@]}" -gt 0 ]; then
    gaia_notebook_research_prefetch_citations ${requested[@]+"${requested[@]}"}
  else
    _GAIA_RESEARCH_CITATIONS_JSON='{"answered":false,"reason":"no valid slug","counts":{}}'
  fi
  gaia_notebook_with_catalog_lock _apply_locked
}

case "$mode" in
  list) _list ;;
  apply) _apply ;;
esac
exit $?
