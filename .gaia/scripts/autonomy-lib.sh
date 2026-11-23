#!/usr/bin/env bash
# shellcheck shell=bash
#
# The one reader of the autonomy switch, <main>/.gaia/local/protected/autonomy.json.
# Every unattended behaviour sources this library; nothing else parses the
# file. Only a human writes it, from their own terminal; block-audit-loop-write.sh
# denies Claude's writes to the protected folder. The file's fields and the
# writer command: wiki/concepts/Autonomy Switch.md.
#
# Fail closed. A missing file, a symlinked file or folder, a file that is not
# exactly the documented object, `enabled: false`, a past `expires_at`, a main
# checkout that cannot be resolved, and a missing jq all read as not
# autonomous, never as an error. The two audit budget fields are the exception
# to "exactly": missing, non-integer or negative reads as 0 and the file stays
# valid. Expiry is read against the clock on every call; nothing is cached.
#
# autonomy_file [directory]
#   Prints the switch's path for the checkout holding `directory` (default:
#   the working directory). Returns 1 when the main checkout cannot be resolved.
# autonomy_active [directory]
#   Returns 0 when the switch is live, 1 otherwise. Prints nothing.
# autonomy_field <name> [directory]
#   Prints one validated field of a live switch: enabled, expires_at
#   (YYYY-MM-DDTHH:MM:SSZ), may_merge (true|false), audit_extra_units_per_pr or
#   audit_units_pool (a whole number). Returns 1, printing nothing, when the
#   switch is not live, and 2 for an unknown name.

_autonomy_library_directory="${BASH_SOURCE[0]%/*}"
[ "$_autonomy_library_directory" != "${BASH_SOURCE[0]}" ] || _autonomy_library_directory=.
# shellcheck source=main-root-lib.sh
. "$_autonomy_library_directory/main-root-lib.sh"

autonomy_file() {
  local main_root
  main_root=$(gaia_resolve_main_root "${1:-$PWD}" 2>/dev/null) || return 1
  [ -n "$main_root" ] || return 1
  printf '%s/.gaia/local/protected/autonomy.json\n' "$main_root"
}

# _autonomy_read [directory]: print the live switch as one tab-separated line,
# "<enabled> <expires_at> <may_merge> <extra units> <units pool>", or return 1.
_autonomy_read() {
  local file record
  file=$(autonomy_file "${1:-$PWD}") || return 1
  # A symlink would let the file's content live somewhere the guard's
  # placement rule never covers.
  [ ! -L "$file" ] && [ ! -L "${file%/*}" ] && [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # The round trip through todate rejects a well-shaped but impossible date.
  record=$(jq -r '
    def whole_or_zero: if type == "number" and . == floor and . >= 0 then . else 0 end;
    if type != "object" then empty
    elif (keys - ["enabled", "expires_at", "may_merge", "audit_extra_units_per_pr", "audit_units_pool"]) != [] then empty
    elif (.enabled | type) != "boolean" or (.may_merge | type) != "boolean" or (.expires_at | type) != "string" then empty
    elif (.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not) then empty
    else (.expires_at | try fromdateiso8601 catch null) as $expiry
      | if $expiry == null or ($expiry | todate) != .expires_at then empty
        elif .enabled != true or $expiry <= now then empty
        else [.enabled, .expires_at, .may_merge, (.audit_extra_units_per_pr | whole_or_zero), (.audit_units_pool | whole_or_zero)] | map(tostring) | @tsv
        end
    end' "$file" 2>/dev/null) || return 1
  [[ $record =~ ^true$'\t'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'\t'(true|false)$'\t'[0-9]+$'\t'[0-9]+$ ]] || return 1
  printf '%s\n' "$record"
}

autonomy_active() {
  _autonomy_read "${1:-$PWD}" >/dev/null
}

autonomy_field() {
  local column record
  case "${1:-}" in
    enabled) column=1 ;;
    expires_at) column=2 ;;
    may_merge) column=3 ;;
    audit_extra_units_per_pr) column=4 ;;
    audit_units_pool) column=5 ;;
    *) return 2 ;;
  esac
  record=$(_autonomy_read "${2:-$PWD}") || return 1
  printf '%s\n' "$record" | cut -f "$column"
}
