#!/usr/bin/env bash
# shellcheck shell=bash
#
# pr-review-guard.sh: the before/after check around the read-only pull request
# reviewer. The reviewer holds Bash and Write, so it is read-only by its prompt
# and kept out of audit state by the read guard hook;
# this script is the backstop that proves it changed nothing.
#
#   pr-review-guard.sh snapshot --root <R> --run-folder <D> --pr <N> --out <file>
#   pr-review-guard.sh compare  --before <file> --after <file> [--output-file <path>]
#
# snapshot refuses a dirty tree (untracked files count), otherwise writes one
# JSON file holding the tree listing, a path and content-hash listing of the
# local audit state and of the run folder, and HEAD's GAIA-Audit commit
# statuses (another integration's status landing during the review is not
# the reviewer's write). The audit listing leaves out records provably keyed
# to another branch or head, since the audit directory is shared by every
# lane's worktree (`audit_listing` owns the rule).
# compare captures the same state again into --after, from the root and run
# folder the snapshot recorded, and reports the first difference in this order:
# the tree, the audit state, the GAIA-Audit statuses. --output-file names the one
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

# folder_listing <main-root> <folder>: a JSON object mapping each file under
# <folder> to its content hash, keyed by the path relative to <main-root> when
# inside it. An absent folder is an empty object.
folder_listing() {
  local main_root="$1" folder="$2"
  [ -d "$folder" ] || {
    printf '{}'
    return 0
  }
  find "$folder" -type f | LC_ALL=C sort | listing_of_files "$main_root"
}

# listing_of_files <main-root>: folder_listing's JSON for the file paths on
# stdin, one per line.
listing_of_files() {
  local main_root="$1" file key
  while IFS= read -r file; do
    case "$file" in
      "$main_root"/*) key="${file#"$main_root"/}" ;;
      *) key="$file" ;;
    esac
    jq -n --arg key "$key" --arg hash "$(hash_file "$file")" '{($key): $hash}'
  done | jq -s 'add // {}'
}

# audit_listing <root> <main-root> <branch-slug> <own-digests>: folder_listing's
# JSON for the local audit directory, minus the records provably keyed to another branch or head, so a
# concurrent lane's attributable writes do not read as the reviewer's. A record
# is dropped only when it is one of:
#   - a branch-keyed file (<40-hex base>.<branch slug>.*) of another branch;
#   - a marker (<64-hex digest>[.<member>].{ok,refused}) or a light route record
#     (light/<digest>.<member>.route.json) whose digest is none of this
#     branch's own member digests and whose recorded tree and commit are both
#     absent from HEAD's recent history.
# Everything else stays, including any file that cannot be attributed. When
# <own-digests> is empty or HEAD's history cannot be read, no marker or route
# record is dropped (another branch's branch-keyed files still are). Dropping
# a marker or route record is safe because the merge gate matches a marker by
# digest and the audit base resolvers anchor on a recorded tree in this
# branch's history, so a record at another digest whose tree and commit are both outside HEAD's
# history can affect neither. The 500-commit window is well past the
# resolvers' anchor walk (MAXIMUM_WALK_COMMIT_COUNT in
# .github/audit/resolve-audit-base.sh), so a record older than the window
# cannot anchor this branch.
audit_listing() {
  local root="$1" main_root="$2" branch_slug="$3" own_digests="$4"
  local audit_directory="$main_root/.gaia/local/audit"
  local scratch listing recent file relative digest
  [ -d "$audit_directory" ] || {
    printf '{}'
    return 0
  }
  scratch=$(mktemp -d) || usage_error 'cannot create a scratch directory'
  find "$audit_directory" -type f | LC_ALL=C sort >"$scratch/files"
  : >"$scratch/dropped"
  : >"$scratch/candidates"

  recent=$(git -C "$root" rev-list -n 500 --format='%H %T' HEAD 2>/dev/null | grep -Ev '^commit ' || true)

  while IFS= read -r file; do
    relative="${file#"$audit_directory"/}"
    if [ -n "$branch_slug" ] && [[ "$relative" =~ ^[0-9a-f]{40}\.[^./]+\. ]]; then
      # A file naming the own slug in any later segment is kept: the readers
      # glob on `.<slug>.`, so a decoy segment ahead of it still reaches them.
      case ".$relative." in
        *".$branch_slug."*) ;;
        *) printf '%s\n' "$file" >>"$scratch/dropped" ;;
      esac
      continue
    fi
    [ -n "$own_digests" ] && [ -n "$recent" ] || continue
    if [[ "$relative" =~ ^([0-9a-f]{64})(\.[^./]+)?\.(ok|refused)$ ]] ||
      [[ "$relative" =~ ^light/([0-9a-f]{64})\.[^./]+\.route\.json$ ]]; then
      digest="${BASH_REMATCH[1]}"
      grep -qx -- "$digest" <<<"$own_digests" || printf '%s\n' "$file" >>"$scratch/candidates"
    fi
  done <"$scratch/files"

  if [ -s "$scratch/candidates" ]; then
    printf '%s\n' "$recent" >"$scratch/recent"
    # The jq program's $-names are jq variables, not shell expansions.
    # shellcheck disable=SC2016
    tr '\n' '\0' <"$scratch/candidates" | xargs -0 jq -n -R -r --rawfile recent "$scratch/recent" '
      ($recent | split("\n") | map(split(" ")) | flatten | map(select(. != "") | {(.): true}) | add // {}) as $known |
      inputs |
      input_filename as $name |
      ((try fromjson catch null) | objects) as $body |
      ($body.tree // "") as $tree |
      ($body.sha // $body.head_sha // "") as $commit |
      select($tree != "" and $commit != "" and ($known[$tree] | not) and ($known[$commit] | not)) |
      $name' >>"$scratch/dropped" || {
      rm -rf "$scratch"
      usage_error 'jq could not read the audit markers'
    }
  fi

  grep -vxFf "$scratch/dropped" "$scratch/files" >"$scratch/kept" || true
  listing=$(listing_of_files "$main_root" <"$scratch/kept")
  rm -rf "$scratch"
  printf '%s' "$listing"
}

# own_scope <root> <pr>: print the JSON {slug, digests} that decides which audit
# records are this branch's own: the branch slug and every member digest
# measured against the local base reference and against the base tip GitHub
# reports for the pull request, the one the merge gate measures from. An
# unreadable slug or digest set is left empty and audit_listing then drops no
# record of that kind.
own_scope() {
  local root="$1" pr="$2" library="$_script_directory/../../.claude/hooks/lib/audit-digest.sh"
  local slug='' digests='' host_base host_digests
  slug=$(bash -c '. "$1"; gaia_branch_slug "$2"' _ "$_script_directory/audit-key-lib.sh" "$root" 2>/dev/null) || slug=''
  if [ -f "$library" ]; then
    digests=$(bash -c '. "$1"; audit_branch_digests_local "$2"' _ "$library" "$root" 2>/dev/null | cut -f2 || true)
    host_base=$( (cd "$root" && gh pr view "$pr" --json baseRefName --jq .baseRefName) 2>/dev/null || true)
    if [[ "$host_base" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      host_digests=$(bash -c '
        . "$1"
        repository=$(audit_github_repository "$2") || exit 1
        tip=$(audit_github_base_tip "$2" "$repository" "$3") || exit 1
        merge_base=$(audit_branch_patch_merge_base "$2" "$tip") || exit 1
        audit_branch_digests_all "$2" "$merge_base"' _ "$library" "$root" "$host_base" 2>/dev/null | cut -f2 || true)
      digests="$digests"$'\n'"$host_digests"
    fi
  fi
  printf '%s\n' "$digests" | grep -E '^[0-9a-f]{64}$' | LC_ALL=C sort -u | jq -R . | jq -s --arg slug "$slug" '{slug: $slug, digests: .}' || true
}

# capture_state <root> <run-folder> <pr> <output-file> [<scope-json>]: print the
# state JSON. The scope is the snapshot's own_scope, handed back at compare so
# nothing the reviewer changes in refs or config moves which records are own.
capture_state() {
  local root="$1" run_folder="$2" pr="$3" output_file="$4" scope="${5:-}"
  local main_root head dirty audit runs statuses
  main_root=$(gaia_resolve_main_root "$root") || usage_error "cannot resolve the main checkout root from $root"
  head=$(git -C "$root" rev-parse HEAD) || usage_error "cannot read HEAD in $root"
  dirty=$(dirty_paths "$root" "$output_file" | jq -R . | jq -s .)
  [ -n "$scope" ] || scope=$(own_scope "$root" "$pr")
  [ -n "$scope" ] || scope='{"slug":"","digests":[]}'
  audit=$(audit_listing "$root" "$main_root" "$(jq -r '.slug' <<<"$scope")" "$(jq -r '.digests[]' <<<"$scope")")
  runs=$(folder_listing "$main_root" "$run_folder")
  statuses=$( (cd "$root" && gh api "repos/{owner}/{repo}/commits/$head/statuses") 2>/dev/null | jq -S -c 'map(select(.context == "GAIA-Audit"))') ||
    usage_error "gh could not read the commit statuses for $head"
  [ -n "$statuses" ] || usage_error "gh returned no commit statuses document for $head"
  jq -n --arg root "$root" --arg run "$run_folder" --arg pr "$pr" --arg head "$head" \
    --argjson dirty "$dirty" --argjson audit "$audit" --argjson runs "$runs" --argjson statuses "$statuses" --argjson scope "$scope" \
    '{root: $root, run_folder: $run, pr: $pr, head: $head, dirty: $dirty, state: ($audit + $runs), statuses: $statuses, scope: $scope}'
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

  dirty=$(dirty_paths "$root" "$out" | paste -sd, -)
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
  capture_state "$root" "$run_folder" "$pr" "$output_file" "$(jq -c '.scope // empty' "$before")" >"$after"

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
