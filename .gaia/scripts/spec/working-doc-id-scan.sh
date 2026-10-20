#!/usr/bin/env bash
# Fails on any working-document id in the frontend's Playwright tree: a SPEC,
# UAT or PLAN id followed by digits (any case, any length), or a machine-local
# path, in a file path or in a file's content, which covers path segments, test
# titles and both comment forms. The detector is machine-local-ref-lib.sh in
# strict mode. The owning-phase gate (uat-gate.sh) and the generated plan
# orchestrator's render step call it from the resolved isolation root; the rule
# it enforces is .claude/rules/working-doc-ids.md.
#
#   working-doc-id-scan.sh [<directory>]
#
# The default directory is the frontend package's .playwright folder, resolved
# package-aware through uat_lib_e2e_directory. The output/ folder directly
# under it (test run artifacts) is skipped.
#
# Exit codes the caller branches on:
#   0  no id found
#   1  one `<path>:<line>: <match>` per hit on stdout (a hit in a path prints
#      `<path>:0: <match>`)
#   2  usage error or unreadable directory
#
# Honest limit: a pattern match, so it cannot tell a real id from prose that
# merely looks like one; and it does not read binary files.
set -uo pipefail

usage() {
  cat <<'USAGE' >&2
usage: working-doc-id-scan.sh [<directory>]
USAGE
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/spec/uat-lib.sh
source "$script_directory/uat-lib.sh"
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
if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

scan_directory="${1:-}"
if [ -z "$scan_directory" ]; then
  e2e_directory=$(uat_lib_e2e_directory "$PWD") || exit 2
  scan_directory=$(dirname "$e2e_directory")
fi
scan_directory="${scan_directory%/}"
if [ ! -d "$scan_directory" ]; then
  printf 'working-doc-id-scan.sh: not a directory: %s\n' "$scan_directory" >&2
  exit 2
fi

hits=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  path_match=$(printf '%s\n' "${file#"$scan_directory"/}" | machine_local_ref_files 1 - | head -n 1)
  if [ -n "$path_match" ]; then
    printf '%s:0: %s\n' "$file" "${path_match#*: }"
    hits=$((hits + 1))
  fi
  # grep -I: a binary file (a screenshot baseline) is not read.
  grep -qI . "$file" 2>/dev/null || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    printf '%s\n' "$hit"
    hits=$((hits + 1))
  done < <(machine_local_ref_files 1 "$file")
done < <(find "$scan_directory" -path "$scan_directory/output" -prune -o -type f -print | LC_ALL=C sort)

[ "$hits" -eq 0 ] || exit 1
exit 0
