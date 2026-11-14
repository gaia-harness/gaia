#!/usr/bin/env bash
# The drift check over a plan's test-design table, and the security-row
# coverage check the merge gate and the status post share.
#
#   test-drift-check.sh classify --root <tree> --plan-dir <dir> [--base <ref>]
#   test-drift-check.sh security --root <tree> --plan-dir <dir> [--base <ref>]
#
# classify prints the drift JSON (.claude/skills/gaia/references/drift-check.md,
# `## The drift JSON`). security prints one `uncovered <row id> <reason>` line
# per approved security row the branch leaves uncovered, reason one of
# missing-from-table, flag-lost, no-matching-test or hollow.
#
# The diff base is --base, else the one audit-base-provenance.sh resolves. The
# changed paths are the committed range plus uncommitted and untracked files,
# so a test written but not yet committed is classified too.
#
# Exit codes:
#   0  ok (security: every approved security row covered)
#   1  security only: one or more rows uncovered
#   2  usage error; classify on a plan dir with no TEST-DESIGN marker (security
#      exits 0 with no output there: an older plan has no approved security rows)
#   3  refusal, reason on stderr: an unreadable or unhashed approved copy, an
#      unreadable table, a test file the extractor refuses or cannot identify a
#      test in, a repeated full name in a planned file, an unresolvable base
#
# WORTHINESS_LEDGER_PATH is the test seam the ledger writer and
# worthiness-step.sh share; production leaves it unset.
#
# Bash 3.2 compatible.
set -uo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$script_directory/../.."
# shellcheck source=.claude/hooks/lib/audit-base-provenance.sh
source "$repository_directory/.claude/hooks/lib/audit-base-provenance.sh"
# shellcheck source=.claude/hooks/lib/worthiness-ledger.sh
source "$repository_directory/.claude/hooks/lib/worthiness-ledger.sh"

usage() {
  printf 'usage: test-drift-check.sh classify|security --root <tree> --plan-dir <dir> [--base <ref>]\n' >&2
  exit 2
}

refuse() {
  printf 'test-drift-check: %s\n' "$1" >&2
  exit 3
}

subcommand="${1:-}"
case "$subcommand" in
  classify | security) shift ;;
  *) usage ;;
esac

root=''
plan_directory=''
base_argument=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root | --plan-dir | --base)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --root) root="$2" ;;
        --plan-dir) plan_directory="$2" ;;
        --base) base_argument="$2" ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$root" ] && [ -n "$plan_directory" ] || usage
[ -d "$root" ] || usage
root="${root%/}"

if [ ! -f "$plan_directory/TEST-DESIGN" ]; then
  [ "$subcommand" = "security" ] && exit 0
  printf 'test-drift-check: no TEST-DESIGN marker in %s\n' "$plan_directory" >&2
  exit 2
fi

provenance=$(audit_resolve_base_provenance "$root" default-branch "$base_argument") || provenance=''
IFS=$'\t' read -r _ _ base <<<"$provenance" || true
[ -n "${base:-}" ] || refuse "cannot resolve a diff base for $root. Next step: pass --base <ref>."

core="$script_directory/test-design/drift.mjs"

if [ "$subcommand" = "security" ]; then
  ledger_path="${WORTHINESS_LEDGER_PATH:-$(worthiness_ledger_path "$root")}" || ledger_path=''
  [ -n "$ledger_path" ] || refuse "cannot resolve the worthiness ledger for $root"
  node "$core" security --root "$root" --plan-dir "$plan_directory" --base "$base" --ledger "$ledger_path"
  exit $?
fi

changed_list="$(mktemp "${TMPDIR:-/tmp}/test-drift-check.XXXXXX")" || refuse "cannot create a temporary file"
trap 'rm -f "$changed_list"' EXIT

committed_paths=$(audit_provenance_changed_files "$root" "$base") || refuse "git diff against $base failed in $root"
{
  printf '%s\n' "$committed_paths" | tr '\n' '\0'
  git -C "$root" diff --name-only -z --no-renames HEAD 2>/dev/null
  git -C "$root" ls-files -z --others --exclude-standard 2>/dev/null
} >"$changed_list"

node "$core" classify --root "$root" --plan-dir "$plan_directory" --base "$base" --changed "$changed_list"
