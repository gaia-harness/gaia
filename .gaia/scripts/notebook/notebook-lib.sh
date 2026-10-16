#!/usr/bin/env bash
# shellcheck shell=bash
#
# The notebook library: the only code that opens the notebook catalog or lists
# a notebook kind folder. Specs, plans and research live in a gitignored
# notebook folder at the main checkout's root, described by one catalog file
# inside it. Dual-mode, like state-registry-lib.sh: source it for the
# functions, or run it for the CLI verbs at the bottom.
#
# Layout under <main>/.notebook/:
#   catalog.json            the catalog (schema below)
#   specs/SPEC-NNN/         a spec; its spec-derived plans nest as plan[-N]/
#   plans/PLAN-NNN/         a spec-less plan
#   research/<slug>/        a research folder
#   .catalog.json.tmp.<pid> the transient write file, skipped by every reader
#
# Catalog schema (this header is the owning statement; the wiki points here):
#   {
#     "version": 1,
#     "move_complete": {"at": "<iso>"},          optional, one-time move marker
#     "items": [
#       {
#         "kind": "spec" | "plan" | "research",
#         "id": "SPEC-NNN" | "PLAN-NNN" | "<research slug>",
#         "path": "specs/SPEC-NNN" | "plans/PLAN-NNN" | "research/<slug>",
#         "status": "<canonical for the kind, below>",
#         "subject": "<text>",
#         "created_at": "<iso>",
#         "status_changed_at": "<iso>",
#         "links": {"research": ["<slug>"], "spec": "SPEC-NNN", "pr": 123},
#         "snoozed_until": "<iso>",
#         "reap": {"at": "<iso>" | null, "by": "<reaper name>" | "pre-catalog"}
#       }
#     ]
#   }
#   links, snoozed_until and reap are optional. Fields carried from the
#   pre-notebook ledgers sit on the row verbatim (source, reservation, intent,
#   merged_at, abandoned_at, renamed_from, pr_number, and any unknown field);
#   every write keeps fields it does not set. A row with a reap record is
#   expected to have no folder. Spec-derived plans get no row: the parent spec
#   row covers them. Paths are notebook-relative.
#
# Statuses:
#   spec      draft | ready | merged | abandoned
#   plan      ready | merged | abandoned
#   research  untagged | active | pending | closed
#
# Ids: spec ^SPEC-[0-9]{3,}$, plan ^PLAN-[0-9]{3,}$,
#   research ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ (no slash, no leading dot, so
#   no id can climb out of its kind folder).
#
# Exit codes, shared by every function and verb:
#   0  ok
#   1  not found, main root unresolvable, or jq missing
#   2  usage, invalid kind, invalid id, non-canonical status, row already exists
#     (a spec or plan register, or a rename target; re-registering research
#     is a no-op, exit 0)
#   3  not ready: the one-time move is pending
#   4  corrupt catalog (present but unparseable or schema-invalid); nothing changed
#   5  .notebook is not gitignored in main; nothing created
#   6  row missing for an update
#   75 lock timeout (passed through from with_ledger_lock)
#
# Decisions every consumer relies on:
#
# Tree selector. Every function and verb resolves main as
#   gaia_resolve_main_root "${GAIA_NOTEBOOK_TREE:-}", through
#   _gaia_notebook_main only. The variable names any tree of the repository
#   (main or a linked worktree); unset or empty, resolution starts from $PWD.
#   The optional <tree_dir> on root, require_ready and move_state overrides it
#   for that call. A consumer handed a repo operand exports the variable from
#   it, so a test running a fixture's script from another cwd touches only the
#   fixture. There is no relative fallback: an unresolvable main is exit 1.
#
# Readiness gate (fail closed before the move). gaia_notebook_require_ready
#   refuses with 3 while a legacy specs or plans ledger exists (see
#   legacy-roots.sh) and the catalog lacks move_complete, printing one stderr
#   line naming the move command. The CLI dispatcher runs it before every verb
#   except root, move-state and require-ready, so a refusal writes nothing and
#   creates no folder. Sourced functions never run it: consumer scripts call it
#   themselves, and the one-time move uses the sourced write primitives while
#   a legacy ledger still exists.
#
# Corrupt catalog. A catalog that is present but not one JSON object with
#   version 1, an items array, and rows each carrying a canonical kind and a
#   string id and status, makes every read used for a decision and every write
#   refuse with 4 and a GAIA_NOTEBOOK_CATALOG_CORRUPT line, changing nothing.
#   Only an absent catalog is created fresh, and never with move_complete.
#
# Gitignore. Every write first requires git -C <main> check-ignore -q .notebook
#   to pass, else refuses with 5 naming the missing .gitignore line, before
#   creating the notebook folder or anything in it. Reads of an absent
#   notebook need no check. The library creates no item folder itself.
#
# Locks. Three lock directories under
#   <main>/.gaia/local/cache/shared/notebook-locks/: catalog, mint-spec,
#   mint-plan, created on first use and built on with_ledger_lock. Every
#   catalog write takes the catalog lock for its own read-modify-write only,
#   then writes a temp file inside the notebook folder and renames it over the
#   catalog. gaia_notebook_with_mint_lock holds a kind's mint lock for a whole
#   command (numbering, any remote reservation) and never takes the catalog
#   lock itself, so writes of other kinds proceed meanwhile.
#   gaia_notebook_with_catalog_lock holds the catalog lock across a block;
#   library writes inside it, in the same process tree, see the exported
#   GAIA_NOTEBOOK_CATALOG_LOCK_HELD and use the held lock instead of waiting on
#   themselves. Honest limit: a background child started inside the block and
#   still writing after it returns inherits the variable and writes unlocked.
#
# One write per operation. register (with its extra fields) and rename each
#   make exactly one locked write, so an allocator lands a whole row, and a
#   renumber re-keys a row, without a window where another writer sees half.
#
# status_changed_at is stamped by register (equal to created_at), and by
#   update and set_status whenever the status changes, unless the patch
#   supplies it.

_GAIA_NOTEBOOK_CATALOG_FILE="catalog.json"
_GAIA_NOTEBOOK_MOVE_COMMAND="bash .gaia/scripts/notebook/move.sh run"

_gaia_notebook_load_parts() {
  local library_directory errexit_was=0
  library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  # Suspend errexit across the loads and restore exactly what was there: an
  # unparseable part would otherwise abandon an errexit caller at the source,
  # and arming errexit in a caller that runs without it kills that caller.
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  # shellcheck source=SCRIPTDIR/../main-root-lib.sh
  source "$library_directory/../main-root-lib.sh"
  # shellcheck source=SCRIPTDIR/../spec/with-ledger-lock.sh
  source "$library_directory/../spec/with-ledger-lock.sh"
  # shellcheck source=SCRIPTDIR/legacy-roots.sh
  source "$library_directory/legacy-roots.sh"
  # shellcheck source=SCRIPTDIR/notebook-lib-catalog.sh
  source "$library_directory/notebook-lib-catalog.sh"
  # shellcheck source=SCRIPTDIR/notebook-lib-paths.sh
  source "$library_directory/notebook-lib-paths.sh"
  if [ "$errexit_was" = 1 ]; then set -e; fi
  return 0
}
_gaia_notebook_load_parts

# _gaia_notebook_main [tree_dir]: the one main resolver (tree selector above).
_gaia_notebook_main() {
  local tree="${1:-${GAIA_NOTEBOOK_TREE:-}}"
  if ! declare -f gaia_resolve_main_root >/dev/null 2>&1; then
    printf 'notebook: main-root-lib.sh did not load beside the notebook library\n' >&2
    return 1
  fi
  gaia_resolve_main_root "$tree" || return 1
}

_gaia_notebook_kind_valid() {
  case "${1:-}" in spec | plan | research) return 0 ;; esac
  printf 'notebook: invalid kind %s (spec, plan or research)\n' "'${1:-}'" >&2
  return 2
}

_gaia_notebook_status_allowed() {
  case "${1:-}:${2:-}" in
    spec:draft | spec:ready | spec:merged | spec:abandoned) return 0 ;;
    plan:ready | plan:merged | plan:abandoned) return 0 ;;
    research:untagged | research:active | research:pending | research:closed) return 0 ;;
  esac
  printf 'notebook: status %s is not canonical for kind %s\n' "'${2:-}'" "'${1:-}'" >&2
  return 2
}

# Prints the root folder name of a kind inside the notebook.
_gaia_notebook_kind_folder() {
  case "${1:-}" in
    spec) printf 'specs' ;;
    plan) printf 'plans' ;;
    research) printf 'research' ;;
    *) return 2 ;;
  esac
}

gaia_notebook_root() {
  local main
  main="$(_gaia_notebook_main "${1:-}")" || return 1
  printf '%s\n' "$main/.notebook"
}

gaia_notebook_require_ready() {
  local main has_marker
  main="$(_gaia_notebook_main "${1:-}")" || return 1
  gaia_notebook_legacy_pending "$main" || return 0
  has_marker="$(_gaia_notebook_catalog_has_move_complete "$main")" || return $?
  [ "$has_marker" = "true" ] && return 0
  printf 'notebook: not ready, a legacy specs or plans ledger is still present and the one-time move has not run. Next step: from the main checkout, run: %s\n' "$_GAIA_NOTEBOOK_MOVE_COMMAND" >&2
  return 3
}

gaia_notebook_move_state() {
  local main has_marker kind legacy_directory
  main="$(_gaia_notebook_main "${1:-}")" || return 1
  has_marker="$(_gaia_notebook_catalog_has_move_complete "$main")" || return $?
  if [ "$has_marker" = "true" ]; then
    printf 'done\n'
    return 0
  fi
  for kind in specs plans research; do
    legacy_directory="$(gaia_notebook_legacy_root "$kind" "$main")" || return 2
    if [ -d "$legacy_directory" ]; then
      printf 'pending\n'
      return 0
    fi
  done
  printf 'none\n'
}

_gaia_notebook_usage() {
  printf 'usage: notebook-lib.sh {root [<tree_dir>] | require-ready [<tree_dir>] | move-state [<tree_dir>] | path <kind> [<id>] | get <kind> <id> | list <kind> [--status <s>]... | folders <kind> | register <kind> <id> <status> [--subject <s>] [--links <json>] [--extra <json>] | set-status <kind> <id> <status> | update <kind> <id> <json-patch> | classify <path>}\n' >&2
  return 2
}

_gaia_notebook_cli_list() {
  local kind="${1:-}"
  local -a statuses=()
  [ "$#" -ge 1 ] || { _gaia_notebook_usage; return 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --status)
        [ "$#" -ge 2 ] || { _gaia_notebook_usage; return 2; }
        statuses+=("$2")
        shift 2
        ;;
      *) _gaia_notebook_usage; return 2 ;;
    esac
  done
  gaia_notebook_rows "$kind" ${statuses[@]+"${statuses[@]}"}
}

_gaia_notebook_cli_register() {
  [ "$#" -ge 3 ] || { _gaia_notebook_usage; return 2; }
  local kind="$1" id="$2" status="$3" subject="" links="" extra=""
  shift 3
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || { _gaia_notebook_usage; return 2; }
    case "$1" in
      --subject) subject="$2" ;;
      --links) links="$2" ;;
      --extra) extra="$2" ;;
      *) _gaia_notebook_usage; return 2 ;;
    esac
    shift 2
  done
  gaia_notebook_register "$kind" "$id" "$status" "$subject" "$links" "$extra"
}

_gaia_notebook_cli() {
  local verb="${1:-}"
  [ "$#" -ge 1 ] && shift
  case "$verb" in
    root) [ "$#" -le 1 ] || { _gaia_notebook_usage; return 2; }; gaia_notebook_root "${1:-}"; return $? ;;
    require-ready) [ "$#" -le 1 ] || { _gaia_notebook_usage; return 2; }; gaia_notebook_require_ready "${1:-}"; return $? ;;
    move-state) [ "$#" -le 1 ] || { _gaia_notebook_usage; return 2; }; gaia_notebook_move_state "${1:-}"; return $? ;;
    path | get | list | folders | register | set-status | update | classify) ;;
    *) _gaia_notebook_usage; return 2 ;;
  esac
  gaia_notebook_require_ready || return $?
  case "$verb" in
    path)
      case "$#" in
        1) gaia_notebook_kind_directory "$1" ;;
        2) gaia_notebook_item_directory "$1" "$2" ;;
        *) _gaia_notebook_usage ;;
      esac
      ;;
    get) [ "$#" -eq 2 ] || { _gaia_notebook_usage; return 2; }; gaia_notebook_row "$1" "$2" ;;
    list) _gaia_notebook_cli_list "$@" ;;
    folders) [ "$#" -eq 1 ] || { _gaia_notebook_usage; return 2; }; gaia_notebook_folders "$1" ;;
    register) _gaia_notebook_cli_register "$@" ;;
    set-status) [ "$#" -eq 3 ] || { _gaia_notebook_usage; return 2; }; gaia_notebook_set_status "$1" "$2" "$3" ;;
    update) [ "$#" -eq 3 ] || { _gaia_notebook_usage; return 2; }; gaia_notebook_update "$1" "$2" "$3" ;;
    classify) [ "$#" -eq 1 ] || { _gaia_notebook_usage; return 2; }; gaia_notebook_classify_path "$1" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _gaia_notebook_cli "$@"
  exit $?
fi
