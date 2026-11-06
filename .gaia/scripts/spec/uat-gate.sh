#!/usr/bin/env bash
# The owning-phase UAT gate. The generated plan orchestrator runs it from the
# resolved isolation root before an owning phase may commit, and once more over
# every real-server, browser, legacy e2e and route row before the pre-merge audit; the procedure is
# .claude/skills/gaia/references/spec/lifecycle.md.
#
#   uat-gate.sh <spec-path> --routing <routing-file> (--phase <N> | --all) [--report <playwright-json>] [--vitest-report <vitest-json>]
#
# For the selected Playwright (real-server, browser, legacy e2e) and route rows
# (the phase's own, or every one), in order:
#   1. static checks per test file: it exists, line 1 is a contract marker, it
#      holds no annotation, and it clears a deterministic floor. A Playwright file
#      holds none of test.fail(, test.fixme(, test.skip(, .only(,
#      test.describe.skip( or test.describe.fixme(, and has a page.<method>(
#      call or a request-fixture call, plus an expect( whose first argument is
#      not a bare literal. A real-server file's floor is a verb call on a
#      request context (a page.<method>( call does not count) plus that expect,
#      and it must open no page: page-use.mjs (Node and typescript) decides, a
#      use reports opens-page. A route file's annotations and floor (a loader( or
#      action( call) live in uat-gate-route.sh;
#   2. uat-divergence-check.sh over the same selection;
#   3. working-doc-id-scan.sh over the frontend's test trees;
#   4. the route arm, when route rows are selected: Vitest (node project) over
#      only the selected files, unless --vitest-report supplies the JSON. It
#      boots no browser and no server, and a failure exits 1 before Playwright;
#   5. the Playwright arm, when Playwright rows are selected: Playwright over only the
#      selected files with the JSON reporter, unless --report supplies that
#      JSON: every test in a file must be expected to pass and have passed, and
#      each file must hold at least one test. --report is Playwright-only.
# A failure in steps 1 to 3 stops before either runner starts.
#
# Exit codes the caller branches on:
#   0  pass; also when the selection has no Playwright or route rows (prints `no owned UAT tests`)
#   1  gate failure; one stderr line per failing file: `uat-gate: <file>: <reason>`
#      with reason one or more of missing, annotation, floor, opens-page, divergence,
#      working-doc-id, expected-failure, skipped, fixme, failed, no-tests,
#      no-report-entry, collection-failed, todo
#      (a line 1 that is not a contract marker reports missing), then one
#      `uat-gate: next step for floor: ...` line when any file failed the floor,
#      and one `uat-gate: next step for opens-page: ...` line when a real-server
#      file opens a page
#   2  invalid input (usage, malformed SPEC, invalid routing table, unreadable
#      --report or --vitest-report)
#   4  a test runner could not run (jq, pnpm or a browser is missing, node or
#      the typescript package is missing for the real-server no-page check, the dev or
#      Storybook port is held, a server failed to boot, Vitest wrote no
#      report); stderr names the runner and the prerequisite, and the other
#      tree when a process of one holds a port
#
# Honest limit: the gate proves a spec turned green and still carries its
# contract. Whether the test body truly exercises the UAT is judged by the
# uat-fidelity-judge agent at the pre-audit UAT checks, not here. The Playwright
# step boots the dev server and the Storybook server, needs a local Chromium,
# and aborts when `pnpm storybook` holds the Storybook port, so it runs only the
# owned files, never the suite.
set -uo pipefail

usage() {
  cat <<'USAGE' >&2
usage: uat-gate.sh <spec-path> --routing <routing-file> (--phase <N> | --all) [--report <playwright-json>] [--vitest-report <vitest-json>]
USAGE
}

usage_failure() {
  printf 'uat-gate.sh: %s\n' "$1" >&2
  usage
  exit 2
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/spec/uat-lib.sh
source "$script_directory/uat-lib.sh"
# shellcheck source=.gaia/scripts/spec/uat-gate-route.sh
source "$script_directory/uat-gate-route.sh"
# shellcheck source=.gaia/scripts/spec/uat-gate-floor.sh
source "$script_directory/uat-gate-floor.sh"
repo_root="$PWD"

spec_path=''
routing_path=''
selected_phase=''
select_all=0
report_path=''
vitest_report_path=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 2
      ;;
    --routing)
      [ "$#" -ge 2 ] || usage_failure '--routing needs a file'
      routing_path="$2"
      shift 2
      ;;
    --phase)
      [ "$#" -ge 2 ] || usage_failure '--phase needs a number'
      selected_phase="$2"
      shift 2
      ;;
    --all)
      select_all=1
      shift
      ;;
    --report)
      [ "$#" -ge 2 ] || usage_failure '--report needs a file'
      report_path="$2"
      shift 2
      ;;
    --vitest-report)
      [ "$#" -ge 2 ] || usage_failure '--vitest-report needs a file'
      vitest_report_path="$2"
      shift 2
      ;;
    -*)
      usage_failure "unknown option: $1"
      ;;
    *)
      [ -z "$spec_path" ] || usage_failure "unexpected argument: $1"
      spec_path="$1"
      shift
      ;;
  esac
done
[ -n "$spec_path" ] || usage_failure 'no SPEC path given'
[ -n "$routing_path" ] || usage_failure '--routing is required'
if [ -z "$selected_phase" ] && [ "$select_all" -eq 0 ]; then
  usage_failure 'one of --phase <N> or --all is required'
fi
if [ -n "$selected_phase" ] && [ "$select_all" -eq 1 ]; then
  usage_failure '--phase and --all are mutually exclusive'
fi
if [ -n "$selected_phase" ] && ! [[ "$selected_phase" =~ ^[1-9][0-9]*$ ]]; then
  usage_failure "--phase needs a positive integer, got '$selected_phase'"
fi
if [ -n "$report_path" ] && [ ! -f "$report_path" ]; then
  printf 'uat-gate.sh: report not found: %s\n' "$report_path" >&2
  exit 2
fi

if [ -n "$vitest_report_path" ] && [ ! -f "$vitest_report_path" ]; then
  printf 'uat-gate.sh: vitest report not found: %s\n' "$vitest_report_path" >&2
  exit 2
fi

uat_lib_parse_spec "$spec_path" >/dev/null || exit 2
uat_lib_validate_routing "$spec_path" "$routing_path" || exit 2
routing_rows=$(uat_lib_parse_routing "$routing_path") || exit 2
e2e_directory=$(uat_lib_e2e_directory "$repo_root") || exit 2
route_directory=$(uat_lib_route_tests_directory "$repo_root") || exit 2

selected_files=''
route_files=''
selected_count=0
while IFS=$'\t' read -r _ surface phase feature_folder file_name; do
  case "$surface" in
    real-server | browser | e2e | route) ;;
    *) continue ;;
  esac
  if [ -n "$selected_phase" ] && [ "$phase" != "$selected_phase" ]; then
    continue
  fi
  if [ "$surface" != "route" ]; then
    # Each row is path, a tab, then the normalized surface (a legacy e2e row is browser).
    selected_files="$selected_files$e2e_directory/$feature_folder/$file_name"$'\t'"$(uat_lib_playwright_surface "$surface")"$'\n'
  else
    route_files="$route_files$route_directory/$(uat_lib_route_test_path "$feature_folder" "$file_name")"$'\n'
  fi
  selected_count=$((selected_count + 1))
done <<<"$routing_rows"
all_files="$selected_files$route_files"

if [ "$selected_count" -eq 0 ]; then
  printf 'no owned UAT tests\n'
  exit 0
fi

# failures rows: file<TAB>reason. One stderr line per file is printed at the end.
failures=''
add_failure() {
  failures="$failures$1"$'\t'"$2"$'\n'
}

floor_e2e=0
floor_route=0
floor_real_server=0
opens_page=0
while IFS=$'\t' read -r relative_path file_surface; do
  [ -n "$relative_path" ] || continue
  is_route=0
  case "$relative_path" in
    "$route_directory"/*) is_route=1 ;;
  esac
  absolute_path="$repo_root/$relative_path"
  if [ ! -f "$absolute_path" ]; then
    add_failure "$relative_path" missing
    continue
  fi
  if [ -z "$(uat_lib_embedded_hash "$absolute_path")" ]; then
    add_failure "$relative_path" missing
    continue
  fi
  if [ "$is_route" -eq 1 ]; then
    if gate_route_annotated "$absolute_path"; then
      add_failure "$relative_path" annotation
    fi
    if ! gate_route_clears_floor "$absolute_path"; then
      add_failure "$relative_path" floor
      floor_route=1
    fi
    continue
  fi
  if grep -qE 'test\.fail\(|test\.fixme\(|test\.skip\(|\.only\(|test\.describe\.skip\(|test\.describe\.fixme\(' "$absolute_path"; then
    add_failure "$relative_path" annotation
  fi
  if [ "$file_surface" = real-server ]; then
    if ! has_request_call "$absolute_path" || ! has_non_literal_expect "$absolute_path"; then
      add_failure "$relative_path" floor
      floor_real_server=1
    fi
    gate_opens_page "$absolute_path"
    case $? in
      1)
        add_failure "$relative_path" opens-page
        opens_page=1
        ;;
      4) exit 4 ;;
    esac
  elif ! has_e2e_call "$absolute_path" || ! has_non_literal_expect "$absolute_path"; then
    add_failure "$relative_path" floor
    floor_e2e=1
  fi
done <<<"$all_files"

# Divergence: the check's own output names `<path> <uat_id> <field>`.
phase_arguments=(--all)
[ -z "$selected_phase" ] || phase_arguments=(--phase "$selected_phase")
divergence_output=$(bash "$script_directory/uat-divergence-check.sh" "$spec_path" --routing "$routing_path" ${phase_arguments[@]+"${phase_arguments[@]}"})
divergence_status=$?
if [ "$divergence_status" -eq 2 ]; then
  exit 2
fi
if [ "$divergence_status" -ne 0 ]; then
  while IFS= read -r divergence_line; do
    [ -n "$divergence_line" ] || continue
    divergence_path="${divergence_line%% *}"
    # A missing file or contract-less file is already reported as missing.
    [ "${divergence_line##* }" = "file" ] && continue
    add_failure "$divergence_path" divergence
  done <<<"$divergence_output"
fi

scan_output=$(bash "$script_directory/working-doc-id-scan.sh")
scan_status=$?
if [ "$scan_status" -eq 2 ]; then
  printf 'uat-gate.sh: the working-document id scan could not read the Playwright tree\n' >&2
  exit 2
fi
if [ "$scan_status" -ne 0 ]; then
  while IFS= read -r scan_line; do
    [ -n "$scan_line" ] || continue
    scan_path="${scan_line%%:[0-9]*}"
    add_failure "$scan_path" working-doc-id
  done <<<"$scan_output"
fi

report_failures() {
  [ -n "$failures" ] || return 1
  printf '%s' "$failures" | LC_ALL=C awk -F'\t' '
    {
      if (!($1 in reasons)) { order[++count] = $1; reasons[$1] = $2; next }
      if (index("," reasons[$1] ",", "," $2 ",") == 0) reasons[$1] = reasons[$1] "," $2
    }
    END { for (item = 1; item <= count; item++) printf "uat-gate: %s: %s\n", order[item], reasons[order[item]] > "/dev/stderr" }
  '
  # The judge and this floor read only the spec file, so an assert moved into
  # a shared helper reads as absent even when the behavior works.
  if [ "$floor_e2e" -eq 1 ]; then
    printf 'uat-gate: next step for floor: the spec file itself must call page.<method>( or a request-fixture call (request.get(, request.post( and the other verbs, or request.newContext( with a verb call) and hold an expect( on a real value. The counted call must be the one the Then-clause asserts read: never add a call whose result no Then assert reads only to clear the floor. When the behavior works and a shared helper holds the Then-clause asserts, move them back into the test body and re-run; a floor failure never calls for reopening the SPEC.\n' >&2
  fi
  if [ "$floor_real_server" -eq 1 ]; then
    printf 'uat-gate: next step for floor: the real-server test file itself must call a verb on the request fixture (request.get(, request.post( and the other verbs, on a request-context fixture the test callback destructures, on a request.newContext( variable, or on a variable bound by awaiting such a fixture (const api = await signIn(...)) or a helper handed one of these (const api = await signInAs(request, ...)); a page.<method>( call does not count, and when a helper builds its own context, pass the request fixture or the request-context fixture into that helper) and hold an expect( on a real value. The counted call must be the one the Then-clause asserts read: never add a call whose result no Then assert reads only to clear the floor. When the behavior works and a shared helper holds the Then-clause asserts, move them back into the test body and re-run; a floor failure never calls for reopening the SPEC.\n' >&2
  fi
  if [ "$opens_page" -eq 1 ]; then
    printf 'uat-gate: next step for opens-page: a real-server test must not open a page; drive it through the request fixture and read rendered HTML with the helper in %s/html.ts. When the Then-clause truly needs a browser, the routing row is wrong: stop and report it instead of editing the test.\n' "${e2e_directory%/e2e}" >&2
  fi
  if [ "$floor_route" -eq 1 ]; then
    printf 'uat-gate: next step for floor: the route test file itself must call the route'"'"'s loader( or action(, by a named import (an alias such as import {action as signOut} counts) or a member call such as logout.action(args), and hold an expect( on a real value; a shared helper may build the request, args and context, but a helper that receives the route module and makes the call (runAction(logout, ...)) does not count. When the behavior works and a shared helper holds the Then-clause asserts, move them back into the test body and re-run; a floor failure never calls for reopening the SPEC.\n' >&2
  fi
  return 0
}

if report_failures; then
  exit 1
fi

# --- Route arm: Vitest ---
route_package="${route_directory%/app/route-tests}"
[ "$route_package" != "$route_directory" ] || route_package='.'
if [ -n "$route_files" ]; then
  gate_route_run "$route_files" "$route_package" "$vitest_report_path"
  if report_failures; then
    exit 1
  fi
fi
[ -n "$selected_files" ] || exit 0

# --- Playwright ---
if ! command -v jq >/dev/null 2>&1; then
  printf 'uat-gate.sh: jq is not on PATH. Next step: install jq and retry.\n' >&2
  exit 4
fi

# port_holders: one sentence per dev or Storybook port of this tree that a
# process from another tree holds, naming that tree. Stopping it is the user's
# call, so the gate names the holder instead of leaving a held port anonymous.
port_holders() {
  local field port answer rest holder_pid holder_directory sentences=''
  for field in dev storybook; do
    port="$(bash "$script_directory/../ports.sh" --tree "$repo_root" --field "$field" 2>/dev/null)" || continue
    answer="$(bash "$script_directory/../server-process-lib.sh" --listener-owner "$port" "$repo_root" 2>/dev/null)"
    case "$answer" in
      'foreign '*)
        rest="${answer#foreign }"
        holder_pid="${rest%% *}"
        holder_directory="${rest#* }"
        if [ "$holder_pid" = 0 ]; then
          sentences="$sentences Port $port is held by a process GAIA could not identify: ask the user before stopping it."
        elif [ "$holder_directory" = unknown ]; then
          sentences="$sentences Port $port is held by process $holder_pid, whose directory GAIA could not read: ask the user before stopping it."
        else
          sentences="$sentences Port $port is held by process $holder_pid running from $holder_directory, which is not this tree: ask the user before stopping it."
        fi
        ;;
    esac
  done
  printf '%s' "$sentences"
}

package_directory="${e2e_directory%/.playwright/e2e}"
[ "$package_directory" != "$e2e_directory" ] || package_directory='.'
if [ "$package_directory" = "." ]; then package_prefix=''; else package_prefix="$package_directory/"; fi

if [ -z "$report_path" ]; then
  if ! command -v pnpm >/dev/null 2>&1; then
    printf 'uat-gate.sh: pnpm is not on PATH, so Playwright cannot run. Next step: install pnpm and the frontend dependencies, then retry.\n' >&2
    exit 4
  fi
  [ -n "${gate_temporary:-}" ] || gate_temporary=$(mktemp -d)
  trap 'rm -rf "$gate_temporary"' EXIT
  report_path="$gate_temporary/report.json"
  playwright_arguments=()
  while IFS=$'\t' read -r relative_path _; do
    [ -n "$relative_path" ] || continue
    playwright_arguments+=("${relative_path#"$package_prefix"}")
  done <<<"$selected_files"
  PLAYWRIGHT_JSON_OUTPUT_NAME="$report_path" pnpm -C "$package_directory" exec playwright test ${playwright_arguments[@]+"${playwright_arguments[@]}"} --reporter=json >/dev/null 2>"$gate_temporary/playwright.stderr"
  if ! jq -e . "$report_path" >/dev/null 2>&1; then
    printf 'uat-gate.sh: Playwright produced no report. Prerequisites: Chromium installed (pnpm exec playwright install chromium), the frontend dependencies installed, and the dev and Storybook ports free (stop pnpm storybook).%s Playwright said: %s\n' "$(port_holders)" "$(head -c 400 "$gate_temporary/playwright.stderr" | LC_ALL=C tr '\r\n\t' '   ')" >&2
    exit 4
  fi
else
  if ! jq -e . "$report_path" >/dev/null 2>&1; then
    printf 'uat-gate.sh: report is not valid JSON: %s\n' "$report_path" >&2
    exit 2
  fi
fi

# A browser that is not installed, or a server that did not boot, shows up as
# top-level errors or as launch errors on every test, not as a test verdict.
if jq -e '((.errors // []) | length) > 0 or ([.. | objects | select(has("results")) | .results[]?.error.message // empty | select(test("Executable doesn.t exist|playwright install|browserType\\.launch|already used|webServer"))] | length) > 0' "$report_path" >/dev/null 2>&1; then
  printf 'uat-gate.sh: Playwright could not run the owned specs. Prerequisites: Chromium installed (pnpm exec playwright install chromium), the dev and Storybook ports free (stop pnpm storybook), the servers able to boot.%s Playwright said: %s\n' "$(port_holders)" "$(jq -r '[(.errors // [])[]?.message // empty] | first // "see the report"' "$report_path" | head -c 400 | LC_ALL=C tr '\r\n\t' '   ')" >&2
  exit 4
fi

while IFS=$'\t' read -r relative_path _; do
  [ -n "$relative_path" ] || continue
  from_package="${relative_path#"$package_prefix"}"
  from_test_directory="${relative_path#"$e2e_directory"/}"
  verdict=$(jq -r --arg a "$from_test_directory" --arg b "$from_package" --arg c "$relative_path" '
    [.. | objects | select(has("tests") and has("file") and has("title")) | select(.file == $a or .file == $b or .file == $c) | .tests[]] as $tests
    | if ($tests | length) == 0 then "no-tests"
      elif any($tests[]; .status == "skipped" or .expectedStatus == "skipped") then
        (if any($tests[]; (.annotations // []) | any(.type == "fixme")) then "fixme" else "skipped" end)
      elif any($tests[]; .expectedStatus != "passed") then "expected-failure"
      elif any($tests[]; .status != "expected" or ((.results // []) | length) == 0 or (.results[-1].status != "passed")) then "failed"
      else "passed" end
  ' "$report_path")
  [ "$verdict" = "passed" ] || add_failure "$relative_path" "$verdict"
done <<<"$selected_files"

if report_failures; then
  exit 1
fi
exit 0
