# shellcheck shell=bash
# Catalog reads, locks and writes for the notebook library. Sourced only by
# notebook-lib.sh, which owns the schema, the exit codes, the catalog filename
# and the readiness gate; see its header. Never call these before that file
# has loaded.

_GAIA_NOTEBOOK_EMPTY_CATALOG='{"version":1,"items":[]}'

_gaia_notebook_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

_gaia_notebook_catalog_path() {
  printf '%s\n' "$1/.notebook/$_GAIA_NOTEBOOK_CATALOG_FILE"
}

_gaia_notebook_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  printf 'notebook: jq is required and was not found on PATH\n' >&2
  return 1
}

# Reads stdin as the whole catalog text and prints "ok" or the reason it is
# corrupt. Slurping catches an empty file and trailing values, both of which a
# plain jq read accepts silently.
_gaia_notebook_catalog_verdict() {
  jq -rs '
    if length != 1 then "not exactly one JSON value"
    else .[0]
      | if type != "object" then "not a JSON object"
        elif .version != 1 then "version is not 1"
        elif (.items | type) != "array" then "items is not an array"
        elif any(.items[]; type != "object") then "a row is not an object"
        elif any(.items[]; (.kind | type) != "string" or (.id | type) != "string" or (.status | type) != "string") then "a row is missing kind, id or status"
        elif any(.items[]; .kind != "spec" and .kind != "plan" and .kind != "research") then "a row has a non-canonical kind"
        else "ok" end
    end' 2>/dev/null || printf 'not valid JSON\n'
}

# _gaia_notebook_catalog_load <main>: prints the validated catalog, or the
# empty catalog when the file is absent; 4 with one named line when corrupt.
_gaia_notebook_catalog_load() {
  local main="$1" catalog_path text verdict
  _gaia_notebook_require_jq || return 1
  catalog_path="$(_gaia_notebook_catalog_path "$main")"
  if [ ! -e "$catalog_path" ] && [ ! -L "$catalog_path" ]; then
    printf '%s\n' "$_GAIA_NOTEBOOK_EMPTY_CATALOG"
    return 0
  fi
  text="$(cat -- "$catalog_path" 2>/dev/null)" || text=""
  verdict="$(printf '%s' "$text" | _gaia_notebook_catalog_verdict)"
  if [ "$verdict" != "ok" ]; then
    printf 'GAIA_NOTEBOOK_CATALOG_CORRUPT: %s: %s; nothing was changed, repair or restore it by hand\n' "$catalog_path" "$verdict" >&2
    return 4
  fi
  printf '%s\n' "$text"
}

_gaia_notebook_catalog_has_move_complete() {
  local catalog
  catalog="$(_gaia_notebook_catalog_load "$1")" || return $?
  printf '%s' "$catalog" | jq -r 'has("move_complete") and (.move_complete | type) == "object"'
}

# _gaia_notebook_lock_directory_for <main> <catalog|mint-spec|mint-plan>
_gaia_notebook_lock_directory_for() {
  printf '%s\n' "$1/.gaia/local/cache/shared/notebook-locks/$2"
}

# _gaia_notebook_lock_path <catalog|mint-spec|mint-plan>: the lock directory
# the current tree selector resolves, without creating it.
_gaia_notebook_lock_path() {
  local main
  main="$(_gaia_notebook_main)" || return 1
  _gaia_notebook_lock_directory_for "$main" "$1"
}

# Gitignore check, then create the notebook folder. Runs before every write.
_gaia_notebook_prepare_write() {
  local main="$1"
  if ! _gaia_git -C "$main" check-ignore -q .notebook 2>/dev/null; then
    printf 'notebook: %s does not ignore .notebook; add the line .notebook to its .gitignore, then retry (nothing was created)\n' "$main" >&2
    return 5
  fi
  mkdir -p -- "$main/.notebook" || return 1
}

# Runs under the catalog lock: loads the catalog, pipes it through
# <transform> [args...], and atomically writes what the transform prints. An
# empty print means no change; a non-zero transform aborts with its status.
_gaia_notebook_locked_apply() {
  local main="$1"
  shift
  local current updated verdict catalog_path temporary_path status=0
  current="$(_gaia_notebook_catalog_load "$main")" || return $?
  updated="$(printf '%s' "$current" | "$@")" || return $?
  [ -n "$updated" ] || return 0
  verdict="$(printf '%s' "$updated" | _gaia_notebook_catalog_verdict)"
  if [ "$verdict" != "ok" ]; then
    printf 'notebook: refusing to write a catalog that would be invalid (%s)\n' "$verdict" >&2
    return 2
  fi
  catalog_path="$(_gaia_notebook_catalog_path "$main")"
  temporary_path="$main/.notebook/.$_GAIA_NOTEBOOK_CATALOG_FILE.tmp.$$"
  printf '%s\n' "$updated" >"$temporary_path" || status=1
  if [ "$status" = 0 ]; then
    mv -f -- "$temporary_path" "$catalog_path" || status=1
  fi
  if [ "$status" != 0 ]; then
    rm -f -- "${temporary_path:?}"
    printf 'notebook: could not write %s\n' "$catalog_path" >&2
  fi
  return "$status"
}

# Sets the held marker for the block, restoring the previous value after, so
# the mkdir lock path (which runs the block in this shell) leaks nothing.
_gaia_notebook_holding_catalog_lock() {
  local lock_directory="$1" previous="${GAIA_NOTEBOOK_CATALOG_LOCK_HELD-}" was_set=0 status=0
  shift
  [ -n "${GAIA_NOTEBOOK_CATALOG_LOCK_HELD+x}" ] && was_set=1
  export GAIA_NOTEBOOK_CATALOG_LOCK_HELD="$lock_directory"
  "$@" || status=$?
  if [ "$was_set" = 1 ]; then
    GAIA_NOTEBOOK_CATALOG_LOCK_HELD="$previous"
  else
    unset GAIA_NOTEBOOK_CATALOG_LOCK_HELD
  fi
  return "$status"
}

# _gaia_notebook_run_under_catalog_lock <main> <command> [args...]
_gaia_notebook_run_under_catalog_lock() {
  local main="$1" lock_directory
  shift
  lock_directory="$(_gaia_notebook_lock_directory_for "$main" catalog)"
  if [ "${GAIA_NOTEBOOK_CATALOG_LOCK_HELD:-}" = "$lock_directory" ]; then
    "$@"
    return $?
  fi
  mkdir -p -- "$lock_directory" || return 1
  with_ledger_lock "$lock_directory" _gaia_notebook_holding_catalog_lock "$lock_directory" "$@"
}

# _gaia_notebook_write <main> <transform> [args...]: one catalog write.
_gaia_notebook_write() {
  local main="$1"
  _gaia_notebook_prepare_write "$main" || return $?
  _gaia_notebook_run_under_catalog_lock "$main" _gaia_notebook_locked_apply "$@"
}

gaia_notebook_with_catalog_lock() {
  local main
  [ "$#" -ge 1 ] || return 2
  main="$(_gaia_notebook_main)" || return 1
  _gaia_notebook_prepare_write "$main" || return $?
  _gaia_notebook_run_under_catalog_lock "$main" "$@"
}

gaia_notebook_with_mint_lock() {
  local kind="${1:-}" main lock_directory
  case "$kind" in
    spec | plan) ;;
    *) printf 'notebook: mint locks exist for spec and plan only, not %s\n' "'$kind'" >&2; return 2 ;;
  esac
  shift
  [ "$#" -ge 1 ] || return 2
  main="$(_gaia_notebook_main)" || return 1
  lock_directory="$(_gaia_notebook_lock_directory_for "$main" "mint-$kind")"
  mkdir -p -- "$lock_directory" || return 1
  with_ledger_lock "$lock_directory" "$@"
}

_gaia_notebook_json_object_or_refuse() {
  local label="$1" text="$2"
  if ! printf '%s' "$text" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'notebook: %s must be a JSON object\n' "$label" >&2
    return 2
  fi
}

gaia_notebook_catalog_read() {
  local main
  main="$(_gaia_notebook_main)" || return 1
  _gaia_notebook_catalog_load "$main"
}

gaia_notebook_rows() {
  local kind="${1:-}" main catalog status statuses_json='[]'
  _gaia_notebook_kind_valid "$kind" || return 2
  shift
  for status in "$@"; do
    _gaia_notebook_status_allowed "$kind" "$status" || return 2
    statuses_json="$(jq -cn --argjson list "$statuses_json" --arg status "$status" '$list + [$status]')"
  done
  main="$(_gaia_notebook_main)" || return 1
  catalog="$(_gaia_notebook_catalog_load "$main")" || return $?
  printf '%s' "$catalog" | jq --arg kind "$kind" --argjson statuses "$statuses_json" \
    '[.items[] | select(.kind == $kind) | select(($statuses | length) == 0 or (.status as $status | any($statuses[]; . == $status)))]'
}

gaia_notebook_row() {
  local kind="${1:-}" id="${2:-}" main catalog row
  gaia_notebook_valid_id "$kind" "$id" || return 2
  main="$(_gaia_notebook_main)" || return 1
  catalog="$(_gaia_notebook_catalog_load "$main")" || return $?
  row="$(printf '%s' "$catalog" | jq -c --arg kind "$kind" --arg id "$id" \
    'first(.items[] | select(.kind == $kind and .id == $id)) // empty')"
  [ -n "$row" ] || return 1
  printf '%s\n' "$row" | jq .
}

_gaia_notebook_transform_register() {
  local kind="$1" id="$2" row="$3" current
  current="$(cat)"
  if printf '%s' "$current" | jq -e --arg kind "$kind" --arg id "$id" \
    'any(.items[]; .kind == $kind and .id == $id)' >/dev/null; then
    [ "$kind" = "research" ] && return 0
    printf 'notebook: %s %s is already registered\n' "$kind" "$id" >&2
    return 2
  fi
  printf '%s' "$current" | jq --argjson row "$row" '.items += [$row]'
}

gaia_notebook_register() {
  local kind="${1:-}" id="${2:-}" status="${3:-}" subject="${4:-}" links="${5:-}" extra="${6:-}"
  local main now folder row
  gaia_notebook_valid_id "$kind" "$id" || return 2
  _gaia_notebook_status_allowed "$kind" "$status" || return 2
  if [ -n "$links" ]; then _gaia_notebook_json_object_or_refuse "links" "$links" || return 2; fi
  if [ -n "$extra" ]; then
    _gaia_notebook_json_object_or_refuse "extra fields" "$extra" || return 2
    if printf '%s' "$extra" | jq -e 'any(keys[]; . == "kind" or . == "id" or . == "path" or . == "status" or . == "created_at" or . == "status_changed_at")' >/dev/null; then
      printf 'notebook: extra fields may not set kind, id, path, status, created_at or status_changed_at\n' >&2
      return 2
    fi
  fi
  main="$(_gaia_notebook_main)" || return 1
  now="$(_gaia_notebook_now)"
  folder="$(_gaia_notebook_kind_folder "$kind")"
  row="$(jq -cn --arg kind "$kind" --arg id "$id" --arg path "$folder/$id" --arg status "$status" \
    --arg now "$now" --arg subject "$subject" --arg links "$links" --arg extra "$extra" '
      ($extra | if . == "" then {} else fromjson end)
      + {kind: $kind, id: $id, path: $path, status: $status, created_at: $now, status_changed_at: $now}
      + (if $subject == "" then {} else {subject: $subject} end)
      + (if $links == "" then {} else {links: ($links | fromjson)} end)')" || return 2
  _gaia_notebook_write "$main" _gaia_notebook_transform_register "$kind" "$id" "$row"
}

_gaia_notebook_transform_rename() {
  local kind="$1" old_id="$2" new_id="$3" new_path="$4" current
  current="$(cat)"
  if printf '%s' "$current" | jq -e --arg kind "$kind" --arg id "$new_id" \
    'any(.items[]; .kind == $kind and .id == $id)' >/dev/null; then
    printf 'notebook: %s %s already exists; rename refused\n' "$kind" "$new_id" >&2
    return 2
  fi
  if ! printf '%s' "$current" | jq -e --arg kind "$kind" --arg id "$old_id" \
    'any(.items[]; .kind == $kind and .id == $id)' >/dev/null; then
    printf 'notebook: no %s row %s to rename\n' "$kind" "$old_id" >&2
    return 6
  fi
  printf '%s' "$current" | jq --arg kind "$kind" --arg old "$old_id" --arg new "$new_id" --arg path "$new_path" \
    '.items |= map(if .kind == $kind and .id == $old then . + {id: $new, path: $path, renamed_from: $old} else . end)'
}

gaia_notebook_rename() {
  local kind="${1:-}" old_id="${2:-}" new_id="${3:-}" main folder
  gaia_notebook_valid_id "$kind" "$old_id" || return 2
  gaia_notebook_valid_id "$kind" "$new_id" || return 2
  main="$(_gaia_notebook_main)" || return 1
  folder="$(_gaia_notebook_kind_folder "$kind")"
  _gaia_notebook_write "$main" _gaia_notebook_transform_rename "$kind" "$old_id" "$new_id" "$folder/$new_id"
}

# Merges <patch> into an existing row, or refuses 6. The status stamp applies
# only when the patch moves the status and does not carry its own stamp.
_gaia_notebook_transform_update() {
  local kind="$1" id="$2" patch="$3" now="$4" current
  current="$(cat)"
  if ! printf '%s' "$current" | jq -e --arg kind "$kind" --arg id "$id" \
    'any(.items[]; .kind == $kind and .id == $id)' >/dev/null; then
    printf 'notebook: no %s row %s to update\n' "$kind" "$id" >&2
    return 6
  fi
  printf '%s' "$current" | jq --arg kind "$kind" --arg id "$id" --argjson patch "$patch" --arg now "$now" '
    .items |= map(if .kind == $kind and .id == $id then
      (if ($patch | has("status")) and ($patch.status != .status) and (($patch | has("status_changed_at")) | not)
        then . + $patch + {status_changed_at: $now} else . + $patch end)
      else . end)'
}

gaia_notebook_update() {
  local kind="${1:-}" id="${2:-}" patch="${3:-}" main status
  gaia_notebook_valid_id "$kind" "$id" || return 2
  _gaia_notebook_json_object_or_refuse "the patch" "$patch" || return 2
  if printf '%s' "$patch" | jq -e 'has("kind") or has("id")' >/dev/null; then
    printf 'notebook: a patch may not change kind or id\n' >&2
    return 2
  fi
  if printf '%s' "$patch" | jq -e 'has("status")' >/dev/null; then
    status="$(printf '%s' "$patch" | jq -r 'if (.status | type) == "string" then .status else "" end')"
    _gaia_notebook_status_allowed "$kind" "$status" || return 2
  fi
  main="$(_gaia_notebook_main)" || return 1
  _gaia_notebook_write "$main" _gaia_notebook_transform_update "$kind" "$id" "$patch" "$(_gaia_notebook_now)"
}

gaia_notebook_set_status() {
  local status_patch
  status_patch="$(jq -cn --arg status "${3:-}" '{status: $status}')" || return 2
  gaia_notebook_update "${1:-}" "${2:-}" "$status_patch"
}

gaia_notebook_record_reap() {
  local by="${3:-}" reap_patch
  if [ -z "$by" ]; then
    printf 'notebook: record_reap needs the name of the reaper\n' >&2
    return 2
  fi
  reap_patch="$(jq -cn --arg at "$(_gaia_notebook_now)" --arg by "$by" '{reap: {at: $at, by: $by}}')" || return 2
  gaia_notebook_update "${1:-}" "${2:-}" "$reap_patch"
}

gaia_notebook_snooze() {
  local until="${2:-}" snooze_patch
  if [ -z "$until" ]; then
    printf 'notebook: snooze needs an until timestamp\n' >&2
    return 2
  fi
  snooze_patch="$(jq -cn --arg until "$until" '{snoozed_until: $until}')" || return 2
  gaia_notebook_update research "${1:-}" "$snooze_patch"
}

# The one-time move's fold: create the row or shallow-merge onto it. The
# status is carried verbatim, so a fold never fails on a ledger's history, but
# the row must end up with a string status to stay schema-valid.
_gaia_notebook_transform_upsert() {
  local kind="$1" id="$2" row="$3" layout_path="$4"
  jq --arg kind "$kind" --arg id "$id" --argjson row "$row" --arg path "$layout_path" '
    if any(.items[]; .kind == $kind and .id == $id)
    then .items |= map(if .kind == $kind and .id == $id then . + $row + {kind: $kind, id: $id} else . end)
    else .items += [{kind: $kind, id: $id, path: $path} + $row + {kind: $kind, id: $id}] end'
}

gaia_notebook_upsert() {
  local kind="${1:-}" id="${2:-}" row="${3:-}" main folder
  gaia_notebook_valid_id "$kind" "$id" || return 2
  _gaia_notebook_json_object_or_refuse "the row" "$row" || return 2
  if ! printf '%s' "$row" | jq -e --arg kind "$kind" --arg id "$id" \
    '((has("kind") | not) or .kind == $kind) and ((has("id") | not) or .id == $id)' >/dev/null; then
    printf 'notebook: the row names a different kind or id than %s %s\n' "$kind" "$id" >&2
    return 2
  fi
  main="$(_gaia_notebook_main)" || return 1
  folder="$(_gaia_notebook_kind_folder "$kind")"
  _gaia_notebook_write "$main" _gaia_notebook_transform_upsert "$kind" "$id" "$row" "$folder/$id"
}

_gaia_notebook_transform_move_complete() {
  jq --arg now "$1" '. + {move_complete: {at: $now}}'
}

gaia_notebook_set_move_complete() {
  local main
  main="$(_gaia_notebook_main)" || return 1
  _gaia_notebook_write "$main" _gaia_notebook_transform_move_complete "$(_gaia_notebook_now)"
}
