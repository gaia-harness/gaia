#!/usr/bin/env bash
#
# audit-frontend-oracles.sh --root <root> --base <base-sha> --out <dir>
#
# Runs the frontend Code Audit Team member's three deterministic oracles
# concurrently, gated by what the branch changed, and prints one Markdown
# table. The member issues this script as ONE Bash call: every turn a member
# takes replays its whole prefix, so three separate calls plus the prose spent
# parsing their raw output cost more than one call that returns a table.
#
# Oracles (each runs with <root> as its working directory, in its own subshell;
# this script never changes the parent shell's directory):
#   react-doctor  npx -y react-doctor@latest . --verbose --scope changed
#   knip          pnpm knip --reporter json
#   advisories    .gaia/cli/gaia update-deps advisories --emit <out>/advisories.json
#
# Scope: `git diff --name-only -z --no-renames <base>...HEAD` in <root>.
#   react-doctor runs only when a path ends .ts or .tsx.
#   knip runs when a path ends .ts or .tsx, or its basename is package.json,
#   pnpm-workspace.yaml or pnpm-lock.yaml: a manifest or lockfile change moves
#   knip's dependency buckets (unused, unlisted, unresolved) with no source
#   file changing.
#   advisories always run: the member attests to the dependency-advisory
#   dimension on every dispatch, whatever changed.
# An empty --base (pass it as `--base ''`, quoted) or a failed diff means the
# scope is unknown: every oracle runs (fail toward running) and each gated
# row's Result says `scope unresolved; ran anyway`.
#
# Outputs under <out> (created if missing): react-doctor.txt, knip.json
# (stdout) with knip.err (stderr), advisories.log, and the advisory payload
# advisories.json.
#
# stdout is the table and nothing else:
#   | Oracle | Status | Result | Output |
#   |---|---|---|---|
#   one row each: react-doctor, knip, advisories
# then, only when advisories surfaced rows, a blank line and
#   | Package | Severity | Advisory | Fix |
#   |---|---|---|---|
# Status: `ran (exit <n>)`, a `skipped: ...` reason, or `failed (exit <n>)`.
# knip exits non-zero when it reports issues, so a non-zero exit with a
# parseable knip.json is `ran`. Exit 0 whenever the table printed (an oracle
# failure is a row, not an exit); exit 2 on a usage error.
#
# react-doctor Result parsing rule (pinned from a recorded member transcript;
# the sample prints no tool version: version not printed): sum the number on
# every whole line shaped `<n> issues` (or `<n> issue`) that the summary
# prints per scanned project; a sum above zero is `<n> diagnostics`. No such
# line (the `No issues found!` line, `No changed source files ... skipping`,
# or empty output) is `No issues`. Output that is neither is `see output`.
#
# Bash 3.2 compatible (no mapfile, no associative arrays, no process
# substitution).

set -u

usage() {
  echo "usage: audit-frontend-oracles.sh --root <root> --base <base-sha> --out <dir>" >&2
  exit 2
}

root=""
out=""
base=""

# A value flag takes the next argument whatever it holds, so `--base ''` never
# lets an empty base swallow the flag after it.
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || usage
      root=$2
      shift 2
      ;;
    --base)
      [ $# -ge 2 ] || usage
      base=$2
      shift 2
      ;;
    --out)
      [ $# -ge 2 ] || usage
      out=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$root" ] || usage
[ -n "$out" ] || usage
[ -d "$root" ] || usage

mkdir -p "$out" || usage
out=$(cd "$out" && pwd) || usage
root=$(cd "$root" && pwd) || usage

scope_file=$(mktemp "${TMPDIR:-/tmp}/audit-oracle-scope.XXXXXX") || exit 2
trap 'rm -f "$scope_file"' EXIT

scope_unresolved=0
if [ -z "$base" ]; then
  scope_unresolved=1
else
  if ! git -C "$root" diff --name-only -z --no-renames "$base...HEAD" >"$scope_file" 2>/dev/null; then
    scope_unresolved=1
  fi
fi

run_react_doctor=0
run_knip=0
if [ "$scope_unresolved" -eq 1 ]; then
  run_react_doctor=1
  run_knip=1
else
  while IFS= read -r -d '' scoped_path; do
    scoped_name=${scoped_path##*/}
    case "$scoped_path" in
      *.ts | *.tsx)
        run_react_doctor=1
        run_knip=1
        ;;
    esac
    case "$scoped_name" in
      package.json | pnpm-workspace.yaml | pnpm-lock.yaml)
        run_knip=1
        ;;
    esac
  done <"$scope_file"
fi

react_doctor_pid=""
knip_pid=""

if [ "$run_react_doctor" -eq 1 ]; then
  (
    cd "$root" || exit 1
    exec npx -y react-doctor@latest . --verbose --scope changed
  ) >"$out/react-doctor.txt" 2>&1 &
  react_doctor_pid=$!
fi

if [ "$run_knip" -eq 1 ]; then
  (
    cd "$root" || exit 1
    exec pnpm knip --reporter json
  ) >"$out/knip.json" 2>"$out/knip.err" &
  knip_pid=$!
fi

rm -f "$out/advisories.json"
(
  cd "$root" || exit 1
  exec .gaia/cli/gaia update-deps advisories --emit "$out/advisories.json"
) >"$out/advisories.log" 2>&1 &
advisories_pid=$!

react_doctor_rc=0
knip_rc=0
if [ -n "$react_doctor_pid" ]; then
  wait "$react_doctor_pid"
  react_doctor_rc=$?
fi
if [ -n "$knip_pid" ]; then
  wait "$knip_pid"
  knip_rc=$?
fi
wait "$advisories_pid"
advisories_rc=$?

# The Result a cell carries, with the unresolved-scope note appended for the
# gated oracles.
note_scope() {
  if [ "$scope_unresolved" -eq 1 ]; then
    printf '%s (scope unresolved; ran anyway)' "$1"
  else
    printf '%s' "$1"
  fi
}

# ---- react-doctor ----
if [ -z "$react_doctor_pid" ]; then
  react_doctor_status="skipped: no .ts or .tsx path in scope"
  react_doctor_result="-"
else
  if [ "$react_doctor_rc" -eq 0 ]; then
    react_doctor_status="ran (exit $react_doctor_rc)"
  else
    react_doctor_status="failed (exit $react_doctor_rc)"
  fi
  if [ "$react_doctor_rc" -ne 0 ]; then
    react_doctor_result="see output"
  elif react_doctor_count=$(awk '/^[0-9]+ issues?$/ { total += $1 } END { print total + 0 }' "$out/react-doctor.txt") && [ "$react_doctor_count" -gt 0 ]; then
    react_doctor_result="$react_doctor_count diagnostics"
  elif [ ! -s "$out/react-doctor.txt" ] || grep -Eq 'No issues found|No changed source files' "$out/react-doctor.txt"; then
    react_doctor_result="No issues"
  else
    react_doctor_result="see output"
  fi
  react_doctor_result=$(note_scope "$react_doctor_result")
fi

# ---- knip ----
if [ -z "$knip_pid" ]; then
  knip_status="skipped: no .ts, .tsx, manifest or lockfile path in scope"
  knip_result="-"
else
  if knip_result=$(jq -er '
    if (.issues | type) != "array" then error("no issues array") else . end
    | [ .issues[]
        | to_entries[]
        | select(.key != "file" and .key != "owners"
                 and (.value | type == "array") and (.value | length > 0))
        | {k: .key, n: (.value | length)} ]
    | group_by(.k)
    | map({k: .[0].k, n: (map(.n) | add)})
    | sort_by([-.n, .k])
    | if length == 0 then "No issues"
      else "\(map(.n) | add) issues: " + (map("\(.k)=\(.n)") | join(", "))
      end' "$out/knip.json" 2>/dev/null); then
    knip_status="ran (exit $knip_rc)"
  else
    knip_status="failed (exit $knip_rc)"
    knip_result="see output"
  fi
  knip_result=$(note_scope "$knip_result")
fi

# ---- advisories ----
surfaced_rows=""
if [ "$advisories_rc" -eq 0 ]; then
  advisories_status="ran (exit $advisories_rc)"
else
  advisories_status="failed (exit $advisories_rc)"
fi
advisories_result="see output"
# One jq pass: line 1 is `unavailable` or empty, lines 2 and 3 the surfaced and
# acknowledged-suppressed high/critical counts, the rest the surfaced rows. A
# non-zero exit means the payload is missing or has no advisories array.
if advisories_scan=$(jq -er '
  def cell: tostring | gsub("\\|"; "\\|");
  def high_critical: .advisories[] | select(.severity == "high" or .severity == "critical");
  def acknowledged: .baselineAcknowledged // false;
  if (.advisories | type) != "array" then error("no advisories array")
  elif (.source // "") == "unavailable" then "unavailable"
  else
    "",
    ([high_critical | select(acknowledged | not)] | length),
    ([high_critical | select(acknowledged)] | length),
    (high_critical
     | select(acknowledged | not)
     | "| \([.package, .severity, (.ghsa // .key),
            (.firstPatchedVersion
             // (if ((.patchedVersions // []) | length) > 0
                 then (.patchedVersions | join(", "))
                 else "no patched range; consider an override or a baseline acknowledgment"
                 end))]
          | map(cell) | join(" | ")) |")
  end' "$out/advisories.json" 2>/dev/null); then
  advisories_source=""
  surfaced_count=0
  suppressed_count=0
  {
    IFS= read -r advisories_source
    IFS= read -r surfaced_count
    IFS= read -r suppressed_count
    surfaced_rows=$(cat)
  } <<<"$advisories_scan"
  if [ "$advisories_source" = "unavailable" ]; then
    advisories_result="source unavailable"
  elif [ "$surfaced_count" -eq 0 ] && [ "$suppressed_count" -eq 0 ]; then
    advisories_result="No high/critical advisories"
  else
    advisories_result="$surfaced_count high/critical surfaced; $suppressed_count acknowledged suppressed"
  fi
fi

printf '| Oracle | Status | Result | Output |\n'
printf '|---|---|---|---|\n'
printf '| react-doctor | %s | %s | %s |\n' "$react_doctor_status" "$react_doctor_result" "$out/react-doctor.txt"
printf '| knip | %s | %s | %s |\n' "$knip_status" "$knip_result" "$out/knip.json"
printf '| advisories | %s | %s | %s |\n' "$advisories_status" "$advisories_result" "$out/advisories.json"

if [ -n "$surfaced_rows" ]; then
  printf '\n'
  printf '| Package | Severity | Advisory | Fix |\n'
  printf '|---|---|---|---|\n'
  printf '%s\n' "$surfaced_rows"
fi

exit 0
