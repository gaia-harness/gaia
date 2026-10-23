#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA main-only-flow refusal helper (single-sourced).
#
# The one place that renders the "this flow is main-checkout-only" refusal.
# What motivated it: a flow that writes `.gaia/VERSION` / a lockfile / cache
# state and opens or drives a PR belongs on the main checkout, never on a
# per-SPEC worktree branch. That is the motivating case, not a membership
# test. The set carrying the refusal has grown past it, and members of that
# set match one half of the description without the other, so whether a new
# flow belongs is not answered by reading this paragraph. Before this file
# existed, /update-gaia and /update-deps each carried their own ~40-line
# copy of the same detection + message, hand-deriving the current tree with
# their own `git rev-parse --show-toplevel` instead of the shared resolver.
# This is the one definition; consumers source it instead of re-deriving
# anything. Which files those are is deliberately not listed here: an
# enumeration in a docblock drifts silently while nothing rechecks it.
# gaia:maintainer-only:start
# `CALL_SITE_FILES` in .gaia/scripts/tests/main-only-lib.bats is the roster,
# kept honest by a census test that reds when a flow drifts out of it. That
# roster covers the flow call sites only, so a shell script sourcing this
# library is pinned by its own suite instead.
# gaia:maintainer-only:end
#
# Deliberately NOT a resolver. This file sources main-root-lib.sh (the one
# canonical resolver) and calls its functions; it performs no root
# derivation of its own, so it cannot count as a second resolver
# definition.
#
# gaia_refuse_if_worktree <flow-name> [state_line_function] [own_branch_prefix]
#   <flow-name>: the slash command's own name as the caller wants it printed
#   (e.g. "/update-gaia"), used verbatim in the message.
#
#   [state_line_function]: optional. The NAME of a shell function the caller
#   defines. Called with one argument, the absolute path of
#   "<main_root>/.gaia/local/cache/shared/update-check.json", and expected to
#   print one line on stdout summarizing cached state relevant to the flow
#   (or nothing, when the cache is unusable). Its stderr and exit status are
#   ignored; only what it prints on stdout is used.
#
#   [own_branch_prefix]: optional. When non-empty and the session is in a
#   linked worktree whose current branch starts with it, the function returns 0
#   and prints nothing, so an update command re-run inside the worktree it
#   created continues there. The caller chooses the prefix because
#   `gaia_branch_classify` maps both update branch kinds and seven others to
#   one mode, so the classifier cannot tell one update command from the other;
#   matching on the caller's own prefix keeps every other worktree, including
#   the other command's, refused. A detached HEAD never matches. Pass "" as
#   the second argument to supply a prefix without a state line function.
#
#   Returns 0 (the caller falls through and continues) when the session is
#   NOT in a linked worktree, or when the main root cannot be resolved. The
#   unresolvable-main case fails OPEN on purpose, matching both of the
#   flows this replaces: an indeterminate main root is not grounds to block
#   the caller's own flow.
#
#   Returns 1, after printing the refusal to stdout, when the session IS in
#   a linked worktree and the main root resolves. The message:
#
#     <flow-name> must run from the main checkout, not a worktree.
#
#     Worktree:       <current tree root>
#     Main checkout:  <main root>
#
#     <state line -- only when state_line_function was supplied>
#
#     This session cannot move into it: ask the user to start Claude Code in
#     <main root> and run <flow-name> there.
#
#   The last line hands the step to the user because a session cannot leave
#   the worktree it lives in, and a `cd` in its shell is banned
#   (.claude/rules/shell-cwd.md).
#
#   When state_line_function is supplied but prints nothing (cache file missing,
#   jq absent, fields empty), the state line falls back to:
#   "Cached state unavailable on main; symlinks may be broken, run
#   `bash .gaia/scripts/link-worktree.sh` to repair." When state_line_function is
#   not supplied at all, the state paragraph and its surrounding blank line
#   are omitted entirely.
#
# gaia_pull_gate <command-name>
#   The pull gate for a command that starts new work (a branch, worktree,
#   claim or id). Compares the main checkout's live `.gaia/VERSION` with the
#   origin version cached as `gaiaOriginVersion` in
#   "<main_root>/.gaia/local/cache/shared/update-check.json". It reads only
#   those two files and never calls gh or the network.
#
#   Returns 0, printing nothing, when the checkout is not behind origin or
#   when anything needed is unavailable: no main root, no jq, a missing or
#   unreadable cache, a missing or non-version `gaiaOriginVersion`, a missing
#   or non-version local `.gaia/VERSION`. A teammate's claim or an available
#   update never gates; only a local version below origin's does.
#
#   When behind, prints `GAIA <origin> is on origin/<default branch> and this
#   checkout has <local>. New work needs it first.` and returns 1 from a
#   session that can pull. From inside a linked worktree, which cannot pull,
#   it also prints a `Next step:` line naming the main checkout and
#   <command-name>, and returns 2.
#
# Usage:
#   . .gaia/scripts/main-only-lib.sh
#   gaia_refuse_if_worktree "/some-flow" || exit 1
#   gaia_pull_gate "/some-flow"
#
#   # With a flow-specific state line:
#   my_state_line() { local cache_file="$1"; ...; printf '%s\n' "$line"; }
#   gaia_refuse_if_worktree "/some-flow" my_state_line || exit 1

# Sibling-location idiom matched from main-root-lib.sh's own callers
# (.gaia/scripts/link-worktree.sh): resolve this file's own directory via
# BASH_SOURCE, never cwd. Guarded so a consumer that already sourced
# main-root-lib.sh itself needs no second, redundant source.
#
# Both statements below are written for the shell that actually sources this
# file. Unlike a hook, which settings.json invokes as `bash <script>`, the
# flow call sites are markdown blocks an agent runs through its shell tool,
# so the sourcing shell is that machine's login shell -- zsh on a stock Mac.
# Under zsh BASH_SOURCE is unset, and `declare -F` declares a float and
# succeeds rather than answering whether a function exists, so the resolver
# was never sourced and every refusal returned 0: the flow continued, from a
# worktree, with no refusal printed. `command -v` asks the same question in
# either shell.
#
# The location candidates are tried in order of authority. $0 is second
# because zsh names the sourced file there, but only sometimes: under
# `zsh -c` a relative `.` drops the directory, so the bare-name and empty
# cases are skipped rather than resolving to the cwd. The last candidate is
# the repo-relative path every call site sources, from a checkout root, where
# the sibling is a tracked file present in every tree. Each candidate must
# actually hold main-root-lib.sh to win, so a wrong guess cannot be adopted.
_GAIA_MAIN_ONLY_LIBRARY_DIRECTORY=""
for _gaia_main_only_candidate in "${BASH_SOURCE[0]:-}" "${0:-}" ".gaia/scripts/main-only-lib.sh"; do
  case "$_gaia_main_only_candidate" in */*) ;; *) continue ;; esac
  _gaia_main_only_directory="$(cd "$(dirname "$_gaia_main_only_candidate")" 2>/dev/null && pwd)" || continue
  if [ -f "$_gaia_main_only_directory/main-root-lib.sh" ]; then
    _GAIA_MAIN_ONLY_LIBRARY_DIRECTORY="$_gaia_main_only_directory"
    break
  fi
done
unset _gaia_main_only_candidate _gaia_main_only_directory

if ! command -v gaia_resolve_main_root >/dev/null 2>&1 && [ -n "$_GAIA_MAIN_ONLY_LIBRARY_DIRECTORY" ]; then
  # shellcheck disable=SC1091
  source "$_GAIA_MAIN_ONLY_LIBRARY_DIRECTORY/main-root-lib.sh"
fi

# The shared fallback state line, used when a supplied state_line_function prints
# nothing. Byte-identical to the text both pre-existing copies used.
_GAIA_MAIN_ONLY_FALLBACK_STATE_LINE="Cached state unavailable on main; symlinks may be broken, run \`bash .gaia/scripts/link-worktree.sh\` to repair."

gaia_refuse_if_worktree() {
  local flow_name="$1" state_line_function="${2:-}" own_branch_prefix="${3:-}"

  gaia_is_linked_worktree || return 0

  local main_root
  main_root="$(gaia_resolve_main_root)" || return 0

  local current_root
  current_root="$(gaia_resolve_tree_root)"

  if [ -n "$own_branch_prefix" ]; then
    local current_branch
    current_branch="$(git -C "$current_root" symbolic-ref --short -q HEAD 2>/dev/null)" || current_branch=""
    case "$current_branch" in
      "$own_branch_prefix"*) return 0 ;;
    esac
  fi

  local message
  message="$flow_name must run from the main checkout, not a worktree.

Worktree:       $current_root
Main checkout:  $main_root"

  if [ -n "$state_line_function" ]; then
    local cache_file="$main_root/.gaia/local/cache/shared/update-check.json"
    local state_line
    state_line="$("$state_line_function" "$cache_file" 2>/dev/null)"
    [ -n "$state_line" ] || state_line="$_GAIA_MAIN_ONLY_FALLBACK_STATE_LINE"
    message="$message

$state_line"
  fi

  message="$message

This session cannot move into it: ask the user to start Claude Code in $main_root and run $flow_name there."

  printf '%s\n' "$message"
  return 1
}

# _gaia_pull_gate_core <version>: prints "<major> <minor> <patch>" and returns
# 0 for `N.N.N` with an optional `-prerelease`, else returns 1. Leading zeros
# are stripped so arithmetic never reads a part as octal. Parameter expansion
# only, so it behaves the same sourced from bash or zsh.
_gaia_pull_gate_core() {
  local version="$1" core rest part parts="" dots
  version="${version%%+*}"
  core="${version%%-*}"
  case "$core" in
    *[!0-9.]* | .* | *. | *..* | "") return 1 ;;
  esac
  dots="${core//[!.]/}"
  [ "${#dots}" -eq 2 ] || return 1
  rest="$core"
  while [ -n "$rest" ]; do
    part="${rest%%.*}"
    case "$rest" in
      *.*) rest="${rest#*.}" ;;
      *) rest="" ;;
    esac
    part="${part#"${part%%[!0]*}"}"
    parts="$parts ${part:-0}"
  done
  printf '%s\n' "${parts# }"
}

# _gaia_pull_gate_is_behind <local> <origin>: returns 0 when local is below
# origin. Core parts compare numerically; at equal cores a prerelease is below
# its release, and two prereleases compare as strings.
_gaia_pull_gate_is_behind() {
  local local_version="$1" origin_version="$2" local_core origin_core
  local local_major local_minor local_patch origin_major origin_minor origin_patch
  local local_prerelease="" origin_prerelease=""
  local_core="$(_gaia_pull_gate_core "$local_version")" || return 1
  origin_core="$(_gaia_pull_gate_core "$origin_version")" || return 1
  read -r local_major local_minor local_patch <<<"$local_core"
  read -r origin_major origin_minor origin_patch <<<"$origin_core"
  if [ "$local_major" -ne "$origin_major" ]; then
    [ "$local_major" -lt "$origin_major" ]
    return $?
  fi
  if [ "$local_minor" -ne "$origin_minor" ]; then
    [ "$local_minor" -lt "$origin_minor" ]
    return $?
  fi
  if [ "$local_patch" -ne "$origin_patch" ]; then
    [ "$local_patch" -lt "$origin_patch" ]
    return $?
  fi
  case "$local_version" in *-*) local_prerelease="${local_version#*-}" ;; esac
  case "$origin_version" in *-*) origin_prerelease="${origin_version#*-}" ;; esac
  [ "$local_prerelease" = "$origin_prerelease" ] && return 1
  [ -z "$local_prerelease" ] && return 1
  [ -z "$origin_prerelease" ] && return 0
  [[ "$local_prerelease" < "$origin_prerelease" ]]
}

# _gaia_pull_gate_default_branch <tree>: the default branch name without its
# `origin/` prefix, read in that order: origin/HEAD, origin/main, origin/master,
# else `main`.
_gaia_pull_gate_default_branch() {
  local tree="$1" branch
  branch="$(git -C "$tree" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || branch=""
  if [ -n "$branch" ]; then
    printf '%s\n' "${branch#origin/}"
  elif git -C "$tree" show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
    printf 'main\n'
  elif git -C "$tree" show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
    printf 'master\n'
  else
    printf 'main\n'
  fi
}

gaia_pull_gate() {
  local command_name="$1" main_root cache_file origin_version version_file local_version="" default_branch

  command -v jq >/dev/null 2>&1 || return 0

  main_root="$(gaia_resolve_main_root 2>/dev/null)" || return 0
  [ -n "$main_root" ] || return 0

  cache_file="$main_root/.gaia/local/cache/shared/update-check.json"
  [ -r "$cache_file" ] || return 0
  origin_version="$(jq -r '.gaiaOriginVersion // ""' "$cache_file" 2>/dev/null)" || return 0
  _gaia_pull_gate_core "$origin_version" >/dev/null || return 0

  version_file="$main_root/.gaia/VERSION"
  [ -r "$version_file" ] || return 0
  IFS= read -r local_version <"$version_file" || [ -n "$local_version" ] || return 0
  local_version="${local_version//[[:space:]]/}"
  _gaia_pull_gate_core "$local_version" >/dev/null || return 0

  _gaia_pull_gate_is_behind "$local_version" "$origin_version" || return 0

  default_branch="$(_gaia_pull_gate_default_branch "$main_root")"
  printf 'GAIA %s is on origin/%s and this checkout has %s. New work needs it first.\n' \
    "$origin_version" "$default_branch" "$local_version"

  if gaia_is_linked_worktree; then
    printf 'Next step: run /update-gaia in the main checkout at %s to pull, then start %s again.\n' \
      "$main_root" "$command_name"
    return 2
  fi
  return 1
}
