#!/usr/bin/env bash
# audit-quick-classify-paths-lib.sh: the quick classifier's path stage and the
# decision line both stages print. Sourced by audit-quick-classify-lib.sh, whose
# header owns the path classes and content markers this stage applies.

# The decision line both stages print; anything else is an internal failure.
_quick_emit() {
  local status="$1" output="$2" tab rest reason path location
  tab="$(printf '\t')"
  [ "$status" -eq 0 ] || return 2
  if [ "$output" = "quick" ]; then
    printf 'quick\n'
    return 0
  fi
  case "$output" in
    "deep$tab"*) ;;
    *) return 2 ;;
  esac
  rest="${output#deep"$tab"}"
  reason="${rest%%"$tab"*}"
  rest="${rest#*"$tab"}"
  path="${rest%"$tab"*}"
  location="${rest##*"$tab"}"
  case "$reason" in
    quick-[a-z]*) ;;
    *) return 2 ;;
  esac
  case "$path" in
    "" | *"$tab"*) return 2 ;;
  esac
  case "$location" in
    -) ;;
    pre:[1-9]* | post:[1-9]*)
      case "${location#*:}" in
        *[!0-9]*) return 2 ;;
      esac
      ;;
    *) return 2 ;;
  esac
  printf '%s\n' "$output"
}

# Reads <paths-file> into QUICK_SELECTED_PATHS. An empty set, or a path holding
# a tab or carriage return (which the output line cannot carry), is a usage
# failure the caller turns into exit 2.
_quick_read_paths() {
  local paths_file="$1" path tab carriage
  tab="$(printf '\t')"
  carriage="$(printf '\r')"
  QUICK_SELECTED_PATHS=()
  [ -f "$paths_file" ] || return 1
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    case "$path" in
      *"$tab"* | *"$carriage"*) return 1 ;;
    esac
    QUICK_SELECTED_PATHS[${#QUICK_SELECTED_PATHS[@]}]="$path"
  done <"$paths_file"
  [ "${#QUICK_SELECTED_PATHS[@]}" -gt 0 ]
}

# _quick_story_admitted <story>: 0 when the story's own component is in the
# selected set and is of class component.
_quick_story_admitted() {
  local component candidate
  component="$(quick_story_component "$1")" || return 1
  [ "$(quick_path_class "$component")" = "component" ] || return 1
  for candidate in ${QUICK_SELECTED_PATHS[@]+"${QUICK_SELECTED_PATHS[@]}"}; do
    [ "$candidate" = "$component" ] && return 0
  done
  return 1
}

# _quick_blob_has_marker <root> <rev> <path> <scratch>: 0 when the blob holds an
# always-deep content marker, 1 when it does not, 2 when it cannot be read.
_quick_blob_has_marker() {
  local status=0
  git -C "$1" show "$2:$3" >"$4/marker-blob" 2>/dev/null || return 2
  LC_ALL=C grep -Eiq -e "$QUICK_CONTENT_MARKERS" "$4/marker-blob" || status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

_quick_paths_run() {
  local root="$1" from="$2" head="$3" scratch="$4" path class meta row_path
  local source_mode target_mode change_status rows rest status
  for path in ${QUICK_SELECTED_PATHS[@]+"${QUICK_SELECTED_PATHS[@]}"}; do
    class="$(quick_path_class "$path")"
    if [ "$class" = "none" ]; then
      if ! _quick_story_admitted "$path"; then
        printf 'deep\tquick-path\t%s\t-\n' "$path"
        return 0
      fi
      class="story"
    fi
    light_route_diff "$root" --raw -z --no-abbrev "$from" "$head" -- "$path" >"$scratch/raw" 2>/dev/null || return 2
    rows=0
    source_mode=""
    target_mode=""
    change_status=""
    while IFS= read -r -d '' meta && IFS= read -r -d '' row_path; do
      rows=$((rows + 1))
      meta="${meta#:}"
      source_mode="${meta%% *}"
      rest="${meta#* }"
      target_mode="${rest%% *}"
      change_status="${meta##* }"
      [ "$row_path" = "$path" ] || return 2
    done <"$scratch/raw"
    case "$class" in
      component | page)
        if [ "$rows" -eq 0 ] || [ "$source_mode" != "000000" ]; then
          status=0
          _quick_blob_has_marker "$root" "$from" "$path" "$scratch" || status=$?
          [ "$status" -ne 2 ] || return 2
          if [ "$status" -eq 0 ]; then
            printf 'deep\tquick-path\t%s\t-\n' "$path"
            return 0
          fi
        fi
        if [ "$rows" -eq 0 ] || [ "$target_mode" != "000000" ]; then
          status=0
          _quick_blob_has_marker "$root" "$head" "$path" "$scratch" || status=$?
          [ "$status" -ne 2 ] || return 2
          if [ "$status" -eq 0 ]; then
            printf 'deep\tquick-path\t%s\t-\n' "$path"
            return 0
          fi
        fi
        ;;
    esac
    if [ "$rows" -ne 1 ] || [ "$source_mode" != "100644" ] || [ "$target_mode" != "100644" ] || [ "$change_status" != "M" ]; then
      printf 'deep\tquick-file-status\t%s\t-\n' "$path"
      return 0
    fi
  done
  printf 'quick\n'
}

# quick_classify_paths <root> <from-tree> <head-sha> <paths-file>: the path
# stage. Prints `quick` or `deep<TAB><reason><TAB><path><TAB>-`; returns 2 on
# any internal failure, printing nothing.
quick_classify_paths() {
  local scratch output status=0
  declare -F light_route_diff >/dev/null 2>&1 || return 2
  [ "$#" -eq 4 ] || return 2
  _quick_read_paths "$4" || return 2
  scratch="$(mktemp -d 2>/dev/null)" || return 2
  output="$(_quick_paths_run "$1" "$2" "$3" "$scratch")" || status=$?
  rm -rf "$scratch"
  _quick_emit "$status" "$output"
}
