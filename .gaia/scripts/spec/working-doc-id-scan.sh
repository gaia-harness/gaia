#!/usr/bin/env bash
# Fails on any working-document id in the files it scans: a SPEC, FLOW or PLAN
# id followed by digits (any case and length, except a lowercase flow- id, which
# counts at exactly three digits), or a machine-local path, in a
# file path or in a file's content, which covers path segments, test titles and
# both comment forms. The detector is machine-local-ref-lib.sh in strict mode.
# Its caller is the flow-coverage check (flow-coverage.sh, run at a spec-derived
# plan's pre-audit flow checks over the flow test files it resolves); the rule
# it enforces is .claude/rules/working-doc-ids.md.
#
#   working-doc-id-scan.sh [<file-or-directory> ...]
#
# With no argument the default is the frontend package's .playwright folder and
# its app/route-tests folder, resolved package-aware; an absent route tests
# folder is empty. A directory is walked, and the output/ folder directly under
# it (test run artifacts) is skipped. A file argument is scanned alone; its
# path is checked by its base name, so the folders above it are never judged.
#
# Exit codes the caller branches on:
#   0  no id found
#   1  one `<path>:<line>: <match>` per hit on stdout (a hit in a path prints
#      `<path>:0: <match>`)
#   2  usage error or an argument that is neither a readable file nor a directory
#
# Honest limit: a pattern match, so it cannot tell a real id from prose that
# merely looks like one; and it does not read binary files.
set -uo pipefail

usage() {
  cat <<'USAGE' >&2
usage: working-doc-id-scan.sh [<file-or-directory> ...]
USAGE
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/spec/flows-lib.sh
source "$script_directory/flows-lib.sh"
# shellcheck source=.gaia/scripts/machine-local-ref-lib.sh
source "$script_directory/../machine-local-ref-lib.sh"

case "${1:-}" in
  -h | --help)
    usage
    exit 2
    ;;
  -*)
    printf 'working-doc-id-scan.sh: unknown option: %s\n' "$1" >&2
    usage
    exit 2
    ;;
esac

scan_targets=''
if [ "$#" -gt 0 ]; then
  for target in "$@"; do
    [ -n "$target" ] || continue
    if [ -d "$target" ]; then
      target="${target%/}"
    elif [ ! -r "$target" ]; then
      printf 'working-doc-id-scan.sh: not a file or directory: %s\n' "$target" >&2
      exit 2
    fi
    scan_targets="$scan_targets${scan_targets:+$'\n'}$target"
  done
else
  e2e_directory=$(flows_lib_web_subdirectory "$PWD" .playwright/e2e) || exit 2
  route_directory=$(flows_lib_web_subdirectory "$PWD" app/route-tests) || exit 2
  scan_targets="$(dirname "$e2e_directory")"
  # Stock has no route tests folder yet, so an absent one is empty.
  if [ -d "$route_directory" ]; then
    scan_targets="$scan_targets"$'\n'"$route_directory"
  fi
fi

hits=0

# scan_file <file> <path-relative-to-its-scan-root>
scan_file() {
  local file="$1" relative="$2" path_match hit
  path_match=$(printf '%s\n' "$relative" | machine_local_ref_files 1 - | head -n 1)
  if [ -n "$path_match" ]; then
    printf '%s:0: %s\n' "$file" "${path_match#*: }"
    hits=$((hits + 1))
  fi
  # grep -I: a binary file (a screenshot baseline) is not read.
  grep -qI . "$file" 2>/dev/null || return 0
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    printf '%s\n' "$hit"
    hits=$((hits + 1))
  done < <(machine_local_ref_files 1 "$file")
}

while IFS= read -r scan_target; do
  if [ -d "$scan_target" ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      scan_file "$file" "${file#"$scan_target"/}"
    done < <(find "$scan_target" -path "$scan_target/output" -prune -o -type f -print | LC_ALL=C sort)
  else
    scan_file "$scan_target" "$(basename "$scan_target")"
  fi
done <<<"$scan_targets"

[ "$hits" -eq 0 ] || exit 1
exit 0
