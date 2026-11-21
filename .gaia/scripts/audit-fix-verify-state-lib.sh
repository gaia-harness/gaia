# shellcheck shell=bash
#
# Repository-state helpers for audit-fix-verify.sh: the pin digest and its
# check, the snapshot of HEAD, index, dirty map and untracked list, and the
# delta of a snapshot from a baseline. Sourced only by audit-fix-verify.sh
# from its own directory, so a pinned copy sources the pinned library; the
# baseline-<r>.json shape these helpers read lives in that script's header.
#
# Reads the caller's ROOT, TEMPORARY_DIRECTORY and _here.

# shellcheck disable=SC2154  # _here is set by audit-fix-verify.sh, which sources this file

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
