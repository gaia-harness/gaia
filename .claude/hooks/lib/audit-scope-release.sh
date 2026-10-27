#!/usr/bin/env bash
# The release-change skip of the ownership classifier. Sourced by audit-scope.sh
# from its own directory, never on its own; does no work at source time. It
# decides ownership exactly as audit-scope.sh does, so the two always ship and
# change together.
#
# A roster member whose `skip_gaia_release_changes` is the literal `true` does
# not own a file GAIA itself ships (class `owned` in .gaia/manifest.json) on a
# branch that applies a GAIA release. Such a file is reviewed in GAIA's own
# repository; what an adopter wrote around it still routes to the member. The
# roster's glob dialect cannot exclude a path, which is why this is a key the
# classifier reads rather than a glob.
#
# The release signal is a change to .gaia/VERSION between the branch's merge
# base and its head. The updater writes that file last and no ordinary branch
# touches it; measuring from the merge base rather than the base tip keeps a
# feature branch cut before the base took an update from reading as one. On an
# ordinary branch nothing is dropped, so an adopter's own edit to a shipped file
# (the updater three-way merges an edited owned file and keeps the edit) still
# routes to the member.
#
# Accepted, not defended: a branch that both bumps .gaia/VERSION and edits the
# manifest can mark its own script `owned` and exempt it. Doing that takes a pull
# request author who already controls the repository's merges.
#
# Every failure direction is over-review, never under-review:
#   - An older classifier reading a roster that carries the key (a release
#     applied part way) ignores it and dispatches the member.
#   - No jq, a manifest that is absent or does not parse on either side, a
#     .gaia/VERSION absent on either side, and an unresolvable merge base each
#     leave the context disarmed, so nothing is dropped.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`.
# Never `cd`. Membership of a path in the owned set is a quoted `case` test on a
# newline-framed string, so classifying a path spawns no process.

# Emits one `SKIP <member>` line per auditors: member whose key carries the RAW
# value `true` (comments stripped, never unquoted, so a quoted "true" is not
# read as true). A separate pass, never folded into the ownership parser, whose
# output is the contract every dispatch and gate consumer reads. The ownership
# parser ends a member's `globs:` list on any `[A-Za-z_]+:` key, which is why
# the key is snake_case and placed after `globs:`.
_audit_scope_parse_release_skip() {
  awk "$_AUDIT_SCOPE_GLOB_AWK"'
    BEGIN { in_auditors = 0; member = "" }
    {
      raw = $0
      if (raw ~ /^auditors[[:space:]]*:/) { in_auditors = 1; next }
      if (!in_auditors) next
      if (raw ~ /^[A-Za-z_]/) { in_auditors = 0; next }
      if (raw ~ /^[[:space:]]*$/) next
      if (raw ~ /^[[:space:]]*#/) next
      if (raw ~ /^[[:space:]]*-[[:space:]]+name[[:space:]]*:/) {
        v = raw
        sub(/^[[:space:]]*-[[:space:]]+name[[:space:]]*:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        member = unq(v)
        next
      }
      if (raw ~ /^[[:space:]]+skip_gaia_release_changes[[:space:]]*:/) {
        v = raw
        sub(/^[[:space:]]+skip_gaia_release_changes[[:space:]]*:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        sub(/[[:space:]]+$/, "", v)
        if (v == "true" && member != "") print "SKIP " member
        next
      }
    }
  '
}

# audit_roster_release_skip_members <config-file>
#
# Prints each member whose `skip_gaia_release_changes` is the literal `true`,
# one per line, in roster order. Exit 1 with nothing on stdout when the file is
# absent or carries no parseable roster; a readable roster with no keyed member
# prints nothing and exits 0.
audit_roster_release_skip_members() {
  local config_file="${1:-}" records
  [ -n "$config_file" ] && [ -f "$config_file" ] || return 1
  records="$(_audit_scope_parse_auditors < "$config_file")"
  [ -n "$records" ] || return 1
  _audit_scope_parse_release_skip < "$config_file" | awk '!seen[$2]++ { print $2 }'
}

# _audit_scope_release_disarm <reason>: drops any armed owned set.
_audit_scope_release_disarm() {
  _AUDIT_SCOPE_RELEASE_ARMED=0
  _AUDIT_SCOPE_RELEASE_REASON="$1"
  _AUDIT_SCOPE_RELEASE_OWNED=""
  _AUDIT_SCOPE_RELEASE_OWNED_COUNT=0
}

# _audit_scope_release_reset <config-file>: called by audit_scope_init. Reads
# the skip-member set (newline-framed) and disarms whatever an earlier init or
# context call left, so a re-init never inherits another tree's owned set.
_audit_scope_release_reset() {
  local config_file="$1" records name members=""
  _AUDIT_SCOPE_SKIP_MEMBERS=""
  # Every init runs on hook hot paths, so a roster that never names the key
  # pays one grep rather than the parse.
  if [ ! -f "$config_file" ] || ! grep -q skip_gaia_release_changes "$config_file" 2>/dev/null; then
    _audit_scope_release_disarm no-skip-member
    return 0
  fi
  records="$(_audit_scope_parse_release_skip < "$config_file")"
  while read -r _ name; do
    [ -z "$name" ] || members="${members}${name}"$'\n'
  done <<EOF
$records
EOF
  [ -z "$members" ] || _AUDIT_SCOPE_SKIP_MEMBERS=$'\n'"${members}"
  if [ -n "$_AUDIT_SCOPE_SKIP_MEMBERS" ]; then
    _audit_scope_release_disarm not-requested
  else
    _audit_scope_release_disarm no-skip-member
  fi
}

# _audit_scope_release_owned_keys <root> <tree-ish>: prints the manifest keys
# whose class is `owned` at <tree-ish>; non-zero when the manifest is absent or
# does not parse. The blob is read into a variable first because an absent blob
# piped into jq reads as an empty, successfully parsed input.
_audit_scope_release_owned_keys() {
  local manifest
  manifest="$(git -C "$1" show "$2:.gaia/manifest.json" 2>/dev/null)" || return 1
  [ -n "$manifest" ] || return 1
  printf '%s\n' "$manifest" | jq -r '.files | to_entries[] | select(.value == "owned") | .key' 2>/dev/null
}

# audit_scope_release_context <root> <base-ref> [<head-tree-ish> [<merge-base>]]
#
# Arms the release context when every condition holds; otherwise leaves it
# disarmed with a reason. Always returns 0 and never writes stdout, so a
# consumer under errexit can call it bare. <head-tree-ish> may be a bare tree
# id (the fix verifier digests a tree it has not committed yet), which has no
# merge base of its own: the caller passes the merge base it already resolved,
# and that value is used as is.
audit_scope_release_context() {
  local root="${1:-}" base_reference="${2:-}" head="${3:-HEAD}" merge_base="${4:-}"
  local base_version head_version base_owned head_owned owned

  if [ -z "${_AUDIT_SCOPE_SKIP_MEMBERS:-}" ]; then
    _audit_scope_release_disarm no-skip-member
    return 0
  fi
  _audit_scope_release_disarm not-requested

  if [ -z "$merge_base" ] && [ -n "$root" ] && [ -n "$base_reference" ]; then
    merge_base="$(git -C "$root" merge-base "$base_reference" "$head" 2>/dev/null)" || merge_base=""
  fi
  if [ -z "$root" ] || [ -z "$merge_base" ]; then
    _audit_scope_release_disarm no-merge-base
    return 0
  fi

  base_version="$(git -C "$root" rev-parse --verify --quiet "${merge_base}:.gaia/VERSION" 2>/dev/null)" || base_version=""
  head_version="$(git -C "$root" rev-parse --verify --quiet "${head}:.gaia/VERSION" 2>/dev/null)" || head_version=""
  if [ -z "$base_version" ] || [ -z "$head_version" ] || [ "$base_version" = "$head_version" ]; then
    _audit_scope_release_disarm no-version-change
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    _audit_scope_release_disarm no-jq
    return 0
  fi
  if ! base_owned="$(_audit_scope_release_owned_keys "$root" "$merge_base")" \
    || ! head_owned="$(_audit_scope_release_owned_keys "$root" "$head")"; then
    _audit_scope_release_disarm manifest-unreadable
    return 0
  fi

  owned="$(printf '%s\n%s\n' "$base_owned" "$head_owned" | awk 'NF && !seen[$0]++')"
  _AUDIT_SCOPE_RELEASE_ARMED=1
  _AUDIT_SCOPE_RELEASE_REASON=""
  _AUDIT_SCOPE_RELEASE_OWNED=$'\n'"${owned}"$'\n'
  _AUDIT_SCOPE_RELEASE_OWNED_COUNT=0
  [ -z "$owned" ] || _AUDIT_SCOPE_RELEASE_OWNED_COUNT="$(printf '%s\n' "$owned" | awk 'END { print NR }')"
  return 0
}

# audit_scope_release_context_state: `armed <owned-path-count>` or
# `disarmed <reason>`. For tests and diagnostics only; no consumer branches on
# it. `not-requested` means a keyed member exists and no context call has run
# since the last init.
audit_scope_release_context_state() {
  if [ "${_AUDIT_SCOPE_RELEASE_ARMED:-0}" = 1 ]; then
    printf 'armed %s\n' "${_AUDIT_SCOPE_RELEASE_OWNED_COUNT:-0}"
  else
    printf 'disarmed %s\n' "${_AUDIT_SCOPE_RELEASE_REASON:-no-skip-member}"
  fi
}

# _audit_scope_release_path_owned <path>: exit 0 when the context is armed and
# <path> is in the owned set. In-process; the quoted expansion makes any glob
# character in the path literal.
_audit_scope_release_path_owned() {
  [ "${_AUDIT_SCOPE_RELEASE_ARMED:-0}" = 1 ] || return 1
  case "$_AUDIT_SCOPE_RELEASE_OWNED" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# _audit_scope_release_member_skips <member>: exit 0 when <member> is keyed.
_audit_scope_release_member_skips() {
  case "${_AUDIT_SCOPE_SKIP_MEMBERS:-}" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}
