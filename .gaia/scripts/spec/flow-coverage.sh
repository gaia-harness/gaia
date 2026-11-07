#!/usr/bin/env bash
# The mechanical half of flow coverage. For each flow a SPEC names, checks that
# its test file exists and changed on the branch; for a web flow also that
# Playwright collects the spec, that it carries a resolvable `// @covers`
# declaration naming every folder the SPEC lists for the flow which the branch
# changed; and that no flow test carries a working-document id. Whether the
# tests are any good is the worthiness review's judgment, not this script's.
#
#   flow-coverage.sh --spec <SPEC.md> --root <tree> [--base <ref>]
#                    [--listing <playwright-list.json>] [--flow-tests-out <file>]
#
# --root is the tree under check and every git call runs against it. The diff
# base is --base, else the one audit-base-provenance.sh resolves. The listing is
# a `playwright test --list --reporter=json` document; without --listing the
# script runs Playwright for it, once, and only when the SPEC has a web flow.
# --flow-tests-out writes one `flow_id<TAB>slug<TAB>kind<TAB>path` row per flow
# whose test file exists.
#
# Every finding is one stdout line `flow-coverage: ...`, all of them in one run.
# The web flow test lives in <frontend package>/.playwright/flows/<slug>.spec.ts.
#
# Exit codes the caller branches on:
#   0  clean, nothing printed
#   1  one or more findings
#   2  usage error, or a SPEC the flows reader refuses (reason on stderr)
#   3  operational failure (no diff base, unreadable or failed listing, git)
set -uo pipefail

usage() {
  cat <<'USAGE' >&2
usage: flow-coverage.sh --spec <SPEC.md> --root <tree> [--base <ref>] [--listing <file>] [--flow-tests-out <file>]
USAGE
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$script_directory/../../.."
# shellcheck source=.gaia/scripts/spec/flows-lib.sh
source "$script_directory/flows-lib.sh"
# shellcheck source=.claude/hooks/lib/audit-base-provenance.sh
source "$repository_directory/.claude/hooks/lib/audit-base-provenance.sh"

spec_file=''
root=''
base_argument=''
listing_file=''
flow_tests_out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --spec | --root | --base | --listing | --flow-tests-out)
      if [ "$#" -lt 2 ]; then
        printf 'flow-coverage.sh: %s needs a value\n' "$1" >&2
        usage
        exit 2
      fi
      case "$1" in
        --spec) spec_file="$2" ;;
        --root) root="$2" ;;
        --base) base_argument="$2" ;;
        --listing) listing_file="$2" ;;
        --flow-tests-out) flow_tests_out="$2" ;;
      esac
      shift 2
      ;;
    *)
      printf 'flow-coverage.sh: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done
if [ -z "$spec_file" ] || [ -z "$root" ]; then
  usage
  exit 2
fi
if [ ! -r "$spec_file" ]; then
  printf 'flow-coverage.sh: cannot read the SPEC: %s\n' "$spec_file" >&2
  exit 2
fi
if [ ! -d "$root" ]; then
  printf 'flow-coverage.sh: not a directory: %s\n' "$root" >&2
  exit 2
fi
root="${root%/}"

flow_rows=$(flows_lib_parse_spec "$spec_file")
parse_status=$?
if [ "$parse_status" -ne 0 ]; then
  [ "$parse_status" -eq 2 ] && exit 2
  exit 3
fi

provenance=$(audit_resolve_base_provenance "$root" default-branch "$base_argument") || provenance=''
IFS=$'\t' read -r _ _ base <<<"$provenance" || true
if [ -z "${base:-}" ]; then
  printf 'flow-coverage.sh: cannot resolve a diff base for %s. Next step: pass --base <ref>.\n' "$root" >&2
  exit 3
fi

committed_paths=$(audit_provenance_changed_files "$root" "$base") || {
  printf 'flow-coverage.sh: git diff against %s failed in %s\n' "$base" "$root" >&2
  exit 3
}
uncommitted_paths=''
while IFS= read -r -d '' uncommitted_path; do
  uncommitted_paths="$uncommitted_paths$uncommitted_path"$'\n'
done < <(git -C "$root" diff --name-only -z --no-renames HEAD 2>/dev/null) || uncommitted_paths=''
untracked_paths=''
while IFS= read -r -d '' untracked_path; do
  untracked_paths="$untracked_paths$untracked_path"$'\n'
done < <(git -C "$root" ls-files -z --others --exclude-standard 2>/dev/null) || untracked_paths=''
changed_paths=$(printf '%s\n%s\n%s\n' "$committed_paths" "$uncommitted_paths" "$untracked_paths" | grep . | LC_ALL=C sort -u)

has_web_flow=0
while IFS=$'\t' read -r _ _ _ _ kind _; do
  [ "$kind" = "web" ] && has_web_flow=1
done <<<"$flow_rows"

package_path=''
flows_directory=''
listed_paths=''
if [ "$has_web_flow" -eq 1 ]; then
  package_path=$(flows_lib_web_package_path "$root") || exit 3
  flows_directory=$(flows_lib_web_subdirectory "$root" .playwright/flows) || exit 3

  if [ -z "$listing_file" ]; then
    listing_file=$(mktemp "${TMPDIR:-/tmp}/flow-coverage-listing.XXXXXX") || exit 3
    trap 'rm -f "$listing_file"' EXIT
    if ! pnpm -C "$root/$package_path" exec playwright test --list --reporter=json >"$listing_file" 2>/dev/null; then
      printf 'flow-coverage.sh: the Playwright listing failed in %s/%s\n' "$root" "$package_path" >&2
      exit 3
    fi
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'flow-coverage.sh: jq is required to read the Playwright listing\n' >&2
    exit 3
  fi
  listing_root=$(jq -r '.config.rootDir // empty' "$listing_file" 2>/dev/null) || {
    printf 'flow-coverage.sh: the Playwright listing is not valid JSON: %s\n' "$listing_file" >&2
    exit 3
  }
  listing_files=$(jq -r '[.. | objects | .file? // empty | strings] | unique[]' "$listing_file" 2>/dev/null) || {
    printf 'flow-coverage.sh: the Playwright listing is not valid JSON: %s\n' "$listing_file" >&2
    exit 3
  }
  # Resolve physically so a symlinked temporary directory compares equal.
  if [ -n "$listing_root" ] && [ -d "$listing_root" ]; then
    listing_root=$(cd "$listing_root" && pwd -P)
  fi
  while IFS= read -r listed; do
    [ -n "$listed" ] || continue
    case "$listed" in
      /*) listed_path="$listed" ;;
      *) listed_path="$listing_root/$listed" ;;
    esac
    if [ -d "$(dirname "$listed_path")" ]; then
      listed_path="$(cd "$(dirname "$listed_path")" && pwd -P)/$(basename "$listed_path")"
    fi
    listed_paths="$listed_paths$listed_path"$'\n'
  done <<<"$listing_files"
fi
physical_root=$(cd "$root" && pwd -P)

findings=0
finding() {
  printf 'flow-coverage: %s\n' "$1"
  findings=$((findings + 1))
}

path_is_changed() {
  grep -qxF -- "$1" <<<"$changed_paths"
}

# True when a changed path is the folder or lies under it.
folder_changed() {
  local folder="$1" changed
  while IFS= read -r changed; do
    case "$changed" in
      "$folder" | "$folder"/*) return 0 ;;
    esac
  done <<<"$changed_paths"
  return 1
}

# True when the declared path is the folder or contains it, by whole segments.
declaration_names_folder() {
  case "$2" in
    "$1" | "$1"/*) return 0 ;;
  esac
  return 1
}

package_prefix() {
  if [ "$package_path" = "." ]; then
    printf ''
  else
    printf '%s/' "$package_path"
  fi
}

check_web_spec() {
  local spec_path="$1" covers_text="$2" prefix declared declared_paths='' covered folder
  prefix=$(package_prefix)

  if ! grep -qxF -- "$physical_root/$spec_path" <<<"$listed_paths"; then
    finding "$spec_path: not in the Playwright listing"
  fi

  if ! declared=$(flows_lib_covers_paths "$root/$spec_path" 2>/dev/null); then
    finding "$spec_path: no @covers declaration"
    return 0
  fi
  while IFS= read -r covered; do
    [ -n "$covered" ] || continue
    covered="${covered#./}"
    covered="${covered%/}"
    declared_paths="$declared_paths$covered"$'\n'
    if [ ! -e "$root/$prefix$covered" ]; then
      finding "$spec_path: @covers path does not resolve: $covered"
    fi
  done <<<"$declared"

  for folder in $covers_text; do
    folder="${folder%/}"
    folder_changed "$prefix$folder" || continue
    covered=0
    while IFS= read -r declared; do
      [ -n "$declared" ] || continue
      if declaration_names_folder "$declared" "$folder"; then
        covered=1
        break
      fi
    done <<<"$declared_paths"
    [ "$covered" -eq 1 ] || finding "$spec_path: @covers misses $folder"
  done
}

[ -z "$flow_tests_out" ] || : >"$flow_tests_out" || exit 3

existing_tests=''
while IFS=$'\t' read -r flow_id slug _ _ kind target; do
  [ -n "$flow_id" ] || continue
  if [ "$kind" = "web" ]; then
    test_path="$flows_directory/$slug.spec.ts"
  else
    test_path="$target"
  fi
  if [ ! -f "$root/$test_path" ]; then
    finding "$flow_id: missing $test_path"
    continue
  fi
  existing_tests="$existing_tests$test_path"$'\n'
  if [ -n "$flow_tests_out" ]; then
    printf '%s\t%s\t%s\t%s\n' "$flow_id" "$slug" "$kind" "$test_path" >>"$flow_tests_out"
  fi
  if ! path_is_changed "$test_path"; then
    finding "$flow_id: $test_path not changed on the branch"
  fi
  if [ "$kind" = "web" ]; then
    check_web_spec "$test_path" "$target"
  fi
done <<<"$flow_rows"

scan_script="$script_directory/working-doc-id-scan.sh"
while IFS= read -r test_path; do
  [ -n "$test_path" ] || continue
  scan_output=$(bash "$scan_script" "$root/$test_path")
  scan_status=$?
  case "$scan_status" in
    0) continue ;;
    1) ;;
    *)
      printf 'flow-coverage.sh: the working-document id scan failed on %s\n' "$test_path" >&2
      exit 3
      ;;
  esac
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    rest="${hit#"$root/$test_path":}"
    finding "$test_path:${rest%%:*}: working-doc id ${rest#*: }"
  done <<<"$scan_output"
done <<<"$existing_tests"

[ "$findings" -eq 0 ] || exit 1
exit 0
