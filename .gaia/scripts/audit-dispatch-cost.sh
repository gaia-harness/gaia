#!/usr/bin/env bash
# shellcheck shell=bash
#
# audit-dispatch-cost.sh: the maintainer-only recorder of what each Code Audit
# Team dispatch cost. `record` finds a dispatched member's (or light reviewer's)
# transcript on disk by agent id, measures it and its descendants, prices them,
# and appends one `dispatch_cost` event to the audit telemetry log. `report`
# prints the medians the events add up to.
#
#   audit-dispatch-cost.sh record --root <r> --kind member|light_reviewer --member <m> --agent-id <id>
#   audit-dispatch-cost.sh record --root <r> --kind member --state not_dispatched
#                                 --reason already_cleared --member <m> [--member <m> ...]
#   audit-dispatch-cost.sh report [--root <r>] [--window <n>]
#
# Log: <main>/.gaia/local/telemetry/audit-light-routing.jsonl, <main> from
# main-root-lib.sh; the same file audit-light-telemetry.sh writes, whose tally
# windows past the dispatch_cost events and reads complete ones for spend.
#
# Why maintainer-only: the log answers a question only the maintainer asks, and
# adopters have no use for the file. This script is release-excluded, and
# `record` additionally checks for
# <main>/.claude/rules/maintainers/harness-triage-threshold.md before writing,
# so a copy that ever reaches an adopter checkout still records nothing and
# creates no directory.
#
# Never blocks: telemetry must not change or delay an audit. `record` exits 0
# with nothing on stdout whatever goes wrong (jq absent, malformed arguments, an
# unwritable directory, a rates table that will not load), at most one line on
# stderr. Callers still wrap the call in `|| true`; this is the second wall.
#
# Lookup scope: the transcript is searched only in this repository's Claude
# Code project folders under the projects root (GAIA_TALLY_PROJECTS_ROOT, then
# CLAUDE_CONFIG_DIR, through usage-lib.sh): the main checkout's folder and the
# folders of its .claude/worktrees checkouts. Each is one non-recursive glob on
# the agent id, so a transcript belonging to another project is never opened,
# let alone read. A worktree created outside the main checkout encodes under an
# unrelated folder and records transcript_missing by design.
#
# Finish wait: the transcript's meta file flips `finished` to true only when
# the dispatch ends, and the recorder can run a moment before that, so it polls
# the meta every 0.2 s for at most GAIA_DISPATCH_COST_FINISH_WAIT_SECONDS
# (default and ceiling 10; anything that is not a non-negative number means 10).
# A dispatch still unfinished at the bound is recorded incomplete, never
# dropped.
#
# Bash 3.2 compatible. Never `cd`; no `set -e`, because every failure here is
# deliberately swallowed.

self_directory="${BASH_SOURCE[0]%/*}"
[ "$self_directory" != "${BASH_SOURCE[0]}" ] || self_directory="."

MAINTAINER_RULE_RELATIVE_PATH=".claude/rules/maintainers/harness-triage-threshold.md"
LOG_RELATIVE_PATH=".gaia/local/telemetry/audit-light-routing.jsonl"
MAXIMUM_FINISH_WAIT_SECONDS=10
POLL_INTERVAL_SECONDS=0.2

usage() {
  cat >&2 <<'EOF'
usage: audit-dispatch-cost.sh record --root <r> --kind member|light_reviewer --member <m> --agent-id <id>
       audit-dispatch-cost.sh record --root <r> --kind member --state not_dispatched --reason already_cleared --member <m> [--member <m> ...]
       audit-dispatch-cost.sh report [--root <r>] [--window <n>]
EOF
}

# One stderr line, never a failure.
swallow() {
  printf 'audit-dispatch-cost: %s\n' "$1" >&2
  exit 0
}

subcommand="${1:-}"
case "$subcommand" in
  record) shift ;;
  report)
    shift
    exec bash "$self_directory/audit-dispatch-cost-report.sh" "$@"
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

root=""
kind=""
state=""
reason=""
agent_id=""
member_count=0
members=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root="${2:-}" ;;
    --kind) kind="${2:-}" ;;
    --state) state="${2:-}" ;;
    --reason) reason="${2:-}" ;;
    --agent-id) agent_id="${2:-}" ;;
    --member)
      members="$members${2:-}"$'\n'
      member_count=$((member_count + 1))
      ;;
    *) swallow "unknown argument: $1" ;;
  esac
  shift 2 2>/dev/null || shift
done

# The id goes into a glob and the member into a record key: only these
# characters, which refuses `/`, `..` and every glob character.
is_plain_token() {
  case "$1" in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

[ -n "$root" ] || swallow "--root is required"
case "$kind" in
  member | light_reviewer) ;;
  *) swallow "--kind must be member or light_reviewer" ;;
esac
[ "$member_count" -ge 1 ] || swallow "--member is required"
while IFS= read -r member_name; do
  [ -n "$member_name" ] || swallow "--member is not a plain name"
  is_plain_token "$member_name" || swallow "--member is not a plain name"
done <<EOF
${members%$'\n'}
EOF

if [ -n "$state" ]; then
  [ "$state" = not_dispatched ] || swallow "--state must be not_dispatched"
  [ "$kind" = member ] || swallow "--state is for --kind member only"
  [ "$reason" = already_cleared ] || swallow "--reason must be already_cleared"
  [ -z "$agent_id" ] || swallow "--agent-id does not go with --state"
else
  [ -z "$reason" ] || swallow "--reason goes with --state not_dispatched"
  [ "$member_count" -eq 1 ] || swallow "--member may repeat only with --state not_dispatched"
  is_plain_token "$agent_id" || swallow "--agent-id is not a plain id"
fi

command -v jq >/dev/null 2>&1 || swallow "jq is not available, nothing recorded"
# shellcheck source=/dev/null
. "$self_directory/main-root-lib.sh" 2>/dev/null || swallow "main-root library unavailable"
# shellcheck source=/dev/null
. "$self_directory/usage-lib.sh" 2>/dev/null || swallow "usage library unavailable"
# shellcheck source=/dev/null
. "$self_directory/audit-key-lib.sh" 2>/dev/null || swallow "audit-key library unavailable"
# shellcheck source=/dev/null
. "$self_directory/audit-dispatch-cost-lib.sh" 2>/dev/null || swallow "measurement library unavailable"

main="$(gaia_resolve_main_root "$root" 2>/dev/null)" || main=""
[ -n "$main" ] || swallow "main checkout unresolved, nothing recorded"
# Adopter installs carry no maintainer rule file: record nothing, create nothing.
[ -f "$main/$MAINTAINER_RULE_RELATIVE_PATH" ] || exit 0

log="$main/$LOG_RELATIVE_PATH"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
branch_slug="$(gaia_branch_slug "$root" 2>/dev/null)" || branch_slug=""
head_tree="$(git -C "$root" rev-parse 'HEAD^{tree}' 2>/dev/null)" || head_tree=""

# member_digest <member>: the digest member-result and the light mark use, so
# the report's join keys agree.
member_digest() {
  bash "$self_directory/audit-member-digest.sh" --root "$root" --member "$1" 2>/dev/null
}

# event_line <member> <digest> <overlay-json>: the full key set, null where the
# state has no value, then the state's own fields laid over it.
event_line() {
  jq -n -c --arg at "$timestamp" --arg branch "$branch_slug" --arg member "$1" \
    --arg kind "$kind" --arg digest "$2" --arg tree "$head_tree" --argjson overlay "$3" '
    {event: "dispatch_cost", schema: 1, at: $at,
     branch: (if $branch == "" then null else $branch end),
     member: $member, kind: $kind, agent_id: null, agent_type: null,
     digest: $digest, tree: $tree, state: null, reason: null,
     incomplete: null, finish: null, claude_code_version: null,
     own: null, children_state: null, children: null, children_dollars: null} + $overlay' 2>/dev/null
}

# append_lines <lines>: one O_APPEND write of complete lines, so a failure
# leaves nothing half-written.
append_lines() {
  [ -n "$1" ] || return 0
  mkdir -p "$(dirname "$log")" 2>/dev/null || swallow "cannot create the telemetry directory"
  { printf '%s\n' "$1" >>"$log"; } 2>/dev/null || swallow "cannot append to the telemetry log"
  exit 0
}

first_member="${members%%$'\n'*}"

if [ "$state" = not_dispatched ]; then
  lines=""
  while IFS= read -r member_name; do
    digest="$(member_digest "$member_name")" || digest=""
    [ -n "$digest" ] || swallow "member digest underivable"
    line="$(event_line "$member_name" "$digest" '{"state":"not_dispatched","reason":"already_cleared"}')" || line=""
    [ -n "$line" ] || swallow "event unbuildable"
    lines="$lines${lines:+$'\n'}$line"
  done <<EOF
${members%$'\n'}
EOF
  append_lines "$lines"
fi

digest="$(member_digest "$first_member")" || digest=""
[ -n "$digest" ] || swallow "member digest underivable"

# The transcript: exactly two non-recursive globs, the main checkout's project
# folder and its worktree folders. The newest by mtime wins.
projects_root="$(gaia_usage_projects_root)"
encoded="$(gaia_usage_encode_path "$main")"
transcript=""
for candidate in \
  "$projects_root/$encoded"/*/subagents/agent-"$agent_id".jsonl \
  "$projects_root/$encoded"--claude-worktrees-*/*/subagents/agent-"$agent_id".jsonl; do
  [ -f "$candidate" ] || continue
  if [ -z "$transcript" ] || [ "$candidate" -nt "$transcript" ]; then
    transcript="$candidate"
  fi
done

if [ -z "$transcript" ]; then
  overlay="$(jq -n -c --arg id "$agent_id" '{agent_id: $id, state: "transcript_missing"}')"
  line="$(event_line "$first_member" "$digest" "$overlay")" || line=""
  [ -n "$line" ] || swallow "event unbuildable"
  append_lines "$line"
fi

subagents_directory="${transcript%/*}"
meta_file="$subagents_directory/agent-$agent_id.meta.json"

finish_wait_seconds="$MAXIMUM_FINISH_WAIT_SECONDS"
case "${GAIA_DISPATCH_COST_FINISH_WAIT_SECONDS:-}" in
  '' | *[!0-9.]* | *.*.* | . | *.) ;;
  *)
    awk -v bound="$GAIA_DISPATCH_COST_FINISH_WAIT_SECONDS" -v ceiling="$MAXIMUM_FINISH_WAIT_SECONDS" \
      'BEGIN { exit !(bound + 0 <= ceiling) }' && finish_wait_seconds="$GAIA_DISPATCH_COST_FINISH_WAIT_SECONDS"
    ;;
esac
maximum_polls="$(awk -v bound="$finish_wait_seconds" -v interval="$POLL_INTERVAL_SECONDS" \
  'BEGIN { printf "%d", int(bound / interval + 0.5) }')"

# meta_finish: finished | timeout | meta_missing | meta_unparsed, as the meta
# file reads right now.
meta_finish() {
  local finished_flag
  [ -f "$meta_file" ] || { printf 'meta_missing'; return 0; }
  finished_flag="$(jq -r 'if type == "object" then (.finished == true | tostring) else "unparsed" end' "$meta_file" 2>/dev/null)" || finished_flag=""
  case "$finished_flag" in
    true) printf 'finished' ;;
    false) printf 'timeout' ;;
    *) printf 'meta_unparsed' ;;
  esac
}

finish="$(meta_finish)"
poll_count=0
while [ "$finish" != finished ] && [ "$poll_count" -lt "$maximum_polls" ]; do
  sleep "$POLL_INTERVAL_SECONDS"
  poll_count=$((poll_count + 1))
  finish="$(meta_finish)"
done
incomplete=true
[ "$finish" = finished ] && incomplete=false

gaia_rates_load "$main"
[ -n "${GAIA_RATES_JSON:-}" ] && [ "$GAIA_RATES_JSON" != null ] || swallow "rates table unreadable, nothing recorded"
[ "${GAIA_RATES_OVERRIDE_STATUS:-none}" != unparseable ] || swallow "rates override unparseable, nothing recorded"

measurement="$(gaia_dispatch_cost_measure "$subagents_directory" "$agent_id" "$GAIA_RATES_JSON" 2>/dev/null)" || measurement=""
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$measurement"; then
  measurement='{"state":"transcript_unparsed"}'
fi
overlay="$(jq -c --arg id "$agent_id" --arg finish "$finish" --argjson incomplete "$incomplete" '
  {agent_id: $id, agent_type, state, incomplete: $incomplete, finish: $finish,
   claude_code_version, own, children_state, children, children_dollars}' <<<"$measurement" 2>/dev/null)" || overlay=""
[ -n "$overlay" ] || swallow "measurement unusable"
line="$(event_line "$first_member" "$digest" "$overlay")" || line=""
[ -n "$line" ] || swallow "event unbuildable"
append_lines "$line"
