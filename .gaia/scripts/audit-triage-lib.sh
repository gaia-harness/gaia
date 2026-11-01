# shellcheck shell=bash
#
# The one definition of an honored triage mark, shared by the dispositions
# check (which grades against it) and the audit loop evaluator (whose default
# stop exempts it). Sourced, never executed; defines variables and one
# function and runs nothing at source time. Bash 3.2 compatible.
#
# A mark is honored when the member that wrote it is a triage member, the
# roster gives that member the entry's path, the entry is security false and
# its severity is not critical. The roster half is a shell lookup
# (_roster_owned_indexes); the rest is the jq fragment below, which reads
# `$triage_members` (pass _TRIAGE_MEMBERS) and expects `.triage` already
# bounded by the roster lookup.

# The members whose sidecar triage mark can be honored. Empty by default, so a
# mark is ignored and the finding is disposed like any other.
_TRIAGE_MEMBERS='[]'
# gaia:maintainer-only:start
# The maintainer members the harness triage threshold governs.
_TRIAGE_MEMBERS='["code-audit-maintainer-shell","code-audit-maintainer-node"]'
# gaia:maintainer-only:end

# shellcheck disable=SC2016
_GAIA_TRIAGE_HONORED_JQ='def triage_honored: .triage == true and .security == false and .severity != "critical" and (.member | IN($triage_members[]));'

# _roster_owned_indexes <audited-root> <scripts-directory> <lookup>: the JSON
# array of lookup indexes whose triage-marked allowlisted entry the roster
# gives to that same member. The roster library lives with the hooks, two
# levels above <scripts-directory>; it is sourced only when a candidate
# exists, and an absent library or unreadable roster honors nothing. Call it
# in a command substitution: the roster library's globals stay in that
# subshell. rc 3 on a jq failure.
_roster_owned_indexes() {
  local root="$1" candidates index member path owned="[]" library="$2/../../.claude/hooks/lib/audit-scope.sh"
  candidates="$(printf '%s' "$3" | jq -r --argjson triage_members "$_TRIAGE_MEMBERS" \
    'to_entries[] | select(.value.triage == true and (.value.member | IN($triage_members[])) and (.value.path | type) == "string")
     | "\(.key)\t\(.value.member)\t\(.value.path)"')" || return 3
  if [ -n "$candidates" ] && [ -f "$library" ]; then
    # shellcheck source=/dev/null
    . "$library" 2>/dev/null
    # No release context is armed: only the triage members write these marks, and a release-skip member never triages.
    if type audit_owner_for_path >/dev/null 2>&1 && audit_scope_init "$root" 2>/dev/null; then
      while IFS=$'\t' read -r index member path; do
        [ -n "$path" ] || continue
        [ "$(audit_owner_for_path "$path")" = "$member" ] || continue
        owned="$(jq -n -c --argjson owned "$owned" --argjson index "$index" '$owned + [$index]')" || return 3
      done <<<"$candidates"
    fi
  fi
  printf '%s\n' "$owned"
}
