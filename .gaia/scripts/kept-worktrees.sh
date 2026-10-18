#!/usr/bin/env bash
# shellcheck shell=bash
#
# kept-worktrees.sh: the ledger of worktrees a post-merge cleanup kept, and the
# session-start reminder that lists them until they are removed.
#
#   bash .gaia/scripts/kept-worktrees.sh record --tree <path> --branch <branch> --why <text>
#   bash .gaia/scripts/kept-worktrees.sh remind [directory]
#   bash .gaia/scripts/kept-worktrees.sh remind --main-root <path>
#
# The `--main-root` form takes a root the caller already resolved with
# main-root-lib.sh, and skips resolving it again: the resolver is most of the
# reminder's cost, and the session-start hook has already paid it.
#
# worktree-removal-check.sh stops a removal when the tree still holds work and
# says so once, in that run's output; nothing else surfaces the tree again.
# The reminder lists a tree from either of two sources:
#   ledger   `record`, which the check runs when it stops, writes one line per
#            tree path (tree, branch, why; tab separated) to the main
#            checkout's .gaia/local/kept-worktrees.tsv, so every tree reads
#            one ledger. The cleanup arm stops before its `git fetch --prune`,
#            so a kept tree's remote-tracking ref usually survives and will
#            not read [gone] until a later prune; the ledger covers that
#            window.
#   [gone]   a linked worktree whose branch's upstream reads [gone]: its
#            remote branch was deleted, usually by the merge, and the tree was
#            never removed.
#
# Both subcommands exit 0 on every path and print nothing when a read or write
# fails, so neither can fail the check's stop or a session start. The reminder
# never removes a tree: it only drops ledger lines whose tree git no longer
# lists as a live worktree.
#
# Cost, paid at every session start: one `git worktree list --porcelain`, one
# `git for-each-ref`, one ledger read and one awk, plus one check call per
# listed tree for its removal wording. No fetch, no network, no per-tree
# `git status`, no jq.
#
# Bash 3.2 compatible. Never `cd`.

set -u

here=${BASH_SOURCE[0]%/*}
[ "$here" != "${BASH_SOURCE[0]}" ] || here=.
# shellcheck source=/dev/null
. "$here/main-root-lib.sh" 2>/dev/null || exit 0

ledger_path() { # <main root>
  printf '%s/.gaia/local/kept-worktrees.tsv' "$1"
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

remind() { # [directory] | --main-root <path>
  local main_root ledger ledger_input porcelain references survivors kept tree branch why separator
  if [ "${1:-}" = --main-root ]; then
    main_root=${2:-}
    [ -n "$main_root" ] || return 0
  else
    main_root=$(gaia_resolve_main_root ${1:+"$1"} 2>/dev/null) || return 0
  fi
  porcelain=$(git -C "$main_root" worktree list --porcelain 2>/dev/null) || return 0
  references=$(git -C "$main_root" for-each-ref --format='%(refname)%09%(upstream:track)' refs/heads 2>/dev/null) || references=""
  ledger=$(ledger_path "$main_root")
  ledger_input=/dev/null
  [ -f "$ledger" ] && ledger_input=$ledger
  survivors="$ledger.$$.tmp"
  separator=$(printf '\037')

  # A worktree counts as live when git lists it and does not mark it
  # prunable (its directory is gone). The first entry is the main checkout,
  # never a kept tree. Ledger lines for trees that are not live are dropped,
  # and the survivors are written only when something was dropped. Each
  # listed tree is printed once, `tree<US>branch<US>why`, ledger first; US,
  # not tab, because a tab IFS collapses an empty field.
  kept=$(KEPT_PORCELAIN="$porcelain" KEPT_REFERENCES="$references" KEPT_SURVIVORS="$survivors" awk -F '\t' '
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
      tab = index(references[i], "\t")
      if (tab && substr(references[i], tab + 1) == "[gone]") gone[substr(references[i], 1, tab - 1)] = 1
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
  print tree us branch us $3
  printed[tree] = 1
  }
  END {
    for (i = 2; i <= tree_count; i++) {
      path = order[i]
      if ((path in printed) || !(path in listed) || !(path in branch_reference)) continue
      if (branch_reference[path] in gone) print path us short(branch_reference[path]) us "its upstream branch is gone"
    }
    if (dropped) {
      printf "" > ENVIRON["KEPT_SURVIVORS"]
      for (i = 1; i <= survivor_count; i++) print survivor[i] > ENVIRON["KEPT_SURVIVORS"]
      close(ENVIRON["KEPT_SURVIVORS"])
    }
  }' "$ledger_input" 2>/dev/null) || kept=""

  if [ -f "$survivors" ]; then
    mv -f "$survivors" "$ledger" 2>/dev/null || rm -f "$survivors" 2>/dev/null
  fi

  [ -n "$kept" ] || return 0
  printf 'Kept worktrees: post-merge cleanup stopped before removing these, or their merged branch was never cleaned up. Each stays listed until it is removed.\n'
  while IFS=$separator read -r tree branch why; do
    [ -n "$tree" ] || continue
    printf -- '- %s (branch %s): %s\n' "$tree" "$branch" "$why"
    printf '  Next step: finish or discard what it holds, then %s\n' \
      "$(bash "$here/worktree-removal-check.sh" --removal-step --tree "$tree" --branch "$branch" 2>/dev/null)"
  done <<EOF
$kept
EOF
  return 0
}

usage() {
  printf 'usage: kept-worktrees.sh record --tree <path> --branch <branch> --why <text>\n       kept-worktrees.sh remind [directory]\n' >&2
}

subcommand=${1:-}
[ $# -eq 0 ] || shift
case "$subcommand" in
  record)
    tree="" branch="" why=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --tree | --branch | --why)
          [ $# -ge 2 ] || { usage; exit 0; }
          case "$1" in
            --tree) tree=$2 ;;
            --branch) branch=$2 ;;
            --why) why=$2 ;;
          esac
          shift 2
          ;;
        *)
          usage
          exit 0
          ;;
      esac
    done
    [ -n "$tree" ] || { usage; exit 0; }
    record "$tree" "$branch" "$why"
    ;;
  remind)
    remind "$@"
    ;;
  *)
    usage
    ;;
esac
exit 0
