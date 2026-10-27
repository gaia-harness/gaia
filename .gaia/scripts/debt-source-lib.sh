# shellcheck shell=bash
#
# Maintainer-only record of the branch that filed a tech-debt issue. This file
# is release-excluded; nothing in an adopter tree sources it. It is sourced,
# never executed, by file-tech-debt.sh (the writer) and debt-source-report.sh
# (the reader), so both sides agree on one line format and one digest.
#
# THE LINE. One HTML comment, directly after the dedup key line:
#
#   <!-- gaia-debt-source: v1 branch=<value> -->
#
# <value> is the first 12 lowercase hex characters of the SHA-256 of the
# normalized branch name (gaia_branch_normalize, so `worktree-debt+1-x` and
# `debt/1-x` agree) hashed with no trailing newline, or `detached` (the tree
# had no branch), or `unknown` (the branch could not be determined). The digest
# keeps the raw branch name, and any working-document id in it, out of the issue
# body text. It is not a privacy guarantee: a known branch name hashes to the
# same digest, which is exactly how the report finds a branch's filings.
#
# PRECEDENCE (gaia_debt_source_resolve), first match wins:
#   1. the finding file's `source_branch`, when it is a JSON string. The empty
#      string means detached; any other string is a branch name. A retry file
#      carries it so a replay records the first attempt's branch.
#   2. a non-empty flag branch (--source-branch).
#   3. the branch checked out in the tree holding the running script.
# A `source_branch` that is not a string is ignored, never a failure.
#
# THE GIT ENVIRONMENT. Every git call here strips GIT_DIR, GIT_WORK_TREE and
# GIT_COMMON_DIR first (the main-root-lib.sh precedent), because a hook or a
# nested git inherits those and would otherwise answer for a different
# repository than the directory passed in.
#
# BASH 3.2. Safe on macOS /bin/bash and under the caller's `set -u`. It never
# calls `exit`, never sets `set -e` or pipefail, and sourcing runs no external
# command. Results come back through globals, so callers must not call a
# function here inside `$(...)` when they need the globals it sets.
#
# USAGE.
#   . "$script_directory/debt-source-lib.sh"
#   gaia_debt_source_resolve "$finding_file" "$flag_branch" "$script_directory" sha256_of_text
#   body_line="$gaia_debt_source_line_text"
#
# Functions:
#   gaia_debt_source_line <value>
#   gaia_debt_source_digest <branch> [<hasher>]
#   gaia_debt_source_line_for_branch <branch> [<hasher>]
#   gaia_debt_source_tree_state <directory>      sets gaia_debt_source_tree_branch
#   gaia_debt_source_resolve <finding-file> <flag-branch> <directory> [<hasher>]
#       sets gaia_debt_source_state, gaia_debt_source_branch,
#       gaia_debt_source_line_text
#   gaia_debt_source_retain <retry-file>

# shellcheck disable=SC2034
# The constants and globals below are read by the sourcing script.
if ! command -v gaia_branch_normalize >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/branch-name-lib.sh"
fi

# ERE for a line the report accepts as a sourced line.
GAIA_DEBT_SOURCE_VALID_RE='^<!-- gaia-debt-source: v1 branch=([0-9a-f]{12}|detached) -->$'
GAIA_DEBT_SOURCE_UNKNOWN_LINE='<!-- gaia-debt-source: v1 branch=unknown -->'

gaia_debt_source_tree_branch=""
gaia_debt_source_state=""
gaia_debt_source_branch=""
gaia_debt_source_line_text=""

# The default hasher: one text argument in, its 64-hex SHA-256 out.
_gaia_debt_source_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    return 1
  fi
}

_gaia_debt_source_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git "$@"
}

gaia_debt_source_line() {
  printf '<!-- gaia-debt-source: v1 branch=%s -->' "$1"
}

gaia_debt_source_digest() {
  local hasher="${2:-_gaia_debt_source_sha256}"
  local normalized hash
  normalized="$(gaia_branch_normalize "${1-}")"
  hash="$("$hasher" "$normalized")" || return 1
  case "$hash" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#hash}" -eq 64 ] || return 1
  printf '%s' "${hash:0:12}"
}

gaia_debt_source_line_for_branch() {
  local digest
  digest="$(gaia_debt_source_digest "$@")" || return 1
  gaia_debt_source_line "$digest"
}

# Returns 0 on a branch, 1 on a detached HEAD, 2 on a tree git cannot read.
# `symbolic-ref`, not `--short`: --short answers `heads/<name>` when a tag
# shares the branch's name.
gaia_debt_source_tree_state() {
  local directory="${1-}" reference="" symbolic_status=0
  gaia_debt_source_tree_branch=""
  _gaia_debt_source_git -C "$directory" rev-parse --git-dir >/dev/null 2>&1 || return 2
  reference="$(_gaia_debt_source_git -C "$directory" symbolic-ref --quiet HEAD 2>/dev/null)" || symbolic_status=$?
  if [ "$symbolic_status" -eq 1 ]; then
    return 1
  fi
  case "$reference" in
    refs/heads/?*)
      gaia_debt_source_tree_branch="${reference#refs/heads/}"
      return 0
      ;;
  esac
  return 2
}

# Always returns 0; a digest that fails degrades to the unknown line.
gaia_debt_source_resolve() {
  local finding_file="${1-}" flag_branch="${2-}" directory="${3-}" hasher="${4-}"
  local field_type="" tree_status=0 digest_line=""
  gaia_debt_source_state="unknown"
  gaia_debt_source_branch=""
  gaia_debt_source_line_text="$GAIA_DEBT_SOURCE_UNKNOWN_LINE"

  if [ -f "$finding_file" ]; then
    field_type="$(jq -r 'if type == "object" then (.source_branch | type) else "none" end' "$finding_file" 2>/dev/null)" || field_type=""
  fi

  if [ "$field_type" = "string" ]; then
    gaia_debt_source_branch="$(jq -r '.source_branch' "$finding_file" 2>/dev/null)"
  elif [ -n "$flag_branch" ]; then
    gaia_debt_source_branch="$flag_branch"
  else
    gaia_debt_source_tree_state "$directory" || tree_status=$?
    if [ "$tree_status" -eq 0 ]; then
      gaia_debt_source_branch="$gaia_debt_source_tree_branch"
    elif [ "$tree_status" -eq 1 ]; then
      gaia_debt_source_branch=""
    else
      return 0
    fi
  fi

  if [ -z "$gaia_debt_source_branch" ]; then
    gaia_debt_source_state="detached"
    gaia_debt_source_line_text="$(gaia_debt_source_line detached)"
    return 0
  fi

  gaia_debt_source_state="branch"
  if digest_line="$(gaia_debt_source_line_for_branch "$gaia_debt_source_branch" ${hasher:+"$hasher"})"; then
    gaia_debt_source_line_text="$digest_line"
  fi
  return 0
}

# Records the resolved branch in a retry file that lacks one. Any failure
# leaves the file as it was.
gaia_debt_source_retain() {
  local retry_file="${1-}" temporary_file=""
  case "$gaia_debt_source_state" in
    branch | detached) ;;
    *) return 0 ;;
  esac
  [ -f "$retry_file" ] || return 0
  jq -e 'type == "object" and (has("source_branch") | not)' "$retry_file" >/dev/null 2>&1 || return 0
  temporary_file="$(mktemp "$retry_file.XXXXXX" 2>/dev/null)" || return 0
  if jq --arg branch "$gaia_debt_source_branch" '.source_branch = $branch' "$retry_file" >"$temporary_file" 2>/dev/null \
    && mv "$temporary_file" "$retry_file" 2>/dev/null; then
    return 0
  fi
  rm -f "$temporary_file" 2>/dev/null
  return 0
}
