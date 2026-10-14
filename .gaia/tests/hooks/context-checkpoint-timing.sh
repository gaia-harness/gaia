#!/usr/bin/env bash
# Local measurement tool for the context checkpoint hook, which runs after every
# tool call of every main session. Not a bats suite and not run in CI.
#
# Purpose: the hook's wall time is paid on every tool call, so each exit path
# of its ladder has a 50 ms p50 budget. This tool measures every path and
# reports; it never tunes the hook and never enforces a budget. It fails (exit
# 1) only when it measured something other than the path it names: a firing run
# whose decoded additionalContext is empty, or a path that emits when it should
# stay silent.
#
# Method: builds a scratch fixture repo (git init, one commit, a feat/9-sample
# branch) holding copies of the real hook, the scripts it loads, the doctrine
# file, and the real settings.json (or the file GAIA_TIMING_SETTINGS names, so
# the empty-context failure can be proven against a scratch copy whose hook
# command is replaced). The registered command string is read from the copied
# settings (the PostToolUse entry whose command names
# context-checkpoint-inject.sh) and executed by /bin/sh -c with the fixture as
# cwd, so the registered rooting step is part of every measurement. The hook
# runs under macOS bash 3.2 when /bin/bash is that version (a PATH shim makes
# `#!/usr/bin/env bash` resolve to it); elsewhere a warning is printed and the
# resolved bash is used. Wall time is taken around the child process only, with
# perl Time::HiRes.
#
# Load resistance: the paths and a no-op baseline (/bin/sh -c true, same stdin)
# are measured in interleaved blocks of a few runs each, cycling through every
# label and reversing the order on alternate cycles, so all of them share the
# same machine load. The baseline row is the floor this machine adds to any
# process spawn at that moment; read each path next to it. The 1-minute load
# average is printed at the start and the end of the run.
#
# Context readings are written with gaia_context_write; token values are
# derived from gaia_context_bands over the same effective line the hook uses,
# so no band number is spelled here. Each run uses a fresh session id.
#
# Paths:
#   subagent               payload carries agent_id, reading past red
#   below_red_unmarked     yellow reading, no marker (one jq, zero git)
#   band_marked            marker skull, reading past skull (exits before the
#                          context read)
#   red_marked_below_fire  marker red, reading between red and fire (reads the
#                          context, then exits as already marked)
#   firing                 reading between red and fire, no marker, no audit
#                          loop state (emits)
#   in_audit_loop          as firing, but a state file for the fixture branch
#                          records the session (runs the predicate, silent)
#   large_payload          as below_red_unmarked with a 200 KB tool_response
#   baseline               /bin/sh -c true
#
# Usage: [GAIA_TIMING_SETTINGS=<path>] bash .gaia/tests/hooks/context-checkpoint-timing.sh [--runs N] [--json]
# Run it from the repo root. Default N is 50.
#
# Reading the output: p50 and p90 are milliseconds per path. injected_bytes is
# the decoded additionalContext length on the firing path. in_audit_loop is
# also checked against a control: the same reading with the state file removed
# must emit, so a silent run cannot be a state file the hook never found.
#
# Budgets: p50 at most 50 ms per path. A baseline well above a few ms means the
# machine was loaded; the output says so and the numbers should be repeated on
# a quieter machine before they are recorded.
#
# --json prints the measurement rows as an array of {metric, value, unit,
# budget} objects. Fixture and temp files are removed on exit.

set -uo pipefail

runs=50
json=0
block_size=5
while [ $# -gt 0 ]; do
  case "$1" in
    --runs)
      runs="${2:-}"
      shift 2 || { echo "--runs needs a value" >&2; exit 2; }
      ;;
    --json) json=1; shift ;;
    *) echo "usage: $0 [--runs N] [--json]" >&2; exit 2 ;;
  esac
done
case "$runs" in '' | *[!0-9]* | 0) echo "--runs must be a positive integer" >&2; exit 2 ;; esac

for tool in jq perl git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 2; }
done

repo=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "run from inside the repo" >&2; exit 2; }
settings_source="${GAIA_TIMING_SETTINGS:-$repo/.claude/settings.json}"
for required_file in .claude/hooks/context-checkpoint-inject.sh .claude/doctrine/context-checkpoint.md \
  .gaia/scripts/context-checkpoint-lib.sh; do
  [ -f "$repo/$required_file" ] || { echo "missing $required_file" >&2; exit 2; }
done
[ -f "$settings_source" ] || { echo "missing settings file: $settings_source" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture="$(cd -P "$work" && pwd)/fixture"

mkdir -p "$fixture/.claude/hooks" "$fixture/.claude/doctrine" "$fixture/.gaia/scripts"
cp "$repo/.claude/hooks/context-checkpoint-inject.sh" "$fixture/.claude/hooks/"
cp "$repo/.claude/doctrine/context-checkpoint.md" "$fixture/.claude/doctrine/"
cp "$settings_source" "$fixture/.claude/settings.json"
for library_file in "$repo"/.gaia/scripts/*.sh; do
  cp "$library_file" "$fixture/.gaia/scripts/"
done
git -C "$fixture" init -q -b main
git -C "$fixture" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
  commit -q --allow-empty -m init
git -C "$fixture" checkout -q -b feat/9-sample

registered_command=$(jq -r '.hooks.PostToolUse[]? | .hooks[]? | .command
  | select(contains("context-checkpoint-inject.sh"))' "$fixture/.claude/settings.json" | sed -n 1p)
[ -n "$registered_command" ] || { echo "no registered context checkpoint command in settings" >&2; exit 2; }

shim="$work/shim"
mkdir -p "$shim"
sys_bash_version=""
[ -x /bin/bash ] && sys_bash_version=$(/bin/bash --version 2>/dev/null)
if grep -q 'version 3\.2' <<<"${sys_bash_version%%$'\n'*}"; then
  ln -s /bin/bash "$shim/bash"
  hook_path="$shim:$PATH"
else
  echo "warning: /bin/bash is not 3.2 here; using whatever bash resolves" >&2
  hook_path="$PATH"
fi
bash_used=$(PATH="$hook_path" bash --version | sed -n 1p)

# shellcheck source=/dev/null
. "$fixture/.gaia/scripts/context-checkpoint-lib.sh"
# shellcheck source=/dev/null
. "$fixture/.gaia/scripts/audit-loop-state-lib.sh"

window=1000000
checkpoint_line=$(gaia_context_effective_line "$fixture" "$window")
read -r yellow_tokens red_tokens fire_tokens skull_tokens <<<"$(gaia_context_bands "$window" "$checkpoint_line")"
yellow_reading=$yellow_tokens
mid_red_to_fire_reading=$(((red_tokens + fire_tokens) / 2))
past_skull_reading=$((skull_tokens + 1000))
state_key=$(gaia_loop_key "$fixture") || { echo "no loop key for the fixture branch" >&2; exit 2; }
state_file=$(gaia_loop_state_file "$fixture" "$state_key")
marker_directory="$fixture/.gaia/local/cache/context-checkpoint"

head -c 200000 /dev/zero | tr '\0' 'x' >"$work/large_response.txt"

uuid_counter=0
session_id=""
next_session_id() {
  uuid_counter=$((uuid_counter + 1))
  printf -v session_id '%08x-%04x-%04x-%04x-%08x%04x' "$$" "$uuid_counter" "$RANDOM" "$RANDOM" "$((RANDOM * RANDOM))" "$RANDOM"
}

epoch_now() { date +%s; }
write_reading() { gaia_context_write "$fixture" "$1" 0 "$2" "$window" "$(epoch_now)"; }
write_marker() { mkdir -p "$marker_directory" && printf '%s\n' "$2" >"$marker_directory/$1"; }
write_state() {
  mkdir -p "${state_file%/*}"
  jq -n --arg key "branch:$state_key" --arg branch "$state_key" --arg session_id "$1" \
    '{schema:1,key:$key,branch:$branch,pr:null,created_at:"2026-01-01T00:00:00Z",
      history:{rounds:[],units:[],checkpoints:[{index:1,at_round:1,reason:"timing",recorded_at:"2026-01-01T00:00:00Z",session_id:$session_id,audited_root:"/x"}]},
      allowance:{answers:[]}}' >"$state_file"
}

# build_payload <session id> <extra jq object> [large]: PostToolUse payload.
build_payload() {
  if [ "${3:-}" = large ]; then
    jq -nc --arg session_id "$1" --arg working_directory "$fixture" --argjson extra "$2" --rawfile response "$work/large_response.txt" \
      '{hook_event_name:"PostToolUse",session_id:$session_id,cwd:$working_directory,tool_name:"Bash",tool_input:{command:"ls"},tool_response:{stdout:$response}} + $extra'
  else
    jq -nc --arg session_id "$1" --arg working_directory "$fixture" --argjson extra "$2" \
      '{hook_event_name:"PostToolUse",session_id:$session_id,cwd:$working_directory,tool_name:"Bash",tool_input:{command:"ls"},tool_response:{stdout:"ok"}} + $extra'
  fi
}

# prepare <label> <session id>: writes the fixture state and the payload file;
# sets $expect to emit or silent.
prepare() {
  local label="$1" sid="$2"
  expect=silent
  case "$label" in
    subagent) write_reading "$sid" "$((red_tokens + 1000))"; build_payload "$sid" '{"agent_id":"agent-1"}' >"$work/in.json" ;;
    below_red_unmarked) write_reading "$sid" "$yellow_reading"; build_payload "$sid" '{}' >"$work/in.json" ;;
    band_marked) write_reading "$sid" "$past_skull_reading"; write_marker "$sid" skull; build_payload "$sid" '{}' >"$work/in.json" ;;
    red_marked_below_fire) write_reading "$sid" "$mid_red_to_fire_reading"; write_marker "$sid" red; build_payload "$sid" '{}' >"$work/in.json" ;;
    firing) write_reading "$sid" "$mid_red_to_fire_reading"; build_payload "$sid" '{}' >"$work/in.json"; expect=emit ;;
    in_audit_loop) write_reading "$sid" "$mid_red_to_fire_reading"; write_state "$sid"; build_payload "$sid" '{}' >"$work/in.json" ;;
    large_payload) write_reading "$sid" "$yellow_reading"; build_payload "$sid" '{}' large >"$work/in.json" ;;
    baseline) build_payload "$sid" '{}' >"$work/in.json" ;;
  esac
}

# time_one <command>: wall ms of the command run by /bin/sh -c with $work/in.json
# on stdin; stdout lands in $work/out.json.
time_one() {
  (cd "$fixture" && PATH="$hook_path" perl -MTime::HiRes=time -e '
    my ($in, $out, $command) = @ARGV;
    open(STDIN, "<", $in) or die; open(STDOUT, ">", $out) or die;
    open(STDERR, ">", "/dev/null") or die;
    my $start = time; system("/bin/sh", "-c", $command); my $elapsed = (time - $start) * 1000;
    open(my $milliseconds_file, ">", "$out.ms") or die; printf $milliseconds_file "%.3f\n", $elapsed;' \
    "$work/in.json" "$work/out.json" "$1")
  cat "$work/out.json.ms"
}

load_one_minute() { uptime | sed -e 's/.*load averages*: *//' -e 's/,/ /g' | awk '{print $1}'; }

labels="subagent below_red_unmarked band_marked red_marked_below_fire firing in_audit_loop large_payload baseline"
failures=0
failure_notes=""
note_failure() { failures=$((failures + 1)); failure_notes="$failure_notes$1
"; }

load_start=$(load_one_minute)
[ "$json" = 1 ] || {
  echo "bash used for the hook: $bash_used"
  echo "load average (1 min) at start: $load_start"
}

# One control before measuring: the in-loop state file must be found by the hook,
# which shows as the same reading emitting once the state file is gone.
next_session_id
prepare in_audit_loop "$session_id"
time_one "$registered_command" >/dev/null
[ ! -s "$work/out.json" ] || note_failure "in_audit_loop emitted although the state file records the session"
rm -f "$state_file"
write_reading "$session_id" "$mid_red_to_fire_reading"
rm -f "$marker_directory/$session_id"
build_payload "$session_id" '{}' >"$work/in.json"
time_one "$registered_command" >/dev/null
[ -s "$work/out.json" ] || note_failure "in_audit_loop control: the same reading without the state file did not emit"

processed=0
cycle=0
while [ "$processed" -lt "$runs" ]; do
  count=$block_size
  [ $((runs - processed)) -ge "$count" ] || count=$((runs - processed))
  ordered_labels="$labels"
  if [ $((cycle % 2)) = 1 ]; then
    ordered_labels=""
    for label in $labels; do ordered_labels="$label $ordered_labels"; done
  fi
  for label in $ordered_labels; do
    iteration=0
    while [ "$iteration" -lt "$count" ]; do
      iteration=$((iteration + 1))
      next_session_id
      prepare "$label" "$session_id"
      if [ "$label" = baseline ]; then
        milliseconds=$(time_one true)
      else
        milliseconds=$(time_one "$registered_command")
      fi
      printf '%s\n' "$milliseconds" >>"$work/times.$label"
      if [ "$expect" = emit ] && [ ! -s "$work/out.json" ]; then
        note_failure "$label produced no output on a run that must emit"
      elif [ "$expect" = silent ] && [ -s "$work/out.json" ]; then
        note_failure "$label emitted on a run that must stay silent"
      fi
      [ "$label" != in_audit_loop ] || rm -f "$state_file"
    done
  done
  processed=$((processed + count))
  cycle=$((cycle + 1))
done
load_end=$(load_one_minute)

# The firing output must decode to a non-empty additionalContext.
next_session_id
prepare firing "$session_id"
time_one "$registered_command" >/dev/null
injected=$(jq -j '.hookSpecificOutput.additionalContext // ""' "$work/out.json" 2>/dev/null | wc -c | tr -d ' ')
[ "$injected" -gt 0 ] || note_failure "firing: the registered command injected an empty additionalContext"

# percentile <label> <p50|p90>
percentile() {
  sort -n "$work/times.$1" | awk -v which="$2" '
    { sorted_milliseconds[NR] = $1 }
    END {
      if (which == "p50") index_value = int((NR + 1) / 2)
      else { index_value = int(NR * 0.9); if (index_value < 1) index_value = 1 }
      printf "%.1f\n", sorted_milliseconds[index_value]
    }'
}

if [ "$json" = 1 ]; then
  rows="[]"
  for label in $labels; do
    p50=$(percentile "$label" p50)
    budget=50
    [ "$label" != baseline ] || budget=null
    rows=$(jq -c --arg metric "p50_${label}_ms" --argjson value "$p50" --argjson budget "$budget" \
      '. + [{metric:$metric,value:$value,unit:"ms",budget:$budget}]' <<<"$rows")
  done
  jq -n --argjson rows "$rows" --argjson injected "$injected" --argjson load_start "$load_start" --argjson load_end "$load_end" \
    '$rows + [{metric:"injected_bytes",value:$injected,unit:"bytes",budget:null},
              {metric:"load_1min_start",value:$load_start,unit:"load",budget:null},
              {metric:"load_1min_end",value:$load_end,unit:"load",budget:null}]'
else
  echo "runs per path: $runs (interleaved blocks of $block_size, baseline included)"
  for label in $labels; do
    printf '%-24s p50 %7s ms   p90 %7s ms\n' "$label" "$(percentile "$label" p50)" "$(percentile "$label" p90)"
  done
  echo "budget: p50 at most 50 ms per path (baseline is the machine's process-spawn floor, not a path)"
  echo "injected_bytes (firing): $injected"
  echo "load average (1 min) at end: $load_end"
fi

if [ "$failures" -gt 0 ]; then
  printf 'FAIL: %s check(s) failed\n%s' "$failures" "$failure_notes" >&2
  exit 1
fi
exit 0
