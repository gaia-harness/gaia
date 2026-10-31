#!/usr/bin/env bash
# Branch authorship: is a finding's site a line this branch wrote? Sourced by
# the audit loop, the tech-debt filer and the worthiness step. Runs nothing at
# source time. Bash 3.2 compatible. Never `cd`s.
#
# Self-contained on purpose: the filer and the worthiness step source it
# without the audit state library, so it carries private helpers rather than
# borrowing the state library's.
#
# The jq predicate answers three states because its callers fail in opposite
# directions. With no merge base the audit counts the finding (authored), and
# the filer files it. Each caller maps `unknown` itself.

# Git with the repository-discovery overrides stripped, so an ambient GIT_DIR
# (a git hook, a `rebase -x` step) cannot point a read at another repository.
_gaia_authorship_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git "$@"
}

# _gaia_authorship_is_oid <s>: a full sha1 or sha256 object id, lowercase hex.
_gaia_authorship_is_oid() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[0-9a-f]{40}$ || "${1-}" =~ ^[0-9a-f]{64}$ ]]
}

# jq defs. $names and $hunks are changed paths and new-side hunks against the
# merge base, null when the merge base cannot be computed. `unknown` means an
# invalid path, an invalid line, or a null $names or $hunks.
# shellcheck disable=SC2016
GAIA_AUTHORSHIP_JQ='
def safe_path: type == "string" and length > 0 and (startswith("/") | not) and (startswith("-") | not)
  and ((("/" + . + "/") | contains("/../")) | not) and (contains("\n") | not) and (contains("\u0000") | not);
def valid_line: . == null or (type == "number" and . == floor and . >= 0 and . < 1000000000);
def in_hunks($hunks): .path as $entry_path | .line as $entry_line | any($hunks[]; .p == $entry_path and .s <= $entry_line and $entry_line <= .e);
def authorship($names; $hunks):
  if (.path | safe_path | not) or (.line | valid_line | not) or $names == null or $hunks == null then "unknown"
  elif (.path as $entry_path | any($names[]; . == $entry_path)) and (.line == null or .line == 0 or in_hunks($hunks)) then "authored"
  else "not-authored" end;
'

# _gaia_authorship_hunks <git-directory> <a> <b>: one `diff -U0` of a..b, printed as
# `<path>\t<first>\t<last>` per new-side hunk. The prefixes and every option a
# user's config could flip (noprefix, mnemonicPrefix, external diff, relative,
# quotePath) are pinned on the command line. `+++ ` names a path only in a
# file header: with -U0 an added content line `++ x` prints as `+++ x`. A path
# git still quotes (a double quote, backslash or control byte in it) does not
# match any finding's path, so such a path's lines read as not authored; the
# path set from gaia_authorship_names is unaffected. rc 1 when git fails, so the
# caller fails closed rather than reading an empty hunk set as "none".
_gaia_authorship_hunks() {
  local diff_output
  _gaia_authorship_is_oid "${2-}" && _gaia_authorship_is_oid "${3-}" || return 2
  diff_output="$(_gaia_authorship_git -C "$1" -c core.quotePath=false diff -U0 -M --no-color --no-ext-diff \
    --no-relative --src-prefix=a/ --dst-prefix=b/ "$2" "$3" -- 2>/dev/null)" || return 1
  printf '%s\n' "$diff_output" |
    awk '
      /^diff --git / { in_header = 1; current_path = ""; next }
      in_header && /^\+\+\+ / {
        header_path = substr($0, 5); sub(/\t$/, "", header_path)
        if (header_path == "/dev/null") current_path = ""; else if (substr(header_path, 1, 2) == "b/") current_path = substr(header_path, 3); else current_path = header_path
        next
      }
      /^@@ / {
        in_header = 0
        if (current_path == "") next
        plus_offset = index($0, " +"); rest = substr($0, plus_offset + 2); space_offset = index(rest, " ")
        spec = substr(rest, 1, space_offset - 1); comma_offset = index(spec, ",")
        if (comma_offset) { start_line = substr(spec, 1, comma_offset - 1) + 0; line_count = substr(spec, comma_offset + 1) + 0 } else { start_line = spec + 0; line_count = 1 }
        if (line_count > 0) printf "%s\t%d\t%d\n", current_path, start_line, start_line + line_count - 1
      }'
}

# gaia_authorship_names <git-directory> <a> <b>: `diff --name-only -M` of a..b, one
# path per line (`-z` so no path is C-quoted).
gaia_authorship_names() {
  _gaia_authorship_is_oid "${2-}" && _gaia_authorship_is_oid "${3-}" || return 2
  # A subshell so pipefail carries git's own failure out without changing the
  # caller's shell options.
  (
    set -o pipefail
    _gaia_authorship_git -C "$1" diff --name-only -z -M --no-relative "$2" "$3" -- 2>/dev/null | tr '\0' '\n'
  )
}

# gaia_authorship_hunks_json <git-directory> <a> <b>: new-side hunks as JSON, or
# `null` when the diff cannot be read.
gaia_authorship_hunks_json() {
  local hunks_output
  hunks_output="$(_gaia_authorship_hunks "$@")" || { printf 'null\n'; return 0; }
  printf '%s' "$hunks_output" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
    | {p: .[0], s: (.[1] | tonumber), e: (.[2] | tonumber)})'
}

# _gaia_authorship_default_reference <git-directory>: the first reference of the
# default-branch ladder that resolves to a commit (origin's HEAD target, else
# origin/main, else local main, else master). Full ref names only, so no ref
# text can be read as an option.
_gaia_authorship_default_reference() {
  local directory="$1" reference oid
  for reference in "$(_gaia_authorship_git -C "$directory" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" \
    refs/remotes/origin/main refs/heads/main refs/heads/master; do
    case "$reference" in refs/*) ;; *) continue ;; esac
    oid="$(_gaia_authorship_git -C "$directory" rev-parse -q --verify "$reference^{commit}" 2>/dev/null)" || continue
    _gaia_authorship_is_oid "$oid" || continue
    printf '%s\n' "$reference"
    return 0
  done
  return 1
}

# gaia_authorship_merge_base <git-directory> <commit>: merge base with the default
# branch, by the ladder in _gaia_authorship_default_reference.
gaia_authorship_merge_base() {
  local directory="$1" commit="$2" reference oid merge_base
  _gaia_authorship_is_oid "$commit" || return 1
  reference="$(_gaia_authorship_default_reference "$directory")" || return 1
  oid="$(_gaia_authorship_git -C "$directory" rev-parse -q --verify "$reference^{commit}" 2>/dev/null)" || return 1
  merge_base="$(_gaia_authorship_git -C "$directory" merge-base "$oid" "$commit" 2>/dev/null)" || return 1
  _gaia_authorship_is_oid "$merge_base" || return 1
  printf '%s\n' "$merge_base"
}

# gaia_authorship_for_head <tree>: one JSON object
# {"state":"on-default-branch"|"computed"|"unknown","names","hunks"} for the
# committed HEAD of <tree> against its merge base with the default branch. It
# reads no working-tree content, so an uncommitted edit never counts. `unknown`
# (no default ref, no merge base, unreadable diff) carries null names and hunks.
gaia_authorship_for_head() {
  local tree="${1-}" reference head_commit head_tree merge_base names hunks current_ref
  if [ -z "$tree" ] || ! reference="$(_gaia_authorship_default_reference "$tree")"; then
    printf '{"state":"unknown","names":null,"hunks":null}\n'
    return 0
  fi
  if current_ref="$(_gaia_authorship_git -C "$tree" symbolic-ref -q HEAD 2>/dev/null)"; then
    case "$reference" in
      refs/remotes/origin/*) reference="refs/heads/${reference#refs/remotes/origin/}" ;;
    esac
    if [ "$current_ref" = "$reference" ]; then
      printf '{"state":"on-default-branch","names":null,"hunks":null}\n'
      return 0
    fi
  fi
  head_commit="$(_gaia_authorship_git -C "$tree" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || head_commit=""
  head_tree="$(_gaia_authorship_git -C "$tree" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)" || head_tree=""
  if _gaia_authorship_is_oid "$head_commit" && _gaia_authorship_is_oid "$head_tree" &&
    merge_base="$(gaia_authorship_merge_base "$tree" "$head_commit")" &&
    names="$(gaia_authorship_names "$tree" "$merge_base" "$head_tree" | jq -R -s -c 'split("\n") | map(select(length > 0))')" &&
    hunks="$(gaia_authorship_hunks_json "$tree" "$merge_base" "$head_tree")" && [ "$hunks" != null ]; then
    printf '{"state":"computed","names":%s,"hunks":%s}\n' "$names" "$hunks"
  else
    printf '{"state":"unknown","names":null,"hunks":null}\n'
  fi
  return 0
}

# gaia_authorship_site_state <tree> <path> <line>: `authored`, `not-authored`,
# `on-default-branch` or `unknown` for one site, exit 0. The path is normalized
# first (a leading `./` and a prefix equal to <tree> are stripped); an unsafe
# path left after that is `unknown`. <line> is an integer, or empty or `null`.
gaia_authorship_site_state() {
  local tree="${1-}" path="${2-}" line="${3-}" authorship_json state
  path="${path#./}"
  [ -n "$tree" ] && path="${path#"${tree%/}"/}"
  authorship_json="$(gaia_authorship_for_head "$tree")"
  state="$(printf '%s' "$authorship_json" | jq -r '.state')"
  if [ "$state" != computed ]; then
    printf '%s\n' "$state"
    return 0
  fi
  printf '%s' "$authorship_json" | jq -r --arg path "$path" --arg line "$line" "$GAIA_AUTHORSHIP_JQ"'
    . as $computed
    | {path: $path, line: (if $line == "" or $line == "null" then null elif ($line | test("^[0-9]{1,9}$")) then ($line | tonumber) else $line end)}
    | authorship($computed.names; $computed.hunks)' 2>/dev/null ||
    printf 'unknown\n'
}
