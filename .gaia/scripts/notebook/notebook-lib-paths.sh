# shellcheck shell=bash
# Ids, folder paths, folder listings, path classification and the auto-memory
# location for the notebook library. Sourced only by notebook-lib.sh, which
# owns the layout, the id patterns and the exit codes; see its header.

_GAIA_NOTEBOOK_SPEC_ID_PATTERN='^SPEC-[0-9]{3,}$'
_GAIA_NOTEBOOK_PLAN_ID_PATTERN='^PLAN-[0-9]{3,}$'
_GAIA_NOTEBOOK_RESEARCH_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
_GAIA_NOTEBOOK_SPEC_PLAN_PATTERN='^plan(-[0-9]+)?$'

gaia_notebook_valid_id() {
  local kind="${1:-}" id="${2:-}" pattern
  _gaia_notebook_kind_valid "$kind" || return 2
  case "$kind" in
    spec) pattern="$_GAIA_NOTEBOOK_SPEC_ID_PATTERN" ;;
    plan) pattern="$_GAIA_NOTEBOOK_PLAN_ID_PATTERN" ;;
    research) pattern="$_GAIA_NOTEBOOK_RESEARCH_ID_PATTERN" ;;
  esac
  # The C locale keeps the bracket ranges to ASCII, so no id can carry a
  # character a path or a shell glob treats specially.
  if LC_ALL=C _gaia_notebook_matches "$id" "$pattern"; then
    return 0
  fi
  printf 'notebook: invalid %s id %s\n' "$kind" "'$id'" >&2
  return 2
}

_gaia_notebook_matches() {
  [[ "$1" =~ $2 ]]
}

# Prints <main>/.notebook/<kind folder> once that folder, when present, is a
# real directory at that exact physical place; 2 when it resolves elsewhere.
_gaia_notebook_contained_kind_directory() {
  local main="$1" kind="$2" folder kind_directory physical
  folder="$(_gaia_notebook_kind_folder "$kind")" || return 2
  kind_directory="$main/.notebook/$folder"
  if [ -e "$kind_directory" ] || [ -L "$kind_directory" ]; then
    physical="$(cd -- "$kind_directory" 2>/dev/null && pwd -P)" || physical=""
    if [ "$physical" != "$kind_directory" ]; then
      printf 'notebook: %s does not resolve to itself (a symlink or not a folder); refusing\n' "$kind_directory" >&2
      return 2
    fi
  fi
  printf '%s\n' "$kind_directory"
}

gaia_notebook_kind_directory() {
  local kind="${1:-}" main folder
  _gaia_notebook_kind_valid "$kind" || return 2
  main="$(_gaia_notebook_main)" || return 1
  folder="$(_gaia_notebook_kind_folder "$kind")"
  printf '%s\n' "$main/.notebook/$folder"
}

gaia_notebook_item_directory() {
  local kind="${1:-}" id="${2:-}" main kind_directory item_directory
  gaia_notebook_valid_id "$kind" "$id" || return 2
  main="$(_gaia_notebook_main)" || return 1
  kind_directory="$(_gaia_notebook_contained_kind_directory "$main" "$kind")" || return 2
  item_directory="$kind_directory/$id"
  if [ -L "$item_directory" ]; then
    printf 'notebook: %s is a symlink; refusing\n' "$item_directory" >&2
    return 2
  fi
  printf '%s\n' "$item_directory"
}

# Prints the names of entries directly under a kind folder that pass the
# <test> predicate, sorted, skipping dotfiles, symlinks and the catalog file.
_gaia_notebook_list_entries() {
  local kind="$1" test_flag="$2" main kind_directory entry name
  main="$(_gaia_notebook_main)" || return 1
  kind_directory="$(_gaia_notebook_contained_kind_directory "$main" "$kind")" || return 2
  [ -d "$kind_directory" ] || return 0
  for entry in "$kind_directory"/*; do
    name="${entry##*/}"
    case "$name" in .* | "$_GAIA_NOTEBOOK_CATALOG_FILE") continue ;; esac
    [ -L "$entry" ] && continue
    test "$test_flag" "$entry" || continue
    printf '%s\n' "$name"
  done | LC_ALL=C sort
}

gaia_notebook_folders() {
  _gaia_notebook_kind_valid "${1:-}" || return 2
  _gaia_notebook_list_entries "$1" -d
}

gaia_notebook_loose_files() {
  if [ "${1:-}" != "research" ]; then
    printf 'notebook: loose files are listed for research only\n' >&2
    return 2
  fi
  _gaia_notebook_list_entries research -f
}

# Prints the notebook-relative remainder of an absolute or repo-relative
# path, or returns 1 when it is not inside main's notebook. An absolute path
# through a linked worktree's notebook link is resolved physically.
_gaia_notebook_relative_to_notebook() {
  local input="$1" main="$2" parent physical_parent combined stripped
  case "$input" in
    /*)
      combined="$input"
      case "$combined" in
        "$main/.notebook/"*) ;;
        *)
          parent="$(dirname -- "$input")"
          physical_parent="$(cd -- "$parent" 2>/dev/null && pwd -P)" || return 1
          combined="$physical_parent/${input##*/}"
          ;;
      esac
      case "$combined" in
        "$main/.notebook/"*) printf '%s\n' "${combined#"$main/.notebook/"}" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      stripped="${input#./}"
      case "$stripped" in
        .notebook/*) printf '%s\n' "${stripped#.notebook/}" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

gaia_notebook_classify_path() {
  local input="${1:-}" main relative top rest id child
  [ -n "$input" ] || return 1
  main="$(_gaia_notebook_main)" || return 1
  relative="$(_gaia_notebook_relative_to_notebook "$input" "$main")" || return 1
  top="${relative%%/*}"
  rest="${relative#"$top"}"
  rest="${rest#/}"
  id="${rest%%/*}"
  child="${rest#"$id"}"
  child="${child#/}"
  child="${child%%/*}"
  case "$top" in
    specs)
      gaia_notebook_valid_id spec "$id" 2>/dev/null || return 1
      if [ -n "$child" ] && LC_ALL=C _gaia_notebook_matches "$child" "$_GAIA_NOTEBOOK_SPEC_PLAN_PATTERN"; then
        printf 'spec-plan %s %s\n' "$id" "$child"
      else
        printf 'spec %s\n' "$id"
      fi
      ;;
    plans)
      gaia_notebook_valid_id plan "$id" 2>/dev/null || return 1
      printf 'plan %s\n' "$id"
      ;;
    research)
      gaia_notebook_valid_id research "$id" 2>/dev/null || return 1
      printf 'research %s\n' "$id"
      ;;
    *) return 1 ;;
  esac
}

# The project auto-memory folder, derived from the main root the same way
# the cleanse workflow derives it, so a citation check and a cleanse read the
# same folder.
gaia_notebook_memory_directory() {
  local main project_key
  if [ -n "${GAIA_NOTEBOOK_MEMORY_DIR:-}" ]; then
    printf '%s\n' "$GAIA_NOTEBOOK_MEMORY_DIR"
    return 0
  fi
  [ -n "${HOME:-}" ] || return 1
  main="$(_gaia_notebook_main)" || return 1
  project_key="$(printf '%s\n' "$main" | sed 's/[^A-Za-z0-9-]/-/g')"
  printf '%s\n' "$HOME/.claude/projects/$project_key/memory"
}
