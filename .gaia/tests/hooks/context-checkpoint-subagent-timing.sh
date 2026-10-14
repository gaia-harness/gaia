#!/usr/bin/env bash
# Local measurement tool for the sub-agent context checkpoint hook, which runs
# after every tool call of every session, main sessions included. Not a bats
# suite and not run in CI.
#
# Purpose: the hook's wall time is paid on every tool call, so its per-call exit
# paths carry a p50 budget (50 ms where every session pays it, 75 ms where only
# an opted-in sub-agent does) and its once-per-agent first-sight path and its
# firing path carry a 100 ms one. This tool measures every path and reports; it
# never tunes the hook and never enforces a budget. It fails (exit 1) only when
# it measured something other than the path it names: a firing run whose decoded
# additionalContext is empty, or a path that emits when it should stay silent.
#
# Method: builds a scratch fixture repo (git init, one commit) holding copies of
# the real hook, the scripts it loads, the yield doctrine file, and the real
# settings.json (or the file GAIA_TIMING_SETTINGS names, so the empty-context
# failure can be proven against a scratch copy whose hook command is replaced).
# The registered command string is read from the copied settings (the PostToolUse
# entry whose command names context-checkpoint-subagent.sh) and executed by
# /bin/sh -c with the fixture as cwd, so the registered rooting step is part of
# every measurement. The hook runs under macOS bash 3.2 when /bin/bash is that
# version (a PATH shim makes `#!/usr/bin/env bash` resolve to it); elsewhere a
# warning is printed and the resolved bash is used. Wall time is taken around the
# child process only, with perl Time::HiRes.
#
# Transcripts: generated sub-agent transcripts, each larger than seven
# megabytes, built once per variant from realistic assistant and tool-result
# lines. The reading in the final usage record comes from the lib's bands, so no
# band number is spelled here. Variants: below red; between red and fire; a
# final line longer than the tail read bound (the widened read runs); a first
# record close to the head read bound (the first-sight head read runs). Each run
# uses a fresh session id, so no marker survives from one run to the next.
#
# Load resistance: the paths and a no-op baseline (/bin/sh -c true, same stdin)
# are measured in interleaved blocks of a few runs each, cycling through every
# label and reversing the order on alternate cycles, so all of them share the
# same machine load. Read each path next to the baseline row. The 1-minute load
# average is printed at the start and the end of the run.
#
# Paths:
#   main_payload          no agent_id key (ends at the first raw pattern check)
#   not_opted_in_marked   marker `opt-in: none` (ends at the marker read)
#   opted_in_below_red    opted-in marker, reading below red (reads the tail)
#   band_marked           marker at the reading's band (reads the tail, exits as
#                         already marked)
#   widened_read          opted in, final line past the tail bound (tail read
#                         finds nothing, then the widened read runs)
#   first_sight           no marker, a first record near the head bound (head
#                         read, opt-in match, marker write, tail read)
#   firing                opted in, reading past red, no band marked (emits)
#   baseline              /bin/sh -c true
#
# Usage: [GAIA_TIMING_SETTINGS=<path>] bash .gaia/tests/hooks/context-checkpoint-subagent-timing.sh
#          [--runs N] [--json] [--main-hook-ms MS --median-tool-calls N]
# Run it from the repo root. Default N is 50.
#
# Per-session aggregate: with --main-hook-ms (the recorded p50 of the main
# session hook's below-red, no-marker path) and --median-tool-calls (the median
# tool calls of a main session, counted by the maintainer from their own
# transcripts), prints (main hook p50 + this hook's main_payload p50) times the
# median tool calls: the no-matcher PostToolUse chain's cost over one session.
#
# Budgets: p50 at most 50 ms on main_payload and not_opted_in_marked, the paths
# every session and every sub-agent pays; at most 75 ms on opted_in_below_red
# and band_marked, which only an opted-in sub-agent pays and which carry the
# payload confirm and the transcript tail read on every call; at most 100 ms on
# first_sight and firing; widened_read is recorded without a budget. A baseline well above a few ms
# means the machine was loaded; repeat on a quieter machine before recording.
#
# --json prints the measurement rows as an array of {metric, value, unit,
# budget} objects. Fixture and temp files are removed on exit.

set -uo pipefail

runs=50
json=0
block_size=5
main_hook_ms=""
median_tool_calls=""
while [ $# -gt 0 ]; do
  case "$1" in
    --runs)
      runs="${2:-}"
      shift 2 || { echo "--runs needs a value" >&2; exit 2; }
      ;;
    --main-hook-ms)
      main_hook_ms="${2:-}"
      shift 2 || { echo "--main-hook-ms needs a value" >&2; exit 2; }
      ;;
    --median-tool-calls)
      median_tool_calls="${2:-}"
      shift 2 || { echo "--median-tool-calls needs a value" >&2; exit 2; }
      ;;
    --json) json=1; shift ;;
    *) echo "usage: $0 [--runs N] [--json] [--main-hook-ms MS --median-tool-calls N]" >&2; exit 2 ;;
  esac
done
case "$runs" in '' | *[!0-9]* | 0) echo "--runs must be a positive integer" >&2; exit 2 ;; esac
if [ -n "$main_hook_ms$median_tool_calls" ]; then
  case "$main_hook_ms" in '' | *[!0-9.]*) echo "--main-hook-ms must be a number" >&2; exit 2 ;; esac
  case "$median_tool_calls" in '' | *[!0-9]* | 0) echo "--median-tool-calls must be a positive integer" >&2; exit 2 ;; esac
fi

for tool in jq perl git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 2; }
done

repo=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "run from inside the repo" >&2; exit 2; }
settings_source="${GAIA_TIMING_SETTINGS:-$repo/.claude/settings.json}"
for required_file in .claude/hooks/context-checkpoint-subagent.sh .claude/doctrine/context-yield.md \
  .gaia/scripts/context-checkpoint-lib.sh; do
  [ -f "$repo/$required_file" ] || { echo "missing $required_file" >&2; exit 2; }
done
[ -f "$settings_source" ] || { echo "missing settings file: $settings_source" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture="$(cd -P "$work" && pwd)/fixture"

mkdir -p "$fixture/.claude/hooks" "$fixture/.claude/doctrine" "$fixture/.gaia/scripts"
cp "$repo/.claude/hooks/context-checkpoint-subagent.sh" "$fixture/.claude/hooks/"
cp "$repo/.claude/doctrine/context-yield.md" "$fixture/.claude/doctrine/"
cp "$settings_source" "$fixture/.claude/settings.json"
for library_file in "$repo"/.gaia/scripts/*.sh; do
  cp "$library_file" "$fixture/.gaia/scripts/"
done
git -C "$fixture" init -q -b main
git -C "$fixture" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
  commit -q --allow-empty -m init

registered_command=$(jq -r '.hooks.PostToolUse[]? | .hooks[]? | .command
  | select(contains("context-checkpoint-subagent.sh"))' "$fixture/.claude/settings.json" | sed -n 1p)
[ -n "$registered_command" ] || { echo "no registered sub-agent checkpoint command in settings" >&2; exit 2; }

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

window=$GAIA_CONTEXT_DEFAULT_WINDOW
checkpoint_line=$(gaia_context_effective_line "$fixture" "$window")
read -r yellow_tokens red_tokens fire_tokens _ <<<"$(gaia_context_bands "$window" "$checkpoint_line")"
below_red_reading=$yellow_tokens
past_red_reading=$(((red_tokens + fire_tokens) / 2))
past_red_band=$(gaia_context_band "$past_red_reading" "$window" "$checkpoint_line")
marker_directory="$fixture/.gaia/local/cache/context-checkpoint-agents"
handoff_path="$fixture/.gaia/local/runs/timing/handoffs/phase-1-task-timing-yield-1.md"
agent_id=agent-timing
minimum_transcript_bytes=7340032
first_record_bytes=$((GAIA_CONTEXT_TRANSCRIPT_HEAD_BYTES - 4096))
long_final_line_bytes=$((GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES + 40000))

# build_transcript <variant> <reading tokens> <first record bytes> <final line bytes>:
# writes <work>/transcripts/<variant>/subagents/agent-<agent id>.jsonl. The first
# record is the dispatch prompt ending in the opt-in line; the body alternates
# assistant records (each with a usage object) and tool-result records; the
# last assistant record carries the reading; a nonzero final line size appends
# one tool-result record of about that size with no usage object.
build_transcript() {
  local variant="$1"
  local directory="$work/transcripts/$variant/subagents"
  mkdir -p "$directory"
  perl -e '
    my ($out, $minimum, $reading, $first_bytes, $final_bytes, $handoff) = @ARGV;
    open(my $fh, ">", $out) or die;
    my $filler_sentence = "Reading the module, tracing the call into the helper, and comparing the result against the expected shape before editing. ";
    my $prompt = "Do the task in the task doc and report back. " . ("Context for the task: " . $filler_sentence) x 4;
    my $unit = "Quoted task text. " . $filler_sentence;
    my $pad = $first_bytes > 1000 ? $unit x int(($first_bytes - 1000) / length($unit)) : "";
    printf $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"%s%s\\n\\nYield handoff: %s\"}}\n", $prompt, $pad, $handoff;
    my $written = tell($fh);
    my $turn = 0;
    my $tool_text = ("line of command output with a path /repo/src/module/file.ts and a count 42\\n") x 50;
    my $assistant_text = $filler_sentence x 8;
    my $low = 5000;
    while ($written < $minimum) {
      $turn++;
      my $tokens = $low + ($turn % 9000);
      printf $fh "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"%s\"},{\"type\":\"tool_use\",\"id\":\"toolu_%06d\",\"name\":\"Bash\",\"input\":{\"command\":\"ls -la\"}}],\"usage\":{\"input_tokens\":6,\"cache_creation_input_tokens\":%d,\"cache_read_input_tokens\":%d,\"output_tokens\":120,\"service_tier\":\"standard\",\"cache_creation\":{\"ephemeral_5m_input_tokens\":0,\"ephemeral_1h_input_tokens\":%d}}}}\n",
        $assistant_text, $turn, 800, $tokens, 800;
      printf $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_%06d\",\"content\":\"%s\"}]}}\n", $turn, $tool_text;
      $written = tell($fh);
    }
    my $creation = 800;
    my $cache_read = $reading - 6 - $creation;
    printf $fh "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"%s\"}],\"usage\":{\"input_tokens\":6,\"cache_creation_input_tokens\":%d,\"cache_read_input_tokens\":%d,\"output_tokens\":120,\"service_tier\":\"standard\"}}}\n",
      $assistant_text, $creation, $cache_read;
    if ($final_bytes > 0) {
      my $body = "x" x $final_bytes;
      printf $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_final\",\"content\":\"%s\"}]}}\n", $body;
    }
    close($fh);
  ' "$directory/agent-$agent_id.jsonl" "$minimum_transcript_bytes" "$2" "$3" "$4" "$handoff_path"
}

build_transcript below_red "$below_red_reading" 0 0
build_transcript past_red "$past_red_reading" 0 0
build_transcript widened "$below_red_reading" 0 "$long_final_line_bytes"
build_transcript first_sight "$below_red_reading" "$first_record_bytes" 0
for variant in below_red past_red widened first_sight; do
  transcript_file="$work/transcripts/$variant/subagents/agent-$agent_id.jsonl"
  transcript_size=$(wc -c <"$transcript_file" | tr -d ' ')
  [ "$transcript_size" -ge "$minimum_transcript_bytes" ] || { echo "transcript $variant is only $transcript_size bytes" >&2; exit 2; }
  tail_reading=$(gaia_context_transcript_reading "$transcript_file") || { echo "transcript $variant has no readable reading" >&2; exit 2; }
  case "$variant" in
    past_red) expected_reading=$past_red_reading ;;
    *) expected_reading=$below_red_reading ;;
  esac
  [ "$tail_reading" = "$expected_reading" ] || { echo "transcript $variant reads $tail_reading, expected $expected_reading" >&2; exit 2; }
done
widened_file="$work/transcripts/widened/subagents/agent-$agent_id.jsonl"
widened_last_line_bytes=$(tail -n 1 "$widened_file" | wc -c | tr -d ' ')
[ "$widened_last_line_bytes" -gt "$GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES" ] || { echo "widened transcript's last line is not past the tail bound" >&2; exit 2; }

uuid_counter=0
session_id=""
next_session_id() {
  uuid_counter=$((uuid_counter + 1))
  printf -v session_id '%08x-%04x-%04x-%04x-%08x%04x' "$$" "$uuid_counter" "$RANDOM" "$RANDOM" "$((RANDOM * RANDOM))" "$RANDOM"
}

write_marker() { mkdir -p "$marker_directory" && printf 'opt-in: %s\nband: %s\n' "$2" "$3" >"$marker_directory/$1.$agent_id"; }

# build_payload <session id> <variant> <subagent|main>: PostToolUse payload.
build_payload() {
  local agent_json='{"agent_id":"'"$agent_id"'"}'
  [ "$3" = subagent ] || agent_json='{}'
  jq -nc --arg session_id "$1" --arg working_directory "$fixture" \
    --arg transcript_path "$work/transcripts/$2.jsonl" --argjson extra "$agent_json" \
    '{hook_event_name:"PostToolUse",session_id:$session_id,transcript_path:$transcript_path,cwd:$working_directory,
      tool_name:"Bash",tool_input:{command:"ls"},tool_response:{stdout:"ok"}} + $extra'
}

# prepare <label> <session id>: writes the fixture state and the payload file;
# sets $expect to emit or silent.
prepare() {
  local label="$1" sid="$2"
  expect=silent
  case "$label" in
    main_payload) build_payload "$sid" below_red main >"$work/in.json" ;;
    not_opted_in_marked) write_marker "$sid" none none; build_payload "$sid" below_red subagent >"$work/in.json" ;;
    opted_in_below_red) write_marker "$sid" "$handoff_path" none; build_payload "$sid" below_red subagent >"$work/in.json" ;;
    band_marked) write_marker "$sid" "$handoff_path" "$past_red_band"; build_payload "$sid" past_red subagent >"$work/in.json" ;;
    widened_read) write_marker "$sid" "$handoff_path" none; build_payload "$sid" widened subagent >"$work/in.json" ;;
    first_sight) build_payload "$sid" first_sight subagent >"$work/in.json" ;;
    firing) write_marker "$sid" "$handoff_path" none; build_payload "$sid" past_red subagent >"$work/in.json"; expect=emit ;;
    baseline) build_payload "$sid" below_red subagent >"$work/in.json" ;;
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

labels="main_payload not_opted_in_marked opted_in_below_red band_marked widened_read first_sight firing baseline"
failures=0
failure_notes=""
note_failure() { failures=$((failures + 1)); failure_notes="$failure_notes$1
"; }

# budget_for <label>: the p50 budget in ms, or none.
budget_for() {
  case "$1" in
    first_sight | firing) echo 100 ;;
    opted_in_below_red | band_marked) echo 75 ;;
    widened_read | baseline) echo none ;;
    *) echo 50 ;;
  esac
}

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

aggregate_ms=""
if [ -n "$main_hook_ms" ]; then
  aggregate_ms=$(awk -v main="$main_hook_ms" -v subagent="$(percentile main_payload p50)" -v calls="$median_tool_calls" \
    'BEGIN { printf "%.1f\n", (main + subagent) * calls }')
fi

if [ "$json" = 1 ]; then
  rows="[]"
  for label in $labels; do
    p50=$(percentile "$label" p50)
    budget=$(budget_for "$label")
    [ "$budget" != none ] || budget=null
    rows=$(jq -c --arg metric "p50_${label}_ms" --argjson value "$p50" --argjson budget "$budget" \
      '. + [{metric:$metric,value:$value,unit:"ms",budget:$budget}]' <<<"$rows")
  done
  aggregate_value=null
  [ -z "$aggregate_ms" ] || aggregate_value=$aggregate_ms
  jq -n --argjson rows "$rows" --argjson injected "$injected" --argjson aggregate "$aggregate_value" \
    --argjson load_start "$load_start" --argjson load_end "$load_end" \
    '$rows + [{metric:"injected_bytes",value:$injected,unit:"bytes",budget:null},
              {metric:"per_session_chain_ms",value:$aggregate,unit:"ms",budget:null},
              {metric:"load_1min_start",value:$load_start,unit:"load",budget:null},
              {metric:"load_1min_end",value:$load_end,unit:"load",budget:null}]'
else
  echo "runs per path: $runs (interleaved blocks of $block_size, baseline included)"
  for label in $labels; do
    printf '%-24s p50 %7s ms   p90 %7s ms   budget %s\n' "$label" "$(percentile "$label" p50)" "$(percentile "$label" p90)" "$(budget_for "$label")"
  done
  echo "budget: p50 in ms (baseline is the machine's process-spawn floor, not a path)"
  echo "injected_bytes (firing): $injected"
  if [ -n "$aggregate_ms" ]; then
    echo "per-session chain: ($main_hook_ms + $(percentile main_payload p50)) ms x $median_tool_calls tool calls = $aggregate_ms ms"
  else
    echo "per-session chain: not computed (pass --main-hook-ms and --median-tool-calls)"
  fi
  echo "load average (1 min) at end: $load_end"
fi

if [ "$failures" -gt 0 ]; then
  printf 'FAIL: %s check(s) failed\n%s' "$failures" "$failure_notes" >&2
  exit 1
fi
exit 0
