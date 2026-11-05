# shellcheck shell=bash
#
# Sourced by uat-gate.sh, never executed. The route arm of the owning-phase UAT
# gate: the static checks for a route row's Vitest test, and the Vitest run that
# judges it. It boots no browser and no server. It relies on the gate's own
# state (repo_root, add_failure) and the floor helpers of uat-gate-floor.sh.
#
# Bash 3.2 compatible; BSD and GNU tools.

# True when the file, read as code alone, annotates a test so it cannot fail
# honestly: a chained .fails, .skip, .skipIf, .runIf, .todo or .only on a test,
# it, describe or suite receiver (in any position of the chain), or the
# `fails: true` option. This scan is the only guard for an inverted test,
# because Vitest's JSON report records a test.fails test as passed. Honest
# limit: a bracket-spelled annotation (test['fails'](...)) escapes it; the
# fidelity judge reads the body and catches that.
gate_route_annotated() {
  local code
  code=$(uat_lib_code_only "$1") || return 1
  grep -qE '(^|[^A-Za-z0-9_$.])(test|it|describe|suite)(\.[A-Za-z_$][A-Za-z0-9_$]*)*\.(fails|skip|skipIf|runIf|todo|only)([^A-Za-z0-9_$]|$)|(^|[^A-Za-z0-9_$])fails[[:space:]]*:[[:space:]]*true([^A-Za-z0-9_$]|$)' <<<"$code"
}

# True when the file, read as code alone, calls loader( or action( (member
# access allowed), or calls the local name a named import binds to a loader or
# action export (`import {loader as requestList}` then `requestList(`), and
# holds an expect( whose first argument is not a bare literal. A bare
# `new Request(` is not a route call. Honest limits: code alone blanks a
# template literal, so an interpolated template as the only expect argument
# reads as a literal; neither form checks which module the name comes from;
# an alias counts only between the braces of an import statement that starts
# its line, with `loader as X` on one line, so a default import, a renaming
# destructure (`{loader: X}`) or a name another module binds, for example, is
# not followed and fails the floor, the safe direction.
gate_route_clears_floor() {
  local code import_braces route_name alias_name
  code=$(uat_lib_code_only "$1") || return 1
  import_braces=$(LC_ALL=C awk '
    inside {
      close_at = index($0, "}")
      if (close_at) { print substr($0, 1, close_at); inside = 0 } else print
      next
    }
    /^[[:space:]]*import[[:space:]]+(type[[:space:]]+)?([A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*,[[:space:]]*)?\{/ {
      rest = substr($0, index($0, "{"))
      close_at = index(rest, "}")
      if (close_at) print substr(rest, 1, close_at); else { print rest; inside = 1 }
    }
  ' <<<"$code")
  route_name='loader|action'
  while IFS= read -r alias_name; do
    [ -n "$alias_name" ] || continue
    route_name="$route_name|$(printf '%s' "$alias_name" | sed 's/\$/\\$/g')"
  done <<EOF
$(grep -oE '(^|[{,])[[:space:]]*(loader|action)[[:space:]]+as[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*' <<<"$import_braces" | sed -E 's/.*[[:space:]]as[[:space:]]+//')
EOF
  grep -qE "(^|[^A-Za-z0-9_\$])($route_name)[[:space:]]*\\(" <<<"$code" || return 1
  has_non_literal_expect <(printf '%s\n' "$code")
}

# The per-file verdict from a parsed Vitest JSON report: passed, or the reason.
# $1 the report, $2 the file's repo-relative path. An unknown status fails.
gate_route_verdict() {
  # shellcheck disable=SC2154 # repo_root is the gate's own variable
  jq -r --arg absolute "$repo_root/$2" --arg suffix "/$2" '
    [(.testResults? // [])[]? | select(.name == $absolute or ((.name // "") | endswith($suffix)))] as $entries
    | if ($entries | length) == 0 then "no-report-entry"
      else
        [$entries[] | (.assertionResults? // [])[]?] as $assertions
        | if ($assertions | length) == 0 then
            (if any($entries[]; .status == "failed") then "collection-failed" else "no-tests" end)
          elif any($assertions[]; .status == "failed") then "failed"
          elif any($assertions[]; .status == "skipped" or .status == "pending") then "skipped"
          elif any($assertions[]; .status == "todo") then "todo"
          elif all($assertions[]; .status == "passed") then "passed"
          else "failed" end
      end
  ' "$1"
}

# gate_route_run <route-files> <package-directory> <vitest-report-or-empty>:
# runs Vitest over the files unless a report is supplied, then records one
# failure per file that is not green. Exit 4 when Vitest could not run, exit 2
# when a supplied report is not JSON.
gate_route_run() {
  local files="$1" package="$2" supplied_report="$3" report prefix='' relative_path verdict
  local arguments=() vitest_stderr
  if ! command -v jq >/dev/null 2>&1; then
    printf 'uat-gate.sh: jq is not on PATH, so the Vitest report cannot be read. Next step: install jq and retry.\n' >&2
    exit 4
  fi
  [ "$package" = "." ] || prefix="$package/"
  if [ -n "$supplied_report" ]; then
    report="$supplied_report"
    if ! jq -e . "$report" >/dev/null 2>&1; then
      printf 'uat-gate.sh: vitest report is not valid JSON: %s\n' "$report" >&2
      exit 2
    fi
  else
    if ! command -v pnpm >/dev/null 2>&1; then
      printf 'uat-gate.sh: pnpm is not on PATH, so Vitest cannot run. Next step: install pnpm and the frontend dependencies, then retry.\n' >&2
      exit 4
    fi
    [ -n "${gate_temporary:-}" ] || gate_temporary=$(mktemp -d)
    trap 'rm -rf "$gate_temporary"' EXIT
    report="$gate_temporary/vitest-report.json"
    vitest_stderr="$gate_temporary/vitest.stderr"
    while IFS= read -r relative_path; do
      [ -n "$relative_path" ] || continue
      arguments+=("${relative_path#"$prefix"}")
    done <<<"$files"
    # Vitest's exit status is ignored: the report judges each file.
    pnpm -C "$package" exec vitest run --project node --reporter=json --outputFile="$report" ${arguments[@]+"${arguments[@]}"} >/dev/null 2>"$vitest_stderr"
    if ! jq -e . "$report" >/dev/null 2>&1; then
      printf 'uat-gate.sh: Vitest produced no report. Prerequisites: the frontend dependencies installed (pnpm install) and a node project in the Vitest config. Vitest said: %s\n' "$(head -c 400 "$vitest_stderr" | LC_ALL=C tr '\r\n\t' '   ')" >&2
      exit 4
    fi
  fi
  while IFS= read -r relative_path; do
    [ -n "$relative_path" ] || continue
    verdict=$(gate_route_verdict "$report" "$relative_path")
    [ "$verdict" = "passed" ] || add_failure "$relative_path" "$verdict"
  done <<<"$files"
}
