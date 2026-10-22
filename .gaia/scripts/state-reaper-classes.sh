# shellcheck shell=bash
# The _gaia_reaper_row_* fields and the other lowercase globals are set by
# state-reaper-lib.sh.
# shellcheck disable=SC2154
#
# Candidate enumeration and per-class reaping over state-reaper-lib.sh, whose
# header owns the retention vocabulary these functions execute.
#
# Callers load the registry (gaia_reaper_load_registry) and take a snapshot
# (gaia_reaper_snapshot) first: a candidate is processed only when the loaded
# registry classifies it to the row being reaped, so with no registry loaded
# nothing is a candidate, and with no snapshot every liveness-dependent class
# reads disabled. Every function returns 0 and prints `removed <path>`,
# `refused <path>: <reason>` and `skipped <row-id>: <reason>` lines; paths are
# relative to .gaia/local.

_gaia_reaper_classes_directory="${BASH_SOURCE[0]%/*}"
[ "$_gaia_reaper_classes_directory" = "${BASH_SOURCE[0]}" ] && _gaia_reaper_classes_directory="."
# shellcheck source=/dev/null
. "$_gaia_reaper_classes_directory/state-reaper-lib.sh"
unset _gaia_reaper_classes_directory

# An audit-loop writer holds its lock for a few jq calls, so a few seconds is
# ample; a lock still held past it belongs to a live writer, and the state
# file is left for the next run rather than deleted under it.
_GAIA_REAPER_LOCK_WAIT_SECONDS=3

# _gaia_reaper_kind_into <absolute-path>: sets _gaia_reaper_kind.
_gaia_reaper_kind_into() {
  if [ -L "$1" ]; then _gaia_reaper_kind='link'; elif [ -d "$1" ]; then _gaia_reaper_kind='dir'; else _gaia_reaper_kind='file'; fi
}

# _gaia_reaper_line_in <needle> <newline-list>
_gaia_reaper_line_in() {
  case "
${2-}
" in *"
$1
"*) return 0 ;; esac
  return 1
}

# _gaia_reaper_real_directory <local-root> <relative-directory>: rc 0 when
# the directory exists with no symlink from .gaia/local down to it.
_gaia_reaper_real_directory() {
  [ -z "$2" ] && return 0
  _gaia_registry_sweep_contained "$1" "$2" && [ -d "$1/$2" ] && [ ! -L "$1/$2" ]
}

# _gaia_reaper_walk_alternative <local-root> <alternative>: every path at the
# alternative's own depth that its pattern matches. A prefix alternative
# without a placeholder yields its direct children; one with a placeholder
# yields the paths at the placeholder's depth.
_gaia_reaper_walk_alternative() {
  local local_root="$1" pattern="${2%/}" tail head base depth base_depth slashes absolute relative
  while [ "${pattern#*<*>}" != "$pattern" ]; do
    pattern="${pattern%%<*}*${pattern#*>}"
  done
  if [ "$_gaia_reaper_row_match" = prefix ]; then
    if [ "${pattern#*\*}" = "$pattern" ]; then
      pattern="$pattern/*"
    else
      tail="${pattern#*\*}"
      pattern="${pattern%%\**}*${tail%%/*}"
    fi
  fi
  head="${pattern%%[*?[]*}"
  case "$head" in */*) base="${head%/*}" ;; *) base="" ;; esac
  slashes="${pattern//[!\/]/}"
  depth=$((${#slashes} + 1))
  base_depth=0
  if [ -n "$base" ]; then
    slashes="${base//[!\/]/}"
    base_depth=$((${#slashes} + 1))
  fi
  _gaia_reaper_real_directory "$local_root" "$base" || return 0
  while IFS= read -r -d '' absolute; do
    relative="${absolute#"$local_root"/}"
    if [ "$_gaia_reaper_row_match" = exact ]; then
      [ "$relative" = "$pattern" ] && printf '%s\n' "$relative"
    else
      # shellcheck disable=SC2254
      case "$relative" in $pattern) printf '%s\n' "$relative" ;; esac
    fi
  done < <(find -P "$local_root${base:+/$base}" -mindepth $((depth - base_depth)) -maxdepth $((depth - base_depth)) -print0 2>/dev/null)
}

# _gaia_reaper_walk_nested <local-root> <row-directory> <live-keys>: the
# topmost paths under the row directory that are not live. The walk descends
# only into a strict ancestor of a live key, so a candidate never holds
# another key's folder.
_gaia_reaper_walk_nested() {
  local local_root="$1" row_directory="$2" live_keys="$3" prefix absolute key live_key descend
  local -a queue=("")
  while [ "${#queue[@]}" -gt 0 ]; do
    prefix="${queue[0]}"
    queue=("${queue[@]:1}")
    while IFS= read -r -d '' absolute; do
      key="${prefix:+$prefix/}${absolute##*/}"
      if ! gaia_reaper_path_live "$key" "$live_keys"; then
        printf '%s/%s\n' "$row_directory" "$key"
        continue
      fi
      if [ ! -d "$absolute" ] || [ -L "$absolute" ]; then continue; fi
      descend=0
      while IFS= read -r live_key; do
        case "$live_key" in "$key"/*) descend=1 ;; esac
      done <<<"$live_keys"
      [ "$descend" = 1 ] && queue+=("$key")
    done < <(find -P "$local_root/$row_directory${prefix:+/$prefix}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  done
}

# _gaia_reaper_walk_files <local-root> <row-directory>: normalized-file rows
# yield every non-directory; audit-loop rows yield every non-directory file
# outside `.closed/`, plus the
# `.d/` and `.json.lock/` directories whole, and each top-level `.closed/`
# entry.
_gaia_reaper_walk_files() {
  local local_root="$1" row_directory="$2" root absolute
  root="$local_root/$row_directory"
  if [ "$_gaia_reaper_row_key" = normalized-file ]; then
    find -P "$root" -mindepth 1 ! -type d -print0 2>/dev/null
  else
    find -P "$root" -mindepth 1 \( -path "$root/.closed" -prune \) -o \
      \( -type d \( -name '*.d' -o -name '*.json.lock' \) -prune -print0 \) -o \( ! -type d -print0 \) 2>/dev/null
    _gaia_reaper_real_directory "$local_root" "$row_directory/.closed" &&
      find -P "$root/.closed" -mindepth 1 -maxdepth 1 -print0 2>/dev/null
  fi | while IFS= read -r -d '' absolute; do
    printf '%s\n' "${absolute#"$local_root"/}"
  done
}

# gaia_reaper_candidates <local-root> <row-json>: the row's candidates,
# classification-filtered. A normalized-path row yields only its topmost
# non-live paths, so it needs the snapshot and yields nothing without it.
gaia_reaper_candidates() {
  local local_root="${1%/}" row_json="${2-}" row_directory raw relative alternative live_keys
  _gaia_reaper_row_fields "$row_json" || return 0
  [ "$_gaia_reaper_row_root" = local ] || return 0
  [ -d "$local_root" ] && [ ! -L "$local_root" ] || return 0
  row_directory="${_gaia_reaper_row_path%%|*}"
  row_directory="${row_directory%/}"
  case "$_gaia_reaper_row_class:$_gaia_reaper_row_key" in
    branch-spent:normalized-path)
      _gaia_reaper_real_directory "$local_root" "$row_directory" || return 0
      live_keys="$(gaia_reaper_live_keys normalize)" || return 0
      raw="$(_gaia_reaper_walk_nested "$local_root" "$row_directory" "$live_keys")"
      ;;
    branch-spent:normalized-file | branch-spent:audit-loop)
      _gaia_reaper_real_directory "$local_root" "$row_directory" || return 0
      raw="$(_gaia_reaper_walk_files "$local_root" "$row_directory")"
      ;;
    *)
      raw=""
      _gaia_reaper_split_alternatives "$_gaia_reaper_row_path"
      for alternative in "${_gaia_reaper_alternatives[@]}"; do
        raw="$raw$(_gaia_reaper_walk_alternative "$local_root" "$alternative")
"
      done
      ;;
  esac
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    _gaia_reaper_kind_into "$local_root/$relative"
    _gaia_reaper_classify_into "$relative" "$_gaia_reaper_kind"
    [ "$_gaia_reaper_class_of" = "$_gaia_reaper_row_id" ] || continue
    if [ "$_gaia_reaper_kind" = dir ] && _gaia_reaper_holds_other_rows "$relative" "$_gaia_reaper_row_id"; then
      continue
    fi
    printf '%s\n' "$relative"
  done <<<"$raw"
}

# _gaia_reaper_remove_and_tidy <local-root> <row-json> <row-directory>
# <relative-path>...: safe removal, then `rmdir` of each emptied parent up to,
# never including, the row directory.
_gaia_reaper_remove_and_tidy() {
  local local_root="$1" row_json="$2" row_directory="$3" output line parent
  shift 3
  [ "$#" -gt 0 ] || return 0
  output="$(gaia_reaper_safe_remove "$local_root" "$row_json" "$@")"
  [ -n "$output" ] && printf '%s\n' "$output"
  while IFS= read -r line; do
    case "$line" in "removed "*) ;; *) continue ;; esac
    parent="${line#removed }"
    while :; do
      parent="${parent%/*}"
      case "$parent" in "$row_directory"/?*) ;; *) break ;; esac
      [ -L "$local_root/$parent" ] && break
      rmdir "$local_root/$parent" 2>/dev/null || break
    done
  done <<<"$output"
}

# _gaia_reaper_audit_unit_spent <local-root> <row-directory> <key> <days>:
# rc 0 when the key's state file and stamps directory (or, with neither, its
# lock) are older than <days>. The lock is left out otherwise, so a writer
# holding it does not make old state look fresh.
_gaia_reaper_audit_unit_spent() {
  local base="$1/$2/$3" seen=0
  if [ -e "$base.json" ]; then
    seen=1
    gaia_reaper_entry_older_than "$base.json" "$4" || return 1
  fi
  if [ -e "$base.d" ]; then
    seen=1
    gaia_reaper_entry_older_than "$base.d" "$4" || return 1
  fi
  [ "$seen" = 1 ] && return 0
  gaia_reaper_entry_older_than "$base.json.lock" "$4"
}

# _gaia_reaper_pr_guard_holds <state-file>: rc 0 when the state file records
# a numeric PR with no merge row, so the audit-loop bound may still carry it
# over to a renamed branch. A null or absent PR has no carry-over target. A
# file jq cannot read is kept.
_gaia_reaper_pr_guard_holds() {
  local pull_request
  [ -f "$1" ] || return 1
  pull_request="$(jq -r 'if (.pr | type) == "number" then (.pr | tostring) else "" end' "$1" 2>/dev/null)" || return 0
  [ -n "$pull_request" ] || return 1
  _gaia_reaper_line_in "$pull_request" "${GAIA_REAPER_MERGED_PRS-}" && return 1
  return 0
}

# _gaia_reaper_audit_key_live <key> <live-keys>: the key, or its `.d` or
# `.json.lock` sibling read as a path, holds a live key.
_gaia_reaper_audit_key_live() {
  gaia_reaper_path_live "$1" "$2" || gaia_reaper_path_live "$1.d" "$2" || gaia_reaper_path_live "$1.json.lock" "$2"
}

# _gaia_reaper_reap_audit_key <local-root> <row-json> <row-directory> <key>
# <days|none>: delete one key's state file and stamps under its lock,
# re-reading liveness, the PR guard and age inside the lock.
_gaia_reaper_reap_audit_key() {
  local local_root="$1" row_json="$2" row_directory="$3" key="$4" days="$5" state_file live_keys output=""
  local -a members=()
  state_file="$local_root/$row_directory/$key.json"
  if ! gaia_loop_lock "$state_file" $(($(date +%s) + _GAIA_REAPER_LOCK_WAIT_SECONDS)); then
    printf 'refused %s/%s.json: its audit-loop lock is held\n' "$row_directory" "$key"
    return 0
  fi
  if live_keys="$(gaia_reaper_live_keys normalize)" &&
    ! _gaia_reaper_audit_key_live "$key" "$live_keys" &&
    ! _gaia_reaper_pr_guard_holds "$state_file" &&
    { [ "$days" = none ] || _gaia_reaper_audit_unit_spent "$local_root" "$row_directory" "$key" "$days"; }; then
    [ -e "$state_file" ] && members+=("$row_directory/$key.json")
    [ -e "${state_file%.json}.d" ] && members+=("$row_directory/$key.d")
  fi
  [ "${#members[@]}" -gt 0 ] && output="$(gaia_reaper_safe_remove "$local_root" "$row_json" "${members[@]}")"
  gaia_loop_unlock "$state_file"
  [ -n "$output" ] || return 0
  printf '%s\n' "$output"
  local parent="$row_directory/$key"
  while :; do
    parent="${parent%/*}"
    case "$parent" in "$row_directory"/?*) ;; *) break ;; esac
    [ -L "$local_root/$parent" ] && break
    rmdir "$local_root/$parent" 2>/dev/null || break
  done
}

# _gaia_reaper_reap_closed <local-root> <row-json> <row-directory> <stem>
# <days|none>: one `.closed/` entry, `.json` and `.d` together.
_gaia_reaper_reap_closed() {
  local local_root="$1" row_json="$2" stem="$3/.closed/$4" days="$5" suffix
  local -a members=()
  for suffix in json d; do
    [ -e "$local_root/$stem.$suffix" ] || [ -L "$local_root/$stem.$suffix" ] || continue
    if [ "$days" != none ] && ! gaia_reaper_entry_older_than "$local_root/$stem.$suffix" "$days"; then
      return 0
    fi
    members+=("$stem.$suffix")
  done
  [ "${#members[@]}" -gt 0 ] && gaia_reaper_safe_remove "$local_root" "$row_json" "${members[@]}"
  return 0
}

# _gaia_reaper_audit_units <row-json> <candidates>: sets _gaia_reaper_keys
# and _gaia_reaper_closed_stems (newline lists, `<stem><TAB><key>` for the
# latter). An unparseable `.closed/` name yields nothing and is kept.
_gaia_reaper_audit_units() {
  local relative key stem
  _gaia_reaper_keys="" _gaia_reaper_closed_stems=""
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    key="$(gaia_reaper_entry_key "$1" "$relative")" || continue
    case "$relative" in
      */.closed/*)
        stem="${relative##*/.closed/}"
        stem="${stem%.json}"
        stem="${stem%.d}"
        _gaia_reaper_line_in "$stem	$key" "$_gaia_reaper_closed_stems" ||
          _gaia_reaper_closed_stems="$_gaia_reaper_closed_stems$stem	$key
"
        ;;
      *)
        _gaia_reaper_line_in "$key" "$_gaia_reaper_keys" || _gaia_reaper_keys="$_gaia_reaper_keys$key
"
        ;;
    esac
  done <<<"$2"
}

# _gaia_reaper_reap_audit_loop <local-root> <row-json> <row-directory>
# <candidates> <days|none> [<only-key>]
_gaia_reaper_reap_audit_loop() {
  local local_root="$1" row_json="$2" row_directory="$3" days="$5" only_key="${6-}" key stem live_keys
  _gaia_reaper_audit_units "$row_json" "$4"
  live_keys="$(gaia_reaper_live_keys normalize)" || return 0
  while IFS=$'\t' read -r stem key; do
    [ -n "$stem" ] || continue
    [ -z "$only_key" ] || [ "$key" = "$only_key" ] || continue
    _gaia_reaper_line_in "$key" "$live_keys" && continue
    _gaia_reaper_reap_closed "$local_root" "$row_json" "$row_directory" "$stem" "$days"
  done <<<"$_gaia_reaper_closed_stems"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [ -z "$only_key" ] || [ "$key" = "$only_key" ] || continue
    _gaia_reaper_audit_key_live "$key" "$live_keys" && continue
    if [ "$days" != none ]; then
      _gaia_reaper_audit_unit_spent "$local_root" "$row_directory" "$key" "$days" || continue
    fi
    _gaia_reaper_pr_guard_holds "$local_root/$row_directory/$key.json" && continue
    _gaia_reaper_reap_audit_key "$local_root" "$row_json" "$row_directory" "$key" "$days"
  done <<<"$_gaia_reaper_keys"
}

# _gaia_reaper_recheck_branches <main-root> <row-id>: the pre-delete
# re-snapshot of refs and the worktree list.
_gaia_reaper_recheck_branches() {
  _gaia_reaper_refresh_git "$1"
  [ -n "${GAIA_REAPER_BRANCHES_OK-}" ] && return 0
  printf 'skipped %s: the branch refs or the worktree list could not be re-read before deleting\n' "$2"
  return 1
}

# _gaia_reaper_reap_branch_spent <main-root> <local-root> <row-json>: a
# normalized-file dot-temp has no key and ages out under the row's days; every
# keyed candidate is re-checked against a fresh snapshot before deletion.
_gaia_reaper_reap_branch_spent() {
  local main_root="$1" local_root="$2" row_json="$3" row_directory candidates relative key window live_keys function_name
  local -a keyed=() removable=()
  row_directory="${_gaia_reaper_row_path%%|*}"
  row_directory="${row_directory%/}"
  candidates="$(gaia_reaper_candidates "$local_root" "$row_json")"
  function_name=normalize
  case "$_gaia_reaper_row_key" in slug-dot-field | slug-glob) function_name=slug ;; esac
  live_keys="$(gaia_reaper_live_keys "$function_name")" || return 0
  if [ "$_gaia_reaper_row_key" = audit-loop ]; then
    _gaia_reaper_recheck_branches "$main_root" "$_gaia_reaper_row_id" || return 0
    _gaia_reaper_reap_audit_loop "$local_root" "$row_json" "$row_directory" "$candidates" "$_gaia_reaper_row_days"
    return 0
  fi
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    window="$_gaia_reaper_row_days"
    if [ "$_gaia_reaper_row_key" = normalized-file ]; then
      case "${relative##*/}" in
        .*)
          gaia_reaper_entry_older_than "$local_root/$relative" "$window" && removable+=("$relative")
          continue
          ;;
      esac
    fi
    key="$(gaia_reaper_entry_key "$row_json" "$relative")" || continue
    _gaia_reaper_key_live "$function_name" "$key" "$live_keys" && continue
    case "$key" in session-*/*) ;; session-*) [ -n "$_gaia_reaper_row_session_days" ] && window="$_gaia_reaper_row_session_days" ;; esac
    gaia_reaper_entry_older_than "$local_root/$relative" "$window" && keyed+=("$relative")
  done <<<"$candidates"
  if [ "${#keyed[@]}" -gt 0 ]; then
    _gaia_reaper_recheck_branches "$main_root" "$_gaia_reaper_row_id" || return 0
    live_keys="$(gaia_reaper_live_keys "$function_name")" || return 0
    for relative in "${keyed[@]}"; do
      key="$(gaia_reaper_entry_key "$row_json" "$relative")" || continue
      _gaia_reaper_key_live "$function_name" "$key" "$live_keys" || removable+=("$relative")
    done
  fi
  [ "${#removable[@]}" -gt 0 ] || return 0
  _gaia_reaper_remove_and_tidy "$local_root" "$row_json" "$row_directory" "${removable[@]}"
}

# _gaia_reaper_key_live <normalize|slug> <key> <live-keys>: slugs never nest,
# so they compare by equality; normalized keys compare by path nesting.
_gaia_reaper_key_live() {
  if [ "$1" = slug ]; then _gaia_reaper_line_in "$2" "$3"; else gaia_reaper_path_live "$2" "$3"; fi
}

# _gaia_reaper_age_filters_pass <absolute-path>: the row's `types` and
# `names` filters. A symlink never passes an explicit `types` list.
_gaia_reaper_age_filters_pass() {
  local name glob
  _gaia_reaper_kind_into "$1"
  if [ -n "$_gaia_reaper_row_types" ]; then
    [ "$_gaia_reaper_kind" != link ] || return 1
    case ",$_gaia_reaper_row_types," in *",$_gaia_reaper_kind,"*) ;; *) return 1 ;; esac
  fi
  [ -n "$_gaia_reaper_row_names" ] || return 0
  name="${1##*/}"
  local rest="$_gaia_reaper_row_names"
  while :; do
    glob="${rest%%$'\036'*}"
    # shellcheck disable=SC2254
    case "$name" in $glob) return 0 ;; esac
    [ "$rest" = "$glob" ] && break
    rest="${rest#*$'\036'}"
  done
  return 1
}

# _gaia_reaper_refusal_shadows_earned <local-root> <relative-path>: rc 0 when
# the path is a clearance `.refused` whose same-digest, same-member `.ok` is
# still inside the row's window. The merge gate checks the refusal before the
# earned marker, so expiring the refusal first would flip the member to
# CLEARED with no supersede record; the refusal waits for its sibling.
_gaia_reaper_refusal_shadows_earned() {
  local earned="$1/${2%.refused}.ok"
  [ "$_gaia_reaper_row_id" = audit-clearance-markers ] || return 1
  case "$2" in *.refused) ;; *) return 1 ;; esac
  [ -e "$earned" ] || [ -L "$earned" ] || return 1
  ! gaia_reaper_entry_older_than "$earned" "$_gaia_reaper_row_days"
}

# _gaia_reaper_spec_spent <local-root> <relative-path>: a draft catalog row
# keeps the entry, any other status spends it; no row, or an id-less
# alternative, falls back to age.
_gaia_reaper_spec_spent() {
  local spec_id catalog_id catalog_status found="" status
  spec_id="$(_gaia_reaper_star_text "$2")"
  status=$?
  [ "$status" = 1 ] && return 1
  if [ "$status" = 0 ]; then
    while IFS=$'\t' read -r catalog_id catalog_status; do
      [ "$catalog_id" = "$spec_id" ] && found="${catalog_status:-unknown}"
    done <<<"${GAIA_REAPER_CATALOG_ROWS-}"
    if [ -n "$found" ]; then
      [ "$found" = draft ] && return 1
      return 0
    fi
  fi
  gaia_reaper_entry_older_than "$1/$2" "$_gaia_reaper_row_days"
}

# gaia_reaper_reap_row <main-root> <row-json>: applies the row's class with
# the current snapshot. rc 0 always.
gaia_reaper_reap_row() {
  local main_root="${1%/}" row_json="${2-}" local_root reason candidates relative
  local -a spent=()
  _gaia_reaper_row_fields "$row_json" || return 0
  if ! reason="$(gaia_reaper_row_check "$row_json")"; then
    printf 'skipped %s: %s\n' "${_gaia_reaper_row_id:-unnamed row}" "$reason"
    return 0
  fi
  [ "$_gaia_reaper_row_root" = local ] || return 0
  local_root="$main_root/.gaia/local"
  [ -d "$local_root" ] && [ ! -L "$local_root" ] || return 0
  case "$_gaia_reaper_row_class" in
    keep | owned) return 0 ;;
    branch-spent)
      if [ -z "${GAIA_REAPER_BRANCHES_OK-}" ]; then
        printf 'skipped %s: the branch refs or the worktree list could not be read\n' "$_gaia_reaper_row_id"
        return 0
      fi
      _gaia_reaper_reap_branch_spent "$main_root" "$local_root" "$row_json"
      return 0
      ;;
    tree-gone)
      if [ -z "${GAIA_REAPER_TREES_OK-}" ]; then
        printf 'skipped %s: the worktree list could not be read or keyed\n' "$_gaia_reaper_row_id"
        return 0
      fi
      ;;
    spec-finalized)
      if [ -z "${GAIA_REAPER_CATALOG_OK-}" ]; then
        printf 'skipped %s: the notebook catalog is absent or unreadable\n' "$_gaia_reaper_row_id"
        return 0
      fi
      ;;
  esac
  candidates="$(gaia_reaper_candidates "$local_root" "$row_json")"
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    case "$_gaia_reaper_row_class" in
      age)
        _gaia_reaper_age_filters_pass "$local_root/$relative" || continue
        gaia_reaper_entry_older_than "$local_root/$relative" "$_gaia_reaper_row_days" || continue
        ! _gaia_reaper_refusal_shadows_earned "$local_root" "$relative" || continue
        ;;
      tree-gone) _gaia_reaper_line_in "${relative##*/}" "$GAIA_REAPER_LIVE_TREE_KEYS" && continue ;;
      spec-finalized) _gaia_reaper_spec_spent "$local_root" "$relative" || continue ;;
    esac
    spent+=("$relative")
  done <<<"$candidates"
  [ "${#spent[@]}" -gt 0 ] || return 0
  if [ "$_gaia_reaper_row_class" = tree-gone ]; then
    _gaia_reaper_refresh_git "$main_root"
    if [ -z "${GAIA_REAPER_TREES_OK-}" ]; then
      printf 'skipped %s: the worktree list could not be re-read before deleting\n' "$_gaia_reaper_row_id"
      return 0
    fi
    local -a still_spent=()
    for relative in "${spent[@]}"; do
      _gaia_reaper_line_in "${relative##*/}" "$GAIA_REAPER_LIVE_TREE_KEYS" || still_spent+=("$relative")
    done
    [ "${#still_spent[@]}" -gt 0 ] || return 0
    spent=("${still_spent[@]}")
  fi
  gaia_reaper_safe_remove "$local_root" "$row_json" "${spent[@]}"
  return 0
}

# gaia_reaper_reap_key <main-root> <row-json> <key>: removes one branch key's
# entries from one branch-spent row with no age check (the post-merge
# cleanup). The caller maps its branch through the row's writer function.
gaia_reaper_reap_key() {
  local main_root="${1%/}" row_json="${2-}" key="${3-}" local_root row_directory live_keys candidates relative target
  local -a matched=()
  _gaia_reaper_row_fields "$row_json" || return 0
  local row_id="$_gaia_reaper_row_id"
  if [ "$_gaia_reaper_row_class" != branch-spent ] || [ "$_gaia_reaper_row_root" != local ]; then
    printf 'skipped %s: not a branch-spent row of .gaia/local\n' "$row_id"
    return 0
  fi
  local_root="$main_root/.gaia/local"
  [ -d "$local_root" ] && [ ! -L "$local_root" ] || return 0
  _gaia_reaper_refresh_git "$main_root"
  if [ -z "${GAIA_REAPER_BRANCHES_OK-}" ] || [ -z "${GAIA_REAPER_TREES_OK-}" ]; then
    printf 'skipped %s: the branch refs or the worktree list could not be read\n' "$row_id"
    return 0
  fi
  row_directory="${_gaia_reaper_row_path%%|*}"
  row_directory="${row_directory%/}"
  case "$_gaia_reaper_row_key" in
    slug-dot-field | slug-glob)
      live_keys="$(gaia_reaper_live_keys slug)" || return 0
      if [ -z "$key" ] || _gaia_reaper_line_in "$key" "$live_keys"; then
        printf 'skipped %s: %s is live\n' "$row_id" "$key"
        return 0
      fi
      candidates="$(gaia_reaper_candidates "$local_root" "$row_json")"
      while IFS= read -r relative; do
        [ -n "$relative" ] || continue
        [ "$(gaia_reaper_entry_key "$row_json" "$relative")" = "$key" ] && matched+=("$relative")
      done <<<"$candidates"
      [ "${#matched[@]}" -gt 0 ] && gaia_reaper_safe_remove "$local_root" "$row_json" "${matched[@]}"
      return 0
      ;;
  esac
  live_keys="$(gaia_reaper_live_keys normalize)" || return 0
  if gaia_reaper_path_live "$key" "$live_keys"; then
    printf 'skipped %s: %s is live or holds a live key\n' "$row_id" "$key"
    return 0
  fi
  case "$_gaia_reaper_row_key" in
    audit-loop)
      candidates="$(gaia_reaper_candidates "$local_root" "$row_json")"
      _gaia_reaper_reap_audit_loop "$local_root" "$row_json" "$row_directory" "$candidates" none "$key"
      return 0
      ;;
    normalized-path) target="$row_directory/$key" ;;
    normalized-file) target="$row_directory/$key.json" ;;
    *) return 0 ;;
  esac
  [ -e "$local_root/$target" ] || [ -L "$local_root/$target" ] || return 0
  _gaia_reaper_kind_into "$local_root/$target"
  _gaia_reaper_classify_into "$target" "$_gaia_reaper_kind"
  [ "$_gaia_reaper_class_of" = "$row_id" ] || return 0
  [ "$(gaia_reaper_entry_key "$row_json" "$target")" = "$key" ] || return 0
  _gaia_reaper_remove_and_tidy "$local_root" "$row_json" "$row_directory" "$target"
}
