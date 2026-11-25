# shellcheck shell=bash
#
# The one owner of which runners run a SPEC flow's test. The spec lint
# (lint.sh) refuses a command flow whose test_path no runner here runs, and
# plan-verify.sh refuses a closing-phase entry whose line for a flow test does
# not hold that flow's runner. Sourced, never executed.
#
# The table is the built-in runners below plus, ahead of them, the entries of
# the optional repository registry `.gaia/flow-runners.json`, a JSON array. Each
# entry is an object:
#   name        a non-empty label
#   paths       non-empty list of globs over the repo-relative test_path; `*`
#               matches across `/`. The first entry (registry, then built-in)
#               with a matching glob is the flow's runner.
#   command     a string or a non-empty list of strings: a gate line runs the
#               test when it holds one of them
#   run         the gate line the test stage writes, placeholders in <angles>
#   names_path  optional boolean, default true: the gate line must also hold
#               the test file's basename. Set it false only for a runner whose
#               command selects its test itself, such as one fixed table.
# No string may hold a tab, newline or carriage return. A missing jq makes
# every function return 2, and so does a malformed registry, except that
# flow_runners_line_runs never reads the registry for a web flow; each prints
# one `flow-runners:` line on stderr.
#
# A web flow is always the Playwright spec; its gate line must hold the test
# file's basename and one built-in runner's command.
#
# Bash 3.2 compatible; BSD and GNU tools.

if [ -n "${FLOW_RUNNERS_LIB_SH:-}" ]; then
  return 0
fi
FLOW_RUNNERS_LIB_SH=1

_FLOW_RUNNERS_BUILTIN='[
  {"name": "playwright", "paths": [], "command": "playwright test"},
  {"name": "bats", "paths": ["*.bats"], "command": ["test:shell", "bats5.sh"],
   "run": "pnpm test:shell <test_path> < /dev/null"},
  {"name": "vitest",
   "paths": ["*.test.ts", "*.test.tsx", "*.test.mts", "*.test.cts", "*.test.js", "*.test.jsx", "*.test.mjs", "*.test.cjs",
             "*.spec.ts", "*.spec.tsx", "*.spec.mts", "*.spec.cts", "*.spec.js", "*.spec.jsx", "*.spec.mjs", "*.spec.cjs"],
   "command": "test --run",
   "run": "pnpm -C <owning package> test --run <package-relative path>"}
]'

_flow_runners_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  printf 'flow-runners: jq is required to read the flow runner table. Next step: install jq.\n' >&2
  return 2
}

# Prints one TSV row per runner that a command flow can resolve to, registry
# entries first: name, names_path (1 or 0), run, paths and commands (each
# \037-joined). Playwright has no paths: it runs web flows only.
_flow_runners_rows() {
  local registry="${1:-}/.gaia/flow-runners.json" registry_json='[]' rows
  _flow_runners_require_jq || return 2
  if [ -f "$registry" ]; then
    registry_json=$(cat "$registry") || {
      printf 'flow-runners: cannot read .gaia/flow-runners.json\n' >&2
      return 2
    }
  fi
  rows=$(jq -rn --argjson builtin "$_FLOW_RUNNERS_BUILTIN" --arg registry "$registry_json" '
    def clean: type == "string" and length > 0 and (test("[\t\n\r]") | not);
    def valid:
      type == "object"
      and (.name | clean) and (.run | clean)
      and (.paths | type == "array" and length > 0 and all(.[]; clean))
      and ((.command | clean) or (.command | type == "array" and length > 0 and all(.[]; clean)))
      and ((has("names_path") | not) or (.names_path | type == "boolean"));
    ($registry | try fromjson catch null) as $entries
    | if ($entries | type) != "array" or ($entries | all(.[]; valid) | not) then error("malformed")
      else ($entries + $builtin)[]
        | select(.paths | length > 0)
        | [.name, (if .names_path == false then "0" else "1" end), .run,
           (.paths | join("\u001f")), ([.command] | flatten | join("\u001f"))]
        | @tsv
      end' 2>/dev/null) || {
    printf 'flow-runners: .gaia/flow-runners.json is not a JSON array of runner entries (name, paths, command, run, optional names_path); see .gaia/scripts/spec/flow-runners-lib.sh\n' >&2
    return 2
  }
  printf '%s\n' "$rows"
}

# flow_runners_for_path <repo root> <test_path>: prints the flow's runner as one
# TSV row: name, names_path, run, commands (\037-joined). Status 1 when no
# runner's glob matches (stderr says so), 2 on an unreadable table.
flow_runners_for_path() {
  local test_path="${2:-}" rows name names_path run paths commands glob
  local -a globs
  rows=$(_flow_runners_rows "${1:-}") || return 2
  while IFS=$'\t' read -r name names_path run paths commands; do
    [ -n "$name" ] || continue
    IFS=$'\037' read -r -a globs <<<"$paths"
    for glob in ${globs[@]+"${globs[@]}"}; do
      # shellcheck disable=SC2053 # the glob is a pattern on purpose
      if [[ "$test_path" == $glob ]]; then
        printf '%s\t%s\t%s\t%s\n' "$name" "$names_path" "$run" "$commands"
        return 0
      fi
    done
  done <<<"$rows"
  printf 'flow-runners: no flow runner runs %s: use a .bats or Vitest test, or a runner registered in .gaia/flow-runners.json\n' "$test_path" >&2
  return 1
}

# flow_runners_line_runs <repo root> <web|command> <test path> <entry text>:
# status 0 when a line of the entry text runs the flow's test, 1 when none
# does (stdout then names what a line must hold), 2 on an unreadable table or
# a command test_path no runner runs (stderr names it).
flow_runners_line_runs() {
  local repo_root="${1:-}" kind="${2:-}" test_path="${3:-}" entry_text="${4:-}"
  local base_name names_path=1 commands='' row command_text entry_line want
  local -a command_list
  base_name=$(basename "$test_path")
  if [ "$kind" = web ]; then
    _flow_runners_require_jq || return 2
    commands=$(jq -r '[.[].command] | flatten | join("\u001f")' <<<"$_FLOW_RUNNERS_BUILTIN")
  else
    row=$(flow_runners_for_path "$repo_root" "$test_path") || return 2
    IFS=$'\t' read -r _ names_path _ commands <<<"$row"
  fi
  IFS=$'\037' read -r -a command_list <<<"$commands"
  while IFS= read -r entry_line; do
    if [ "$names_path" = 1 ]; then
      case "$entry_line" in *"$base_name"*) ;; *) continue ;; esac
    fi
    for command_text in ${command_list[@]+"${command_list[@]}"}; do
      case "$entry_line" in *"$command_text"*) return 0 ;; esac
    done
  done <<<"$entry_text"
  want="${commands//$'\037'/, }"
  if [ "$names_path" = 1 ]; then
    printf 'no line holds %s with a runner (%s)\n' "$base_name" "$want"
  else
    printf 'no line holds its runner (%s)\n' "$want"
  fi
  return 1
}
