# shellcheck shell=bash
# The GAIA_REAPER_* globals are read by state-reaper-classes.sh and callers.
# shellcheck disable=SC2034
#
# Retention vocabulary and the reaper's building blocks: row validation,
# the liveness snapshot, branch keys, entry age, in-process classification
# and symlink-safe removal. state-reaper-classes.sh builds candidate
# enumeration and per-class reaping on top of these functions.
#
# This header is the one owner of the retention vocabulary. Every other
# document points here; a row's own window lives only in its own
# `retention.days`.
#
# The `retention` object (on every `.entries[]` row of the state registry):
#   class         One of:
#     branch-spent    Keyed by branch. Spent when no live branch maps onto the
#                     entry under the row's `key` function and the entry is
#                     older than `days`.
#     tree-gone       Keyed by tree key (the directory name). Spent when no
#                     listed, non-prunable worktree, main included, has that
#                     tree key. No age grace.
#     spec-finalized  Keyed by SPEC id (the text the row path's single
#                     wildcard or <placeholder> matched). A catalog row with
#                     status `draft` keeps it at any age; any other status
#                     spends it. A parsed catalog with no row for the id, and
#                     an alternative with no wildcard (id-less), fall back to
#                     age under `days`.
#     age             Spent when neither the entry nor anything under it has
#                     an mtime within the last `days` x 24 hours.
#     owned           Another named reaper owns the row; never touched here.
#     keep            Durable state; never touched.
#   days          Positive integer. Required on branch-spent (grace),
#                 spec-finalized (fallback window) and age (window);
#                 forbidden on tree-gone, owned and keep.
#   key           Required on branch-spent, forbidden elsewhere. Names how
#                 an entry's key is read and which writer function maps a
#                 live branch onto it:
#     normalized-path   gaia_branch_normalize; the directory path relative to
#                       the row directory. Keys nest on `/`.
#     normalized-file   gaia_branch_normalize; a `<key>.json` file's path
#                       relative to the row directory, `.json` stripped. A
#                       basename starting with `.` (the writer's orphan
#                       temp) has no key and ages out under `days`.
#     audit-loop        gaia_branch_normalize; `<key>.json`, `<key>.d/`,
#                       `<key>.json.lock/`, and `.closed/<key, / as +>.
#                       <pr|none>.<YYYYMMDDTHHMMSSZ>.(json|d)`.
#     slug-dot-field    gaia_key_slug; the second `.`-separated field of the
#                       basename (`<base_sha>.<slug>.<rest>`).
#     slug-glob         gaia_key_slug; the text the row path's single `*`
#                       matched.
#   session_days  Optional, branch-spent with key normalized-path only: the
#                 window for a top-level `session-<id>` entry.
#   types         Optional, age only: a subset of ["file","dir"], default
#                 both. ["file"] makes only regular files candidates, so
#                 symlinks and directories survive.
#   names         Optional, age only: basename globs; a candidate must match
#                 one.
#   owner         Required on owned (non-empty prose naming the reaper),
#                 forbidden elsewhere.
#   Protected rule: a row whose path starts `protected/` is keep, or
#   branch-spent with `days` 7; any other protected row is skipped.
#
# Liveness is decided only by forward matching: every live branch (each
# local ref plus the branch of every listed worktree) is mapped through the
# row's own writer function and compared with the entry key. A key is never
# decoded back into a branch name, because the mapping is lossy (a
# `worktree-` prefix is dropped and `+` becomes `/`). Nesting keys are live
# when they equal a live key, are an ancestor of one, or lie inside one.
#
# Fail closed: a failed ref or worktree-list read disables every
# branch-spent row (a worktree-list failure, or a listed non-prunable path
# that cannot be keyed, also disables tree-gone); an absent, unreadable or
# unparseable catalog disables spec-finalized; an unreadable links ledger
# reads as no merge rows. Each disablement appends a reason line to
# GAIA_REAPER_SKIPPED.
#
# Sourcing defines functions and globals only, never exits and never leaves
# errexit changed. Bash 3.2 compatible: sets are newline strings or indexed
# arrays.
#
# Globals a caller reads:
#   GAIA_REAPER_ROW_IDS[], GAIA_REAPER_ROW_JSONS[]  local-root entries in
#       registry order, set by gaia_reaper_load_registry.
#   GAIA_REAPER_BRANCHES_OK, GAIA_REAPER_LIVE_BRANCHES, GAIA_REAPER_TREES_OK,
#   GAIA_REAPER_LIVE_TREE_KEYS, GAIA_REAPER_CATALOG_OK,
#   GAIA_REAPER_CATALOG_ROWS, GAIA_REAPER_MERGED_PRS, GAIA_REAPER_SKIPPED
#       set by gaia_reaper_snapshot; an OK flag is `1` or empty.

_gaia_reaper_library_directory="${BASH_SOURCE[0]%/*}"
[ "$_gaia_reaper_library_directory" = "${BASH_SOURCE[0]}" ] && _gaia_reaper_library_directory="."
_gaia_reaper_errexit_was=0
case $- in *e*) _gaia_reaper_errexit_was=1 ;; esac
set +e
# shellcheck source=/dev/null
. "$_gaia_reaper_library_directory/main-root-lib.sh"
# shellcheck source=/dev/null
. "$_gaia_reaper_library_directory/state-registry-lib.sh"
# shellcheck source=/dev/null
. "$_gaia_reaper_library_directory/branch-name-lib.sh"
# shellcheck source=/dev/null
. "$_gaia_reaper_library_directory/audit-key-lib.sh"
# shellcheck source=/dev/null
. "$_gaia_reaper_library_directory/audit-loop-state-lib.sh"
[ "$_gaia_reaper_errexit_was" = 1 ] && set -e
unset _gaia_reaper_library_directory _gaia_reaper_errexit_was

GAIA_REAPER_SKIPPED="${GAIA_REAPER_SKIPPED-}"

gaia_reaper_known_class() {
  case "${1-}" in branch-spent | tree-gone | spec-finalized | age | owned | keep) return 0 ;; esac
  return 1
}

gaia_reaper_known_key() {
  case "${1-}" in normalized-path | normalized-file | audit-loop | slug-dot-field | slug-glob) return 0 ;; esac
  return 1
}

# shellcheck disable=SC2016
_GAIA_REAPER_ROW_CHECK_JQ='
def positive: type == "number" and . == floor and . > 0;
def reasons:
  if (.retention | type) != "object" then
    (if has("reaped_by") then "missing retention (carries only the legacy reaped_by field)" else "missing retention" end)
  else
    .retention as $r | ($r.class // "") as $c | (.path // "") as $p
    | (($r | keys[]) | select(IN("class","days","key","session_days","types","names","owner") | not) | "unknown retention field \(.)"),
      (if $c == "" then "retention needs class"
       elif ($c | IN("branch-spent","tree-gone","spec-finalized","age","owned","keep")) then empty
       else "unknown class \($c | tojson)" end),
      (if ($c | IN("branch-spent","spec-finalized","age")) then
         (if ($r | has("days")) | not then "\($c) needs days" elif ($r.days | positive) | not then "days must be a positive integer" else empty end)
       elif ($r | has("days")) then "days is not allowed on \($c)" else empty end),
      (if $c == "branch-spent" then
         (if ($r | has("key")) | not then "branch-spent needs key"
          elif ($r.key | IN("normalized-path","normalized-file","audit-loop","slug-dot-field","slug-glob")) | not then "unknown key \($r.key | tojson)"
          else empty end)
       elif ($r | has("key")) then "key is only allowed on branch-spent" else empty end),
      (if ($r | has("session_days")) then
         (if $c != "branch-spent" or $r.key != "normalized-path" then "session_days is only allowed on branch-spent with key normalized-path"
          elif ($r.session_days | positive) | not then "session_days must be a positive integer" else empty end)
       else empty end),
      (if ($r | has("types")) then
         (if $c != "age" then "types is only allowed on age"
          elif ($r.types | type) != "array" or ($r.types | length) == 0 or ($r.types | all(IN("file","dir")) | not) then "types must be a non-empty subset of [\"file\",\"dir\"]"
          else empty end)
       else empty end),
      (if ($r | has("names")) then
         (if $c != "age" then "names is only allowed on age"
          elif ($r.names | type) != "array" or ($r.names | length) == 0 or ($r.names | all(type == "string" and length > 0) | not) then "names must be a non-empty array of globs"
          else empty end)
       else empty end),
      (if $c == "owned" then
         (if ($r.owner | type) != "string" or ($r.owner | length) == 0 then "owned needs a non-empty owner" else empty end)
       elif ($r | has("owner")) then "owner is only allowed on owned" else empty end),
      (if ($p | startswith("protected/")) and ($c != "keep") and (($c != "branch-spent") or ($r.days != 7)) then
         "a protected/ row must be keep, or branch-spent with days 7" else empty end)
  end;
[reasons] | first // empty
'

# gaia_reaper_row_check <row-json>: rc 0 when the row's retention satisfies
# the vocabulary above; else rc 1 and one reason line.
gaia_reaper_row_check() {
  local reason
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is not available\n'
    return 1
  fi
  reason="$(printf '%s' "${1-}" | jq -r "$_GAIA_REAPER_ROW_CHECK_JQ" 2>/dev/null)" || {
    printf 'row is not a JSON object\n'
    return 1
  }
  [ -z "$reason" ] && return 0
  printf '%s\n' "$reason"
  return 1
}

# _gaia_reaper_skip <reason>: append one line to GAIA_REAPER_SKIPPED.
_gaia_reaper_skip() {
  GAIA_REAPER_SKIPPED="${GAIA_REAPER_SKIPPED:+$GAIA_REAPER_SKIPPED
}$1"
}

# _gaia_reaper_row_fields <row-json>: sets the _gaia_reaper_row_* fields
# from one jq call, cached on the row text so a per-candidate caller pays it
# once. The unit and record separators cannot occur in a registry path.
_gaia_reaper_cached_row_json=""
_gaia_reaper_row_fields() {
  local row_json="${1-}" fields
  [ -n "$row_json" ] || return 1
  [ "$row_json" = "$_gaia_reaper_cached_row_json" ] && return 0
  fields="$(printf '%s' "$row_json" | jq -r '
    [ (.id // ""), (.path // ""), (.match // ""), (.kind // ""), (.root // "local"),
      (.retention.class // ""), (.retention.days // "" | tostring), (.retention.key // ""),
      (.retention.session_days // "" | tostring), ((.retention.types // []) | join(",")),
      ((.retention.names // []) | join("\u001e")) ] | join("\u001f")' 2>/dev/null)" || return 1
  IFS=$'\037' read -r _gaia_reaper_row_id _gaia_reaper_row_path _gaia_reaper_row_match _gaia_reaper_row_kind \
    _gaia_reaper_row_root _gaia_reaper_row_class _gaia_reaper_row_days _gaia_reaper_row_key \
    _gaia_reaper_row_session_days _gaia_reaper_row_types _gaia_reaper_row_names <<<"$fields"
  _gaia_reaper_cached_row_json="$row_json"
}

# _gaia_reaper_split_alternatives <path>: fills _gaia_reaper_alternatives
# with the `|`-separated alternatives, without the here-string temp file a
# `read -a` costs per call on bash 3.2.
_gaia_reaper_split_alternatives() {
  local rest="${1-}" alternative
  _gaia_reaper_alternatives=()
  while :; do
    alternative="${rest%%|*}"
    [ -n "$alternative" ] && _gaia_reaper_alternatives+=("$alternative")
    [ "$rest" = "$alternative" ] && break
    rest="${rest#*|}"
  done
}

# gaia_reaper_load_registry <registry-path>: residue, report_only and the
# local-root entries, one row per alternative, read once.
gaia_reaper_load_registry() {
  local registry="${1-}" lines tag first second third fourth alternative
  command -v jq >/dev/null 2>&1 || return 1
  [ -r "$registry" ] || return 1
  lines="$(jq -r '
    def local: (.root // "local") == "local";
    ((.residue // [])[] | select(local) | . as $row | (.path | split("|")[]) | ["R", $row.match, ., "", ""]),
    ((.report_only // [])[] | select(local) | . as $row | (.path | split("|")[]) | ["O", $row.match, ., "", ""]),
    ((.entries // [])[] | select(local) | . as $row
      | (["J", $row.id, ($row | tojson), "", ""],
         ((.path | split("|")[]) | ["E", $row.match, ., $row.kind, $row.id])))
    | join("\u001f")' "$registry" 2>/dev/null)" || return 1
  _gaia_reaper_residue_match=() _gaia_reaper_residue_path=()
  _gaia_reaper_report_match=() _gaia_reaper_report_path=()
  _gaia_reaper_entry_match=() _gaia_reaper_entry_path=() _gaia_reaper_entry_kind=() _gaia_reaper_entry_id=()
  GAIA_REAPER_ROW_IDS=() GAIA_REAPER_ROW_JSONS=()
  while IFS=$'\037' read -r tag first second third fourth; do
    case "$tag" in
      R) _gaia_reaper_residue_match+=("$first") && _gaia_reaper_residue_path+=("$second") ;;
      O) _gaia_reaper_report_match+=("$first") && _gaia_reaper_report_path+=("$second") ;;
      J) GAIA_REAPER_ROW_IDS+=("$first") && GAIA_REAPER_ROW_JSONS+=("$second") ;;
      E)
        alternative="$second"
        _gaia_reaper_entry_match+=("$first")
        _gaia_reaper_entry_path+=("$alternative")
        _gaia_reaper_entry_kind+=("$third")
        _gaia_reaper_entry_id+=("$fourth")
        ;;
    esac
  done <<<"$lines"
  return 0
}

# _gaia_reaper_classify_into <relative-path> <file|dir|link>: sets
# _gaia_reaper_class_of to the first-match classification, so a
# per-candidate caller pays no subshell. Glob and exact rows match only a
# path of their own kind (a symlink matches any kind, the residue sweep's
# rule); prefix rows match any kind.
_gaia_reaper_classify_into() {
  local relative="${1%/}" kind="${2-}" index=0
  while [ "$index" -lt "${#_gaia_reaper_residue_path[@]}" ]; do
    if _gaia_registry_alternative_matches "$relative" "${_gaia_reaper_residue_path[index]}" "${_gaia_reaper_residue_match[index]}"; then
      _gaia_reaper_class_of=residue
      return 0
    fi
    index=$((index + 1))
  done
  index=0
  while [ "$index" -lt "${#_gaia_reaper_report_path[@]}" ]; do
    if _gaia_registry_alternative_matches "$relative" "${_gaia_reaper_report_path[index]}" "${_gaia_reaper_report_match[index]}"; then
      _gaia_reaper_class_of=report-only
      return 0
    fi
    index=$((index + 1))
  done
  index=0
  while [ "$index" -lt "${#_gaia_reaper_entry_path[@]}" ]; do
    case "${_gaia_reaper_entry_match[index]}:${_gaia_reaper_entry_kind[index]}:$kind" in
      prefix:* | *:file:file | *:dir:dir | *:link) ;;
      *)
        index=$((index + 1))
        continue
        ;;
    esac
    if _gaia_registry_alternative_matches "$relative" "${_gaia_reaper_entry_path[index]}" "${_gaia_reaper_entry_match[index]}"; then
      _gaia_reaper_class_of="${_gaia_reaper_entry_id[index]}"
      return 0
    fi
    index=$((index + 1))
  done
  _gaia_reaper_class_of=unknown
}

gaia_reaper_classify() {
  _gaia_reaper_classify_into "${1-}" "${2-}"
  printf '%s\n' "$_gaia_reaper_class_of"
}

# _gaia_reaper_holds_other_rows <relative-dir> <row-id>: rc 0 when the
# directory is an ancestor of another row's (or a residue or report-only
# row's) path, so taking it whole would delete state the row does not own.
_gaia_reaper_holds_other_rows() {
  local relative="${1%/}" row_id="${2-}" index=0 alternative slashes segments
  slashes="${relative//[!\/]/}"
  local -a paths=()
  while [ "$index" -lt "${#_gaia_reaper_entry_path[@]}" ]; do
    if [ "${_gaia_reaper_entry_id[index]}" != "$row_id" ]; then
      paths+=("${_gaia_reaper_entry_path[index]}")
    fi
    index=$((index + 1))
  done
  paths+=(${_gaia_reaper_residue_path[@]+"${_gaia_reaper_residue_path[@]}"} ${_gaia_reaper_report_path[@]+"${_gaia_reaper_report_path[@]}"})
  for alternative in ${paths[@]+"${paths[@]}"}; do
    alternative="${alternative%/}"
    while [ "${alternative#*<*>}" != "$alternative" ]; do
      alternative="${alternative%%<*}*${alternative#*>}"
    done
    while [ "${alternative%/*}" != "$alternative" ]; do
      alternative="${alternative%/*}"
      segments="${alternative//[!\/]/}"
      [ "${#segments}" = "${#slashes}" ] || continue
      # An ancestor whose last segment is a bare wildcard (`cache/*` from
      # `cache/*/renders.json`) matches every sibling directory, so it would
      # block every directory row beside it. Such a row owns only its named
      # descendant, never the directory itself.
      case "$alternative" in */\*) continue ;; esac
      # shellcheck disable=SC2254
      case "$relative" in $alternative) return 0 ;; esac
    done
  done
  return 1
}

# _gaia_reaper_refresh_git <main-root>: re-reads refs and the worktree list.
# Git runs with GIT_DIR, GIT_WORK_TREE and GIT_COMMON_DIR stripped. The ref
# read takes the full refname and strips the prefix, because
# `refname:short` can print `heads/<x>` when a name is ambiguous.
_gaia_reaper_refresh_git() {
  local main_root="${1-}" refs listing line path="" branch="" prunable="" bare="" key
  local refs_ok=1 trees_ok=1 branches="" tree_keys=""
  GAIA_REAPER_BRANCHES_OK="" GAIA_REAPER_TREES_OK="" GAIA_REAPER_LIVE_BRANCHES="" GAIA_REAPER_LIVE_TREE_KEYS=""
  if ! refs="$(_gaia_git -C "$main_root" for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null)"; then
    refs_ok=0
    _gaia_reaper_skip "branch-spent: cannot read the local branch refs"
  fi
  if ! listing="$(_gaia_git -C "$main_root" worktree list --porcelain 2>/dev/null)"; then
    _gaia_reaper_skip "branch-spent and tree-gone: cannot read the worktree list"
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      refs/heads/*) branches="$branches${line#refs/heads/}
" ;;
    esac
  done <<<"$refs"
  # A blank line ends a record; the trailing `printf` closes the last one.
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      prunable | "prunable "*) prunable=1 ;;
      bare) bare=1 ;;
      "")
        [ -n "$branch" ] && branches="$branches$branch
"
        if [ -n "$path" ] && [ -z "$prunable" ] && [ -z "$bare" ]; then
          if key="$(gaia_tree_key "$path" 2>/dev/null)" && [ -n "$key" ]; then
            tree_keys="$tree_keys$key
"
          else
            trees_ok=0
            _gaia_reaper_skip "tree-gone: cannot key the listed worktree $path"
          fi
        fi
        path="" branch="" prunable="" bare=""
        ;;
    esac
  done < <(printf '%s\n\n' "$listing")
  GAIA_REAPER_LIVE_BRANCHES="${branches%
}"
  GAIA_REAPER_LIVE_TREE_KEYS="${tree_keys%
}"
  [ "$refs_ok" = 1 ] && GAIA_REAPER_BRANCHES_OK=1
  [ "$trees_ok" = 1 ] && GAIA_REAPER_TREES_OK=1
  return 0
}

# gaia_reaper_snapshot <main-root>: reads refs, the worktree list, the
# notebook catalog and the links ledger once for the run. rc 0 always.
gaia_reaper_snapshot() {
  local main_root="${1-}" catalog links
  GAIA_REAPER_SKIPPED="" GAIA_REAPER_CATALOG_OK="" GAIA_REAPER_CATALOG_ROWS="" GAIA_REAPER_MERGED_PRS=""
  _gaia_reaper_refresh_git "$main_root"
  catalog="$main_root/.notebook/catalog.json"
  if ! command -v jq >/dev/null 2>&1; then
    _gaia_reaper_skip "spec-finalized and the audit-loop merge guard: jq is not available"
    return 0
  fi
  if [ ! -f "$catalog" ]; then
    _gaia_reaper_skip "spec-finalized: no notebook catalog"
  elif GAIA_REAPER_CATALOG_ROWS="$(jq -r 'if (.items | type) == "array" then .items[] | select(.kind == "spec")
      | [(.id | tostring), (.status | tostring)] | join("\t") else error("no items") end' "$catalog" 2>/dev/null)"; then
    GAIA_REAPER_CATALOG_OK=1
  else
    GAIA_REAPER_CATALOG_ROWS=""
    _gaia_reaper_skip "spec-finalized: the notebook catalog cannot be read or parsed"
  fi
  links="$main_root/.gaia/local/telemetry/links.jsonl"
  if [ -e "$links" ]; then
    GAIA_REAPER_MERGED_PRS="$(jq -R -r 'fromjson? | select(type == "object" and .kind == "merge" and (.pr | type) == "number") | .pr' "$links" 2>/dev/null)" || {
      GAIA_REAPER_MERGED_PRS=""
      _gaia_reaper_skip "audit-loop merge guard: the links ledger cannot be read; no PR reads as merged"
    }
  fi
  return 0
}

# gaia_reaper_live_keys <normalize|slug>: the live branch set mapped through
# one writer function.
gaia_reaper_live_keys() {
  local function_name="${1-}" branch
  [ -n "${GAIA_REAPER_BRANCHES_OK-}" ] || return 1
  case "$function_name" in normalize | slug) ;; *) return 2 ;; esac
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    if [ "$function_name" = normalize ]; then gaia_branch_normalize "$branch"; else gaia_key_slug "$branch"; fi
    printf '\n'
  done <<<"${GAIA_REAPER_LIVE_BRANCHES-}"
  return 0
}

# gaia_reaper_path_live <entry-key> <live-keys>: segment-aware nesting
# match. An empty key names the row directory itself, which holds every key,
# so it reads live.
gaia_reaper_path_live() {
  local entry_key="${1-}" live_key
  [ -n "$entry_key" ] || return 0
  while IFS= read -r live_key; do
    [ -n "$live_key" ] || continue
    case "$live_key" in "$entry_key" | "$entry_key"/*) return 0 ;; esac
    case "$entry_key" in "$live_key"/*) return 0 ;; esac
  done <<<"${2-}"
  return 1
}

# gaia_reaper_entry_older_than <absolute-path> <days>: rc 0 when neither
# the path nor anything under it (`find -P`, never following a link) has an
# mtime within the last <days> x 24 hours. `-mtime -N` is true for an age
# under N whole days, on BSD and GNU alike. A walk that fails part way
# reads as recent, so an unreadable subtree is never spent.
gaia_reaper_entry_older_than() {
  local path="${1-}" days="${2-}" recent
  case "$days" in '' | *[!0-9]*) return 1 ;; esac
  [ -e "$path" ] || [ -L "$path" ] || return 1
  recent="$(find -P "$path" -mtime "-$days" -print -quit 2>/dev/null)" || return 1
  [ -z "$recent" ]
}

# _gaia_reaper_star_text <relative-path>: with the row fields loaded, prints
# the text the matching alternative's single wildcard (`*` or
# <placeholder>) matched. rc 2 when the matching alternative has no
# wildcard; rc 1 when none matches or the wildcard is not a single `*`.
_gaia_reaper_star_text() {
  local relative="${1%/}" alternative pattern head tail text
  _gaia_reaper_split_alternatives "$_gaia_reaper_row_path"
  for alternative in "${_gaia_reaper_alternatives[@]}"; do
    pattern="${alternative%/}"
    while [ "${pattern#*<*>}" != "$pattern" ]; do
      pattern="${pattern%%<*}*${pattern#*>}"
    done
    if [ "$_gaia_reaper_row_match" = prefix ] && [ "${pattern#*\*}" != "$pattern" ]; then
      tail="${pattern#*\*}"
      pattern="${pattern%%\**}*${tail%%/*}"
    fi
    # shellcheck disable=SC2254
    case "$relative" in $pattern) ;; *) continue ;; esac
    case "$pattern" in
      *\** | *\?* | *\[*) ;;
      *) return 2 ;;
    esac
    head="${pattern%%\**}"
    tail="${pattern#*\*}"
    case "$tail" in *\** | *\?* | *\[*) return 1 ;; esac
    case "$head" in *\?* | *\[*) return 1 ;; esac
    text="${relative#"$head"}"
    text="${text%"$tail"}"
    [ -n "$text" ] && [ "$head$text$tail" = "$relative" ] || return 1
    printf '%s\n' "$text"
    return 0
  done
  return 1
}

# gaia_reaper_entry_key <row-json> <relative-path>: the candidate's entry key
# under the row's `key` (path relative to .gaia/local). The only key parser.
gaia_reaper_entry_key() {
  local relative="${2%/}" row_directory inner base stem pull_request stamp key
  local stamp_pattern='^[0-9]{8}T[0-9]{6}Z$'
  _gaia_reaper_row_fields "${1-}" || return 1
  case "$_gaia_reaper_row_key" in
    slug-glob)
      _gaia_reaper_star_text "$relative"
      return $?
      ;;
    slug-dot-field)
      base="${relative##*/}"
      stem="${base#*.}"
      [ "$stem" != "$base" ] || return 1
      key="${stem%%.*}"
      [ "$key" != "$stem" ] && [ -n "$key" ] || return 1
      printf '%s\n' "$key"
      return 0
      ;;
    normalized-path | normalized-file | audit-loop) ;;
    *) return 1 ;;
  esac
  row_directory="${_gaia_reaper_row_path%%|*}"
  row_directory="${row_directory%/}"
  case "$relative" in "$row_directory"/?*) ;; *) return 1 ;; esac
  inner="${relative#"$row_directory"/}"
  base="${inner##*/}"
  case "$_gaia_reaper_row_key" in
    normalized-path) key="$inner" ;;
    normalized-file)
      case "$base" in .*) return 1 ;; *.json) key="${inner%.json}" ;; *) return 1 ;; esac
      ;;
    audit-loop)
      case "$inner" in
        .closed/*/*) return 1 ;;
        .closed/*)
          stem="${inner#.closed/}"
          case "$stem" in *.json) stem="${stem%.json}" ;; *.d) stem="${stem%.d}" ;; *) return 1 ;; esac
          case "$stem" in *.*.*) ;; *) return 1 ;; esac
          stamp="${stem##*.}"
          [[ "$stamp" =~ $stamp_pattern ]] || return 1
          stem="${stem%.*}"
          pull_request="${stem##*.}"
          case "$pull_request" in none) ;; '' | *[!0-9]*) return 1 ;; esac
          key="${stem%.*}"
          [ -n "$key" ] || return 1
          key="${key//+//}"
          ;;
        *.json.lock) key="${inner%.json.lock}" ;;
        *.json) key="${inner%.json}" ;;
        *.d) key="${inner%.d}" ;;
        *) return 1 ;;
      esac
      ;;
  esac
  case "$key" in '' | */ | */.json) return 1 ;; esac
  printf '%s\n' "$key"
}

# _gaia_reaper_alternative_directory <alternative>: the row directory of one
# alternative, relative to .gaia/local ('' for .gaia/local itself). A prefix
# alternative without a placeholder is its own directory; any other is the
# literal text up to the last `/` before its first wildcard or `<`, or the
# alternative's parent when it has none.
_gaia_reaper_alternative_directory() {
  local alternative="${1-}" head
  if [ "$_gaia_reaper_row_match" = prefix ] && [ "${alternative#*<}" = "$alternative" ]; then
    _gaia_reaper_directory_of="${alternative%/}"
    return 0
  fi
  head="${alternative%%[*?[<]*}"
  [ "$head" = "$alternative" ] && head="${alternative%/}"
  case "$head" in */*) _gaia_reaper_directory_of="${head%/*}" ;; *) _gaia_reaper_directory_of="" ;; esac
}

# _gaia_reaper_refusal <local-root> <relative-path>: sets
# _gaia_reaper_refusal_reason and returns 0 when the candidate must not be
# removed (no `..`, matched by its row, strictly
# inside its row directory, no symlink from .gaia/local down to its parent,
# and a physical parent inside the row directory).
_gaia_reaper_refusal() {
  local local_root="$1" relative="$2" alternative matched="" walked rest segment parent physical_parent physical_row
  local newline=$'\n'
  case "/$relative/" in
    */../* | */./* | *//* | *"$newline"*)
      _gaia_reaper_refusal_reason="the path is not a plain relative path"
      return 0
      ;;
  esac
  _gaia_reaper_split_alternatives "$_gaia_reaper_row_path"
  for alternative in "${_gaia_reaper_alternatives[@]}"; do
    if _gaia_registry_alternative_matches "$relative" "$alternative" "$_gaia_reaper_row_match"; then
      matched="$alternative"
      break
    fi
  done
  if [ -z "$matched" ]; then
    _gaia_reaper_refusal_reason="the path matches no alternative of its row"
    return 0
  fi
  _gaia_reaper_alternative_directory "$matched"
  if [ -n "$_gaia_reaper_directory_of" ]; then
    case "$relative" in
      "$_gaia_reaper_directory_of"/?*) ;;
      *)
        _gaia_reaper_refusal_reason="the path is not inside its row directory"
        return 0
        ;;
    esac
  fi
  walked="$local_root"
  rest="$relative"
  while [ "${rest#*/}" != "$rest" ]; do
    segment="${rest%%/*}"
    walked="$walked/$segment"
    if [ -L "$walked" ] || [ ! -d "$walked" ]; then
      _gaia_reaper_refusal_reason="a symlink or non-directory sits on its path"
      return 0
    fi
    rest="${rest#*/}"
  done
  parent="${relative%/*}"
  [ "$parent" = "$relative" ] && parent=""
  physical_parent="$(_gaia_physical_directory "$local_root${parent:+/$parent}")"
  physical_row="$(_gaia_physical_directory "$local_root${_gaia_reaper_directory_of:+/$_gaia_reaper_directory_of}")"
  if [ -z "$physical_parent" ] || [ -z "$physical_row" ]; then
    _gaia_reaper_refusal_reason="its parent or its row directory does not resolve"
    return 0
  fi
  case "$physical_parent/" in
    "$physical_row"/*) ;;
    *)
      _gaia_reaper_refusal_reason="its physical parent lies outside its row directory"
      return 0
      ;;
  esac
  return 1
}

# gaia_reaper_safe_remove <local-root> <row-json> <relative-path>...: removes
# each candidate that passes the checks above. A symlink is unlinked, never
# followed. Directories and files go in one batched `rm -rf`. rc 0 always.
gaia_reaper_safe_remove() {
  local local_root="${1-}" row_json="${2-}" relative target
  shift 2 2>/dev/null || return 0
  local -a batch=()
  if [ -L "$local_root" ] || [ ! -d "$local_root" ] || ! _gaia_reaper_row_fields "$row_json"; then
    for relative in "$@"; do printf 'refused %s: the state root or the row is unusable\n' "$relative"; done
    return 0
  fi
  local_root="${local_root%/}"
  for relative in "$@"; do
    relative="${relative%/}"
    if [ -z "$relative" ] || _gaia_reaper_refusal "$local_root" "$relative"; then
      printf 'refused %s: %s\n' "$relative" "${_gaia_reaper_refusal_reason:-empty path}"
      continue
    fi
    target="$local_root/$relative"
    if [ -L "$target" ]; then
      if rm -f -- "$target" 2>/dev/null && [ ! -L "$target" ]; then
        printf 'removed %s\n' "$relative"
      else
        printf 'refused %s: could not unlink it\n' "$relative"
      fi
    elif [ -e "$target" ]; then
      batch+=("$relative")
    fi
  done
  [ "${#batch[@]}" -gt 0 ] || return 0
  local -a absolute=()
  for relative in "${batch[@]}"; do absolute+=("$local_root/$relative"); done
  rm -rf -- "${absolute[@]}" 2>/dev/null
  for relative in "${batch[@]}"; do
    if [ -e "$local_root/$relative" ] || [ -L "$local_root/$relative" ]; then
      printf 'refused %s: could not delete it\n' "$relative"
    else
      printf 'removed %s\n' "$relative"
    fi
  done
  return 0
}
