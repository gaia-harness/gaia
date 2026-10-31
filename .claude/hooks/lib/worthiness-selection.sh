#!/usr/bin/env bash
# The one implementation of which emergent tests a pull request puts in scope
# for the worthiness presence check. The merge hook and the worthiness step both
# call it, so the set they judge and the set the hook demands cannot drift.
#
# Sourced, never executed; nothing runs at source time.
#
# Caller contract, all of it set before the call in the caller's own shell:
#   - gaia-packages.sh and red-ledger.sh sourced, and gaia_packages_load run for
#     the tree (its failure is the caller's own package-error path).
#   - WORTHINESS_SELECTION_ERE: `gaia_package_globs_ere emergentTests`. Set but
#     empty matches nothing (no records, return 0). Unset is a caller that
#     skipped this step, so the walk returns 9 rather than read it as nothing in
#     scope.
#   - WORTHINESS_SELECTION_CLASSIFIER: absolute path of the caller's own
#     classify-determinism.mjs. It is never derived from the tree argument, so
#     the classifier that runs does not change when two trees differ.
#
# Call shape. A pipe or command substitution loses the return status and the
# error variable, and a lost refusal reads as an allowed merge:
#   walk_status=0
#   worthiness_selection_walk "$tree_root" "$base" >"$records_file" || walk_status=$?
#   # act on walk_status and WORTHINESS_SELECTION_ERROR here, in this shell
#   while IFS= read -r record; do ...; done <"$records_file"
#
# Records on stdout: <repo-relative path><TAB><extractor NDJSON line>.
# Returns 0 on a complete walk; RED_LEDGER_UNRESOLVABLE_SHAPE_STATUS or
# RED_LEDGER_OLD_FORMAT_STATUS on an extractor refusal; 9 on a classifier package
# error or a missing input. Each non-zero sets WORTHINESS_SELECTION_ERROR to the
# reason the hook prints.

# shellcheck disable=SC2034 # read by the sourcing caller
WORTHINESS_SELECTION_ERROR=''

_worthiness_selection_is_emergent=0
_worthiness_selection_package_error=''

# Sets _worthiness_selection_is_emergent to 1 only when the classifier
# affirmatively answers emergent. Exit 7 is the one failure that is not a quiet
# 0: the classifier could not read the package descriptor. Not a command
# substitution at the call site, so both variables survive.
_worthiness_selection_classify() {
  local relative_path="$1" tree_root="$2"
  local classifier_output classifier_status=0
  _worthiness_selection_is_emergent=0
  # The classifier reads the repo-relative path and finds the registry from its
  # working directory, so it runs from the tree under judgment; the cd is inside
  # a command substitution and never persists.
  classifier_output=$( cd "$tree_root" && node "$WORTHINESS_SELECTION_CLASSIFIER" "$relative_path" 2>/dev/null ) || classifier_status=$?
  if [ "$classifier_status" -eq 7 ]; then
    _worthiness_selection_package_error=$(printf '%s' "$classifier_output" | jq -r '.error // empty' 2>/dev/null)
    [ -n "$_worthiness_selection_package_error" ] || _worthiness_selection_package_error='gaia-packages: the determinism classifier could not read the package descriptor. Next step: fix .gaia/packages.json or the package descriptor and retry.'
    return 0
  fi
  [ "$classifier_status" -eq 0 ] || return 0
  [ -n "$classifier_output" ] || return 0
  if [ -n "$(printf '%s' "$classifier_output" \
    | jq -r 'select((.classification // "") == "emergent") | "emergent"' \
        2>/dev/null \
    | head -1)" ]; then
    _worthiness_selection_is_emergent=1
  fi
}

# Emit one record per test the presence check examines in <tree_root> against
# <base>: every test of an emergent file that changed, the exact renames,
# deletions, parse failures and files with no emitted tests skipped.
worthiness_selection_walk() {
  local tree_root="$1" base="$2"
  local changed='' diff_status diff_path diff_new_path
  local path relative_path extractor_error_file extractor_status extractor_error_line current_ndjson line

  WORTHINESS_SELECTION_ERROR=''
  if [ -z "${WORTHINESS_SELECTION_ERE+set}" ] || [ -z "${WORTHINESS_SELECTION_CLASSIFIER+set}" ]; then
    WORTHINESS_SELECTION_ERROR='Worthiness selection: the caller did not set WORTHINESS_SELECTION_ERE and WORTHINESS_SELECTION_CLASSIFIER before the walk, so the emergent tests in scope are unknown.'
    return 9
  fi

  # `-z` because the glob below matches a path literally: under git's default
  # core.quotePath a non-ASCII path comes back quoted and matches none of them.
  # `--name-status -M100%` reports an EXACT rename as `R100<NUL>old<NUL>new`,
  # skipped (identical content, nothing new to judge); every other status
  # carries one path, in scope at that path. A rename below 100% is reported as
  # D plus A, so its new path is in scope.
  while IFS= read -r -d '' diff_status; do
    IFS= read -r -d '' diff_path || break
    case "$diff_status" in
      R* | C*)
        IFS= read -r -d '' diff_new_path || break
        [ "$diff_status" = "R100" ] && continue
        diff_path="$diff_new_path"
        ;;
    esac
    changed="${changed}${diff_path}
"
  done < <(git -C "$tree_root" diff --name-status -z -M100% "${base}...HEAD" 2>/dev/null)
  [ -n "$changed" ] || return 0

  while IFS= read -r path; do
    [ -n "$path" ] || continue

    # The signal helper only emits for test files; a non-test file that slips
    # through emits nothing and drops out below. An empty ERE matches nothing.
    [ -n "$WORTHINESS_SELECTION_ERE" ] && [[ "$path" =~ $WORTHINESS_SELECTION_ERE ]] || continue

    relative_path=$(red_ledger_repo_relative_path "$path")

    # A deletion leaves nothing to recompute. Tested against the tree, not the
    # process working directory: from a subdirectory a cwd test answers
    # "deleted" for every file and empties the scan into a clean pass.
    [ -f "$tree_root/$relative_path" ] || continue

    # The classifier decides emergent membership. A deterministic `.ts` test is
    # RED-gated, not worthiness-gated. A classifier failure other than a package
    # error is not emergent (fail-open; the RED gate owns that surface).
    _worthiness_selection_package_error=''
    _worthiness_selection_classify "$relative_path" "$tree_root"
    if [ -n "$_worthiness_selection_package_error" ]; then
      WORTHINESS_SELECTION_ERROR="$_worthiness_selection_package_error"
      return 9
    fi
    [ "$_worthiness_selection_is_emergent" -eq 1 ] || continue

    # Run from the tree for the reason above: the helper reads the file at the
    # repo-relative path. Exit 7 (a story play it cannot follow) and exit 8 (an
    # old-format story file) refuse, because skipping would let an unreviewable
    # test through. Every other non-zero is a mid-edit parse error, skipped.
    extractor_error_file=$(mktemp "${TMPDIR:-/tmp}/worthiness-extractor-XXXXXX") || extractor_error_file=/dev/null
    extractor_status=0
    current_ndjson=$( cd "$tree_root" && red_ledger_signals "$relative_path" 2>"$extractor_error_file" ) || extractor_status=$?
    if [ "$extractor_status" = "$RED_LEDGER_UNRESOLVABLE_SHAPE_STATUS" ] || [ "$extractor_status" = "$RED_LEDGER_OLD_FORMAT_STATUS" ]; then
      extractor_error_line=$(head -n 1 "$extractor_error_file" 2>/dev/null || true)
      [ "$extractor_error_file" = /dev/null ] || rm -f "$extractor_error_file"
      WORTHINESS_SELECTION_ERROR=$(red_ledger_refusal_reason "$extractor_status" "$relative_path" "$extractor_error_line")
      return "$extractor_status"
    fi
    [ "$extractor_error_file" = /dev/null ] || rm -f "$extractor_error_file"
    [ "$extractor_status" -eq 0 ] || continue
    [ -n "$current_ndjson" ] || continue

    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$relative_path" "$line"
    done <<EOF
$current_ndjson
EOF
  done <<EOF
$changed
EOF
  return 0
}
