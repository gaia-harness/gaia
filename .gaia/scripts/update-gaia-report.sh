#!/usr/bin/env bash
#
# Deterministic helper for the /update-gaia merge report. The dispatched
# execution agent writes a JSON report and one candidate file per non-trivial
# option into a run directory; the orchestrator uses this script to count what
# a real report must hold, validate the report before any candidate reaches the
# adopter's tree, split the both-changed files into chunks, fold chunk
# judgments back in, copy clean merges, and decide whether an upstream-removed
# file is still referenced.
#
# Usage: bash .gaia/scripts/update-gaia-report.sh <subcommand> [flags]
#
#   prepare        --run-dir <abs>
#   expect-count   --baseline-dir <dir> --latest-dir <dir> [--decisions <file>]
#   expected-paths same flags as expect-count
#   both-changed   --tree <dir> --baseline-dir <dir> --latest-dir <dir>
#                  [--decisions <file>] [--extra <tag>=<dir>]...
#   chunk          the both-changed flags plus --run-dir <abs> --size <n>
#   validate       --report <file> --run-dir <abs> --baseline-dir <dir>
#                  --latest-dir <dir> [--decisions <file>] [--final]
#   merge-judgments --report <file> --judgment <file>...
#   apply-auto     --report <file> --run-dir <abs> --tree <dir>
#   references     --tree <dir> --path <p>
#
# The expected set of report paths is keys(baseline manifest .files) union
# keys(latest manifest .files) union the path of every `deferred` entry in the
# decision log (read with jq; an absent log means none). A manifest lives at
# <dir>/.gaia/manifest.json.
#
# The report's paths drive file writes, so `validate` is the gate: the path set
# must equal the expected set, and every candidate must resolve inside the run
# directory and hold no conflict marker line. `apply-auto` re-checks
# containment before it copies anything.
#
# Exit: 0 success; 1 a failed check (violations on stdout, or a message on
# stderr); 2 usage error. Bash 3.2 and BSD tools safe; needs jq.

set -u

NL='
'
TAB="$(printf '\t')"
RUN_DIR_SUFFIX='/.gaia/local/cache/shared/update-gaia/run'

die() {
  local code="$1"
  shift
  printf 'update-gaia-report: %s\n' "$*" >&2
  exit "$code"
}

command -v jq >/dev/null 2>&1 || die 1 'jq is required'

# ---------- argument parsing ----------

TREE=''
BASELINE_DIR=''
LATEST_DIR=''
DECISIONS=''
EXTRAS=''
RUN_DIR=''
SIZE=''
REPORT=''
JUDGMENTS=''
PATH_ARG=''
FINAL=0

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --final) FINAL=1; shift ;;
      --judgment)
        shift
        while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
          JUDGMENTS="$JUDGMENTS$1$NL"
          shift
        done
        ;;
      --tree | --baseline-dir | --latest-dir | --decisions | --extra | --run-dir | --size | --report | --path)
        [ $# -ge 2 ] || die 2 "$1 needs a value"
        case "$1" in
          --tree) TREE="$2" ;;
          --baseline-dir) BASELINE_DIR="$2" ;;
          --latest-dir) LATEST_DIR="$2" ;;
          --decisions) DECISIONS="$2" ;;
          --extra) EXTRAS="$EXTRAS$2$NL" ;;
          --run-dir) RUN_DIR="$2" ;;
          --size) SIZE="$2" ;;
          --report) REPORT="$2" ;;
          --path) PATH_ARG="$2" ;;
        esac
        shift 2
        ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
}

require_set() {
  local name
  for name in "$@"; do
    eval "[ -n \"\${$name}\" ]" || die 2 "missing required flag for $name"
  done
}

# ---------- expected set ----------

manifest_keys() {
  local manifest="$1/.gaia/manifest.json"
  [ -f "$manifest" ] || { printf 'update-gaia-report: manifest not found: %s\n' "$manifest" >&2; return 1; }
  jq -r '.files | keys[]' "$manifest" 2>/dev/null \
    || { printf 'update-gaia-report: manifest does not parse: %s\n' "$manifest" >&2; return 1; }
}

# path<TAB>baselineTag per deferred entry.
deferred_pairs() {
  [ -n "$DECISIONS" ] && [ -f "$DECISIONS" ] || return 0
  jq -r '(.decisions // [])[] | select(.decision == "deferred") | [.path, (.baselineTag // "")] | @tsv' "$DECISIONS" 2>/dev/null \
    || { printf 'update-gaia-report: decision log does not parse: %s\n' "$DECISIONS" >&2; return 1; }
}

expected_set() {
  local from_baseline from_latest from_deferred
  from_baseline="$(manifest_keys "$BASELINE_DIR")" || return 1
  from_latest="$(manifest_keys "$LATEST_DIR")" || return 1
  from_deferred="$(deferred_pairs)" || return 1
  from_deferred="$(printf '%s\n' "$from_deferred" | awk -F'\t' 'NF { print $1 }')"
  printf '%s\n%s\n%s\n' "$from_baseline" "$from_latest" "$from_deferred" \
    | grep -v '^$' | LC_ALL=C sort -u
}

cmd_expected_paths() {
  require_set BASELINE_DIR LATEST_DIR
  local set
  set="$(expected_set)" || exit 1
  [ -n "$set" ] && printf '%s\n' "$set"
  exit 0
}

cmd_expect_count() {
  require_set BASELINE_DIR LATEST_DIR
  local set
  set="$(expected_set)" || exit 1
  printf '%s\n' "$set" | awk 'NF { n++ } END { print n + 0 }'
}

# ---------- both-changed and chunk ----------

registered_package_dirs() {
  local registry="$TREE/.gaia/packages.json" dirs=''
  if [ -f "$registry" ]; then
    dirs="$(jq -r '.[].path' "$registry" 2>/dev/null)" || dirs='frontend'
  else
    dirs='frontend'
  fi
  printf '%s\n' "$dirs" \
    | grep -E '^(\.|[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*)$' | grep -v '\.\.' | grep -v '^\.$'
}

design_system_established() {
  local page="$TREE/wiki/concepts/Design System.md"
  [ -f "$page" ] || return 1
  awk '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    /^established:[[:space:]]*true[[:space:]]*$/ { found = 1 }
    END { exit !found }
  ' "$page"
}

both_changed() {
  local set excluded='' pairs deferred_paths='' pair_path pair_tag extra tag dir
  local path base_root a b l
  set="$(expected_set)" || return 1
  pairs="$(deferred_pairs)" || return 1
  excluded="package.json$NL"
  while IFS= read -r dir; do
    [ -n "$dir" ] && excluded="$excluded$dir/package.json$NL"
  done <<EOF
$(registered_package_dirs)
EOF
  excluded="${excluded}pnpm-workspace.yaml$NL.gaia/audit-ci.yml$NL"
  if design_system_established; then
    excluded="${excluded}wiki/concepts/Design System.md${NL}frontend/.claude/rules/design-baseline.md$NL"
  fi
  while IFS="$TAB" read -r pair_path pair_tag; do
    [ -n "$pair_path" ] && deferred_paths="$deferred_paths$pair_path$NL"
  done <<EOF
$pairs
EOF

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$NL$excluded" in *"$NL$path$NL"*) continue ;; esac
    base_root="$BASELINE_DIR"
    case "$NL$deferred_paths" in
      *"$NL$path$NL"*)
        tag=''
        while IFS="$TAB" read -r pair_path pair_tag; do
          if [ "$pair_path" = "$path" ]; then tag="$pair_tag"; break; fi
        done <<EOF
$pairs
EOF
        while IFS= read -r extra; do
          if [ -n "$extra" ] && [ "${extra%%=*}" = "$tag" ]; then base_root="${extra#*=}"; break; fi
        done <<EOF
$EXTRAS
EOF
        ;;
    esac
    a="$TREE/$path"
    b="$base_root/$path"
    l="$LATEST_DIR/$path"
    [ -f "$a" ] && [ -f "$b" ] && [ -f "$l" ] || continue
    cmp -s "$a" "$b" && continue
    cmp -s "$b" "$l" && continue
    printf '%s\n' "$path"
  done <<EOF
$set
EOF
}

cmd_both_changed() {
  require_set TREE BASELINE_DIR LATEST_DIR
  both_changed || exit 1
}

cmd_chunk() {
  require_set TREE BASELINE_DIR LATEST_DIR RUN_DIR SIZE
  case "$SIZE" in '' | *[!0-9]*) die 2 '--size must be a positive integer' ;; esac
  [ "$SIZE" -ge 1 ] || die 2 '--size must be a positive integer'
  local list total=0 k=0 in_chunk=0 path
  list="$(both_changed)" || exit 1
  mkdir -p "$RUN_DIR" || die 1 "cannot create $RUN_DIR"
  rm -f "$RUN_DIR"/chunk-*.txt
  : >"$RUN_DIR/both-changed.txt" || die 1 "cannot write $RUN_DIR/both-changed.txt"
  if [ -n "$list" ]; then
    printf '%s\n' "$list" >"$RUN_DIR/both-changed.txt"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if [ "$in_chunk" -eq 0 ]; then k=$((k + 1)); fi
      printf '%s\n' "$path" >>"$RUN_DIR/chunk-$k.txt" || die 1 "cannot write chunk $k"
      in_chunk=$((in_chunk + 1))
      total=$((total + 1))
      if [ "$in_chunk" -ge "$SIZE" ]; then in_chunk=0; fi
    done <<EOF
$list
EOF
  fi
  printf 'CHUNKS %s %s\n' "$k" "$total"
}

# ---------- candidate containment ----------

# Physical path of an existing or dangling file: follow symlinks to the end,
# then resolve the directory with `cd -P` in a subshell.
physical_path() {
  local p="$1" hops=0 target dir
  while [ -L "$p" ] && [ "$hops" -lt 40 ]; do
    target="$(readlink "$p")"
    case "$target" in
      /*) p="$target" ;;
      *) p="$(dirname "$p")/$target" ;;
    esac
    hops=$((hops + 1))
  done
  [ -L "$p" ] && return 1
  dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$p")"
}

# Prints the reason a run-dir-relative candidate is unusable, or nothing.
# $1 physical run dir, $2 candidate.
candidate_problem() {
  local run_real="$1" candidate="$2" resolved
  case "$candidate" in
    /*) printf 'is an absolute path'; return 0 ;;
  esac
  case "/$candidate/" in
    */../*) printf 'has a .. segment'; return 0 ;;
  esac
  resolved="$(physical_path "$run_real/$candidate")" || { printf 'cannot be resolved'; return 0; }
  case "$resolved" in
    "$run_real"/*) ;;
    *) printf 'resolves outside the run directory'; return 0 ;;
  esac
  [ -f "$resolved" ] || { printf 'does not exist'; return 0; }
  return 0
}

check_conflict_markers() {
  grep -aEq '^(<<<<<<<|>>>>>>>)' "$1"
}

# Prints problems for one candidate, one line each. $1 run real, $2 owner
# path, $3 field label, $4 candidate.
candidate_violations() {
  local run_real="$1" owner="$2" label="$3" candidate="$4" problem resolved
  problem="$(candidate_problem "$run_real" "$candidate")"
  if [ -n "$problem" ]; then
    printf '%s: %s %s %s\n' "$owner" "$label" "$candidate" "$problem"
    return 0
  fi
  resolved="$(physical_path "$run_real/$candidate")"
  if check_conflict_markers "$resolved"; then
    printf '%s: %s %s holds a conflict marker\n' "$owner" "$label" "$candidate"
  fi
  return 0
}

# ---------- validate ----------

# Structural checks in jq; one violation string per output line.
# shellcheck disable=SC2016  # jq program text: $final, $e and friends are jq variables.
STRUCTURE_PROGRAM='
  def statuses: ["skip","overwrite","merge","add","removed","auto-merged","deleted","field-aware","open","pending-judgment"];
  (if .schemaVersion != 1 then "schemaVersion must be 1" else empty end),
  (if (.files | type) != "array" then "files is not an array"
   else
     ([.files[] | select(type == "object" and (.path | type) == "string") | .path]) as $paths
     | (.files[] | select((type != "object") or ((.path | type) != "string")) | "a files entry has no string path"),
       ($paths | group_by(.) | .[] | select(length > 1) | "duplicate path " + .[0]),
       (.files[] | select(type == "object" and (.path | type) == "string")
        | . as $e | $e.path as $p
        | (if (statuses | index($e.status)) == null then $p + ": unknown status " + ($e.status | tostring) else empty end),
          (if $e.status == "open" and (($e.items // []) | length) == 0 then $p + ": open entry has no items" else empty end),
          (if $final and $e.status == "pending-judgment" then $p + ": pending-judgment is not allowed in a final report" else empty end),
          (if $e.autoCandidate != null and $e.status != "auto-merged" then $p + ": autoCandidate on a status other than auto-merged" else empty end),
          (if $e.autoCandidate != null and ($e.autoCandidate | type) != "string" then $p + ": autoCandidate is not a string" else empty end),
          (($e.items // [])[] | . as $i | ($i.id // $p) as $id | ($i.options // []) as $o
           | (if ($o | length) == 0 then $p + ": item " + $id + " has no options"
              else
                (if $i.recommended != $o[0].id then $p + ": item " + $id + " recommended " + ($i.recommended | tostring) + " is not options[0] " + ($o[0].id | tostring) else empty end),
                (if $o[-1].id != "defer" then $p + ": item " + $id + " last option is not defer" else empty end),
                ($o[] | select(.candidate != null and (.candidate | type) != "string") | $p + ": item " + $id + " option " + (.id | tostring) + " candidate is not a string"),
                (if $i.key == null then ($o[] | select((.id == "combine" or .id == "gaia" or .id == "higher") and (.candidate == null)) | $p + ": item " + $id + " option " + .id + " needs a candidate") else empty end)
              end)))
   end)
'

# Every candidate reference: owner<TAB>label<TAB>candidate.
# shellcheck disable=SC2016  # jq program text.
CANDIDATE_PROGRAM='
  (.files // [])[] | select(type == "object" and (.path | type) == "string")
  | . as $e
  | (if ($e.autoCandidate | type) == "string" then [$e.path, "autoCandidate", $e.autoCandidate] else empty end),
    (($e.items // [])[] | (.options // [])[] | select((.candidate | type) == "string") | [$e.path, "candidate", .candidate])
  | @tsv
'

cmd_validate() {
  require_set REPORT RUN_DIR BASELINE_DIR LATEST_DIR
  local violations='' expected run_real structure actual_file expected_file
  local owner label candidate rows

  [ -f "$REPORT" ] || die 1 "report not found: $REPORT"
  if ! jq -e . "$REPORT" >/dev/null 2>&1; then
    printf 'REPORT_INVALID report is not valid JSON\n'
    exit 1
  fi
  expected="$(expected_set)" || die 1 'cannot derive the expected path set'
  run_real="$(cd -P "$RUN_DIR" 2>/dev/null && pwd -P)" || {
    printf 'REPORT_INVALID run directory not found: %s\n' "$RUN_DIR"
    exit 1
  }

  SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/update-gaia-report.XXXXXX")" || die 1 'cannot create a scratch directory'
  trap 'rm -rf "$SCRATCH_DIR"' EXIT
  actual_file="$SCRATCH_DIR/actual"
  expected_file="$SCRATCH_DIR/expected"
  printf '%s\n' "$expected" | LC_ALL=C sort -u >"$expected_file"

  if ! structure="$(jq -r --argjson final "$([ "$FINAL" -eq 1 ] && echo true || echo false)" "$STRUCTURE_PROGRAM" "$REPORT" 2>/dev/null)"; then
    printf 'REPORT_INVALID report shape is not readable\n'
    exit 1
  fi
  [ -n "$structure" ] && violations="$structure$NL"

  jq -r '[(.files // [])[] | select(type == "object" and (.path | type) == "string") | .path] | unique | .[]' "$REPORT" 2>/dev/null \
    | LC_ALL=C sort -u >"$actual_file"
  violations="$violations$(check_path_set "$expected_file" "$actual_file")$NL"

  if ! rows="$(jq -r "$CANDIDATE_PROGRAM" "$REPORT" 2>/dev/null)"; then
    printf 'REPORT_INVALID report shape is not readable\n'
    exit 1
  fi
  while IFS="$TAB" read -r owner label candidate; do
    [ -n "$candidate" ] || continue
    violations="$violations$(candidate_violations "$run_real" "$owner" "$label" "$candidate")$NL"
  done <<EOF
$rows
EOF

  local count n=0 line
  count="$(jq -r '(.files // []) | length' "$REPORT" 2>/dev/null)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'REPORT_INVALID %s\n' "$line"
    n=$((n + 1))
  done <<EOF
$violations
EOF
  if [ "$n" -gt 0 ]; then exit 1; fi
  printf 'REPORT_OK %s\n' "$count"
}

check_path_set() {
  local expected_file="$1" actual_file="$2" path
  while IFS= read -r path; do
    [ -n "$path" ] && printf 'missing path %s\n' "$path"
  done <<EOF
$(LC_ALL=C comm -23 "$expected_file" "$actual_file")
EOF
  while IFS= read -r path; do
    [ -n "$path" ] && printf 'unexpected path %s\n' "$path"
  done <<EOF
$(LC_ALL=C comm -13 "$expected_file" "$actual_file")
EOF
}

# ---------- merge-judgments ----------

cmd_merge_judgments() {
  require_set REPORT JUDGMENTS
  [ -f "$REPORT" ] || die 1 "report not found: $REPORT"
  local judged file merged scratch
  judged='[]'
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || die 1 "judgment not found: $file"
    jq -e 'type == "array" and all(.[]; type == "object" and (.path | type) == "string")' "$file" >/dev/null 2>&1 \
      || die 1 "judgment is not an array of file entries: $file"
    judged="$(jq -c -n --argjson acc "$judged" --slurpfile next "$file" '$acc + $next[0]')" || die 1 "cannot read judgment: $file"
  done <<EOF
$JUDGMENTS
EOF
  scratch="$(mktemp "$(dirname "$REPORT")/.merge-judgments.XXXXXX")" || die 1 'cannot create a temporary file beside the report'
  if ! jq --argjson judged "$judged" '
        (reduce $judged[] as $e ({}; .[$e.path] = $e)) as $by_path
        | ([.files[].path]) as $report_paths
        | if ([$by_path | keys[] | select(. as $p | $report_paths | index($p) | not)] | length) > 0
          then error("judged path absent from the report")
          else .files |= map($by_path[.path] // .) end
      ' "$REPORT" >"$scratch" 2>/dev/null; then
    rm -f "$scratch"
    die 1 'a judged path is absent from the report; report unchanged'
  fi
  merged="$(printf '%s' "$judged" | jq -r '[.[].path] | unique | length')"
  mv "$scratch" "$REPORT" || { rm -f "$scratch"; die 1 'cannot replace the report'; }
  printf 'MERGED %s\n' "$merged"
}

# ---------- apply-auto ----------

cmd_apply_auto() {
  require_set REPORT RUN_DIR TREE
  [ -f "$REPORT" ] || die 1 "report not found: $REPORT"
  local run_real rows owner candidate resolved problem count=0 failed=0 plan=''
  run_real="$(cd -P "$RUN_DIR" 2>/dev/null && pwd -P)" || die 1 "run directory not found: $RUN_DIR"
  rows="$(jq -r '(.files // [])[] | select(type == "object" and (.path | type) == "string" and (.autoCandidate | type) == "string") | [.path, .status, .autoCandidate] | @tsv' "$REPORT" 2>/dev/null)" \
    || die 1 'report shape is not readable'
  local status
  while IFS="$TAB" read -r owner status candidate; do
    [ -n "$owner" ] || continue
    if [ "$status" != "auto-merged" ]; then
      printf 'REPORT_INVALID %s: autoCandidate on a status other than auto-merged\n' "$owner"
      failed=1
      continue
    fi
    case "$owner" in
      /* | ../* | */../* | */.. | ..)
        printf 'REPORT_INVALID %s: path escapes the tree\n' "$owner"
        failed=1
        continue
        ;;
    esac
    problem="$(candidate_problem "$run_real" "$candidate")"
    if [ -n "$problem" ]; then
      printf 'REPORT_INVALID %s: autoCandidate %s %s\n' "$owner" "$candidate" "$problem"
      failed=1
      continue
    fi
    resolved="$(physical_path "$run_real/$candidate")"
    if check_conflict_markers "$resolved"; then
      printf 'REPORT_INVALID %s: autoCandidate %s holds a conflict marker\n' "$owner" "$candidate"
      failed=1
      continue
    fi
    plan="$plan$owner$TAB$resolved$NL"
  done <<EOF
$rows
EOF
  [ "$failed" -eq 0 ] || exit 1
  local source
  while IFS="$TAB" read -r owner source; do
    [ -n "$owner" ] || continue
    mkdir -p "$(dirname "$TREE/$owner")" || die 1 "cannot create the directory for $owner"
    cp "$source" "$TREE/$owner" || die 1 "cannot copy onto $owner"
    count=$((count + 1))
  done <<EOF
$plan
EOF
  printf 'APPLIED_AUTO %s\n' "$count"
}

# ---------- references ----------

cmd_references() {
  require_set TREE PATH_ARG
  local base hits rc hit
  base="$(basename -- "$PATH_ARG")"
  hits="$(git -C "$TREE" grep -lF -e "$PATH_ARG" -e "$base" -- . 2>/dev/null)"
  rc=$?
  [ "$rc" -le 1 ] || die 1 "git grep failed in $TREE"
  hit="$(printf '%s\n' "$hits" | grep -vxF -e "$PATH_ARG" | grep -v '^$' | head -n 1)"
  if [ -n "$hit" ]; then
    printf 'REFERENCED %s\n' "$hit"
  else
    printf 'UNREFERENCED\n'
  fi
}

# ---------- prepare ----------

cmd_prepare() {
  require_set RUN_DIR
  case "$RUN_DIR" in
    /*) ;;
    *) die 2 "--run-dir must be an absolute path: $RUN_DIR" ;;
  esac
  case "/$RUN_DIR/" in
    */../*) die 2 "--run-dir must not contain a .. segment: $RUN_DIR" ;;
  esac
  case "$RUN_DIR" in
    *"$RUN_DIR_SUFFIX") ;;
    *) die 2 "--run-dir must end in $RUN_DIR_SUFFIX: $RUN_DIR" ;;
  esac
  rm -rf -- "$RUN_DIR" || die 1 "cannot empty $RUN_DIR"
  mkdir -p "$RUN_DIR/candidates" "$RUN_DIR/instructions" || die 1 "cannot create $RUN_DIR"
  printf 'PREPARED %s\n' "$RUN_DIR"
}

# ---------- dispatch ----------

[ $# -ge 1 ] || die 2 'usage: update-gaia-report.sh <prepare|expect-count|expected-paths|both-changed|chunk|validate|merge-judgments|apply-auto|references> [flags]'
SUBCOMMAND="$1"
shift
parse_args "$@"

case "$SUBCOMMAND" in
  prepare) cmd_prepare ;;
  expect-count) cmd_expect_count ;;
  expected-paths) cmd_expected_paths ;;
  both-changed) cmd_both_changed ;;
  chunk) cmd_chunk ;;
  validate) cmd_validate ;;
  merge-judgments) cmd_merge_judgments ;;
  apply-auto) cmd_apply_auto ;;
  references) cmd_references ;;
  *) die 2 "unknown subcommand: $SUBCOMMAND" ;;
esac
