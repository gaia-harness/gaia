#!/usr/bin/env bash
#
# Deterministic half of /gaia-cleanse (.claude/skills/gaia/references/cleanse.md):
# who owns a file an action targets, whether a 0-action report may finalize
# without a human, and the one-time move of old reports. The playbook's model
# stages call this rather than computing any of it themselves. What the
# knowledge stores hold (the listing and the counts) is the CLI's:
# `.gaia/cli/gaia fitness inventory --json`.
#
# Usage:
#   bash .gaia/scripts/knowledge-inventory.sh classify [--root <project-root>] <path>...
#   bash .gaia/scripts/knowledge-inventory.sh verify   [--root <project-root>] <report> [--scope-hint <text>]
#   bash .gaia/scripts/knowledge-inventory.sh relocate-reports [--root <project-root>]
#
# With no --root the project is the git top level of the working directory.
# The memory dir derives from the root the way Claude Code keys it: every
# character outside A-Za-z0-9- becomes a dash, and a root given through a
# symlink names a different memory dir than its target.
#
# classify  one `<class>\t<path>` line per input, in input order:
#             project-memory  under the project's memory dir or its
#                             .claude/agent-memory/ (gitignored, yet the
#                             project's own)
#             user-memory     under ~/.claude/agent-memory/, which every
#                             project on the machine shares
#           anything else is answered by .gaia/scripts/fitness-ownership.sh
#           (third-party, ignored, gaia-shipped, adopter), whose exit status
#           passes through: on a non-zero exit nothing is printed.
# verify    exit 0 and `verified: <counts>` when the report may auto-apply:
#           full scope, no scope hint, no action block, a Summary reading
#           `Actions proposed: 0`, an `## Out-of-scope findings` section (a
#           report cut short lacks its last section), and every store count
#           equal to a fresh recount. The recount is the CLI's
#           (`<script dir>/../cli/gaia fitness inventory --json`, each store's
#           `count`). Otherwise exit 1 with one `refuse: <reason>` line per
#           failed condition on stderr. When the CLI cannot run or its output
#           does not parse, verify exits 3 and prints no `verified:` line: it
#           fails closed, so a report is never auto-applied on a recount that
#           did not happen.
#
# relocate-reports
#           one-time move of <root>/.gaia/local/audit/KNOWLEDGE-*.md into
#           <root>/.gaia/local/cleanse/ (the directory /gaia-cleanse writes
#           to), keeping each file's mtime because the newest applied report's
#           mtime anchors the statusline nudge's drift clock. Never overwrites
#           and never deletes: a report whose name already sits in cleanse/ is
#           left where it is. Prints nothing on success.
#           It moves only when the working directory is the main checkout. A
#           linked worktree shares one .gaia/local with the main checkout, so a
#           move from there would rename reports out from under sessions still
#           running the old layout; --root is never the test, because the
#           statusline refresher passes the main checkout's root from a
#           worktree. From a linked worktree, outside a repository, or on
#           --help it exits 0 and moves nothing.
#
# Exit 2: usage error. Exit 3: an input could not be read, the CLI recount
# could not run, or a move failed.

set -uo pipefail

fail_usage() {
  printf 'knowledge-inventory: %s\n' "$1" >&2
  exit 2
}

fail_input() {
  printf 'knowledge-inventory: %s\n' "$1" >&2
  exit 3
}

[ "$#" -ge 1 ] || fail_usage "usage: knowledge-inventory.sh classify|verify|relocate-reports [--root <project-root>] ..."
subcommand="$1"
shift
case "$subcommand" in
  classify | verify | relocate-reports) ;;
  *) fail_usage "unknown subcommand: $subcommand" ;;
esac

root=""
scope_hint=""
arguments=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || fail_usage "--root needs a directory"
      root="$2"
      shift 2
      ;;
    --scope-hint)
      [ "$#" -ge 2 ] || fail_usage "--scope-hint needs a value"
      scope_hint="$2"
      shift 2
      ;;
    --help | -h)
      printf 'usage: knowledge-inventory.sh classify|verify|relocate-reports [--root <project-root>] ...\n'
      exit 0
      ;;
    -*) fail_usage "unknown option: $1" ;;
    *)
      arguments+=("$1")
      shift
      ;;
  esac
done

if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail_input "not inside a git work tree; pass --root"
fi
root="${root%/}"
memory_dir="$HOME/.claude/projects/$(printf %s "$root" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
user_agent_memory_dir="$HOME/.claude/agent-memory"

# memory_class <path>: project-memory or user-memory for a path inside a
# memory store, nothing otherwise. A `..` segment never matches, so a path
# that climbs out of a store falls through to the ownership classifier.
memory_class() {
  case "/$1/" in */../*) return 0 ;; esac
  case "$1" in
    "$memory_dir"/* | "$root"/.claude/agent-memory/* | .claude/agent-memory/*) printf 'project-memory' ;;
    "$user_agent_memory_dir"/*) printf 'user-memory' ;;
  esac
}

classify_paths() {
  [ "${#arguments[@]}" -gt 0 ] || fail_usage "usage: knowledge-inventory.sh classify [--root <project-root>] <path>..."
  local given class delegated=() classified="" index=0 line
  for given in ${arguments[@]+"${arguments[@]}"}; do
    [ -n "$(memory_class "$given")" ] || delegated+=("$given")
  done
  if [ "${#delegated[@]}" -gt 0 ]; then
    classified="$(bash "${KNOWLEDGE_OWNERSHIP_CLASSIFIER:-$(dirname "$0")/fitness-ownership.sh}" --root "$root" -- ${delegated[@]+"${delegated[@]}"})" || exit "$?"
  fi
  local classified_lines=()
  while IFS= read -r line; do
    [ -n "$line" ] && classified_lines+=("$line")
  done <<<"$classified"
  for given in ${arguments[@]+"${arguments[@]}"}; do
    class="$(memory_class "$given")"
    if [ -n "$class" ]; then
      case "$given" in
        "$root"/*) given="${given#"$root"/}" ;;
      esac
      printf '%s\t%s\n' "$class" "$given"
    else
      printf '%s\n' "${classified_lines[$index]}"
      index=$((index + 1))
    fi
  done
}

# recount_stores: `<store>=<count>` per store in the CLI inventory's order,
# space separated, on stdout. Returns 3 when jq or the CLI is missing, the
# CLI exits non-zero, or its output is not a store map, so verify never
# compares a report against a recount that did not happen.
recount_stores() {
  local cli inventory counts
  cli="$(dirname "$0")/../cli/gaia"
  command -v jq >/dev/null 2>&1 || {
    printf 'knowledge-inventory: jq is required for the store recount\n' >&2
    return 3
  }
  [ -x "$cli" ] || {
    printf 'knowledge-inventory: cannot run %s\n' "$cli" >&2
    return 3
  }
  inventory="$("$cli" fitness inventory --json --root "$root")" || {
    printf 'knowledge-inventory: the CLI store recount failed\n' >&2
    return 3
  }
  counts="$(jq -r '[.stores | to_entries[] | "\(.key)=\(.value.count)"] | join(" ")' <<<"$inventory" 2>/dev/null)" || counts=""
  [ -n "$counts" ] || {
    printf 'knowledge-inventory: the CLI store recount did not print a store map\n' >&2
    return 3
  }
  printf '%s\n' "$counts"
}

# frontmatter_value <report> <key>: the value of <key> in the report's
# leading `---` block, or nothing.
frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, key ":") == 1 { sub("^" key ":[[:space:]]*", ""); print; exit }
  ' "$1"
}

verify_report() {
  [ "${#arguments[@]}" -eq 1 ] || fail_usage "usage: knowledge-inventory.sh verify [--root <project-root>] <report> [--scope-hint <text>]"
  local report="${arguments[0]}"
  [ -f "$report" ] && [ -r "$report" ] || fail_input "cannot read report $report"

  local refusals=() scope action_blocks recorded recomputed stores store report_count recomputed_count
  recomputed="$(recount_stores)" || exit "$?"
  stores="$(tr ' ' '\n' <<<"$recomputed" | sed 's/=.*//')"

  [ -z "$scope_hint" ] || refusals+=("scope hint given ($scope_hint); a scoped run never auto-applies")
  scope="$(frontmatter_value "$report" scope)"
  [ "$scope" = "full" ] || refusals+=("report scope is ${scope:-unset}, not full")
  action_blocks="$(grep -cE '^- \[.\] `' "$report")"
  [ "$action_blocks" -eq 0 ] || refusals+=("report carries $action_blocks action block(s)")
  grep -qxE -- '- Actions proposed: 0' "$report" || refusals+=("Summary does not read Actions proposed: 0")
  grep -qx '## Out-of-scope findings' "$report" || refusals+=("report has no ## Out-of-scope findings section")

  recorded=" $(frontmatter_value "$report" store_counts) "
  for store in $stores; do
    report_count="$(tr ' ' '\n' <<<"$recorded" | sed -n "s/^$store=//p")"
    recomputed_count="$(tr ' ' '\n' <<<"$recomputed" | sed -n "s/^$store=//p")"
    [ "$report_count" = "$recomputed_count" ] ||
      refusals+=("store $store: report ${report_count:-none}, recomputed $recomputed_count")
  done

  if [ "${#refusals[@]}" -gt 0 ]; then
    printf 'refuse: %s\n' ${refusals[@]+"${refusals[@]}"} >&2
    exit 1
  fi
  printf 'verified: %s\n' "$recomputed"
}

relocate_reports() {
  local audit_dir="$root/.gaia/local/audit" cleanse_dir="$root/.gaia/local/cleanse" report
  # Nothing to move is the steady state after the one move, and the
  # statusline refresher calls this on every refresh: return before the
  # checkout checks below spawn git.
  set -- "$audit_dir"/KNOWLEDGE-*.md
  [ -f "$1" ] || return 0

  # shellcheck source=/dev/null
  . "$(dirname "$0")/main-root-lib.sh" || return 0
  if gaia_is_linked_worktree "$PWD"; then
    return 0
  fi
  gaia_resolve_main_root "$PWD" >/dev/null 2>&1 || return 0

  for report in "$audit_dir"/KNOWLEDGE-*.md; do
    [ -f "$report" ] || continue
    [ ! -e "$cleanse_dir/${report##*/}" ] || continue
    mkdir -p "$cleanse_dir" || fail_input "cannot create $cleanse_dir"
    mv "$report" "$cleanse_dir/" || fail_input "cannot move $report"
  done
}

case "$subcommand" in
  relocate-reports) relocate_reports ;;
  classify) classify_paths ;;
  verify) verify_report ;;
esac
