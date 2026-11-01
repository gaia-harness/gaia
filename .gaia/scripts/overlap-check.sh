#!/usr/bin/env bash
# The deterministic half of the plan run's overlap pass: whether the pass runs
# (route), the branch's changed tests with their layers (changed), and the
# check that stands between the overlap evaluator's proposals and the human
# (check). Dispatching the evaluator and asking the human stay in the step's
# instructions.
#
# Usage:
#   overlap-check.sh route   --root <tree>
#   overlap-check.sh changed --root <tree>
#   overlap-check.sh check   --root <tree> --proposals <file> [--post-fix]
#
# route prints run, skip-no-playwright-change or skip-no-base. changed prints a
# JSON array of {file, layer}. check prints {"kept":[...],"discarded":[...]};
# a kept element carries seam, layer, siblingLayer and a disposition (offer, or
# report-only with a reportReason). --post-fix re-verifies the same proposals
# after the fixer ran, before the commit.
#
# Exit 2 on usage, 3 on unreadable input or a package error, with the reason on
# stderr: a silent empty answer would read as nothing to do.
#
# Bash 3.2 compatible.

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 3
script_root="$(cd "$script_directory/../.." 2>/dev/null && pwd)" || exit 3
library_directory="$script_root/.claude/hooks/lib"
checker_script="$script_directory/overlap/check-proposals.mjs"

die_usage() { printf 'overlap-check: %s\n' "$*" >&2; exit 2; }
die_input() { printf 'overlap-check: %s\n' "$*" >&2; exit 3; }

absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

require_value() { [ "$2" -ge 2 ] || die_usage "$1 needs a value"; }

load_libraries() {
  local library
  for library in \
    "$library_directory/gaia-packages.sh" \
    "$library_directory/audit-base-provenance.sh" \
    "$script_directory/branch-authorship-lib.sh"; do
    [ -f "$library" ] || die_input "cannot load $library"
    # shellcheck source=/dev/null
    . "$library" || die_input "cannot load $library"
  done
  command -v jq >/dev/null 2>&1 || die_input 'jq is not on PATH'
  [ -f "$checker_script" ] || die_input "the checker is missing at $checker_script"
}

# Sets base and package_dir; package_dir stays empty when no web-stack package
# is registered, which leaves every path without a layer. The checker maps
# paths under one package directory, so several web members are refused.
resolve_subject() {
  local root="$1" provenance packages_status=0 members member_names
  gaia_packages_load "$root" || packages_status=$?
  [ "$packages_status" -eq 0 ] || die_input "$GAIA_PACKAGES_ERROR"
  package_dir=''
  has_package_dir=0
  members="$(gaia_packages_web_members)"
  if [ -z "$members" ]; then
    printf 'overlap-check: no package in .gaia/packages.json declares "stack": "web", so no path is mapped to a test layer\n' >&2
  elif [ "$(printf '%s\n' "$members" | grep -c .)" -gt 1 ]; then
    member_names="$(printf '%s\n' "$members" | cut -f1 | paste -sd, - | sed 's/,/, /g')"
    die_input "several packages declare the web stack ($member_names), and the layer mapping reads one package directory. Next step: leave one web-stack package"
  else
    package_dir="$(printf '%s\n' "$members" | cut -f2)"
    has_package_dir=1
  fi
  provenance="$(audit_resolve_base_provenance "$root" default-branch)" || provenance=''
  base=''
  IFS=$'\t' read -r _ _ base <<<"$provenance" || true
}

run_layers() {
  if [ "$has_package_dir" -eq 1 ]; then
    node "$checker_script" layer --package-dir "$package_dir"
  else
    node "$checker_script" layer
  fi
}

cmd_route() {
  local root='' names layered
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) require_value "$1" "$#"; root="$(absolute "$2")"; shift 2 ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$root" ] || die_usage 'route needs --root'
  load_libraries
  resolve_subject "$root"
  if [ -z "$base" ]; then
    printf 'skip-no-base\n'
    return 0
  fi
  names="$(mktemp)" || die_input 'cannot create a temporary file'
  if ! git -C "$root" diff --name-only -z "$base...HEAD" >"$names"; then
    rm -f "$names"
    die_input "cannot list the files changed since $base"
  fi
  layered="$(run_layers <"$names")" || { rm -f "$names"; die_input 'the layer mapping failed'; }
  rm -f "$names"
  if printf '%s' "$layered" | jq -e 'any(.[]; .layer == "e2e")' >/dev/null 2>&1; then
    printf 'run\n'
  else
    printf 'skip-no-playwright-change\n'
  fi
}

cmd_changed() {
  local root='' names
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) require_value "$1" "$#"; root="$(absolute "$2")"; shift 2 ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$root" ] || die_usage 'changed needs --root'
  load_libraries
  resolve_subject "$root"
  if [ -z "$base" ]; then
    printf '[]\n'
    return 0
  fi
  # A deleted file has nothing left to read.
  names="$(mktemp)" || die_input 'cannot create a temporary file'
  if ! git -C "$root" diff --name-only -z --diff-filter=d "$base...HEAD" >"$names"; then
    rm -f "$names"
    die_input "cannot list the files changed since $base"
  fi
  run_layers <"$names" || { rm -f "$names"; die_input 'the layer mapping failed'; }
  rm -f "$names"
}

# shellcheck disable=SC2016
DISPOSITION_JQ='
def answer_for($file; $line): {path: $file, line: $line} | authorship($names; $hunks);
def disposition_of:
  if ._rendered then {disposition: "report-only", reportReason: "rendered"}
  elif ._present == false then
    {disposition: (.disposition // "offer")} + (if .reportReason then {reportReason: .reportReason} else {} end)
  elif $state == "on-default-branch" then {disposition: "report-only", reportReason: "not-authored"}
  else
    .file as $file
    | [._ranges[] | range(.[0]; .[1] + 1) | answer_for($file; .)] as $answers
    | if any($answers[]; . == "not-authored") then {disposition: "report-only", reportReason: "not-authored"}
      elif any($answers[]; . == "unknown") then {disposition: "report-only", reportReason: "authorship-unknown"}
      else {disposition: "offer"} end
  end;
{kept: [.kept[] | disposition_of as $verdict | del(._ranges, ._rendered, ._present, .disposition, .reportReason) + $verdict], discarded: .discarded}
'

cmd_check() {
  local root='' proposals='' post_fix=0 result authorship_json state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) require_value "$1" "$#"; root="$(absolute "$2")"; shift 2 ;;
      --proposals) require_value "$1" "$#"; proposals="$(absolute "$2")"; shift 2 ;;
      --post-fix) post_fix=1; shift ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$proposals" ] || die_usage 'check needs --root and --proposals'
  [ -f "$proposals" ] || die_input "cannot read $proposals"
  load_libraries
  resolve_subject "$root"
  local arguments=(check --root "$root" --proposals "$proposals")
  [ "$has_package_dir" -eq 1 ] && arguments+=(--package-dir "$package_dir")
  [ "$post_fix" -eq 1 ] && arguments+=(--post-fix)
  result="$(node "$checker_script" "${arguments[@]}")" || die_input 'the proposal check failed'
  authorship_json="$(gaia_authorship_for_head "$root")"
  state="$(printf '%s' "$authorship_json" | jq -r '.state')"
  printf '%s' "$result" | jq -c \
    --argjson names "$(printf '%s' "$authorship_json" | jq -c '.names')" \
    --argjson hunks "$(printf '%s' "$authorship_json" | jq -c '.hunks')" \
    --arg state "$state" \
    "$GAIA_AUTHORSHIP_JQ $DISPOSITION_JQ" || die_input 'cannot build the check result'
}

[ "$#" -ge 1 ] || die_usage 'usage: overlap-check.sh route|changed|check ...'
subcommand="$1"
shift
case "$subcommand" in
  route) cmd_route "$@" ;;
  changed) cmd_changed "$@" ;;
  check) cmd_check "$@" ;;
  *) die_usage "unknown subcommand $subcommand" ;;
esac
