#!/usr/bin/env bash
# The deterministic half of the pre-audit worthiness step: what each emergent
# test's stored state means (route), recording verdicts (record), settling a
# test the step finished with (settle), building the filer's finding (finding)
# and dropping stale recorded residuals (prune). Dispatching the evaluator and
# asking the human stay in the step's instructions.
#
# Usage:
#   worthiness-step.sh route  --root <tree> --run-folder <dir>
#   worthiness-step.sh record --root <tree> --verdicts <file> [--expect <route-json-file>]
#   worthiness-step.sh settle --run-folder <dir> --file <f> --full-name <n> --signal <s>
#                             --as residual|refused|filed|fixed [--first-line <n> --reason <text>]
#   worthiness-step.sh finding --entry <file holding one route element>
#   worthiness-step.sh prune  --root <tree> --run-folder <dir>
#
# route prints a JSON array, one element per test the selection library emits:
# {file, fullName, signal, firstLine, authored, route, artifact}. Exit 3 on an
# extractor refusal, a package error or a missing classifier, with the reason on
# stderr: a silent empty list would read as nothing to do. A base that does not
# resolve prints [] and exits 0, as the merge hook allows.
#
# WORTHINESS_LEDGER_PATH is a test seam shared with the ledger writer; route and
# record read the same file through it.
#
# Bash 3.2 compatible.

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 3
script_root="$(cd "$script_directory/../.." 2>/dev/null && pwd)" || exit 3
library_directory="$script_root/.claude/hooks/lib"
writer_script="$script_directory/audit-ledger/append-worthiness.mjs"

scratch_directory=''
cleanup() { [ -z "$scratch_directory" ] || rm -rf "$scratch_directory"; }
trap cleanup EXIT

die_usage() { printf 'worthiness-step: %s\n' "$*" >&2; exit 2; }
die_input() { printf 'worthiness-step: %s\n' "$*" >&2; exit 3; }

absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

require_value() { [ "$2" -ge 2 ] || die_usage "$1 needs a value"; }

load_libraries() {
  local library
  for library in \
    "$library_directory/gaia-packages.sh" \
    "$library_directory/red-ledger.sh" \
    "$library_directory/worthiness-ledger.sh" \
    "$library_directory/worthiness-selection.sh" \
    "$library_directory/audit-base-provenance.sh" \
    "$script_directory/branch-authorship-lib.sh"; do
    [ -f "$library" ] || die_input "cannot load $library"
    # shellcheck source=/dev/null
    . "$library" || die_input "cannot load $library"
  done
  command -v jq >/dev/null 2>&1 || die_input 'jq is not on PATH'
  scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/worthiness-step-XXXXXX")" || die_input 'cannot create a scratch directory'
}

# The ledger is append-only and the latest line at the current signal is the
# stored verdict, so route reads it whole, skipping any line that is not an object.
read_jsonl() {
  if [ -f "$1" ]; then
    jq -R -c 'fromjson? | select(type == "object")' "$1" 2>/dev/null | jq -s -c . 2>/dev/null || printf '[]\n'
  else
    printf '[]\n'
  fi
}

resolve_ledger() {
  ledger_path="${WORTHINESS_LEDGER_PATH:-$(worthiness_ledger_path "$1")}"
  [ -n "$ledger_path" ] || die_input 'cannot resolve the worthiness ledger path'
}

# shellcheck disable=SC2016
ROUTE_JQ='
def verdict_for($file; $name; $signal):
  [$ledger[] | select((.schema // 0) == 1 and .file == $file and .fullName == $name and .signal == $signal)] | last;
def settled_as($file; $name; $signal; $kind):
  any($settlements[]; .file == $file and .fullName == $name and .signal == $signal and .settlement == $kind);
def authored_in($ranges; $path):
  any($ranges[]; . as $range | any(range($range[0]; $range[1] + 1);
    . as $line | ({path: $path, line: $line} | authorship($names; $hunks)) as $answer
    | $answer == "authored" or $answer == "unknown"));
split("\n") | map(select(length > 0) | index("\t") as $tab | {path: .[:$tab], test: (.[$tab + 1:] | fromjson)})
| map(. as $record | $record.test as $test
  | ($test.firstLine // 1) as $first
  | (if ($test.ranges // []) | length > 0 then $test.ranges else [[$first, $first]] end) as $ranges
  | (if $state == "on-default-branch" then false
     elif $state == "computed" then authored_in($ranges; $record.path)
     else true end) as $authored
  | verdict_for($record.path; $test.fullName; $test.signal) as $stored
  | (if (settled_as($record.path; $test.fullName; $test.signal; "residual")
         or settled_as($record.path; $test.fullName; $test.signal; "refused")
         or settled_as($record.path; $test.fullName; $test.signal; "filed")) then "settled"
     elif $stored == null then "evaluate"
     elif $stored.verdict == "keep" then "keep"
     elif $stored.verdict == "delete" then "delete"
     elif settled_as($record.path; $test.fullName; $test.signal; "fixed") then "residual"
     elif $authored then "fix"
     else "file" end) as $route
  | {file: $record.path, fullName: $test.fullName, signal: $test.signal, firstLine: $first,
     authored: $authored, route: $route, artifact: ($stored.artifact // null)})
'

cmd_route() {
  local root='' run_folder='' base prov records_file walk_status=0 authorship_json state ledger_path
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) require_value "$1" "$#"; root="$(absolute "$2")"; shift 2 ;;
      --run-folder) require_value "$1" "$#"; run_folder="$(absolute "$2")"; shift 2 ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$run_folder" ] || die_usage 'route needs --root and --run-folder'
  load_libraries
  # The walk and the extractor read the working directory for repo-relative paths.
  cd "$root" || die_input "cannot enter $root"

  local packages_status=0
  gaia_packages_load "$root" || packages_status=$?
  [ "$packages_status" -eq 0 ] || die_input "$GAIA_PACKAGES_ERROR"
  local classifier="$script_root/.gaia/scripts/classifier/classify-determinism.mjs"
  [ -f "$classifier" ] || die_input "the determinism classifier is missing at $classifier, so the emergent tests in scope are unknown"

  prov="$(audit_resolve_base_provenance "$root" default-branch)" || prov=''
  IFS=$'\t' read -r _ _ base <<<"$prov" || true
  if [ -z "$base" ]; then
    printf '[]\n'
    return 0
  fi

  # shellcheck disable=SC2034
  WORTHINESS_SELECTION_ERE="$(gaia_package_globs_ere emergentTests)"
  # shellcheck disable=SC2034
  WORTHINESS_SELECTION_CLASSIFIER="$classifier"
  records_file="$scratch_directory/records"
  worthiness_selection_walk "$root" "$base" >"$records_file" || walk_status=$?
  [ "$walk_status" -eq 0 ] || die_input "${WORTHINESS_SELECTION_ERROR:-the worthiness selection walk failed}"
  if [ ! -s "$records_file" ]; then
    printf '[]\n'
    return 0
  fi

  authorship_json="$(gaia_authorship_for_head "$root")"
  state="$(printf '%s' "$authorship_json" | jq -r '.state')"
  resolve_ledger "$root"
  jq -R -s -c \
    --argjson ledger "$(read_jsonl "$ledger_path")" \
    --argjson settlements "$(read_jsonl "$run_folder/worthiness-settlements.jsonl")" \
    --argjson names "$(printf '%s' "$authorship_json" | jq -c '.names')" \
    --argjson hunks "$(printf '%s' "$authorship_json" | jq -c '.hunks')" \
    --arg state "$state" \
    "$GAIA_AUTHORSHIP_JQ $ROUTE_JQ" "$records_file" || die_input 'cannot build the route list'
}

cmd_record() {
  local root='' verdicts='' expect='' ledger_path missing count index file name verdict artifact
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) require_value "$1" "$#"; root="$(absolute "$2")"; shift 2 ;;
      --verdicts) require_value "$1" "$#"; verdicts="$(absolute "$2")"; shift 2 ;;
      --expect) require_value "$1" "$#"; expect="$(absolute "$2")"; shift 2 ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$verdicts" ] || die_usage 'record needs --root and --verdicts'
  load_libraries
  jq -e 'type == "array" and all(.[]; type == "object" and (.file | type == "string") and (.fullName | type == "string")
    and (.verdict | IN("keep", "fix", "delete"))
    and (if .verdict == "keep" then true else ((.artifact // "") | type == "string" and length > 0) end))' "$verdicts" >/dev/null 2>&1 ||
    die_input "$verdicts is not a JSON array of {file, fullName, verdict, artifact?} with an artifact for every fix and delete"
  if [ -n "$expect" ]; then
    missing="$(jq -r --slurpfile verdicts "$verdicts" '.[] | select(.route == "evaluate")
      | select(. as $entry | any($verdicts[0][]; .file == $entry.file and .fullName == $entry.fullName) | not)
      | "\(.file) > \(.fullName)"' "$expect" 2>/dev/null)" || die_input "cannot read $expect as a route list"
    if [ -n "$missing" ]; then
      printf 'worthiness-step: no verdict for these tests, nothing was recorded:\n%s\n' "$missing" >&2
      exit 1
    fi
  fi
  resolve_ledger "$root"
  export WORTHINESS_LEDGER_PATH="$ledger_path"
  cd "$root" || die_input "cannot enter $root"
  count="$(jq 'length' "$verdicts")"
  index=0
  while [ "$index" -lt "$count" ]; do
    file="$(jq -r ".[$index].file" "$verdicts")"
    name="$(jq -r ".[$index].fullName" "$verdicts")"
    verdict="$(jq -r ".[$index].verdict" "$verdicts")"
    artifact="$(jq -r ".[$index].artifact // empty" "$verdicts")"
    if [ -n "$artifact" ]; then
      node "$writer_script" "$file" "$name" "$verdict" "$artifact" || die_input "the ledger writer refused $file > $name"
    else
      node "$writer_script" "$file" "$name" "$verdict" || die_input "the ledger writer refused $file > $name"
    fi
    index=$((index + 1))
  done
}

cmd_settle() {
  local run_folder='' file='' name='' signal='' kind='' first_line='' reason='' now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-folder) require_value "$1" "$#"; run_folder="$(absolute "$2")"; shift 2 ;;
      --file) require_value "$1" "$#"; file="$2"; shift 2 ;;
      --full-name) require_value "$1" "$#"; name="$2"; shift 2 ;;
      --signal) require_value "$1" "$#"; signal="$2"; shift 2 ;;
      --as) require_value "$1" "$#"; kind="$2"; shift 2 ;;
      --first-line) require_value "$1" "$#"; first_line="$2"; shift 2 ;;
      --reason) require_value "$1" "$#"; reason="$2"; shift 2 ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$run_folder" ] && [ -n "$file" ] && [ -n "$name" ] && [ -n "$signal" ] || die_usage 'settle needs --run-folder, --file, --full-name and --signal'
  case "$kind" in residual | refused | filed | fixed) ;; *) die_usage '--as must be residual, refused, filed or fixed' ;; esac
  if [ "$kind" = residual ]; then
    case "$first_line" in '' | *[!0-9]* | 0) die_usage '--as residual needs --first-line, an integer of at least 1' ;; esac
    [ -n "$reason" ] || die_usage '--as residual needs --reason'
  fi
  command -v jq >/dev/null 2>&1 || die_input 'jq is not on PATH'
  mkdir -p "$run_folder" || die_input "cannot create $run_folder"
  local settlements="$run_folder/worthiness-settlements.jsonl" residuals="$run_folder/recorded-residuals.jsonl"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! { [ -f "$settlements" ] && jq -e -s --arg f "$file" --arg n "$name" --arg s "$signal" --arg k "$kind" \
    'any(.[]; .file == $f and .fullName == $n and .signal == $s and .settlement == $k)' "$settlements" >/dev/null 2>&1; }; then
    jq -nc --arg f "$file" --arg n "$name" --arg s "$signal" --arg k "$kind" --arg t "$now" \
      '{file: $f, fullName: $n, signal: $s, settlement: $k, decidedAt: $t}' >>"$settlements" || die_input "cannot append to $settlements"
  fi
  [ "$kind" = residual ] || return 0
  # One row per key: finding_class, path and line, as the renderer dedups.
  if [ -f "$residuals" ] && jq -e -s --arg p "$file" --argjson l "$first_line" \
    'any(.[]; .finding_class == "holistic/unclassified" and .path == $p and .line == $l)' "$residuals" >/dev/null 2>&1; then
    return 0
  fi
  jq -nc --arg f "$file" --arg n "$name" --arg s "$signal" --arg r "$reason" --argjson l "$first_line" \
    '{source: "worthiness", member: "worthiness-evaluator", finding_class: "holistic/unclassified",
      path: $f, line: $l, reason: $r, file: $f, fullName: $n, signal: $s}' >>"$residuals" || die_input "cannot append to $residuals"
}

cmd_finding() {
  local entry='' audience=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --entry) require_value "$1" "$#"; entry="$(absolute "$2")"; shift 2 ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$entry" ] || die_usage 'finding needs --entry'
  command -v jq >/dev/null 2>&1 || die_input 'jq is not on PATH'
  jq -e 'type == "object" and (.file | type == "string") and (.fullName | type == "string")' "$entry" >/dev/null 2>&1 ||
    die_input "cannot read $entry as a route element"
  # gaia:maintainer-only:start
  case "$(jq -r '.file' "$entry")" in
    .gaia/tests/* | .gaia/scripts/tests/* | .github/* | .claude/maintainers/* | studio/*) audience=maintainer ;;
    *) audience=adopter ;;
  esac
  # gaia:maintainer-only:end
  jq -c --arg audience "$audience" '{
      member: "worthiness-evaluator", finding_class: "holistic/unclassified", security: false,
      issue_severity: "Minor", path: .file, line: .firstLine,
      title: ("Test needs a fix: " + .fullName),
      failure_mode: (.artifact // ""), suggested_fix: (.artifact // "")}
    + (if $audience == "" then {} else {audience: $audience} end)' "$entry"
}

cmd_prune() {
  local root='' run_folder='' residuals kept_file current_file file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) require_value "$1" "$#"; root="$(absolute "$2")"; shift 2 ;;
      --run-folder) require_value "$1" "$#"; run_folder="$(absolute "$2")"; shift 2 ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$run_folder" ] || die_usage 'prune needs --root and --run-folder'
  residuals="$run_folder/recorded-residuals.jsonl"
  [ -f "$residuals" ] || return 0
  load_libraries
  cd "$root" || die_input "cannot enter $root"
  current_file="$scratch_directory/current"
  : >"$current_file"
  while IFS= read -r file; do
    [ -n "$file" ] && [ -f "$root/$file" ] || continue
    red_ledger_signals "$file" 2>/dev/null | jq -c --arg f "$file" 'select(.signal != null) | {file: $f, fullName, signal}' >>"$current_file" 2>/dev/null || true
  done <<EOF
$(jq -r 'select(.source == "worthiness") | .file // empty' "$residuals" 2>/dev/null | sort -u)
EOF
  kept_file="$scratch_directory/kept"
  jq -c --slurpfile current "$current_file" '
    . as $row | select($row.source != "worthiness"
      or any($current[]; .file == $row.file and .fullName == $row.fullName and .signal == $row.signal))' "$residuals" >"$kept_file" || die_input 'cannot prune the recorded residuals'
  cat "$kept_file" >"$residuals" || die_input "cannot rewrite $residuals"
}

[ "$#" -ge 1 ] || die_usage 'usage: worthiness-step.sh route|record|settle|finding|prune ...'
subcommand="$1"
shift
case "$subcommand" in
  route) cmd_route "$@" ;;
  record) cmd_record "$@" ;;
  settle) cmd_settle "$@" ;;
  finding) cmd_finding "$@" ;;
  prune) cmd_prune "$@" ;;
  *) die_usage "unknown subcommand $subcommand" ;;
esac
