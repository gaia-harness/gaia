#!/usr/bin/env bash
# shellcheck shell=bash
#
# pr-review-guard.sh: the before/after check around the read-only pull request
# reviewer. The reviewer is read-only by tool grant and by the read guard hook;
# this script is the backstop that proves it changed nothing.
#
#   pr-review-guard.sh snapshot --root <R> --run-folder <D> --pr <N> --out <file>
#   pr-review-guard.sh compare  --before <file> --after <file> [--output-file <path>]
#
# snapshot refuses a dirty tree (untracked files count), otherwise writes one
# JSON file holding the tree listing, a path and content-hash listing of the
# local audit state and of the run folder, and HEAD's commit statuses.
# compare captures the same state again into --after, from the root and run
# folder the snapshot recorded, and reports the first difference in this order:
# the tree, the audit state, the commit statuses. --output-file names the one
# file the tree listing ignores: the reviewer's own output.
#
# Exit 0 clean, 1 the first difference (one line on stdout), 2 usage or an
# environment that cannot answer (no jq, no hash tool, a `gh` that fails: a
# status list that cannot be read is never an empty list).
#
# Order per attempt: record attempt-open, snapshot, dispatch, compare, record
# attempt-close. No record-script call runs between snapshot and compare, so
# the record's own writes fall outside the window. The snapshot file and the
# reviewer's output belong in the session scratchpad: a file under the local
# state root would read as a change to the audit state it sits in.
#
# Limit: hashes are of file content, so a rewrite with identical bytes reads
# as no change, which is the safe direction for a guard against edits.
set -euo pipefail

_script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=main-root-lib.sh
. "$_script_directory/main-root-lib.sh"

usage_error() {
  printf 'pr-review-guard.sh: %s\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || usage_error 'jq is required'

# hash_file <path>: the content hash of one file, on macOS and Linux alike.
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | cut -d' ' -f1
  else
    usage_error 'no sha256sum or shasum on PATH'
  fi
}

# dirty_paths <root> <output-file>: the sorted porcelain paths of <root>, one
# per line, untracked files included, minus the output file.
dirty_paths() {
  local root="$1" output_file="$2" line path relative_output=''
  if [ -n "$output_file" ]; then
    case "$output_file" in
      "$root"/*) relative_output="${output_file#"$root"/}" ;;
      /*) ;;
      *) relative_output="$output_file" ;;
    esac
  fi
  git -C "$root" status --porcelain --untracked-files=all | while IFS= read -r line; do
    path="${line:3}"
    case "$path" in
      *' -> '*) path="${path##* -> }" ;;
    esac
    [ -n "$relative_output" ] && [ "$path" = "$relative_output" ] && continue
    printf '%s\n' "$path"
  done | LC_ALL=C sort
}

# join_lines: stdin lines as one comma-separated line.
join_lines() {
  paste -sd, -
}

# folder_listing <main-root> <folder>: a JSON object mapping each file under
# <folder> to its content hash, keyed by the path relative to <main-root> when
# inside it. An absent folder is an empty object.
folder_listing() {
  local main_root="$1" folder="$2" file key
  [ -d "$folder" ] || {
    printf '{}'
    return 0
  }
  find "$folder" -type f | LC_ALL=C sort | while IFS= read -r file; do
    case "$file" in
      "$main_root"/*) key="${file#"$main_root"/}" ;;
      *) key="$file" ;;
    esac
    jq -n --arg key "$key" --arg hash "$(hash_file "$file")" '{($key): $hash}'
  done | jq -s 'add // {}'
}

# capture_state <root> <run-folder> <pr> <output-file>: print the state JSON.
capture_state() {
  local root="$1" run_folder="$2" pr="$3" output_file="$4"
  local main_root head dirty audit runs statuses
  main_root=$(gaia_resolve_main_root "$root") || usage_error "cannot resolve the main checkout root from $root"
  head=$(git -C "$root" rev-parse HEAD) || usage_error "cannot read HEAD in $root"
  dirty=$(dirty_paths "$root" "$output_file" | jq -R . | jq -s .)
  audit=$(folder_listing "$main_root" "$main_root/.gaia/local/audit")
  runs=$(folder_listing "$main_root" "$run_folder")
  statuses=$( (cd "$root" && gh api "repos/{owner}/{repo}/commits/$head/statuses") 2>/dev/null | jq -S -c .) ||
    usage_error "gh could not read the commit statuses for $head"
  [ -n "$statuses" ] || usage_error "gh returned no commit statuses document for $head"
  jq -n --arg root "$root" --arg run "$run_folder" --arg pr "$pr" --arg head "$head" \
    --argjson dirty "$dirty" --argjson audit "$audit" --argjson runs "$runs" --argjson statuses "$statuses" \
    '{root: $root, run_folder: $run, pr: $pr, head: $head, dirty: $dirty, state: ($audit + $runs), statuses: $statuses}'
}

# first_state_difference <before-file> <after-file>: the first added, removed
# or changed path of the audit state, or nothing.
first_state_difference() {
  jq -r -n --slurpfile before "$1" --slurpfile after "$2" '
    ($before[0].state) as $b | ($after[0].state) as $a |
    ( [($a | keys[]) | select($b[.] == null)]
      + [($b | keys[]) | select($a[.] == null)]
      + [($b | keys[]) | select($a[.] != null and $a[.] != $b[.])] ) | first // empty'
}

run_snapshot() {
  local root='' run_folder='' pr='' out='' dirty state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) root="${2:-}"; shift 2 ;;
      --run-folder) run_folder="${2:-}"; shift 2 ;;
      --pr) pr="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      *) usage_error "snapshot: unknown argument $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$run_folder" ] && [ -n "$pr" ] && [ -n "$out" ] ||
    usage_error 'snapshot needs --root, --run-folder, --pr and --out'
  [ -d "$root" ] || usage_error "snapshot: no such root $root"

  dirty=$(dirty_paths "$root" "$out" | join_lines)
  if [ -n "$dirty" ]; then
    printf 'PR review: tree dirty before dispatch: %s\n' "$dirty"
    exit 1
  fi
  state=$(capture_state "$root" "$run_folder" "$pr" "$out") || exit "$?"
  printf '%s\n' "$state" >"$out"
}

run_compare() {
  local before='' after='' output_file='' root run_folder pr
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --before) before="${2:-}"; shift 2 ;;
      --after) after="${2:-}"; shift 2 ;;
      --output-file) output_file="${2:-}"; shift 2 ;;
      *) usage_error "compare: unknown argument $1" ;;
    esac
  done
  [ -n "$before" ] && [ -n "$after" ] || usage_error 'compare needs --before and --after'
  [ -f "$before" ] || usage_error "compare: no snapshot at $before"

  root=$(jq -r '.root' "$before")
  run_folder=$(jq -r '.run_folder' "$before")
  pr=$(jq -r '.pr' "$before")
  capture_state "$root" "$run_folder" "$pr" "$output_file" >"$after"

  local dirty difference before_head after_head
  dirty=$(jq -r '.dirty | join(",")' "$after")
  if [ -n "$dirty" ]; then
    printf 'PR review left the tree dirty: %s\n' "$dirty"
    exit 1
  fi
  before_head=$(jq -r '.head' "$before")
  after_head=$(jq -r '.head' "$after")
  if [ "$before_head" != "$after_head" ]; then
    printf 'PR review moved HEAD: %s to %s\n' "${before_head:0:7}" "${after_head:0:7}"
    exit 1
  fi
  difference=$(first_state_difference "$before" "$after")
  if [ -n "$difference" ]; then
    printf 'PR review changed audit state: %s\n' "$difference"
    exit 1
  fi
  if [ "$(jq -c '.statuses' "$before")" != "$(jq -c '.statuses' "$after")" ]; then
    printf 'PR review changed commit statuses on %s\n' "${before_head:0:7}"
    exit 1
  fi
}

subcommand="${1:-}"
[ "$#" -gt 0 ] && shift
case "$subcommand" in
  snapshot) run_snapshot "$@" ;;
  compare) run_compare "$@" ;;
  *) usage_error 'usage: pr-review-guard.sh snapshot|compare ...' ;;
esac
