#!/usr/bin/env bash
# release-bookkeeping-check.sh: the one predicate for "this change is GAIA
# release bookkeeping and nothing else". A `chore(release)` pull request bumps
# version strings, graduates the CHANGELOG and rewrites the wiki state pointer
# and log, over a tree main has already verified; every consumer that swaps its
# full gate for a narrow check on such a change asks this script, so the CI
# skip, the local verify-harness run and the audit scope cannot disagree about
# what counts.
#
# The decision is keyed on the diff, never on a branch name or a PR title: a
# `chore/release-*` branch carrying anything else runs every gate.
#
# Usage:
#   release-bookkeeping-check.sh diff --base <commit> [--head <commit>] [--root <path>]
#   release-bookkeeping-check.sh ci --event pull_request|push --repository <owner/name>
#     --head <sha> [--base <sha>] [--branch <branch>] [--workflow <file>] [--root <path>]
#
# diff: is the tree delta <base>..<head> (two-dot, head defaults to HEAD; either
#   side may be a commit or a bare tree)
#   release bookkeeping? Exit 0 yes, printing `bookkeeping <old> -> <new>`;
#   exit 1 no, one reason on stderr; exit 2 usage error or an unreadable input.
#   A change is bookkeeping only when every condition holds:
#     - the changed paths are .gaia/VERSION, .gaia/manifest.json, package.json,
#       frontend/package.json and CHANGELOG.md, each modified, plus at most
#       wiki/.state.json and wiki/log.md: a release that had no wiki drift
#       leaves those two alone, every other file must move;
#     - .gaia/VERSION holds one X.Y.Z line on each side, and the two differ;
#     - both package.json files and the manifest are equal on each side once
#       their version (and the manifest's `generated` stamp) is deleted, and
#       carry the old version before and the new one after;
#     - CHANGELOG.md at head, with the new `## [<new>] - <date>` heading and
#       the blank line after it removed, the new `[<new>]:` release link
#       removed, and the `[Unreleased]:` compare link pointed back at the old
#       version, is byte-equal to the base: the graduation, nothing else;
#     - wiki/.state.json is equal on each side once its last_evaluated pair is
#       deleted;
#     - wiki/log.md at head is exactly the release scrub's rendering for the
#       new version (renderLogMd in .gaia/cli/src/release/scrub-wiki.ts).
#   Structural rather than a line allowlist: each file is parsed or rebuilt and
#   compared whole, so a hunk shaped like a version line cannot carry anything
#   past it. A scrub or graduation whose output format changes only stops
#   matching, which runs the full gates.
#
# ci: the CI fast-path decision for one workflow run. Prints `fast=true` or
# `fast=false` on stdout, in GITHUB_OUTPUT form. <head> is the commit the run
# tests, and the base is its first parent: the base tip a pull request's merge
# commit was built on, the main head a one-commit release branch was cut from,
# or the main head before a push. A --base that is not that parent (a push of
# several commits) runs every gate. `fast=true` needs the diff above to hold, <base> to be green, and, on a
# pull request, <base> to still be the head of <branch> on GitHub. Green is
# verify-main-green.sh passing on <base>, plus, with --workflow, that
# workflow's own push run on <base> having completed `success`, so a run still
# in progress on main's head never lends its verdict. Then it runs the narrow
# consistency check that replaces the full gates: `release manifest --check`.
# Any signal it cannot read prints `fast=false` and exits 0, so a doubt runs
# every gate; the one red exit is a bookkeeping change whose manifest check
# fails (exit 1), which is a broken release, not a reason to run the rest.
#
# Maintainer-only (release-excluded): it describes GAIA's own release files.
# Bash 3.2 compatible; BSD and GNU tools. Never `cd`.
set -uo pipefail

readonly REQUIRED_PATHS='.gaia/VERSION .gaia/manifest.json package.json frontend/package.json CHANGELOG.md'
readonly OPTIONAL_PATHS='wiki/.state.json wiki/log.md'

script_directory="${BASH_SOURCE[0]%/*}"
[ "$script_directory" != "${BASH_SOURCE[0]}" ] || script_directory="."

usage() {
  printf 'usage: release-bookkeeping-check.sh diff --base <commit> [--head <commit>] [--root <path>]\n' >&2
  printf '       release-bookkeeping-check.sh ci --event pull_request|push --repository <owner/name> --head <sha> [--base <sha>] [--branch <branch>] [--workflow <file>] [--root <path>]\n' >&2
  exit 2
}

mode="${1:-}"
case "$mode" in
  diff | ci) shift ;;
  *) usage ;;
esac

root=""
base=""
head=""
event=""
repository=""
branch="main"
workflow=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root | --base | --head | --event | --repository | --branch | --workflow)
      [ $# -ge 2 ] || usage
      case "$1" in
        --root) root="$2" ;;
        --base) base="$2" ;;
        --head) head="$2" ;;
        --event) event="$2" ;;
        --repository) repository="$2" ;;
        --branch) branch="$2" ;;
        --workflow) workflow="$2" ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

[ "$mode" = ci ] || [ -n "$base" ] || usage
if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'release-bookkeeping-check: not inside a git checkout (pass --root)\n' >&2
    exit 2
  }
fi

not_bookkeeping() {
  printf 'release-bookkeeping-check: not release bookkeeping: %s\n' "$1" >&2
  return 1
}

# Prints the blob <tree>:<path>; non-zero when it does not exist.
read_blob() {
  git -C "$root" cat-file blob "$1:$2" 2>/dev/null
}

# jq -S of <tree>:<path> with <filter> applied; non-zero when either fails.
normalized_json() {
  local blob
  blob="$(read_blob "$1" "$2")" || return 1
  printf '%s\n' "$blob" | jq -S "$3" 2>/dev/null
}

json_version() {
  local blob
  blob="$(read_blob "$1" "$2")" || return 1
  printf '%s\n' "$blob" | jq -er '.version | strings' 2>/dev/null
}

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Rebuilds the base CHANGELOG from the head one by undoing the graduation.
# Prints nothing and exits 1 when the heading or the release link is not there
# exactly once.
ungraduate_changelog() {
  awk -v old="$1" -v new="$2" '
    BEGIN {
      heading = "## [" new "] - "
      link_prefix = "[" new "]: https://github.com/"
      link_suffix = "/releases/tag/v" new
      unreleased_prefix = "[Unreleased]: "
      new_compare = "compare/v" new "...HEAD"
      old_compare = "compare/v" old "...HEAD"
      headings = 0; links = 0; drop_blank = 0; out = ""
    }
    {
      line = $0
      if (drop_blank) {
        drop_blank = 0
        if (line == "") next
      }
      if (index(line, heading) == 1 && substr(line, length(heading) + 1) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
        headings++; drop_blank = 1; next
      }
      if (index(line, link_prefix) == 1 && length(line) > length(link_prefix) + length(link_suffix) \
        && substr(line, length(line) - length(link_suffix) + 1) == link_suffix) {
        links++; next
      }
      if (index(line, unreleased_prefix) == 1 && length(line) >= length(new_compare) \
        && substr(line, length(line) - length(new_compare) + 1) == new_compare) {
        line = substr(line, 1, length(line) - length(new_compare)) old_compare
      }
      print line
    }
    END { if (headings != 1 || links != 1) exit 1 }
  '
}

render_log() {
  printf -- '---\ntype: meta\ntitle: Log\nstatus: active\ncreated: %s\nupdated: %s\ntags: [meta, log]\n---\n\n# Log\n\n## [v%s] %s | Released\n\nSee CHANGELOG.md for details.\n' \
    "$2" "$2" "$1" "$2"
}

# The diff predicate. Returns 0/1/2 per the header; on 0 sets old_version and
# new_version.
check_diff() {
  local base_tree head_tree changes status path seen_required="" required
  local base_blob head_blob base_side head_side head_log log_date

  command -v jq >/dev/null 2>&1 || { printf 'release-bookkeeping-check: jq not found\n' >&2; return 2; }
  # Trees, not commits: the audit's fix verifier asks about a tree it has not
  # committed yet, and every read below is a blob of a tree.
  base_tree="$(git -C "$root" rev-parse --verify --quiet "$base^{tree}" 2>/dev/null)" \
    || { printf 'release-bookkeeping-check: %s is not a commit or tree\n' "$base" >&2; return 2; }
  head_tree="$(git -C "$root" rev-parse --verify --quiet "${head:-HEAD}^{tree}" 2>/dev/null)" \
    || { printf 'release-bookkeeping-check: %s is not a commit or tree\n' "${head:-HEAD}" >&2; return 2; }

  # -z so a non-ASCII path is never C-quoted past the comparisons below.
  changes="$(git -C "$root" -c core.quotepath=false diff --name-status --no-renames -z "$base_tree" "$head_tree" 2>/dev/null | tr '\0' '\n')" \
    || { printf 'release-bookkeeping-check: cannot diff %s..%s\n' "$base_tree" "$head_tree" >&2; return 2; }
  [ -n "$changes" ] || { not_bookkeeping 'the change is empty'; return 1; }
  while IFS= read -r status && IFS= read -r path; do
    [ "$status" = M ] || { not_bookkeeping "$path is not a plain modification ($status)"; return 1; }
    case " $REQUIRED_PATHS " in
      *" $path "*) seen_required="$seen_required $path" ;;
      *)
        case " $OPTIONAL_PATHS " in
          *" $path "*) ;;
          *) not_bookkeeping "$path is outside the release bookkeeping set"; return 1 ;;
        esac
        ;;
    esac
  done <<EOF
$changes
EOF
  for required in $REQUIRED_PATHS; do
    case "$seen_required " in
      *" $required "*) ;;
      *) not_bookkeeping "$required did not change"; return 1 ;;
    esac
  done

  if ! base_blob="$(read_blob "$base_tree" .gaia/VERSION)" || ! head_blob="$(read_blob "$head_tree" .gaia/VERSION)"; then
    printf 'release-bookkeeping-check: cannot read .gaia/VERSION\n' >&2
    return 2
  fi
  old_version="$base_blob"
  new_version="$head_blob"
  if ! is_semver "$old_version" || ! is_semver "$new_version"; then
    not_bookkeeping '.gaia/VERSION is not one X.Y.Z line on each side'
    return 1
  fi
  # The blob reads above drop trailing newlines, so the size proves the file is
  # the one line and its newline.
  [ "$(git -C "$root" cat-file -s "$head_tree:.gaia/VERSION")" -eq $((${#new_version} + 1)) ] \
    || { not_bookkeeping '.gaia/VERSION carries more than its version line'; return 1; }

  for path in package.json frontend/package.json .gaia/manifest.json; do
    if ! base_side="$(normalized_json "$base_tree" "$path" 'del(.version, .generated)')" \
      || ! head_side="$(normalized_json "$head_tree" "$path" 'del(.version, .generated)')"; then
      not_bookkeeping "$path does not parse"
      return 1
    fi
    [ "$base_side" = "$head_side" ] || { not_bookkeeping "$path changed beyond its version"; return 1; }
    [ "$(json_version "$base_tree" "$path")" = "$old_version" ] && [ "$(json_version "$head_tree" "$path")" = "$new_version" ] \
      || { not_bookkeeping "$path does not move $old_version to $new_version"; return 1; }
  done
  for path in package.json frontend/package.json; do
    [ "$(normalized_json "$base_tree" "$path" 'has("generated")')" = false ] \
      && [ "$(normalized_json "$head_tree" "$path" 'has("generated")')" = false ] \
      || { not_bookkeeping "$path carries a generated key"; return 1; }
  done

  if ! base_blob="$(read_blob "$base_tree" CHANGELOG.md)" || ! head_blob="$(read_blob "$head_tree" CHANGELOG.md)"; then
    printf 'release-bookkeeping-check: cannot read CHANGELOG.md\n' >&2
    return 2
  fi
  head_side="$(printf '%s\n' "$head_blob" | ungraduate_changelog "$old_version" "$new_version")" \
    || { not_bookkeeping "CHANGELOG.md does not add one [$new_version] heading and one release link"; return 1; }
  [ "$head_side" = "$base_blob" ] || { not_bookkeeping 'CHANGELOG.md changed beyond graduating [Unreleased]'; return 1; }

  case "$changes" in
    *wiki/.state.json*)
      if ! base_side="$(normalized_json "$base_tree" wiki/.state.json 'del(.last_evaluated_sha, .last_evaluated_at)')" \
        || ! head_side="$(normalized_json "$head_tree" wiki/.state.json 'del(.last_evaluated_sha, .last_evaluated_at)')"; then
        not_bookkeeping 'wiki/.state.json does not parse'
        return 1
      fi
      [ "$base_side" = "$head_side" ] || { not_bookkeeping 'wiki/.state.json changed beyond its last_evaluated pair'; return 1; }
      ;;
  esac
  case "$changes" in
    *wiki/log.md*)
      head_log="$(read_blob "$head_tree" wiki/log.md)" || { not_bookkeeping 'wiki/log.md is unreadable'; return 1; }
      log_date="$(printf '%s\n' "$head_log" | sed -n 's/^created: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' | head -n 1)"
      [ -n "$log_date" ] && [ "$head_log" = "$(render_log "$new_version" "$log_date")" ] \
        || { not_bookkeeping 'wiki/log.md is not the release scrub of this version'; return 1; }
      ;;
  esac

  return 0
}

if [ "$mode" = diff ]; then
  check_diff
  diff_status=$?
  [ "$diff_status" -ne 0 ] || printf 'bookkeeping %s -> %s\n' "$old_version" "$new_version"
  exit "$diff_status"
fi

# ci mode. Every refusal below is a full run, never a red check.
run_everything() {
  printf 'release-bookkeeping-check: full gates: %s\n' "$1" >&2
  printf 'fast=false\n'
  exit 0
}

case "$event" in
  pull_request | push) ;;
  *) usage ;;
esac
[ -n "$repository" ] && [ -n "$head" ] || usage

parent="$(git -C "$root" rev-parse --verify --quiet "$head^1" 2>/dev/null)" || run_everything "the parent of $head is not in this checkout"
if [ -n "$base" ]; then
  [ "$parent" = "$(git -C "$root" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null)" ] \
    || run_everything "$base is not the first parent of $head"
fi
base="$parent"

check_diff
diff_status=$?
[ "$diff_status" -eq 0 ] || run_everything "the change is not release bookkeeping"

if [ "$event" = pull_request ]; then
  branch_head="$(gh api "repos/${repository}/commits/${branch}" --jq '.sha' 2>/dev/null)" \
    || run_everything "could not read the head of ${branch}"
  [ "$branch_head" = "$parent" ] || run_everything "the pull request is built on ${parent}, not the head of ${branch} (${branch_head})"
fi

bash "$script_directory/verify-main-green.sh" --repo "$repository" --branch "$branch" --sha "$parent" >&2 \
  || run_everything "${branch} is not green at ${parent}"

if [ -n "$workflow" ]; then
  workflow_conclusion="$(gh api "repos/${repository}/actions/workflows/${workflow}/runs?event=push&branch=${branch}&head_sha=${parent}&per_page=100" \
    --jq '.workflow_runs | sort_by(.created_at) | last // empty | "\(.status) \(.conclusion // "none")"' 2>/dev/null)" \
    || run_everything "could not read the ${workflow} push runs for ${parent}"
  [ "$workflow_conclusion" = "completed success" ] \
    || run_everything "the ${workflow} push run for ${parent} is '${workflow_conclusion:-absent}', not a completed success"
fi

command -v node >/dev/null 2>&1 || run_everything "node is not installed, so the manifest check cannot run"
if ! (cd "$root" && node .gaia/cli/gaia-maintainer release manifest --check) >&2; then
  printf '::error::release bookkeeping change, but release manifest --check failed: regenerate the manifest with gaia-maintainer release manifest --allow-undecided\n' >&2
  printf 'fast=false\n'
  exit 1
fi

printf 'release-bookkeeping-check: release bookkeeping %s -> %s on a green %s: the narrow check replaces the full gates\n' \
  "$old_version" "$new_version" "$branch" >&2
printf 'fast=true\n'
exit 0
