#!/usr/bin/env bash
# shellcheck shell=bash
#
# Removes the `unowned:` entries a newly added roster member makes overbroad.
#
#   roster-prune-overbroad.sh --root <dir> --member <name> [--member <name>]...
#
# /update-gaia appends a GAIA-authored member to an adopter's existing
# `.gaia/audit-ci.yml`. When that member claims paths the adopter had declared
# ownerless (an `unowned:` entry such as `scripts/**`), the entry now reaches a
# path a member owns, and the roster check fails it as `overbroad-unowned-glob`,
# which the pre-commit hook would turn into a blocked update commit. This script
# runs the checker under <dir>, and for each overbroad finding whose witness is
# owned by a NAMED member deletes that one list item from the `unowned:` block.
# An entry made overbroad by a member that was not named is left alone.
#
# Only list items inside the `unowned:` block change. Every comment, blank line
# and other line stays byte for byte. An item may be written `- "g"`, `- 'g'` or
# `- g`, with an optional trailing comment. The roster is rewritten through a
# temp file in its own directory and an atomic `mv`.
#
# Output, one line per removal on stdout:
#   REMOVED<TAB><glob><TAB><witness path><TAB><owner>
#
# Idempotent: a second run finds nothing overbroad and changes nothing. When the
# removed entry also covered paths no member owns, one stderr line says so (the
# roster check now reports them as ownerless, and the quality gate before the
# update commit surfaces that finding); the exit stays 0, the removal is right.
#
# Exit: 0 ok (removals or none) | 1 the checker is missing or failed to run |
#       2 usage error or an unreadable roster.
#
# Bash 3.2 safe. Never changes directory.

set -u

usage() {
  printf 'usage: roster-prune-overbroad.sh --root <dir> --member <name> [--member <name>]...\n' >&2
  exit 2
}

root=""
members=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || usage
      root="$2"
      shift 2
      ;;
    --member)
      [ $# -ge 2 ] || usage
      [ -n "$2" ] || usage
      members="${members}${2}"$'\n'
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$root" ] && [ -n "$members" ] || usage

roster="${root}/.gaia/audit-ci.yml"
checker="${root}/.gaia/scripts/verify-audit-roster.sh"

if [ ! -f "$roster" ] || [ ! -r "$roster" ]; then
  printf 'roster-prune-overbroad: roster not readable: %s\n' "$roster" >&2
  exit 2
fi
if [ ! -f "$checker" ]; then
  printf 'roster-prune-overbroad: roster check not found: %s\n' "$checker" >&2
  exit 1
fi

# Runs the checker into the named variable; exit 0 (clean) and 1 (findings) are
# both a successful run, anything else means the checker did not run.
run_checker() {
  local output status
  output="$(bash "$checker" --root "$root" 2>&1)"
  status=$?
  if [ "$status" -gt 1 ]; then
    printf 'roster-prune-overbroad: the roster check failed to run (exit %s)\n' "$status" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  checker_output="$output"
}

# One tab-separated `glob<TAB>witness<TAB>owner` record per overbroad finding.
overbroad_records() {
  printf '%s\n' "$1" | awk '
    /^verify-audit-roster: FAIL overbroad-unowned-glob$/ { want = 1; glob = ""; next }
    want && /^  glob:[[:space:]]+/ { glob = $0; sub(/^  glob:[[:space:]]+/, "", glob); next }
    want && /^  witness:[[:space:]]+/ {
      rest = $0
      sub(/^  witness:[[:space:]]+/, "", rest)
      if (match(rest, /.* \(owned by /) && glob != "") {
        owner = substr(rest, RLENGTH + 1)
        sub(/\)$/, "", owner)
        printf "%s\t%s\t%s\n", glob, substr(rest, 1, RLENGTH - length(" (owned by ")), owner
      }
      want = 0
    }
  '
}

is_named_member() {
  printf '%s' "$members" | grep -qxF -- "$1"
}

# Deletes every list item equal to glob `$1` inside the `unowned:` block of the
# roster named `$2`, writing the result to `$3`.
drop_unowned_item() {
  awk -v target="$1" '
    function item_value(line,    v, q, rest, hash) {
      v = line
      sub(/^[ \t]*-[ \t]+/, "", v)
      q = substr(v, 1, 1)
      if (q == "\"" || q == "\047") {
        rest = substr(v, 2)
        hash = index(rest, q)
        if (hash == 0) return v
        return substr(rest, 1, hash - 1)
      }
      hash = match(v, /[ \t]+#/)
      if (hash > 0) v = substr(v, 1, hash - 1)
      sub(/[ \t]+$/, "", v)
      return v
    }
    /^unowned:[ \t]*(#.*)?$/ { inside = 1; print; next }
    inside && /^[^ \t#]/ { inside = 0 }
    inside && /^[ \t]*-[ \t]+/ && item_value($0) == target { next }
    { print }
  ' "$2" >"$3"
}

run_checker
first_output="$checker_output"
records="$(overbroad_records "$first_output")"

# A finding the parser cannot read must not look like a clean roster.
if [ -z "$records" ] && printf '%s\n' "$first_output" | grep -q 'overbroad-unowned-glob'; then
  printf 'roster-prune-overbroad: the roster check reported overbroad-unowned-glob in a format that was not recognized\n' >&2
  printf '%s\n' "$first_output" | awk '/overbroad-unowned-glob/ { show = 1 } show' >&2
  exit 1
fi

removed=0
if [ -n "$records" ]; then
  while IFS="$(printf '\t')" read -r glob witness owner; do
    [ -n "$glob" ] || continue
    is_named_member "$owner" || continue
    temp_roster="$(mktemp "${roster}.prune.XXXXXX")" || {
      printf 'roster-prune-overbroad: cannot write beside %s\n' "$roster" >&2
      exit 2
    }
    cp -p "$roster" "$temp_roster"
    drop_unowned_item "$glob" "$roster" "$temp_roster"
    if cmp -s "$roster" "$temp_roster"; then
      rm -f "$temp_roster"
      continue
    fi
    mv "$temp_roster" "$roster"
    removed=$((removed + 1))
    printf 'REMOVED\t%s\t%s\t%s\n' "$glob" "$witness" "$owner"
  done <<EOF
$records
EOF
fi

if [ "$removed" -gt 0 ]; then
  run_checker
  if ! printf '%s\n' "$first_output" | grep -q 'FAIL ownerless-path' &&
    printf '%s\n' "$checker_output" | grep -q 'FAIL ownerless-path'; then
    printf 'roster-prune-overbroad: a removed entry also covered paths no member owns; add a narrower unowned entry for them\n' >&2
  fi
fi

exit 0
