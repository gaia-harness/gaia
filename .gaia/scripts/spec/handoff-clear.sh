#!/usr/bin/env bash
# Creates a plan's handoffs folder and clears the handoff files of one unit, so
# a dispatcher pre-clears a path under a single allow entry instead of an
# absolute-path rm and mkdir that no allow rule matches.
#
# Usage: handoff-clear.sh <plan-dir> <unit> [<k>]
#
#   <plan-dir>  absolute path of an existing plan folder that is not a symlink.
#   <unit>      `planner`, or `phase-<N>-task-<name>` (digits, then lowercase
#               letters, digits and hyphens).
#   <k>         optional positive integer, the yield number.
#
# Creates <plan-dir>/handoffs when absent. With <k> removes
# <plan-dir>/handoffs/<unit>-yield-<k>.md; without it, every
# <unit>-yield-<number>.md there. Only regular files are removed, never a
# symlink or a directory, and nothing is removed recursively. A missing target
# is not an error.
#
# Refuses (exit 1) when <plan-dir> is a symlink, when handoffs exists as
# anything but a real directory, or when its resolved path is not directly
# inside the resolved <plan-dir>: a symlinked handoffs folder would otherwise
# send the removal to files outside the plan.
#
# Called by the planner, the plan.md planner-yield steps and the generated
# ORCHESTRATOR.md before each executor or planner dispatch; a non-zero exit is a
# stop for the caller.
#
# Exit codes: 0 done (nothing to remove is still 0); 1 refused, reason on one
# stderr line; 2 usage error. No stdout.
#
# Bash 3.2 compatible; BSD and GNU tools.
set -uo pipefail

usage() {
  printf 'usage: handoff-clear.sh <plan-dir> <unit> [<k>]\n' >&2
  exit 2
}

refuse() {
  printf 'handoff-clear: %s\n' "$1" >&2
  exit 1
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
plan_directory="$1"
unit="$2"
yield_number="${3-}"

case "$plan_directory" in
  /*) ;;
  *) usage ;;
esac
plan_directory="${plan_directory%/}"
[ -n "$plan_directory" ] || usage
if [ ! -d "$plan_directory" ]; then
  printf 'handoff-clear: plan folder not found: %s\n' "$plan_directory" >&2
  exit 2
fi

if [ "$unit" != planner ] && ! printf '%s\n' "$unit" | grep -Eq '^phase-[0-9]+-task-[a-z0-9][a-z0-9-]*$'; then
  printf 'handoff-clear: unit must be planner or phase-<N>-task-<name>: %s\n' "$unit" >&2
  exit 2
fi
if [ "$#" -eq 3 ] && ! printf '%s\n' "$yield_number" | grep -Eq '^[1-9][0-9]*$'; then
  printf 'handoff-clear: yield number must be a positive integer: %s\n' "$yield_number" >&2
  exit 2
fi

[ ! -L "$plan_directory" ] || refuse "plan folder is a symlink: $plan_directory"

handoffs="$plan_directory/handoffs"
if [ -L "$handoffs" ]; then
  refuse "handoffs is a symlink: $handoffs"
elif [ -e "$handoffs" ] && [ ! -d "$handoffs" ]; then
  refuse "handoffs exists and is not a directory: $handoffs"
elif [ ! -e "$handoffs" ]; then
  mkdir "$handoffs" 2>/dev/null || refuse "cannot create $handoffs"
fi

resolved_plan="$(cd -P "$plan_directory" 2>/dev/null && pwd)" || refuse "cannot resolve $plan_directory"
resolved_handoffs="$(cd -P "$handoffs" 2>/dev/null && pwd)" || refuse "cannot resolve $handoffs"
[ "$resolved_handoffs" = "$resolved_plan/handoffs" ] || refuse "handoffs resolves outside the plan folder: $resolved_handoffs"

remove_regular_file() {
  if [ -f "$1" ] && [ ! -L "$1" ]; then
    rm -f -- "$1" || refuse "cannot remove $1"
  fi
}

if [ "$#" -eq 3 ]; then
  remove_regular_file "$handoffs/$unit-yield-$yield_number.md"
else
  prefix="$unit-yield-"
  for candidate in "$handoffs/$prefix"*.md; do
    name="${candidate##*/}"
    number="${name#"$prefix"}"
    number="${number%.md}"
    # A longer unit name can share this prefix (phase-1-task-a and
    # phase-1-task-a-yield-2); only the digits-only remainder is this unit's.
    case "$number" in
      '' | *[!0-9]*) continue ;;
    esac
    remove_regular_file "$candidate"
  done
fi
exit 0
