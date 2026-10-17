#!/usr/bin/env bash
# move.sh: the one-time move of specs, plans and research from their
# pre-notebook locations into the notebook, plus the auto-memory report and
# repoint that go with it. Run from the main checkout.
#
# Usage: move.sh <run|check|memory-report|memory-repoint>
#
#   run              fold both legacy ledgers into the catalog, rename every
#                    spec, plan and research item into the notebook, stamp the
#                    pre-catalog reap record on rows left without a folder,
#                    freeze each legacy ledger under a backup name, then write
#                    the move-complete marker. Prints a report on stdout.
#   check            exit 3 while the move is pending, else 0.
#   memory-report    list the auto-memory files that name an old location.
#   memory-repoint   rewrite exactly the three old prefixes in exactly those
#                    files; refuses a symlink; runs no part of the move.
#
# Exit: 0 ok, 2 usage, 3 (check only) move pending, 9 refused (a precondition
# failed; nothing moved), 1 any other failure, or a status passed through from
# the notebook or lock library (for example 4 corrupt catalog, 75 lock
# timeout). After a 1 a re-run converges:
# every step is idempotent and the marker is written last.
#
# Never deletes: items move by rename (never copy), a both-present collision
# keeps both copies, ledgers are renamed in place, and this file calls no rm.
#
# Why the order matters: the fold comes first and the marker last, so a move
# interrupted before the ledgers are frozen leaves the library refusing
# consumers (legacy ledger present, marker absent) rather than serving a half-moved
# notebook. A rename is atomic on one device, which the device check enforces
# because mv across devices silently copies and then deletes.
#
# This is the one non-library script that may name the old roots, and it
# reaches the catalog only through the sourced library functions, which never
# refuse for readiness. Its own CLI verbs would refuse until the marker exists.
# The move body runs by name through the lock helpers, which shellcheck cannot follow.
# shellcheck disable=SC2329
set -uo pipefail

_move_script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/notebook-lib.sh
. "${_move_script_directory}/notebook-lib.sh" || {
  echo "move: cannot load the notebook library; nothing moved" >&2
  exit 1
}

_MOVE_COMMAND="bash .gaia/scripts/notebook/move.sh"
_MOVE_BACKUP_NAME="ledger.pre-notebook.json"

_move_usage() {
  printf 'usage: move.sh {run | check | memory-report | memory-repoint}\n' >&2
  return 2
}

_move_refuse() {
  printf 'move: refused: %s\n' "$1" >&2
}

# Device id of a path. GNU stat takes -c, BSD stat takes -f; GNU's -f means
# filesystem status and would print an unrelated number, so -c is tried first.
_move_device_id() {
  local path="$1" identifier
  if identifier="$(stat -c %d -- "$path" 2>/dev/null)" && [[ "$identifier" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$identifier"
    return 0
  fi
  if identifier="$(stat -f %d -- "$path" 2>/dev/null)" && [[ "$identifier" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$identifier"
    return 0
  fi
  return 1
}

# Prints the entry names directly under a directory, dotfiles included.
_move_entry_names() {
  local directory="$1" entry
  [ -d "$directory" ] || return 0
  find "$directory" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort | while IFS= read -r entry; do
    printf '%s\n' "${entry##*/}"
  done
}

_move_names_old_prefix() {
  local file="$1" kind prefix
  for kind in specs plans research; do
    prefix="$(gaia_notebook_legacy_prefix "$kind")" || return 2
    if grep -qIF -- "$prefix" "$file" 2>/dev/null; then return 0; fi
  done
  return 1
}

# Regular files directly under the auto-memory folder that name an old prefix.
_move_memory_files() {
  local memory_directory entry
  memory_directory="$(gaia_notebook_memory_directory)" || return 0
  [ -d "$memory_directory" ] || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ -f "$memory_directory/$entry" ] && [ ! -L "$memory_directory/$entry" ] || continue
    if _move_names_old_prefix "$memory_directory/$entry"; then
      printf '%s\n' "$memory_directory/$entry"
    fi
  done < <(_move_entry_names "$memory_directory")
}

_move_memory_report() {
  _move_memory_files
}

_move_memory_repoint() {
  local memory_directory entry kind prefix replacement
  local -a expressions=()
  memory_directory="$(gaia_notebook_memory_directory)" || return 1
  [ -d "$memory_directory" ] || return 0
  # A symlink naming an old prefix through its target is refused whole, before
  # any write, so the human sees the refusal rather than a half-repointed set.
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ -L "$memory_directory/$entry" ] && _move_names_old_prefix "$memory_directory/$entry"; then
      _move_refuse "$memory_directory/$entry is a symlink that names an old location; replace it with a regular file or repoint its target by hand, then re-run. Nothing was changed."
      return 9
    fi
  done < <(_move_entry_names "$memory_directory")
  for kind in specs plans research; do
    prefix="$(gaia_notebook_legacy_prefix "$kind")" || return 1
    replacement=".notebook/$kind/"
    expressions+=(-e "s#${prefix//./\\.}#${replacement}#g")
  done
  local file content rewritten
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # Read the file whole and write it back through the same inode, keeping its
    # mode; the trailing x guards a final newline against command substitution.
    content="$(cat -- "$file"; printf x)"
    content="${content%x}"
    rewritten="$(printf '%s' "$content" | sed ${expressions[@]+"${expressions[@]}"}; printf x)"
    rewritten="${rewritten%x}"
    printf '%s' "$rewritten" > "$file" || return 1
    printf 'move: repointed %s\n' "$file"
  done < <(_move_memory_files)
}

# ---- run: preconditions ------------------------------------------------------

# Each check prints its cause and fix on stderr and returns 1 when it fails.

_move_check_main_checkout() {
  local tree_root
  tree_root="$(gaia_resolve_tree_root "${GAIA_NOTEBOOK_TREE:-}")" || tree_root=""
  if [ -z "$tree_root" ] || [ "$tree_root" != "$main_root" ]; then
    _move_refuse "run from the main checkout, not a linked worktree. Fix: cd to $main_root and run: $_MOVE_COMMAND run"
    return 1
  fi
}

_move_check_gitignore() {
  if ! _gaia_git -C "$main_root" check-ignore -q .notebook 2>/dev/null; then
    _move_refuse "$main_root does not ignore .notebook. Fix: add the line .notebook to its .gitignore, then re-run: $_MOVE_COMMAND run"
    return 1
  fi
}

# Every linked worktree's HEAD must carry the library, or a session in it would
# keep writing to the old locations after the move.
_move_check_worktrees() {
  local line worktree_path="" head="" branch="" prunable=0 offenders=0
  local porcelain
  porcelain="$(_gaia_git -C "$main_root" worktree list --porcelain 2>/dev/null)" || {
    _move_refuse "cannot list the linked worktrees of $main_root. Fix: check the repository state with git worktree list, then re-run."
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "worktree "*)
        worktree_path="${line#worktree }"; head=""; branch=""; prunable=0
        ;;
      "HEAD "*) head="${line#HEAD }" ;;
      "branch "*) branch="${line#branch refs/heads/}" ;;
      detached) branch="(detached HEAD)" ;;
      "prunable"*) prunable=1 ;;
      "")
        if _move_worktree_is_offender "$worktree_path" "$head" "$branch" "$prunable"; then offenders=1; fi
        worktree_path=""
        ;;
    esac
  done <<EOF_PORCELAIN
$porcelain

EOF_PORCELAIN
  [ "$offenders" -eq 0 ]
}

_move_worktree_is_offender() {
  local worktree_path="$1" head="$2" branch="$3" prunable="$4" physical
  [ -n "$worktree_path" ] || return 1
  [ "$prunable" -eq 0 ] || return 1
  physical="$(cd -- "$worktree_path" 2>/dev/null && pwd -P)" || physical="$worktree_path"
  [ "$physical" != "$main_root" ] || return 1
  if [ -n "$head" ] && _gaia_git -C "$main_root" cat-file -e "$head:.gaia/scripts/notebook/notebook-lib.sh" 2>/dev/null; then
    return 1
  fi
  printf 'move: refused: worktree %s (branch %s) has no notebook library at its HEAD. Fix: catch that branch up with main, or remove the worktree, then re-run: %s run\n' \
    "$worktree_path" "${branch:-unknown}" "$_MOVE_COMMAND" >&2
  return 0
}

_move_check_sentinels() {
  local root sentinel found=0
  for root in "$specs_root" "$plans_root"; do
    [ -d "$root" ] || continue
    while IFS= read -r sentinel; do
      [ -n "$sentinel" ] || continue
      printf 'move: refused: a run is live, sentinel %s exists. Fix: let that run finish or end it, then re-run: %s run\n' "$sentinel" "$_MOVE_COMMAND" >&2
      found=1
    done < <(find "$root" -name RUNNING -print | LC_ALL=C sort)
  done
  [ "$found" -eq 0 ]
}

_move_check_devices() {
  local root main_device root_device
  main_device="$(_move_device_id "$main_root")" || {
    _move_refuse "cannot read the device id of $main_root. Fix: install a stat that supports -c or -f, then re-run."
    return 1
  }
  for root in "$specs_root" "$plans_root" "$research_root"; do
    [ -d "$root" ] || continue
    root_device="$(_move_device_id "$root")" || {
      _move_refuse "cannot read the device id of $root. Fix: check the folder is readable, then re-run."
      return 1
    }
    if [ "$root_device" != "$main_device" ]; then
      _move_refuse "$root is on a different device than $main_root/.notebook, and mv across devices copies then deletes. Fix: put them on one device, then re-run: $_MOVE_COMMAND run"
      return 1
    fi
  done
}

# A ledger that is not a JSON object would fail the fold after the first rows
# landed, so it is refused up front.
_move_check_ledgers() {
  local root key ledger bad=0
  for key in specs plans; do
    root="$(gaia_notebook_legacy_root "$key" "$main_root")"
    ledger="$root/ledger.json"
    [ -f "$ledger" ] || continue
    if ! jq -e --arg key "$key" 'type == "object" and ((.[$key] // []) | type) == "array" and all((.[$key] // [])[]; type == "object")' "$ledger" >/dev/null 2>&1; then
      printf 'move: refused: %s is not a JSON object holding a %s array of objects. Fix: repair or restore it by hand, then re-run: %s run\n' "$ledger" "$key" "$_MOVE_COMMAND" >&2
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

# ---- run: steps ----------------------------------------------------------------

_move_load_lineage_support() {
  local errexit_was=0
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  # shellcheck source=SCRIPTDIR/../usage-lib.sh
  . "${_move_script_directory}/../usage-lib.sh" 2>/dev/null
  # shellcheck source=SCRIPTDIR/../usage-resolve-lib.sh
  . "${_move_script_directory}/../usage-resolve-lib.sh" 2>/dev/null
  if [ "$errexit_was" = 1 ]; then set -e; fi
  declare -f gaia_usage_spec_lineage >/dev/null 2>&1
}

# Prints the research slugs a SPEC's lineage names, as a JSON array.
_move_lineage_research() {
  local spec_file="$1" entry slugs='[]'
  while IFS= read -r entry; do
    case "$entry" in
      research:*)
        gaia_notebook_valid_id research "${entry#research:}" 2>/dev/null || continue
        slugs="$(jq -cn --argjson list "$slugs" --arg slug "${entry#research:}" '$list + [$slug] | unique')"
        ;;
    esac
  done < <(gaia_usage_spec_lineage "$spec_file")
  printf '%s\n' "$slugs"
}

# Folds one legacy ledger into the catalog. <key> is specs or plans.
_move_fold_ledger() {
  local key="$1" kind="$2" folder_name="$3" root ledger row id mapped spec_file slugs
  root="$(gaia_notebook_legacy_root "$key" "$main_root")"
  ledger="$root/ledger.json"
  [ -f "$ledger" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id="$(printf '%s' "$row" | jq -r '.id // empty')"
    if ! gaia_notebook_valid_id "$kind" "$id" 2>/dev/null; then
      report_lines="${report_lines}move: unfoldable ledger row left only in the frozen ledger (id '$id' is not a valid $kind id)"$'\n'
      continue
    fi
    mapped="$(printf '%s' "$row" | jq -c --arg kind "$kind" --arg path "$folder_name/$id" --arg now "$move_time" '
      (.allocated_at // $now) as $created
      | del(.allocated_at)
      + {kind: $kind, path: $path, created_at: $created,
         status_changed_at: (.merged_at // .abandoned_at // .allocated_at // $now)}')" || return 1
    if [ "$kind" = spec ]; then
      spec_file=""
      if [ -f "$root/$id/SPEC.md" ]; then spec_file="$root/$id/SPEC.md"
      elif [ -f "$notebook_root/specs/$id/SPEC.md" ]; then spec_file="$notebook_root/specs/$id/SPEC.md"; fi
      if [ -n "$spec_file" ]; then
        slugs="$(_move_lineage_research "$spec_file")"
        if [ "$slugs" != "[]" ]; then
          mapped="$(printf '%s' "$mapped" | jq -c --argjson slugs "$slugs" '. + {links: ((.links // {}) + {research: $slugs})}')" || return 1
        fi
      fi
    fi
    gaia_notebook_upsert "$kind" "$id" "$mapped" || return 1
    folded_rows="${folded_rows}${kind} ${id}"$'\n'
  done < <(jq -c --arg key "$key" '(.[$key] // [])[]' "$ledger")
}

_move_fold_research() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -d "$research_root/$name" ] && [ ! -L "$research_root/$name" ] || continue
    gaia_notebook_valid_id research "$name" 2>/dev/null || continue
    gaia_notebook_register research "$name" untagged "" || return 1
  done < <(_move_entry_names "$research_root")
}

# Moves one item by rename. Sets move_result to moved, collision or failed.
_move_item() {
  local source_path="$1" destination_path="$2"
  if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
    move_result=collision
    return 0
  fi
  if mv -- "$source_path" "$destination_path"; then
    move_result=moved
    return 0
  fi
  move_result=failed
  return 1
}

_move_note_left() {
  report_lines="${report_lines}move: left in place: ${1#"$main_root/"} ($2)"$'\n'
}

_move_note_collision() {
  report_lines="${report_lines}move: collision, both copies kept (the notebook copy is untouched): ${1#"$main_root/"}"$'\n'
  collision_count=$((collision_count + 1))
}

# Moves the SPEC-NNN or PLAN-NNN folders of one legacy root.
_move_rename_numbered() {
  local key="$1" kind="$2" folder_name="$3" root name moved=0 destination_directory
  root="$(gaia_notebook_legacy_root "$key" "$main_root")"
  [ -d "$root" ] || return 0
  destination_directory="$notebook_root/$folder_name"
  mkdir -p -- "$destination_directory" || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if gaia_notebook_valid_id "$kind" "$name" 2>/dev/null && [ -d "$root/$name" ] && [ ! -L "$root/$name" ]; then
      _move_item "$root/$name" "$destination_directory/$name" || {
        printf 'move: could not rename %s into the notebook; re-run to converge\n' "$root/$name" >&2
        return 1
      }
      if [ "$move_result" = collision ]; then _move_note_collision "$root/$name"; else moved=$((moved + 1)); fi
      continue
    fi
    case "$name" in
      specs.lock | specs.lock.d) _move_note_left "$root/$name" "lock file" ;;
      ledger*.json) _move_note_left "$root/$name" "ledger" ;;
      archived) _move_note_left "$root/$name" "archived residue, review by hand" ;;
      *)
        if [ "$kind" = plan ] && [ -d "$root/$name" ] && [ ! -L "$root/$name" ]; then
          _move_note_left "$root/$name" "slug-named plan folder"
        else
          _move_note_left "$root/$name" "not a ${kind} folder"
        fi
        ;;
    esac
  done < <(_move_entry_names "$root")
  report_lines="${report_lines}move: moved ${key}: $moved"$'\n'
}

_move_rename_research() {
  local name destination_directory moved_folders=0 moved_files=0
  [ -d "$research_root" ] || return 0
  destination_directory="$notebook_root/research"
  mkdir -p -- "$destination_directory" || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      .*) _move_note_left "$research_root/$name" "dotfile"; continue ;;
    esac
    if [ -L "$research_root/$name" ]; then
      _move_note_left "$research_root/$name" "symlink"
      continue
    fi
    if [ -d "$research_root/$name" ] && ! gaia_notebook_valid_id research "$name" 2>/dev/null; then
      _move_note_left "$research_root/$name" "name is not a valid research slug"
      continue
    fi
    if [ ! -d "$research_root/$name" ] && [ ! -f "$research_root/$name" ]; then
      _move_note_left "$research_root/$name" "not a regular file or folder"
      continue
    fi
    _move_item "$research_root/$name" "$destination_directory/$name" || {
      printf 'move: could not rename %s into the notebook; re-run to converge\n' "$research_root/$name" >&2
      return 1
    }
    if [ "$move_result" = collision ]; then
      _move_note_collision "$research_root/$name"
    elif [ -d "$destination_directory/$name" ]; then
      moved_folders=$((moved_folders + 1))
    else
      moved_files=$((moved_files + 1))
      report_lines="${report_lines}move: loose research file moved: research/$name"$'\n'
    fi
  done < <(_move_entry_names "$research_root")
  report_lines="${report_lines}move: moved research folders: $moved_folders"$'\n'
  report_lines="${report_lines}move: moved loose research files: $moved_files"$'\n'
}

# Stamps the pre-catalog reap record on each folded row whose folder is gone.
_move_stamp_reaps() {
  local entry kind id folder_name row
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    kind="${entry%% *}"
    id="${entry#* }"
    folder_name="$(_gaia_notebook_kind_folder "$kind")"
    [ -e "$notebook_root/$folder_name/$id" ] && continue
    row="$(gaia_notebook_row "$kind" "$id")" || return 1
    if printf '%s' "$row" | jq -e 'has("reap")' >/dev/null; then continue; fi
    gaia_notebook_update "$kind" "$id" '{"reap":{"at":null,"by":"pre-catalog"}}' || return 1
  done <<EOF_FOLDED
$folded_rows
EOF_FOLDED
}

_move_freeze_ledgers() {
  local key root
  for key in specs plans; do
    root="$(gaia_notebook_legacy_root "$key" "$main_root")"
    [ -f "$root/ledger.json" ] || continue
    if [ -e "$root/$_MOVE_BACKUP_NAME" ] || [ -L "$root/$_MOVE_BACKUP_NAME" ]; then
      _move_note_left "$root/ledger.json" "a frozen backup already exists beside it, so it was not renamed over it"
      continue
    fi
    mv -- "$root/ledger.json" "$root/$_MOVE_BACKUP_NAME" || {
      printf 'move: could not rename %s; re-run to converge\n' "$root/ledger.json" >&2
      return 1
    }
    report_lines="${report_lines}move: ledger frozen as ${_MOVE_BACKUP_NAME}: ${root#"$main_root/"}"$'\n'
  done
}

# Lists text files that name an old prefix, under the run states and inside the
# moved notebook, so the human can repoint them.
_move_report_stale_references() {
  local kind prefix file state_directory
  local -a patterns=()
  for kind in specs plans research; do
    prefix="$(gaia_notebook_legacy_prefix "$kind")" || return 1
    patterns+=(-e "$prefix")
  done
  state_directory="$main_root/.gaia/local/runs"
  if [ -d "$state_directory" ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      if grep -qIF ${patterns[@]+"${patterns[@]}"} -- "$file" 2>/dev/null; then
        report_lines="${report_lines}move: run state names an old location: ${file#"$main_root/"}"$'\n'
      fi
    done < <(find "$state_directory" -name STATE.md -type f -print | LC_ALL=C sort)
  fi
  if [ -d "$notebook_root" ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      report_lines="${report_lines}move: notebook file names an old location: ${file#"$main_root/"}"$'\n'
    done < <(grep -rIlF ${patterns[@]+"${patterns[@]}"} -- "$notebook_root" 2>/dev/null | LC_ALL=C sort)
  fi
}

_move_body() {
  local memory_file memory_count=0 marker
  report_lines=""
  folded_rows=""
  collision_count=0
  move_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  _move_fold_ledger specs spec specs || return 1
  _move_fold_ledger plans plan plans || return 1
  _move_fold_research || return 1

  _move_rename_numbered specs spec specs || return 1
  _move_rename_numbered plans plan plans || return 1
  _move_rename_research || return 1

  _move_stamp_reaps || return 1
  _move_freeze_ledgers || return 1

  marker="$(gaia_notebook_move_state)" || return 1
  if [ "$marker" != "done" ]; then
    gaia_notebook_set_move_complete || return 1
  fi

  _move_report_stale_references || return 1
  printf '%s' "$report_lines"
  printf 'move: collisions: %s\n' "$collision_count"
  while IFS= read -r memory_file; do
    [ -n "$memory_file" ] || continue
    printf 'move: memory file names an old location: %s\n' "$memory_file"
    memory_count=$((memory_count + 1))
  done < <(_move_memory_files)
  if [ "$memory_count" -gt 0 ]; then
    printf 'move: to repoint those memory files, run: %s memory-repoint\n' "$_MOVE_COMMAND"
  fi
  printf 'move: complete\n'
}

_move_under_plans_lock() {
  if [ -d "$plans_root" ]; then
    with_ledger_lock "$plans_root" gaia_notebook_with_catalog_lock "$@"
  else
    gaia_notebook_with_catalog_lock "$@"
  fi
}

_move_under_specs_lock() {
  if [ -d "$specs_root" ]; then
    with_ledger_lock "$specs_root" _move_under_plans_lock "$@"
  else
    _move_under_plans_lock "$@"
  fi
}

_move_run() {
  [ "$#" -eq 0 ] || { _move_usage; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "move: jq is required and was not found on PATH" >&2; return 1; }
  main_root="$(_gaia_notebook_main)" || { _move_refuse "the main checkout does not resolve from here. Fix: run from inside the repository's main checkout."; return 9; }
  notebook_root="$main_root/.notebook"
  specs_root="$(gaia_notebook_legacy_root specs "$main_root")"
  plans_root="$(gaia_notebook_legacy_root plans "$main_root")"
  research_root="$(gaia_notebook_legacy_root research "$main_root")"

  _move_check_main_checkout || return 9
  _move_check_gitignore || return 9
  _move_check_worktrees || return 9
  _move_check_sentinels || return 9
  _move_check_devices || return 9
  _move_check_ledgers || return 9
  _move_load_lineage_support || { echo "move: cannot load the usage libraries the SPEC lineage reader needs; nothing moved" >&2; return 1; }

  _move_under_specs_lock _move_body
}

_move_check() {
  local state
  state="$(gaia_notebook_move_state)" || return $?
  if [ "$state" = pending ]; then
    printf 'move: pending. Next step: from the main checkout, run: %s run\n' "$_MOVE_COMMAND" >&2
    return 3
  fi
  return 0
}

_move_main() {
  local verb="${1:-}"
  [ "$#" -ge 1 ] && shift
  case "$verb" in
    run) _move_run "$@" ;;
    check) [ "$#" -eq 0 ] || { _move_usage; return 2; }; _move_check ;;
    memory-report) [ "$#" -eq 0 ] || { _move_usage; return 2; }; _move_memory_report ;;
    memory-repoint) [ "$#" -eq 0 ] || { _move_usage; return 2; }; _move_memory_repoint ;;
    *) _move_usage ;;
  esac
}

_move_main "$@"
exit $?
