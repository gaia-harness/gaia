#!/usr/bin/env bash
# shellcheck shell=bash
#
# Hook-scope check: hooks reach .gaia/local and the notebook root only through
# a resolved root.
#
# A hook that builds a .gaia/local (or .notebook) path from a bare literal resolves it
# against whatever tree the hook happens to run in, so from inside a linked
# worktree a write meant for one tree lands in another with no error. Scans
# every .sh under .claude/hooks/** directly. Two assertions, both in
# gaia_check_hook_scope_manifest:
#
#   1. No bare literal   no hook holds a live `.gaia/local` or `.notebook` reference that is
#                        not immediately preceded by a path-join character,
#                        i.e. one reached without a resolved-root variable. A
#                        comment mention is allowed.
#   2. Resolver-backed   every hook outside .claude/hooks/lib/ that holds any
#                        live `.gaia/local` or `.notebook` reference names a
#                        resolver-backed lib (main-root-lib.sh, state-registry-lib.sh,
#                        red-ledger.sh, or gh-artifact-lib.sh), so the joined root traces back
#                        to one. A sourced lib under .claude/hooks/lib/ may
#                        instead take its root from its caller, as
#                        lib/audit-clearance.sh's `${root}/.gaia/local/audit`
#                        does, so it is held to assertion 1 only.
#
# Dual-mode, mirroring the repo's other check/lib scripts: source it for
# gaia_check_hook_scope_manifest, or run it directly.

# Libs whose presence, alongside a resolved (non-bare) .gaia/local reference,
# counts as "this hook derives its root from a resolver" for assertion 2 --
# the hook may source main-root-lib.sh directly, or inherit an already-
# resolver-backed helper (state-registry-lib.sh, red-ledger.sh,
# gh-artifact-lib.sh) rather than re-sourcing the resolver itself.
GAIA_HOOKCHECK_RESOLVER_LIBRARIES=(
  "main-root-lib.sh"
  "state-registry-lib.sh"
  "red-ledger.sh"
  "gh-artifact-lib.sh"
)

# _gaia_hookcheck_is_comment_line <line>: true when <line>, trimmed of
# leading whitespace, is a bash comment line. Every hook here is shell, so
# this is a shell-only classifier rather than the per-tier one the registry
# checks need, and it is defined here rather than sourced so this check
# stands alone.
_gaia_hookcheck_is_comment_line() {
  local line="$1" trimmed
  trimmed="${line#"${line%%[![:space:]]*}"}"
  [[ "$trimmed" == \#* ]]
}

# _gaia_hookcheck_is_bare_reference <line>: true when <line> holds the literal
# ".gaia/local" not immediately preceded by "/" or "\" (a resolved-root join,
# e.g. "$main_root/.gaia/local/...", always has "/" directly before it; a
# sed/grep regex pattern matching path SHAPE, e.g. 's#.*/\.gaia/local/...#',
# always has the escaped "\." there, and is parsing an already-resolved
# string rather than constructing one; a bare literal like
# ".gaia/local/audit/x.jsonl" has neither). The line-start case is its own
# test rather than an `(^|...)` alternation, whose `^` not every regex library
# reads as an anchor inside a group.
_gaia_hookcheck_is_bare_reference() {
  local preceded_pattern='[^/\\]\.(gaia/local|notebook)'
  [[ "$1" == .gaia/local* ]] || [[ "$1" == .notebook* ]] || [[ "$1" =~ $preceded_pattern ]]
}

# _gaia_hookcheck_scan <repo_root> <hook_relative_path>...: one grep over every
# hook for `.gaia/local` and one for the resolver libraries, rather than
# several per hook. Sets three newline-wrapped sets the caller looks a hook up
# in: _gaia_hookcheck_bare_lines ("file:line" per NON-COMMENT bare reference),
# _gaia_hookcheck_live_files (each file holding a NON-COMMENT reference, bare
# or resolved), and _gaia_hookcheck_resolver_files (each file naming one of
# GAIA_HOOKCHECK_RESOLVER_LIBRARIES). grep runs with -H so a single hook still
# prints its name.
_gaia_hookcheck_scan() {
  local repo_root="$1" relative_path line_number text library
  shift
  local library_arguments=()
  for library in "${GAIA_HOOKCHECK_RESOLVER_LIBRARIES[@]}"; do
    library_arguments+=(-e "$library")
  done
  _gaia_hookcheck_bare_lines=$'\n'
  _gaia_hookcheck_live_files=$'\n'
  _gaia_hookcheck_resolver_files=$'\n'
  while IFS=: read -r relative_path line_number text; do
    [ -n "$line_number" ] || continue
    _gaia_hookcheck_is_comment_line "$text" && continue
    _gaia_hookcheck_live_files+="$relative_path"$'\n'
    _gaia_hookcheck_is_bare_reference "$text" &&
      _gaia_hookcheck_bare_lines+="$relative_path:$line_number"$'\n'
  done < <(cd "$repo_root" && grep -H -n -F -e '.gaia/local' -e '.notebook' -- "$@" 2>/dev/null)
  while IFS= read -r relative_path; do
    _gaia_hookcheck_resolver_files+="$relative_path"$'\n'
  done < <(cd "$repo_root" && grep -l -F "${library_arguments[@]}" -- "$@" 2>/dev/null)
}

# gaia_check_hook_scope_manifest <repo_root>
#   Runs both assertions over every .sh under <repo_root>/.claude/hooks/**;
#   returns 0 iff both pass for every hook.
gaia_check_hook_scope_manifest() {
  local repo_root="${1:?gaia_check_hook_scope_manifest requires a repo_root argument}"
  [ -d "$repo_root/.claude/hooks" ] || {
    printf 'hook scope: no .claude/hooks directory under %s\n' "$repo_root"
    return 1
  }

  local exit_status=0 total=0 hook_path bare bare_line
  local hook_paths=()
  while IFS= read -r hook_path; do
    [ -n "$hook_path" ] || continue
    hook_paths+=("$hook_path")
  done < <(cd "$repo_root" && find .claude/hooks -name '*.sh' | sort)
  # grep with no file operand reads stdin, so an empty list never reaches it.
  [ "${#hook_paths[@]}" -eq 0 ] || _gaia_hookcheck_scan "$repo_root" "${hook_paths[@]}"

  for hook_path in ${hook_paths[@]+"${hook_paths[@]}"}; do
    total=$((total + 1))

    bare=""
    while IFS= read -r bare_line; do
      case "$bare_line" in
        "$hook_path":*) bare+="${bare:+$'\n'}$bare_line" ;;
      esac
    done <<<"$_gaia_hookcheck_bare_lines"
    if [ -n "$bare" ]; then
      printf 'BARE LITERAL: %s builds a .gaia/local or .notebook path without a resolved root; join it to a root from main-root-lib.sh (or a caller-supplied root in a lib):\n%s\n' "$hook_path" "$bare"
      exit_status=1
      continue
    fi

    case "$hook_path" in
      .claude/hooks/lib/*) continue ;;
    esac
    case "$_gaia_hookcheck_live_files" in
      *$'\n'"$hook_path"$'\n'*) ;;
      *) continue ;;
    esac
    case "$_gaia_hookcheck_resolver_files" in
      *$'\n'"$hook_path"$'\n'*) ;;
      *)
        printf 'NO RESOLVER: %s holds a resolved .gaia/local or .notebook reference but names no resolver-backed lib; source main-root-lib.sh and derive the root with gaia_resolve_main_root\n' "$hook_path"
        exit_status=1
        ;;
    esac
  done

  if [ "$total" -eq 0 ]; then
    printf 'hook scope: no hooks found under %s/.claude/hooks\n' "$repo_root"
    return 1
  fi
  [ "$exit_status" -eq 0 ] && printf 'hook scope: all %s hooks reach .gaia/local only through a resolved root\n' "$total"
  return $exit_status
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-hook-scope-manifest: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_hook_scope_manifest "$repo_root"
  exit $?
fi
