# shellcheck shell=bash
#
# Repository-state helpers for audit-fix-verify.sh: the ENFORCEMENT_PATHS
# list, the pin digest and its check, the snapshot of HEAD, index, dirty map
# and untracked list, the delta of a snapshot from a baseline, and the judged
# path map the check records and settled compares. Sourced only by audit-fix-verify.sh
# from its own directory, so a pinned copy sources the pinned library; the
# baseline-<r>.json shape these helpers read lives in that script's header.
#
# Reads the caller's ROOT, TEMPORARY_DIRECTORY and _here.

# shellcheck disable=SC2154  # _here is set by audit-fix-verify.sh, which sources this file

# Paths a fixer may touch only when the dispositions file lists them in
# enforcement_paths_allowed (and a fix entry names them): the code that bounds
# the loop must not be editable by the actor the loop bounds. That holds for
# this verifier through its pinned copy (see the header of audit-fix-verify.sh):
# the working-tree file is protected here, and the copy that judges the round is
# out of the tree.
# shellcheck disable=SC2034 # read by audit-fix-verify-check-lib.sh
ENFORCEMENT_PATHS=(
  '.claude/hooks/audit-loop-bound.sh'         # denies a dispatch past the allowance
  '.claude/hooks/audit-loop-grant.sh'         # records the human's grant or accept line
  '.claude/hooks/block-audit-loop-write.sh'   # keeps Claude off the branch state files
  '.claude/hooks/lib/audit-loop-write-scan.sh'   # that hook's path and command scan
  '.claude/hooks/lib/gate-input-paths-guard.sh'  # that hook's protected-folder and context classes
  '.claude/hooks/lib/hook-only-scripts-guard.sh' # that hook's recorder and reaper classes
  '.claude/hooks/lib/rate-limits-guard.sh'    # that hook's per-session rate-limit reading arm
  '.claude/hooks/lib/jq-availability.sh'      # every hook's fail-closed jq check
  '.claude/hooks/lib/hook-payload.sh'         # the Bash-path hooks' one-jq payload reader
  '.gaia/scripts/audit-loop-state-lib.sh'     # state schema, locking and line parsing
  '.gaia/scripts/audit-loop-eval.sh'          # verdict and allowance formulas
  '.gaia/scripts/audit-loop-allowance-lib.sh' # the allowance fold and the gate decision
  '.gaia/scripts/audit-loop-round-lib.sh'     # the finding set and the round snapshot
  '.gaia/scripts/audit-loop-report-lib.sh'    # the checkpoint brief and the record values
  '.gaia/scripts/audit-budget-lib.sh'         # the unattended audit budget's limits and spend record
  '.gaia/scripts/audit-fix-verify.sh'         # this verifier
  '.gaia/scripts/branch-name-lib.sh'          # branch key every state path derives from
  '.gaia/scripts/main-root-lib.sh'            # main-checkout resolution for every state path
  '.gaia/scripts/exclusive-lock-lib.sh'       # the state file's lock
  '.claude/settings.json'                     # hook registrations and env knobs
  '.claude/settings.local.json'               # machine-local overrides of the same
  '.claude/hooks/audit-loop-ask-grant.sh'     # records the human's AskUserQuestion answer
  '.claude/hooks/autonomy-gate.sh'            # parks a human-only question and denies a protected edit while the switch is live
  '.gaia/scripts/context-checkpoint-lib.sh'   # shared context threshold and bands
  '.gaia/scripts/audit-dispositions-check.sh' # deterministic dispositions check
  '.gaia/scripts/audit-dispositions-grade-lib.sh'    # the dispositions grading program, lookups and outcome check
  '.gaia/scripts/audit-dispositions-snapshot-lib.sh' # the dispositions check frozen-snapshot helpers and live and snapshot checks
  '.gaia/scripts/branch-authorship-lib.sh'    # the authorship predicate the audit and filer share
  '.gaia/scripts/audit-pr-sections-lib.sh'    # renders the PR-body records and the recorded residuals
  '.gaia/scripts/pr-body-sections-lib.sh'     # the PR-body headings the audit writers and the review bundle share
  '.gaia/scripts/pr-review-record.sh'         # writes the PR review record
  '.gaia/scripts/pr-review-record-lib.sh'     # the PR review record writer's helpers and audit veto state
  '.gaia/scripts/audit-recorded-decision-lib.sh' # writes a recorded fix decision's veto
  '.gaia/scripts/audit-decided-unattended-lib.sh' # renders the decision log's PR-body section
  '.gaia/scripts/autonomy-lib.sh'             # whether the switch is live, the audit budget's size, and the decision log a spend is written to and the PR-body section reads
  '.gaia/scripts/filing-outcomes-lib.sh'      # reads which keys the filer refused as branch-authored
  '.gaia/scripts/audit-loop-signals-lib.sh'   # rubric signals and unit/member decisions
  '.gaia/scripts/audit-loop-automatic-lib.sh' # the round cap and the trigger set an unattended admission may cover
  '.gaia/scripts/audit-veto-lib.sh'           # decides veto satisfaction
  '.gaia/scripts/audit-loop-stop-lib.sh'      # decides the default-stop inputs, the stop override and the reopened round
  '.gaia/scripts/audit-triage-lib.sh'         # the triage mark the dispositions check honors
  '.gaia/scripts/audit-gate-owed.sh'          # the owed-gate record the status refusal trusts
  '.claude/agents/audit-loop-unit.md'         # the unit orchestrator's definition
  '.gaia/statusline/gaia-statusline.sh'       # writes the context reading the gate trusts
  '.gaia/statusline/context-reading.sh'       # the context reading writer
  '.gaia/statusline/gaia-statusline-left.sh'  # statusline left side, same writer chain
  '.gaia/statusline/gaia-statusline-right.sh' # statusline right side, same writer chain
  '.gaia/statusline/setup-owed.sh'            # sourced by the right side, same writer chain
  '.gaia/scripts/audit-fix-verify-state-lib.sh' # this list, and this verifier's snapshot, delta and pin helpers
  '.gaia/scripts/audit-fix-verify-check-lib.sh' # this verifier's check subcommand
  '.claude/hooks/lib/audit-digest.sh'         # branch digests the check subcommand sources from the tree
  '.claude/hooks/lib/audit-scope.sh'          # the digest's ownership classifier, loaded from the tree
  '.claude/hooks/lib/audit-scope-release.sh'  # the ownership classifier's release-change skip, loaded from the tree
  '.claude/hooks/lib/audit-machinery.sh'      # the digest's machinery path list, loaded from the tree
  '.claude/hooks/lib/audit-branch-patch.sh'   # the branch's own patch the digest keys, loaded from the tree
  '.claude/hooks/lib/audit-base-provenance.sh' # the digest's base and provenance resolution, loaded from the tree
  '.gaia/scripts/audit-key-lib.sh'            # the audit key; pinned, but audit-digest.sh loads the tree copy
)

_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git -C "$ROOT" "$@"; }

# Prints the sha256 of stdin. `shasum` is on macOS and most Linux, `sha256sum`
# is the coreutils fallback.
_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    return 1
  fi
}

# Prints the pin digest of the named files in directory $1: the sha256 of one
# `<file sha256>  <name>` line per file, in the order given.
_pin_digest() {
  local directory="$1" file_name file_digest
  shift
  for file_name in "$@"; do
    file_digest="$(_sha256 <"$directory/$file_name")" || return 1
    printf '%s  %s\n' "$file_digest" "$file_name"
  done | _sha256
}

# Succeeds when the files beside this script hash to the digest the baseline
# file $1 recorded. Fails closed on a baseline with no pin record or a pinned
# name that is not a plain file name.
_verify_pin() {
  local baseline_file="$1" want got file_name files=()
  want="$(jq -r '.verifier_digest // empty' "$baseline_file" 2>/dev/null)" || return 1
  [ -n "$want" ] || return 1
  while IFS= read -r file_name; do
    case "$file_name" in
      '' | */* | .*) return 1 ;;
    esac
    files+=("$file_name")
  done < <(jq -r '(.verifier_files // [])[]' "$baseline_file" 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || return 1
  got="$(_pin_digest "$_here" "${files[@]}")" || return 1
  [ "$got" = "$want" ]
}

# Atomic write: stdin to a temp file beside the destination, then mv.
_atomic_write() {
  local destination="$1" temporary_file
  mkdir -p "$(dirname "$destination")" || return 1
  temporary_file="$(mktemp "$destination.XXXXXX")" || return 1
  if cat >"$temporary_file" && mv "$temporary_file" "$destination"; then
    return 0
  fi
  rm -f "$temporary_file"
  return 1
}

_is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# Prints the tree id of the root's working content (tracked files as they are
# on disk plus untracked, unignored ones), built in a throwaway index so the
# real index is untouched.
_working_tree_id() {
  local index_file="$TEMPORARY_DIRECTORY/wt-index"
  rm -f "$index_file"
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR GIT_INDEX_FILE="$index_file" git -C "$ROOT" read-tree HEAD >/dev/null 2>&1 || return 1
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR GIT_INDEX_FILE="$index_file" git -C "$ROOT" add -A >/dev/null 2>&1 || return 1
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR GIT_INDEX_FILE="$index_file" git -C "$ROOT" write-tree 2>/dev/null
}

# Snapshot the current repo state into directory $1: head, index digest, a
# dirty map (path to working-content blob hash, or "deleted") and the
# untracked list.
snapshot_state() {
  local snapshot_directory="$1" file_path content_hash
  mkdir -p "$snapshot_directory" || return 1
  _git rev-parse HEAD >"$snapshot_directory/head" 2>/dev/null || return 1
  _git ls-files -s -z >"$snapshot_directory/index.raw" 2>/dev/null || return 1
  _sha256 <"$snapshot_directory/index.raw" >"$snapshot_directory/index_digest" || return 1
  # --no-renames: a rename would otherwise list only the new name and hide
  # the deleted old path.
  _git diff --no-ext-diff --no-renames --name-only -z HEAD -- >"$snapshot_directory/dirty.raw" 2>/dev/null || return 1
  : >"$snapshot_directory/dirty.tsv"
  while IFS= read -r -d '' file_path; do
    case "$file_path" in
      *$'\n'*) return 1 ;;
    esac
    if [ -e "$ROOT/$file_path" ] || [ -L "$ROOT/$file_path" ]; then
      content_hash="$(_git hash-object -- "$file_path" 2>/dev/null)" || content_hash='unreadable'
    else
      content_hash='deleted'
    fi
    printf '%s\t%s\n' "$content_hash" "$file_path" >>"$snapshot_directory/dirty.tsv"
  done <"$snapshot_directory/dirty.raw"
  jq -Rn '[inputs | capture("^(?<content_hash>[^\t]*)\t(?<file_path>.*)$")] | map({key: .file_path, value: .content_hash}) | from_entries' \
    <"$snapshot_directory/dirty.tsv" >"$snapshot_directory/dirty.json" || return 1
  _git ls-files --others --exclude-standard -z >"$snapshot_directory/untracked.raw" 2>/dev/null || return 1
  : >"$snapshot_directory/untracked.txt"
  while IFS= read -r -d '' file_path; do
    case "$file_path" in
      *$'\n'*) return 1 ;;
    esac
    printf '%s\n' "$file_path" >>"$snapshot_directory/untracked.txt"
  done <"$snapshot_directory/untracked.raw"
  LC_ALL=C sort -u "$snapshot_directory/untracked.txt" -o "$snapshot_directory/untracked.txt"
  return 0
}

# Delta of the current snapshot ($2) from a baseline file ($1), as sorted path
# lists in $2/d_mod (content differs from the baseline value), $2/d_rev (a
# baseline-dirty path now equal to HEAD) and $2/d_unt (an untracked path added
# or removed).
compute_delta() {
  local baseline_file="$1" current_directory="$2"
  jq -r --slurpfile current_dirty "$current_directory/dirty.json" \
    '.dirty as $baseline_dirty | $current_dirty[0] | to_entries[] | select($baseline_dirty[.key] != .value) | .key' "$baseline_file" |
    LC_ALL=C sort -u >"$current_directory/d_mod" || return 1
  jq -r --slurpfile current_dirty "$current_directory/dirty.json" \
    '.dirty | keys[] as $dirty_path | select(($current_dirty[0] | has($dirty_path)) | not) | $dirty_path' "$baseline_file" |
    LC_ALL=C sort -u >"$current_directory/d_rev" || return 1
  jq -r '.untracked[]' "$baseline_file" | LC_ALL=C sort -u >"$current_directory/base_untracked.txt" || return 1
  {
    LC_ALL=C comm -13 "$current_directory/base_untracked.txt" "$current_directory/untracked.txt"
    LC_ALL=C comm -23 "$current_directory/base_untracked.txt" "$current_directory/untracked.txt"
  } | LC_ALL=C sort -u >"$current_directory/d_unt"
  return 0
}

# Writes $1/judged.json from the snapshot in $1: each path whose working
# content differs from HEAD, and each untracked path, mapped to its
# working-content blob hash (or deleted, or unreadable). Untracked paths are
# hashed here, unlike in the baseline, so a later edit to a new file shows.
judged_paths() {
  local snapshot_directory="$1" file_path content_hash
  : >"$snapshot_directory/untracked.tsv"
  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    content_hash="$(_git hash-object -- "$file_path" 2>/dev/null)" || content_hash='unreadable'
    printf '%s\t%s\n' "$content_hash" "$file_path" >>"$snapshot_directory/untracked.tsv"
  done <"$snapshot_directory/untracked.txt"
  jq -Rn --slurpfile dirty "$snapshot_directory/dirty.json" \
    '$dirty[0] + ([inputs | capture("^(?<content_hash>[^\t]*)\t(?<file_path>.*)$")]
      | map({key: .file_path, value: .content_hash}) | from_entries)' \
    <"$snapshot_directory/untracked.tsv" >"$snapshot_directory/judged.json"
}
