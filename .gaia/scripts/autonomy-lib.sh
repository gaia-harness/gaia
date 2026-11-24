#!/usr/bin/env bash
# shellcheck shell=bash
#
# The one reader of the autonomy switch, <main>/.gaia/local/protected/autonomy.json.
# Every unattended behaviour sources this library; nothing else parses the
# file. Only a human writes it, from their own terminal; block-audit-loop-write.sh
# denies Claude's writes to the protected folder. The file's fields and the
# writer command: wiki/concepts/Autonomy Switch.md.
#
# Fail closed. A missing file, a symlinked file or folder (or a symlinked
# .gaia or .gaia/local above it), a file that is not exactly the documented
# object, `enabled: false`, a past `expires_at`, a main
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
#
# The functions below serve the gate, .claude/hooks/autonomy-gate.sh.
#
# autonomy_log_file [directory]
#   Prints the decision log's path, <main>/.gaia/local/protected/
#   autonomy-log.jsonl, for the checkout holding `directory`. Returns 1 when
#   the main checkout cannot be resolved.
# autonomy_log_decision <session_id> <branch> <header> <option> [directory]
#   Appends one line to the decision log: {time (ISO-8601 UTC), session_id,
#   branch, header, option}. The gate is its only caller; the protected-folder guard denies
#   Claude's own writes. Returns 1, writing nothing, when the main checkout
#   cannot be resolved, jq is missing, the log or its folder is a symlink, or
#   the append fails.
# autonomy_human_only_header <header>
#   Returns 0 when the header is on the human-only list,
#   .gaia/autonomy-human-only-headers.json (`headers`, an array of strings),
#   1 when it is not, and 2 when the file cannot be read.
# autonomy_protected_globs <repository root>
#   Prints the protected set, one repo-relative glob per line: each `root`
#   glob of .gaia/autonomy-protected-paths.json as written, then each `package`
#   glob joined to every package path the registry
#   (.claude/hooks/lib/gaia-packages.sh) lists under that root. Returns 1,
#   printing nothing, when the file or the registry cannot be read.
# autonomy_relative_path <physical path> <main root> [tree root]
#   Prints the path relative to the checkout holding it: the linked worktree
#   <tree root> first, then any linked worktree under
#   <main>/.claude/worktrees/<name>/, else the main checkout. Returns 1 for a
#   path outside all of them.
# autonomy_protected_match <repo-relative path> <globs>
#   Returns 0 when the path matches one of the newline-separated globs, read
#   as `case` patterns: `*` and `**` both match any run, `/` included.

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
  # A symlinked .gaia or .gaia/local above the folder passes the test above but
  # puts the file where block-audit-loop-write.sh's physical path resolution
  # allows a Write, so the folder must also sit physically where the placement
  # rule says.
  local physical_folder physical_main
  physical_folder=$(cd -P -- "${file%/*}" 2>/dev/null && pwd -P) || return 1
  physical_main=$(cd -P -- "${file%/.gaia/local/protected/autonomy.json}" 2>/dev/null && pwd -P) || return 1
  [ "$physical_folder" = "$physical_main/.gaia/local/protected" ] || return 1
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

_autonomy_data_directory="$_autonomy_library_directory/.."

autonomy_log_file() {
  local main_root
  main_root=$(gaia_resolve_main_root "${1:-$PWD}" 2>/dev/null) || return 1
  [ -n "$main_root" ] || return 1
  printf '%s/.gaia/local/protected/autonomy-log.jsonl\n' "$main_root"
}

autonomy_log_decision() {
  local log folder
  log=$(autonomy_log_file "${5:-$PWD}") || return 1
  command -v jq >/dev/null 2>&1 || return 1
  folder="${log%/*}"
  # The placement rule the switch reader holds: a symlinked log or folder would
  # put the record where the protected-folder guard never looks.
  [ ! -L "$folder" ] && [ ! -L "$log" ] || return 1
  mkdir -p "$folder" 2>/dev/null || return 1
  jq -nc --arg session_id "$1" --arg branch "$2" --arg header "$3" --arg option "$4" \
    '{time: (now | floor | todate), session_id: $session_id, branch: $branch, header: $header, option: $option}' \
    >>"$log" 2>/dev/null
}

autonomy_human_only_header() {
  local file="$_autonomy_data_directory/autonomy-human-only-headers.json" answer
  command -v jq >/dev/null 2>&1 || return 2
  answer=$(jq -r --arg header "${1-}" '
    if (.headers | type) == "array" and all(.headers[]; type == "string")
    then (any(.headers[]; . == $header) | tostring) else empty end' "$file" 2>/dev/null) || return 2
  case "$answer" in
    true) return 0 ;;
    false) return 1 ;;
    *) return 2 ;;
  esac
}

autonomy_protected_globs() {
  local root="${1-}" file="$_autonomy_data_directory/autonomy-protected-paths.json"
  local status=0 root_globs package_globs name package_path glob
  command -v jq >/dev/null 2>&1 || return 1
  local valid='def strings_only: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
    (.root | strings_only) and (.package | strings_only)'
  root_globs=$(jq -r "if $valid then .root[] else empty end" "$file" 2>/dev/null) || return 1
  package_globs=$(jq -r "if $valid then .package[] else empty end" "$file" 2>/dev/null) || return 1
  [ -n "$root_globs" ] && [ -n "$package_globs" ] || return 1
  # shellcheck source=../../.claude/hooks/lib/gaia-packages.sh
  . "$_autonomy_data_directory/../.claude/hooks/lib/gaia-packages.sh" 2>/dev/null || return 1
  gaia_packages_load "$root" || status=$?
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$root_globs"
  while IFS=$'\t' read -r name package_path; do
    [ -n "$name" ] && [ "$package_path" != . ] || continue
    while IFS= read -r glob; do
      printf '%s/%s\n' "$package_path" "$glob"
    done <<<"$package_globs"
  done <<<"$(gaia_packages_list)"
}

autonomy_relative_path() {
  local path="${1-}" main_root="${2-}" tree_root="${3-}" rest
  if [ -n "$tree_root" ] && [ "$tree_root" != "$main_root" ]; then
    case "$path" in
      "$tree_root"/*)
        printf '%s\n' "${path#"$tree_root/"}"
        return 0
        ;;
    esac
  fi
  case "$path" in
    "$main_root/.claude/worktrees/"*/*)
      rest="${path#"$main_root/.claude/worktrees/"}"
      printf '%s\n' "${rest#*/}"
      ;;
    "$main_root"/*) printf '%s\n' "${path#"$main_root/"}" ;;
    *) return 1 ;;
  esac
}

autonomy_protected_match() {
  local path="${1-}" glob
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2254 # the glob is a pattern on purpose
    case "$path" in
      $glob) return 0 ;;
    esac
  done <<<"${2-}"
  return 1
}
