#!/usr/bin/env bash
# shellcheck shell=bash
#
# autonomy-gate-repair.sh: the deterministic bounds of the plan orchestrator's
# unattended gate repair (orchestrator-template.md, `## Unattended gate
# repair`). Under a live autonomy switch, a phase gate failure the gate retry
# does not settle may get one repair the orchestrator applies itself, then a
# rerun of the whole gate. This script decides whether the repair may start
# and judges what it changed; the orchestrator never trusts its own account.
#
# Usage:
#   autonomy-gate-repair.sh baseline --root <R> --plan-dir <P> --phase <N> --out <file> --task <task doc>...
#   autonomy-gate-repair.sh check    --root <R> --baseline <file>
#
# baseline refuses, writing nothing, when the switch is not live for <R>
# (`attended`: the run halts as attended runs do) or when the phase's repair is
# already spent: <P>/PROGRESS.md holds a `## Phase <N>, <title> (GATE REPAIR)`
# block, or <P>/gate-repair-phase-<N>.spent exists (`already-repaired`: one
# repair per phase, across resumes). Otherwise it writes <file>: line 1
# `head <sha>`, then one `task <sha256> <path>` line per --task doc (each must
# sit under <P>) and one `declared <word>` line per word declared_words reads
# from them, then one `<blob or -> TAB <path>` line per path `git status`
# lists, so check can tell which paths the repair touched, and then writes the
# .spent marker in the git-ignored plan folder, so a run that dies before the
# orchestrator records the block still counts the repair as spent on resume.
#
# check judges the paths whose state differs from the baseline (a new, edited,
# reverted or deleted path). Each must be named by a `declared` line of the
# baseline (taken from the task docs when the baseline was written, so check
# never reads a task doc live), must still exist, and must be in neither the
# autonomy protected set (autonomy_protected_globs) nor the audit fixer's
# ENFORCEMENT_PATHS (audit-fix-verify-state-lib.sh). It also refuses a moved
# HEAD and a repair that changed nothing. On a pass it prints `changed <path>`
# per path on stdout.
#
# Honest limit: the snapshot is `git status`, so an edit to a git-ignored file
# (`.env`) is invisible to check; the orchestrator's prose forbids one. The task
# docs sit in the git-ignored plan folder the snapshot cannot see, so check
# refuses a repair when any recorded doc's hash differs from the baseline's.
# The --baseline file is itself an orchestrator-held input check trusts as
# written: its declared words, task hashes and snapshot carry no integrity
# check, so editing it between baseline and check widens the bound. The
# orchestrator's prose forbids that edit; the script cannot see it.
#
# Exit codes: 0 pass, 1 refused (each reason on stderr as `<kind> <detail>`;
# kinds: attended, already-repaired, head-moved, task-doc-changed, no-change,
# undeclared, deleted, protected, enforcement, protected-unreadable), 2 usage or a
# repository that cannot be read.
#
# Bash 3.2 compatible.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage:
  autonomy-gate-repair.sh baseline --root <R> --plan-dir <P> --phase <N> --out <file> --task <task doc>...
  autonomy-gate-repair.sh check    --root <R> --baseline <file>
EOF
  exit 2
}

# snapshot <root>: one `<blob or -> TAB <path>` line per path git status
# lists, sorted.
snapshot() {
  local root="$1" entry path blob
  git -C "$root" status --porcelain=v1 -z --untracked-files=all --no-renames |
    while IFS= read -r -d '' entry; do
      path="${entry:3}"
      if [ -f "$root/$path" ]; then
        blob=$(git -C "$root" hash-object --no-filters -- "$path")
      else
        blob=-
      fi
      printf '%s\t%s\n' "$blob" "$path"
    done | LC_ALL=C sort
}

# declared_words <task doc>...: every backtick span and every
# whitespace-separated word of the docs, leading `(` and quotes, a leading `./`,
# trailing punctuation and a trailing `:N` or `:N-M` line-range hint stripped,
# one per line.
declared_words() {
  awk '
    function emit(word) {
      sub(/^[("'"'"']+/, "", word)
      sub(/^\.\//, "", word)
      sub(/[.,;:)"'"'"']+$/, "", word)
      sub(/:[0-9]+(-[0-9]+)?$/, "", word)
      if (word != "") print word
    }
    {
      line = $0
      while (match(line, /`[^`]+`/)) {
        emit(substr(line, RSTART + 1, RLENGTH - 2))
        line = substr(line, RSTART + RLENGTH)
      }
      gsub(/`/, " ", $0)
      for (i = 1; i <= NF; i++) emit($i)
    }' "$@" | LC_ALL=C sort -u
}

command_name="${1:-}"
[ -n "$command_name" ] || usage
shift
root="" plan_dir="" phase="" out="" baseline=""
tasks=()
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --root) root="$2" ;;
    --plan-dir) plan_dir="$2" ;;
    --phase) phase="$2" ;;
    --out) out="$2" ;;
    --baseline) baseline="$2" ;;
    --task) tasks+=("$2") ;;
    *) usage ;;
  esac
  shift 2
done
if [ -z "$root" ] || ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then usage; fi

case "$command_name" in
  baseline)
    [ -n "$plan_dir" ] && [ -n "$out" ] || usage
    [[ $phase =~ ^[1-9][0-9]*$ ]] || usage
    [ "${#tasks[@]}" -gt 0 ] && [ -d "$plan_dir" ] || usage
    plan_physical=$(cd "$plan_dir" && pwd -P)
    for task in ${tasks[@]+"${tasks[@]}"}; do
      [ -f "$task" ] || usage
      task_physical="$(cd "$(dirname "$task")" && pwd -P)/$(basename "$task")"
      case "$task_physical" in
        "$plan_physical"/*) ;;
        *) usage ;;
      esac
    done
    # shellcheck source=autonomy-lib.sh
    . "$_here/autonomy-lib.sh"
    # shellcheck source=audit-fix-verify-state-lib.sh
    . "$_here/audit-fix-verify-state-lib.sh"
    if ! autonomy_active "$root"; then
      echo "attended the autonomy switch is not live" >&2
      exit 1
    fi
    spent_marker="$plan_dir/gate-repair-phase-$phase.spent"
    if [ -e "$spent_marker" ] || { [ -f "$plan_dir/PROGRESS.md" ] &&
      grep -Eq "^## Phase $phase, .*\(GATE REPAIR\)[[:space:]]*\$" "$plan_dir/PROGRESS.md"; }; then
      echo "already-repaired phase $phase" >&2
      exit 1
    fi
    head_sha=$(git -C "$root" rev-parse HEAD) || exit 2
    lines=$(snapshot "$root") || exit 2
    {
      printf 'head %s\n' "$head_sha"
      for task in ${tasks[@]+"${tasks[@]}"}; do
        task_physical="$(cd "$(dirname "$task")" && pwd -P)/$(basename "$task")"
        printf 'task %s %s\n' "$(_sha256 <"$task")" "$task_physical"
      done
      declared_words ${tasks[@]+"${tasks[@]}"} | sed 's/^/declared /'
      [ -z "$lines" ] || printf '%s\n' "$lines"
    } >"$out"
    printf 'phase %s repair started\n' "$phase" >"$spent_marker"
    ;;
  check)
    [ -n "$baseline" ] && [ -f "$baseline" ] && [ "${#tasks[@]}" -eq 0 ] || usage
    # shellcheck source=autonomy-lib.sh
    . "$_here/autonomy-lib.sh"
    # shellcheck source=audit-fix-verify-state-lib.sh
    . "$_here/audit-fix-verify-state-lib.sh"
    refused=0
    refuse() {
      echo "$1 $2" >&2
      refused=1
    }
    head_sha=$(git -C "$root" rev-parse HEAD) || exit 2
    [ "$(sed -n 1p "$baseline")" = "head $head_sha" ] || refuse head-moved "$head_sha"
    while IFS= read -r record; do
      [ -n "$record" ] || continue
      recorded_rest="${record#task }"
      recorded_path="${recorded_rest#* }"
      recorded_sha="${recorded_rest%% *}"
      { [ -f "$recorded_path" ] && [ "$(_sha256 <"$recorded_path")" = "$recorded_sha" ]; } ||
        refuse task-doc-changed "$recorded_path"
    done <<<"$(grep '^task ' "$baseline" || true)"
    declared=$(sed -n 's/^declared //p' "$baseline")
    before=$(sed 1d "$baseline" | grep -Ev '^(task|declared) ' || true)
    after=$(snapshot "$root") || exit 2
    changed=$(printf '%s\n%s\n' "$before" "$after" | LC_ALL=C sort | uniq -u | cut -f2- | LC_ALL=C sort -u | sed '/^$/d')
    [ -n "$changed" ] || refuse no-change "the repair changed no path"
    globs=$(autonomy_protected_globs "$root") || {
      refuse protected-unreadable ".gaia/autonomy-protected-paths.json"
      globs=""
    }
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      grep -Fxq -- "$path" <<<"$declared" || refuse undeclared "$path"
      [ -e "$root/$path" ] || refuse deleted "$path"
      if [ -n "$globs" ] && autonomy_protected_match "$path" "$globs"; then
        refuse protected "$path"
      fi
      for enforcement_path in ${ENFORCEMENT_PATHS[@]+"${ENFORCEMENT_PATHS[@]}"}; do
        [ "$path" = "$enforcement_path" ] && refuse enforcement "$path"
      done
    done <<<"$changed"
    [ "$refused" -eq 0 ] || exit 1
    while IFS= read -r path; do
      [ -n "$path" ] && printf 'changed %s\n' "$path"
    done <<<"$changed"
    ;;
  *) usage ;;
esac
