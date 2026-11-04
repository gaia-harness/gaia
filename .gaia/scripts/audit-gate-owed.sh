#!/usr/bin/env bash
# shellcheck shell=bash
#
# The owed-gate record. A round whose fix entries are all Minor commits after a
# smaller gate that skips Playwright, the dev smoke test and the production
# build; those steps stay owed until they pass on the final tree. This script
# owns <run-folder>/gate-owed.json and the refusal that reads it.
#
#   audit-gate-owed.sh choose       --root <R> --run-folder <D> --round <r>
#   audit-gate-owed.sh mark         --root <R> --run-folder <D> --round <r>
#   audit-gate-owed.sh gate-steps   --root <R> --run-folder <D>
#   audit-gate-owed.sh steps-passed --root <R> --run-folder <D>
#   audit-gate-owed.sh selection    --root <R> --run-folder <D>
#   audit-gate-owed.sh status       --root <R> [--run-folder <D>]
#   audit-gate-owed.sh run          --root <R> --run-folder <D>
#
# choose prints smaller or full. status exits 0 clear, 1 owed, 3 unreadable
# (read as owed by every caller). run and gate-steps exit 0 pass, 1 failure,
# 3 refused; their last output line is `gate-owed exit <status>`. A refusal is
# the dev smoke test exiting 2 (usage) or 3 (refused to start, such as a held
# port): it is not a defect, so it records nothing.
# run executes the owed steps on the committed tree and, on a pass, clears the
# record. gate-steps executes the same steps for a gate before its commit and
# touches no record: on a pass it leaves the evidence below for the working
# tree, which steps-passed then clears once that tree is committed.
# gate-pass.json is the pass evidence: the tree the three steps passed on.
# steps-passed clears only when it holds that evidence for the HEAD tree, else
# exits 4 and changes nothing, so a failed gate never clears by hand. A new run
# or gate-steps discards the evidence before its steps start. The evidence is
# a local file, so it stops a mistaken call, not a forged file.
# gate-failure.json is the failure record the reopened-round hook and the unit
# read. Exit 2 is usage, 3 an unreadable input.

set -uo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Owned by the Quality Gate page's Quick check and, in the maintainer repo, its
# frontend filter: keep both equal to the page.
GATE_QUICK_CHECK_PATTERN='\.(ts|tsx|js|jsx|mjs|cjs|css)$|^([^/]+/)*(package\.json|pnpm-lock\.yaml|tsconfig.*\.json|vite\.config\.|vitest\.config\.|playwright\.config\.|eslint\.config\.)|^(\.gaia/packages\.json|([^/]+/)*gaia\.package\.json)$'
# gaia:maintainer-only:start
GATE_FRONTEND_FILTER_PATTERN='^\.gaia/(cli|tests|scripts)/'
# gaia:maintainer-only:end

usage() {
  printf 'usage: audit-gate-owed.sh choose|mark|gate-steps|steps-passed|selection|status|run --root <R> [--run-folder <D>] [--round <r>]\n' >&2
  exit 2
}

subcommand="${1:-}"
[ -n "$subcommand" ] || usage
shift
root=""
folder=""
round=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --root) root="$2" ;;
    --run-folder) folder="$2" ;;
    --round) round="$2" ;;
    *) usage ;;
  esac
  shift 2
done
case "$subcommand" in choose | mark | gate-steps | steps-passed | selection | status | run) ;; *) usage ;; esac
case "$root" in /*) ;; *) usage ;; esac
case "$subcommand" in
  choose | mark) case "$round" in '' | *[!0-9]*) usage ;; esac ;;
esac

if [ -z "$folder" ]; then
  [ "$subcommand" = status ] || usage
  folder="$(
    . "$script_directory/audit-loop-state-lib.sh" 2>/dev/null || exit 1
    main="$(gaia_resolve_main_root "$root" 2>/dev/null)" || exit 1
    key="$(gaia_loop_key "$root" 2>/dev/null)" || exit 1
    gaia_loop_run_directory "$main" "$key"
  )" || exit 3
  [ -n "$folder" ] || exit 3
fi
case "$folder" in /*) ;; *) usage ;; esac

record="$folder/gate-owed.json"
failure_file="$folder/gate-failure.json"
evidence_file="$folder/gate-pass.json"
evaluator="$script_directory/audit-loop-eval.sh"

head_commit() { git -C "$root" rev-parse HEAD 2>/dev/null; }
head_tree() { git -C "$root" rev-parse 'HEAD^{tree}' 2>/dev/null; }

# The tree a commit of everything in the working tree would hold: tracked
# changes plus untracked, non-ignored files, hashed through a scratch index so
# the real index is untouched.
working_tree() {
  local index tree
  index="$(mktemp)" || return 3
  if ! cp "$(git -C "$root" rev-parse --path-format=absolute --git-path index 2>/dev/null)" "$index" 2>/dev/null; then
    GIT_INDEX_FILE="$index" git -C "$root" read-tree HEAD 2>/dev/null || { rm -f "$index"; return 3; }
  fi
  if GIT_INDEX_FILE="$index" git -C "$root" add -A 2>/dev/null; then
    tree="$(GIT_INDEX_FILE="$index" git -C "$root" write-tree 2>/dev/null)"
  fi
  rm -f "$index"
  [ -n "${tree:-}" ] || return 3
  printf '%s\n' "$tree"
}

record_valid() {
  jq -e 'type == "object" and .version == 1 and (.owed | type) == "boolean" and (.since | type) == "string"
    and (.rounds | type) == "array" and (.passed == null or ((.passed.tree | type) == "string" and (.passed.commit | type) == "string"))' \
    "$record" >/dev/null 2>&1
}

# Prints the record, or `none` when absent; returns 3 when present and corrupt.
read_record() {
  if [ ! -e "$record" ]; then printf 'none\n'; return 0; fi
  record_valid || return 3
  jq -c . "$record"
}

write_record() {
  local temporary
  mkdir -p "$folder" || return 3
  temporary="$(mktemp "$folder/.gate-owed.XXXXXX")" || return 3
  if printf '%s\n' "$1" >"$temporary" && mv "$temporary" "$record"; then
    return 0
  fi
  rm -f "$temporary"
  return 3
}

blank_record() {
  jq -n -c --arg since "$(head_commit)" '{version: 1, owed: false, since: $since, rounds: [], passed: null, last_failure: null}'
}

current_record() {
  local existing
  existing="$(read_record)" || return 3
  if [ "$existing" = none ]; then blank_record; else printf '%s\n' "$existing"; fi
}

selection() {
  local existing from paths
  existing="$(read_record)" || return 3
  [ "$existing" != none ] || return 0
  from="$(printf '%s' "$existing" | jq -r 'if .owed then .since else (.passed.commit // "") end')"
  [ -n "$from" ] || return 0
  paths="$(git -C "$root" log --first-parent --no-merges --format= --name-only "$from..HEAD" 2>/dev/null)" || return 3
  paths="$(printf '%s\n' "$paths" | grep -E "$GATE_QUICK_CHECK_PATTERN")" || true
  if [ -n "${GATE_FRONTEND_FILTER_PATTERN:-}" ] && [ -n "$paths" ]; then
    paths="$(printf '%s\n' "$paths" | grep -vE "${GATE_FRONTEND_FILTER_PATTERN:-}")" || true
  fi
  [ -z "$paths" ] || printf '%s\n' "$paths" | sort -u
}

# Prints smaller when the round has a fix entry and every one is a Minor,
# non-security finding with a sidecar row, else full.
choose() {
  local dispositions="$folder/dispositions-$round.json" findings
  [ -f "$dispositions" ] || return 3
  findings="$(bash "$evaluator" findings --root "$root" --round "$round" 2>/dev/null)" || return 3
  jq -n -r --slurpfile d "$dispositions" --argjson f "$findings" '
    [$d[0].entries[] | select(.disposition == "fix")] as $fixes
    | if ($fixes | length) > 0 and all($fixes[]; . as $e
        | any($f.entries[]; .member == $e.member and .finding_class == $e.finding_class and .path == $e.path
            and .line == $e.line and .severity == "minor" and .security == false))
      then "smaller" else "full" end' 2>/dev/null
}

mark() {
  local existing head_parent updated
  existing="$(current_record)" || return 3
  head_parent="$(git -C "$root" rev-parse 'HEAD^' 2>/dev/null)" || head_parent="$(head_commit)"
  updated="$(printf '%s' "$existing" | jq -c --argjson round "$round" --arg since "$head_parent" \
    '(if .owed then . else .since = $since end) | .owed = true | .rounds += [$round]')" || return 3
  write_record "$updated"
}

steps_passed() {
  local existing updated tree
  tree="$(head_tree)"
  if ! jq -e --arg tree "$tree" 'type == "object" and .version == 1 and .tree == $tree and .exit == 0
      and .steps == ["pw", "smoke", "build"]' "$evidence_file" >/dev/null 2>&1; then
    printf 'audit-gate-owed: steps-passed refused: no pass evidence for HEAD tree %s; run audit-gate-owed.sh run\n' "$tree" >&2
    return 4
  fi
  existing="$(current_record)" || return 3
  updated="$(printf '%s' "$existing" | jq -c --arg tree "$(head_tree)" --arg commit "$(head_commit)" \
    '.owed = false | .passed = {tree: $tree, commit: $commit} | .last_failure = null')" || return 3
  write_record "$updated"
}

status() {
  local existing paths
  existing="$(read_record)" || return 3
  [ "$existing" != none ] || return 0
  if [ "$(printf '%s' "$existing" | jq -r '.owed | not')" = true ] \
    && [ "$(printf '%s' "$existing" | jq -r '.passed.tree // ""')" = "$(head_tree)" ]; then
    return 0
  fi
  paths="$(selection)" || return 3
  [ -n "$paths" ] || return 0
  return 1
}

# A snapshot that changes when a tracked or untracked non-ignored path does.
tree_snapshot() {
  { git -C "$root" status --porcelain=v1 -uall; git -C "$root" diff HEAD; } 2>/dev/null | cksum
}

finish() {
  printf 'gate-owed exit %s\n' "$1"
  exit "$1"
}

# $1 is run (the committed tree; a failure is recorded and a pass clears) or
# gate-steps (the working tree before a commit; records nothing but evidence).
run_steps() {
  local mode="$1" number log step before rounds_current existing updated command_status pass_tree
  number=$(($(find "$folder" -maxdepth 1 -name 'gate-owed-*.log' 2>/dev/null | wc -l | tr -d ' ') + 1))
  mkdir -p "$folder" || finish 3
  rm -f "$evidence_file" || finish 3
  log="$folder/gate-owed-$number.log"
  : >"$log"
  existing="$(current_record)" || finish 3
  before="$(tree_snapshot)"
  for step in pw smoke build; do
    command_status=0
    case "$step" in
      pw) pnpm -C "$root" pw >>"$log" 2>&1 </dev/null || command_status=$? ;;
      smoke) bash "$root/.gaia/scripts/dev-smoke.sh" --tree "$root" >>"$log" 2>&1 </dev/null || command_status=$? ;;
      build) pnpm -C "$root" build >>"$log" 2>&1 </dev/null || command_status=$? ;;
    esac
    if [ "$step" = smoke ] && { [ "$command_status" -eq 2 ] || [ "$command_status" -eq 3 ]; }; then
      finish 3
    fi
    if [ "$command_status" -eq 0 ] && [ "$(tree_snapshot)" != "$before" ]; then
      printf 'gate-owed: step %s changed the working tree\n' "$step" >>"$log"
      command_status=1
    fi
    if [ "$command_status" -ne 0 ] && [ "$mode" = gate-steps ]; then
      finish 1
    fi
    if [ "$command_status" -ne 0 ]; then
      rounds_current="$(bash "$evaluator" current-round --root "$root" 2>/dev/null)" || finish 3
      case "$rounds_current" in '' | *[!0-9]*) finish 3 ;; esac
      jq -n -c --arg step "$step" --arg log "$log" --arg tree "$(head_tree)" --argjson after "$rounds_current" \
        '{version: 1, step: $step, log: $log, tree: $tree, after_round: $after}' >"$failure_file.tmp" || finish 3
      mv "$failure_file.tmp" "$failure_file" || finish 3
      updated="$(printf '%s' "$existing" | jq -c --arg step "$step" --arg log "$log" '.owed = true | .last_failure = {step: $step, log: $log}')" || finish 3
      write_record "$updated" || finish 3
      finish 1
    fi
  done
  if [ "$mode" = gate-steps ]; then pass_tree="$(working_tree)" || finish 3; else pass_tree="$(head_tree)"; fi
  jq -n -c --arg tree "$pass_tree" --arg commit "$(head_commit)" \
    '{version: 1, tree: $tree, commit: $commit, steps: ["pw", "smoke", "build"], exit: 0}' >"$evidence_file.tmp" || finish 3
  mv "$evidence_file.tmp" "$evidence_file" || finish 3
  [ "$mode" = gate-steps ] && finish 0
  steps_passed || finish 3
  rm -f "$failure_file"
  finish 0
}

case "$subcommand" in
  choose) choose; exit $? ;;
  mark) mark; exit $? ;;
  steps-passed) steps_passed; exit $? ;;
  selection) selection; exit $? ;;
  status) status; exit $? ;;
  gate-steps) run_steps gate-steps ;;
  run) run_steps run ;;
esac
