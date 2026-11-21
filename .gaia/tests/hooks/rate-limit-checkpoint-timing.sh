#!/usr/bin/env bash
# Local measurement tool for the rate-limit checkpoint hook, which runs before
# every Agent, Task and Workflow dispatch of every session. Not a bats suite and
# not run in CI.
#
# Purpose: each exit path of the hook's ladder has a p50 budget (50 ms for the
# paths that end early, 100 ms for the firing path). This tool measures every
# path and reports; it never tunes the hook and never enforces a budget. It
# fails (exit 1) only when it measured something other than the path it names:
# a firing run that prints nothing, or a path that prints when it must stay
# silent.
#
# Method: builds a scratch fixture repo (git init, one commit) holding copies of
# the real hook and the scripts it loads. The registered command string is read
# from the real settings (the PreToolUse command naming the hook) and executed
# by /bin/sh -c with the fixture as cwd, so the registered rooting step is part
# of every measurement. The hook runs under macOS bash 3.2 when /bin/bash is
# that version (a PATH shim makes `#!/usr/bin/env bash` resolve to it).
# Wall time is taken around the child process only, with perl Time::HiRes.
#
# Load resistance: the paths and a no-op baseline (/bin/sh -c true) are
# measured in interleaved blocks of a few runs each, reversing the order on
# alternate cycles, so all of them share the same machine load. Read each path
# next to the baseline row. The 1-minute load average is printed at the start
# and the end.
#
# Paths:
#   subagent        payload carries agent_id, reading at the warning band
#   no_shared_file  no shared reading file
#   below_warning   reading below the warning band
#   band_marked     reading at the warning band, band already marked for the session
#   firing          reading at the warning band, no marker (emits)
#   baseline        /bin/sh -c true
#
# Usage: bash .gaia/tests/hooks/rate-limit-checkpoint-timing.sh [--runs N] [--json]
# Run it from the repo root. Default N is 50.

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
for required_file in .claude/hooks/rate-limit-checkpoint-inject.sh .gaia/scripts/rate-limits-lib.sh; do
  [ -f "$repo/$required_file" ] || { echo "missing $required_file" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture="$(cd -P "$work" && pwd)/fixture"

mkdir -p "$fixture/.claude/hooks" "$fixture/.gaia/scripts"
cp "$repo/.claude/hooks/rate-limit-checkpoint-inject.sh" "$fixture/.claude/hooks/"
cp "$repo/.claude/settings.json" "$fixture/.claude/settings.json"
for library_file in "$repo"/.gaia/scripts/*.sh; do
  cp "$library_file" "$fixture/.gaia/scripts/"
done
git -C "$fixture" init -q -b main
git -C "$fixture" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
  commit -q --allow-empty -m init

registered_command=$(jq -r '.hooks.PreToolUse[]? | .hooks[]? | .command
  | select(contains("rate-limit-checkpoint-inject.sh"))' "$fixture/.claude/settings.json" | sed -n 1p)
[ -n "$registered_command" ] || { echo "no registered rate-limit checkpoint command in settings" >&2; exit 2; }

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
. "$fixture/.gaia/scripts/rate-limits-lib.sh"

fixed_now=$(date +%s)
warning_percentage=$GAIA_RATE_LIMIT_WARNING_PERCENTAGE
below_percentage=$((warning_percentage - 1))
resets_at=$((fixed_now + 3600))
shared_file=$(gaia_rate_limits_file "$fixture")
marker_directory="$fixture/.gaia/local/cache/rate-limit-checkpoint"

uuid_counter=0
session_id=""
next_session_id() {
  uuid_counter=$((uuid_counter + 1))
  printf -v session_id '%08x-%04x-4%03x-8%03x-%08x%04x' "$$" "$uuid_counter" "$((RANDOM % 4096))" "$((RANDOM % 4096))" "$((RANDOM * RANDOM))" "$RANDOM"
}

# write_reading <percentage>: a valid shared reading holding one window.
write_reading() {
  mkdir -p "${shared_file%/*}"
  jq -n --argjson percentage "$1" --argjson resets_at "$resets_at" --argjson observed_at "$fixed_now" \
    '{version: 1, windows: {five_hour: {used_percentage: $percentage, resets_at: $resets_at, observed_at: $observed_at,
      producer: "statusline", history: [{used_percentage: $percentage, observed_at: $observed_at, producer: "statusline"}]}}}' >"$shared_file"
}

# build_payload <session id> <extra jq object>: a PreToolUse Workflow payload.
build_payload() {
  jq -nc --arg session_id "$1" --arg working_directory "$fixture" --argjson extra "$2" \
    '{hook_event_name:"PreToolUse",session_id:$session_id,cwd:$working_directory,tool_name:"Workflow",tool_input:{}} + $extra'
}

# time_one <command>: wall ms of the command run by /bin/sh -c with $work/in.json
# on stdin; stdout lands in $work/out.json.
time_one() {
  (cd "$fixture" && GAIA_RATE_LIMITS_NOW="$fixed_now" PATH="$hook_path" perl -MTime::HiRes=time -e '
    my ($in, $out, $command) = @ARGV;
    open(STDIN, "<", $in) or die; open(STDOUT, ">", $out) or die;
    open(STDERR, ">", "/dev/null") or die;
    my $start = time; system("/bin/sh", "-c", $command); my $elapsed = (time - $start) * 1000;
    open(my $milliseconds_file, ">", "$out.ms") or die; printf $milliseconds_file "%.3f\n", $elapsed;' \
    "$work/in.json" "$work/out.json" "$1")
  cat "$work/out.json.ms"
}

# prepare <label> <session id>: writes the fixture state and the payload file;
# sets $expect to emit or silent.
prepare() {
  local label="$1" sid="$2"
  expect=silent
  rm -rf "$marker_directory"
  case "$label" in
    subagent) write_reading "$warning_percentage"; build_payload "$sid" '{"agent_id":"agent-1"}' >"$work/in.json" ;;
    no_shared_file) rm -f "$shared_file"; build_payload "$sid" '{}' >"$work/in.json" ;;
    below_warning) write_reading "$below_percentage"; build_payload "$sid" '{}' >"$work/in.json" ;;
    band_marked)
      write_reading "$warning_percentage"; build_payload "$sid" '{}' >"$work/in.json"
      time_one "$registered_command" >/dev/null
      ;;
    firing) write_reading "$warning_percentage"; build_payload "$sid" '{}' >"$work/in.json"; expect=emit ;;
    baseline) build_payload "$sid" '{}' >"$work/in.json" ;;
  esac
}

load_one_minute() { uptime | sed -e 's/.*load averages*: *//' -e 's/,/ /g' | awk '{print $1}'; }

labels="subagent no_shared_file below_warning band_marked firing baseline"
failures=0
failure_notes=""
note_failure() { failures=$((failures + 1)); failure_notes="$failure_notes$1
"; }

load_start=$(load_one_minute)
[ "$json" = 1 ] || {
  echo "bash used for the hook: $bash_used"
  echo "load average (1 min) at start: $load_start"
}

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
    done
  done
  processed=$((processed + count))
  cycle=$((cycle + 1))
done
load_end=$(load_one_minute)

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

budget_of() {
  case "$1" in
    firing) echo 100 ;;
    baseline) echo null ;;
    *) echo 50 ;;
  esac
}

if [ "$json" = 1 ]; then
  rows="[]"
  for label in $labels; do
    rows=$(jq -c --arg metric "p50_${label}_ms" --argjson value "$(percentile "$label" p50)" --argjson budget "$(budget_of "$label")" \
      '. + [{metric:$metric,value:$value,unit:"ms",budget:$budget}]' <<<"$rows")
  done
  jq -n --argjson rows "$rows" --argjson injected "$injected" --argjson load_start "$load_start" --argjson load_end "$load_end" \
    '$rows + [{metric:"injected_bytes",value:$injected,unit:"bytes",budget:null},
              {metric:"load_1min_start",value:$load_start,unit:"load",budget:null},
              {metric:"load_1min_end",value:$load_end,unit:"load",budget:null}]'
else
  echo "runs per path: $runs (interleaved blocks of $block_size, baseline included)"
  for label in $labels; do
    printf '%-24s p50 %7s ms   p90 %7s ms   budget %s\n' "$label" "$(percentile "$label" p50)" "$(percentile "$label" p90)" "$(budget_of "$label")"
  done
  echo "injected_bytes (firing): $injected"
  echo "load average (1 min) at end: $load_end"
fi

if [ "$failures" -gt 0 ]; then
  printf 'FAIL: %s check(s) failed\n%s' "$failures" "$failure_notes" >&2
  exit 1
fi
exit 0
