#!/usr/bin/env bash
# shellcheck shell=bash
#
# kept-worktrees.sh: the ledger of worktrees a post-merge cleanup kept, and the
# session-start reminder that lists the orphaned ones until they are removed.
#
#   bash .gaia/scripts/kept-worktrees.sh record --tree <path> --branch <branch> --why <text>
#   bash .gaia/scripts/kept-worktrees.sh occupy --session <id> --tree <path>
#   bash .gaia/scripts/kept-worktrees.sh remind [directory]
#   bash .gaia/scripts/kept-worktrees.sh remind --main-root <path> [--own-tree <path>]
#   bash .gaia/scripts/kept-worktrees.sh lookup-merged --main-root <path>
#
# The `--main-root` form takes a root the caller already resolved with
# main-root-lib.sh, and skips resolving it again: the resolver is most of the
# reminder's cost, and the session-start hook has already paid it.
#
# worktree-removal-check.sh stops a removal when the tree still holds work and
# says so once, in that run's output; nothing else surfaces the tree again.
# Candidates come from two sources:
#   ledger   `record`, which the check runs when it stops, writes one line per
#            tree path (tree, branch, why; tab separated) to the main
#            checkout's .gaia/local/kept-worktrees.tsv, so every tree reads
#            one ledger. The cleanup arm stops before its `git fetch --prune`,
#            so a kept tree's remote-tracking ref usually survives and will
#            not read [gone] until a later prune; the ledger covers that
#            window.
#   [gone]   a linked worktree whose branch's upstream reads [gone]: its
#            remote branch was deleted and the tree was never removed. No
#            removal check ran on it, so its next step runs the check and
#            compares the branch against the base first.
#
# A candidate is listed only when it is orphaned, and unknown on any term
# means not listed:
#   merged   a ledger tree is merged by contract: the check runs only from
#            post-merge cleanup. A [gone] tree is merged when its tip is an
#            ancestor of its remote's HEAD branch, or when the cached lookup
#            found a merged pull request whose head is that tip. A squash
#            merge defeats the ancestry test, so `lookup-merged` asks gh, in a
#            detached process at most once per LOOKUP_INTERVAL_MINUTES, never
#            on the session-start path; until it answers the tree is not
#            listed. An unmerged or abandoned tree is never listed.
#   unheld   no live Claude session occupies it. `occupy`, which worktree
#            provisioning runs on session start and on EnterWorktree, records
#            the session's tree; the session's host process comes from the
#            record ports-session-start.sh writes. A host that has exited, or
#            whose pid now names another process, releases the tree and its
#            occupancy is pruned; a host that cannot be read holds it. The
#            ports dead-session reap (gaia_server_reap_dead_sessions) deletes
#            a dead session's host record, which would then read as
#            unreadable, so it deletes that session's occupancy record in the
#            same step.
#   not own  the tree the starting session is in (`--own-tree`).
# Held trees are counted in one line rather than listed. Nothing detects a
# person working in a tree outside Claude, so the block tells Claude to remove
# a listed tree only when the user names it.
#
# Every subcommand exits 0 on every path and prints nothing when a read or
# write fails, so none can fail the check's stop or a session start. The
# reminder never removes a tree: it only drops ledger lines whose tree
# is no longer listed, and the occupancy records of a tree it checks whose
# session has exited. The ports reap drops the rest.
#
# Cost, paid at every session start: one `git worktree list --porcelain`, one
# `git for-each-ref`, one ledger read and one awk. Only when a candidate
# exists: an occupancy read and a `ps` per occupying session, an ancestry test
# per [gone] candidate, and one `git log` and one check call per listed tree.
# No fetch and no network on this path, no per-tree `git status`, no jq.
#
# Bash 3.2 compatible. Never `cd`, except in the detached lookup's subshell:
# gh reads the repository from its working directory.

set -u

# One gh lookup per hour bounds a session-start burst to a single network
# call while still confirming a fresh squash merge within the hour.
LOOKUP_INTERVAL_MINUTES=60

here=${BASH_SOURCE[0]%/*}
[ "$here" != "${BASH_SOURCE[0]}" ] || here=.
# shellcheck source=/dev/null
. "$here/main-root-lib.sh" 2>/dev/null || exit 0

tab=$(printf '\t')
separator=$(printf '\037')

ledger_path() { # <main root>
  printf '%s/.gaia/local/kept-worktrees.tsv' "$1"
}

occupancy_directory() { # <main root>
  printf '%s/.gaia/local/worktree-occupancy' "$1"
}

merged_cache_path() { # <main root>
  printf '%s/.gaia/local/cache/shared/kept-worktrees-merged.tsv' "$1"
}

lookup_stamp_path() { # <main root>
  printf '%s/.gaia/local/cache/shared/kept-worktrees-lookup.stamp' "$1"
}

is_session_id() {
  case "$1" in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

record() { # <tree> <branch> <why>
  local tree_root main_root ledger ledger_directory temporary
  tree_root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  main_root=$(gaia_resolve_main_root "$tree_root" 2>/dev/null) || return 0
  ledger=$(ledger_path "$main_root")
  ledger_directory=${ledger%/*}
  mkdir -p "$ledger_directory" 2>/dev/null || return 0
  temporary="$ledger.$$.tmp"
  # One line per tree path: a second stop of the same tree replaces its line.
  if {
    if [ -f "$ledger" ]; then
      KEPT_TREE="$tree_root" awk -F '\t' '$1 != ENVIRON["KEPT_TREE"]' "$ledger"
    fi
    printf '%s\t%s\t%s\n' "$tree_root" "$2" "$3"
  } >"$temporary" 2>/dev/null; then
    mv -f "$temporary" "$ledger" 2>/dev/null || rm -f "$temporary" 2>/dev/null
  else
    rm -f "$temporary" 2>/dev/null
  fi
  return 0
}

occupy() { # <session id> <tree>
  local tree_root main_root directory
  is_session_id "$1" || return 0
  tree_root=$(git -C "$2" rev-parse --show-toplevel 2>/dev/null) || return 0
  main_root=$(gaia_resolve_main_root "$tree_root" 2>/dev/null) || return 0
  directory=$(occupancy_directory "$main_root")
  mkdir -p "$directory" 2>/dev/null || return 0
  if printf '%s\n' "$tree_root" >"$directory/$1.tsv.$$" 2>/dev/null; then
    mv -f "$directory/$1.tsv.$$" "$directory/$1.tsv" 2>/dev/null || rm -f "$directory/$1.tsv.$$" 2>/dev/null
  else
    rm -f "$directory/$1.tsv.$$" 2>/dev/null
  fi
  return 0
}

# host_state <main root> <session id>: live, dead or unknown, for the host
# process the session's ports record names.
process_library_state=""
host_state() {
  local host_record line host_pid host_start identity
  if [ -z "$process_library_state" ]; then
    process_library_state=missing
    # shellcheck source=/dev/null
    . "$here/server-process-lib.sh" 2>/dev/null && type gaia_server_process_identity >/dev/null 2>&1 && process_library_state=loaded
  fi
  [ "$process_library_state" = loaded ] || { printf unknown; return 0; }
  host_record="${GAIA_PORTS_STATE_DIRECTORY:-$1/.gaia/local/ports}/sessions/$2.tsv"
  [ -f "$host_record" ] || { printf unknown; return 0; }
  IFS= read -r line <"$host_record" || [ -n "$line" ] || { printf unknown; return 0; }
  host_pid=${line%%"$tab"*}
  line=${line#*"$tab"}
  host_start=${line%%"$tab"*}
  case "$host_pid" in
    '' | *[!0-9]*) printf unknown; return 0 ;;
  esac
  [ -n "$host_start" ] || { printf unknown; return 0; }
  kill -0 "$host_pid" 2>/dev/null || _gaia_server_pid_alive "$host_pid" 2>/dev/null || { printf dead; return 0; }
  identity=$(gaia_server_process_identity "$host_pid" 2>/dev/null) || { printf unknown; return 0; }
  # A different start time means the pid now names another process.
  if [ "${identity%%"$tab"*}" = "$host_start" ]; then printf live; else printf dead; fi
}

# tree_occupancy <main root> <tree>: held when a live or unreadable session
# occupies the tree, else free. Occupancy of an exited session is pruned.
tree_occupancy() {
  local directory occupancy_file occupied_tree session_id state held=false
  directory=$(occupancy_directory "$1")
  [ -d "$directory" ] || { printf free; return 0; }
  for occupancy_file in "$directory"/*.tsv; do
    [ -f "$occupancy_file" ] || continue
    IFS= read -r occupied_tree <"$occupancy_file" || [ -n "$occupied_tree" ] || continue
    [ "$occupied_tree" = "$2" ] || continue
    session_id=${occupancy_file##*/}
    session_id=${session_id%.tsv}
    state=$(host_state "$1" "$session_id")
    case "$state" in
      dead) rm -f "$occupancy_file" 2>/dev/null ;;
      *) held=true ;;
    esac
  done
  if [ "$held" = true ]; then printf held; else printf free; fi
}

# merge_state <main root> <branch> <tip> <remote>: merged or unconfirmed.
merge_state() {
  local cache line
  if [ -n "$4" ] && git -C "$1" merge-base --is-ancestor "$3" "refs/remotes/$4/HEAD" 2>/dev/null; then
    printf merged
    return 0
  fi
  cache=$(merged_cache_path "$1")
  if [ -f "$cache" ]; then
    while IFS= read -r line; do
      [ "$line" = "$2$tab$3${tab}merged" ] && { printf merged; return 0; }
    done <"$cache"
  fi
  printf unconfirmed
}

lookup_fresh() { # <main root>
  local stamp
  stamp=$(lookup_stamp_path "$1")
  [ -f "$stamp" ] || return 1
  [ -n "$(find "$stamp" -mmin "-$LOOKUP_INTERVAL_MINUTES" 2>/dev/null)" ]
}

# spawn_lookup <main root>: starts `lookup-merged` detached, at most once per
# interval. The stamp is written before the spawn, so a hung gh cannot buy a
# retry every session.
spawn_lookup() {
  local stamp
  lookup_fresh "$1" && return 0
  stamp=$(lookup_stamp_path "$1")
  mkdir -p "${stamp%/*}" 2>/dev/null || return 0
  : >"$stamp" 2>/dev/null || return 0
  (cd "$1" && nohup bash "$here/kept-worktrees.sh" lookup-merged --main-root "$1" </dev/null >/dev/null 2>&1 &) >/dev/null 2>&1
  return 0
}

# lookup_merged <main root>: for each [gone] branch not already merged, asks gh
# for a merged pull request from that head and caches the branch and tip when
# one's head is the branch's current tip. A newer local tip holds unmerged
# work, so it is not confirmed.
lookup_merged() {
  local references reference track tip remote branch heads cache temporary
  command -v gh >/dev/null 2>&1 || return 0
  references=$(git -C "$1" for-each-ref --format='%(refname)%09%(upstream:track)%09%(objectname)%09%(upstream:remotename)' refs/heads 2>/dev/null) || return 0
  cache=$(merged_cache_path "$1")
  while IFS="$tab" read -r reference track tip remote; do
    [ "$track" = "[gone]" ] || continue
    branch=${reference#refs/heads/}
    [ "$(merge_state "$1" "$branch" "$tip" "$remote")" = merged ] && continue
    heads=$(cd "$1" && gh pr list --head "$branch" --state merged --json headRefOid --jq '.[].headRefOid' --limit 20 2>/dev/null) || continue
    case "$heads" in
      *"$tip"*) ;;
      *) continue ;;
    esac
    mkdir -p "${cache%/*}" 2>/dev/null || return 0
    temporary="$cache.$$.tmp"
    if { [ ! -f "$cache" ] || cat "$cache"; printf '%s\t%s\tmerged\n' "$branch" "$tip"; } >"$temporary" 2>/dev/null; then
      mv -f "$temporary" "$cache" 2>/dev/null || rm -f "$temporary" 2>/dev/null
    else
      rm -f "$temporary" 2>/dev/null
    fi
  done <<EOF
$references
EOF
  return 0
}

remind() { # [directory] | --main-root <path> [--own-tree <path>]
  local main_root="" own_tree="" ledger ledger_input porcelain references survivors candidates
  local tree branch why source tip remote listing="" held_count=0 unconfirmed=false age
  while [ $# -gt 0 ]; do
    case "$1" in
      --main-root | --own-tree)
        [ $# -ge 2 ] || return 0
        if [ "$1" = --main-root ]; then main_root=$2; else own_tree=$2; fi
        shift 2
        ;;
      *)
        main_root=$(gaia_resolve_main_root "$1" 2>/dev/null) || return 0
        shift
        ;;
    esac
  done
  if [ -z "$main_root" ]; then
    main_root=$(gaia_resolve_main_root 2>/dev/null) || return 0
  fi
  [ -n "$main_root" ] || return 0
  porcelain=$(git -C "$main_root" worktree list --porcelain 2>/dev/null) || return 0
  references=$(git -C "$main_root" for-each-ref --format='%(refname)%09%(upstream:track)%09%(objectname)%09%(upstream:remotename)' refs/heads 2>/dev/null) || references=""
  ledger=$(ledger_path "$main_root")
  ledger_input=/dev/null
  [ -f "$ledger" ] && ledger_input=$ledger
  survivors="$ledger.$$.tmp"

  # A worktree counts as live when git lists it and does not mark it
  # prunable (its directory is gone). The first entry is the main checkout,
  # never a kept tree. Ledger lines for trees that are not live are dropped,
  # and the survivors are written only when something was dropped. Each
  # candidate is printed once, `tree<US>branch<US>why<US>source<US>tip<US>remote`,
  # ledger first (source `checked`: the removal check ran) then [gone]
  # (`unchecked`); US, not tab, because a tab IFS collapses an empty field.
  candidates=$(KEPT_PORCELAIN="$porcelain" KEPT_REFERENCES="$references" KEPT_SURVIVORS="$survivors" awk -F '\t' '
  function short(reference) { sub(/^refs\/heads\//, "", reference); return reference }
  BEGIN {
    us = sprintf("%c", 31)
    line_count = split(ENVIRON["KEPT_PORCELAIN"], lines, "\n")
    for (i = 1; i <= line_count; i++) {
      line = lines[i]
      if (substr(line, 1, 9) == "worktree ") {
        path = substr(line, 10); tree_count++; order[tree_count] = path
        if (tree_count > 1) listed[path] = 1
      } else if (substr(line, 1, 7) == "branch ") {
        branch_reference[path] = substr(line, 8)
      } else if (line == "prunable" || substr(line, 1, 9) == "prunable ") {
        delete listed[path]
      }
    }
    reference_count = split(ENVIRON["KEPT_REFERENCES"], references, "\n")
    for (i = 1; i <= reference_count; i++) {
      field_count = split(references[i], fields, "\t")
      if (field_count >= 3 && fields[2] == "[gone]") {
        gone[fields[1]] = 1; tip[fields[1]] = fields[3]; remote[fields[1]] = fields[4]
      }
    }
  }
  {
  tree = $1
  if (!(tree in listed) || (tree in printed)) {
    dropped++
    next
  }
  survivor[++survivor_count] = $0
  branch = (tree in branch_reference) ? short(branch_reference[tree]) : $2
  print tree us branch us $3 us "checked" us "" us ""
  printed[tree] = 1
  }
  END {
    for (i = 2; i <= tree_count; i++) {
      path = order[i]
      if ((path in printed) || !(path in listed) || !(path in branch_reference)) continue
      reference = branch_reference[path]
      if (reference in gone) print path us short(reference) us "merged, and its upstream branch is gone" us "unchecked" us tip[reference] us remote[reference]
    }
    if (dropped) {
      printf "" > ENVIRON["KEPT_SURVIVORS"]
      for (i = 1; i <= survivor_count; i++) print survivor[i] > ENVIRON["KEPT_SURVIVORS"]
      close(ENVIRON["KEPT_SURVIVORS"])
    }
  }' "$ledger_input" 2>/dev/null) || candidates=""

  if [ -f "$survivors" ]; then
    mv -f "$survivors" "$ledger" 2>/dev/null || rm -f "$survivors" 2>/dev/null
  fi

  [ -n "$candidates" ] || return 0
  while IFS=$separator read -r tree branch why source tip remote; do
    [ -n "$tree" ] || continue
    [ -n "$own_tree" ] && [ "$tree" = "$own_tree" ] && continue
    case "$(tree_occupancy "$main_root" "$tree")" in
      held) held_count=$((held_count + 1)); continue ;;
    esac
    if [ "$source" = unchecked ]; then
      case "$(merge_state "$main_root" "$branch" "$tip" "$remote")" in
        merged) ;;
        *) unconfirmed=true; continue ;;
      esac
    fi
    age=$(git -C "$tree" log -1 --format=%cr 2>/dev/null) || age=""
    listing="$listing$(printf -- '- %s (branch %s, last commit %s): %s' "$tree" "$branch" "${age:-unknown}" "$why")
"
    if [ "$source" = unchecked ]; then
      # No removal check ran on this tree, and with the upstream gone the
      # check cannot count its unpushed commits, so the step verifies first.
      listing="$listing$(printf '  Next step: run \140%s\140, confirm every commit on %s landed on the base branch (a squash merge leaves them in \140git log\140), then \140%s\140 and \140%s\140.' \
        "bash .gaia/scripts/worktree-removal-check.sh --tree $tree" "$branch" \
        "git worktree remove $tree" "git branch -D $branch")
"
    else
      listing="$listing$(printf '  Next step: finish or discard what it holds, then %s' \
        "$(bash "$here/worktree-removal-check.sh" --removal-step --tree "$tree" --branch "$branch" 2>/dev/null)")
"
    fi
  done <<EOF
$candidates
EOF

  [ "$unconfirmed" = false ] || spawn_lookup "$main_root"
  if [ -n "$listing" ]; then
    printf 'Kept worktrees: merged, kept by post-merge cleanup or never removed, and no live Claude session is using them. Each stays listed until it is removed.\n'
    printf '%s' "$listing"
  fi
  [ "$held_count" -eq 0 ] || printf '%s more kept worktree(s) not listed: a live Claude session is using them, or whether one is could not be read.\n' "$held_count"
  [ -z "$listing" ] || printf 'Claude: remove a listed tree only when the user names that tree. A tree can hold work in progress outside Claude, so a request to remove them all means confirming each one first.\n'
  return 0
}

usage() {
  printf 'usage: kept-worktrees.sh record --tree <path> --branch <branch> --why <text>\n       kept-worktrees.sh occupy --session <id> --tree <path>\n       kept-worktrees.sh remind [directory] | --main-root <path> [--own-tree <path>]\n       kept-worktrees.sh lookup-merged --main-root <path>\n' >&2
}

subcommand=${1:-}
[ $# -eq 0 ] || shift
if [ "$subcommand" = remind ]; then
  remind "$@"
  exit 0
fi
tree="" branch="" why="" session="" main_root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tree | --branch | --why | --session | --main-root) [ $# -ge 2 ] || { usage; exit 0; } ;;
    *) usage; exit 0 ;;
  esac
  case "$1" in
    --tree) tree=$2 ;;
    --branch) branch=$2 ;;
    --why) why=$2 ;;
    --session) session=$2 ;;
    --main-root) main_root=$2 ;;
  esac
  shift 2
done
case "$subcommand" in
  record)
    [ -n "$tree" ] || { usage; exit 0; }
    record "$tree" "$branch" "$why"
    ;;
  occupy)
    [ -n "$session" ] && [ -n "$tree" ] || { usage; exit 0; }
    occupy "$session" "$tree"
    ;;
  lookup-merged)
    [ -n "$main_root" ] || { usage; exit 0; }
    lookup_merged "$main_root"
    ;;
  *)
    usage
    ;;
esac
exit 0
