# shellcheck shell=bash
# Judges one headless review child's result file. Sourced, never executed; does
# no work at source time. Bash 3.2 compatible. Never `cd`s.
#
# This parser is the trust boundary over untrusted text: the review's prose can
# quote a diff, so it never decides anything and never counts findings. Only the
# result's own structured fields and one exact fenced array do. One exception: a
# string result that begins with Not logged in AND carries total_cost_usd of 0
# reads as not logged in, because a child with no credentials did no billed work. Every value
# reaches jq as an input file, stdin or --rawfile, never interpolated into a program.
#
#   gaia_review_judge <result-json-file>
#     Prints one line of JSON and returns 0:
#       {"verdict":"ran","reason":null,"findings":[{file,line,summary,failure_scenario}...]}
#       {"verdict":"no findings","reason":null,"findings":[]}
#       {"verdict":"failed","reason":"<closed reason>","findings":[]}
#     The caller owns the first check of the order, exit 0, since this function
#     sees a file and no process. A clean review is exactly one closed fenced
#     empty array. A diff could plant a fenced empty array and read as no
#     findings; that blocks nothing, since the members still run, so it is an
#     accepted limit with no defense.
#
#   gaia_review_denials <result-json-file> <guard-log-file>
#     Prints {"count":n,"tools":[...],"detail":[{tool,path}...]}. The count is the
#     larger of the two sources rather than their sum: the same denial can appear
#     in both, and if the sets are disjoint the count is low by the smaller one
#     and still nonzero, which is all the outcome depends on. A hook-blocked read
#     the result omits therefore cannot pass as no denial.
#
#   gaia_review_result_facts <result-json-file>
#     Prints {"cost":number|"unknown","model":string|null}.

# Size bounds, each generous enough for a large real review and low enough that
# one hostile result cannot inflate a member's prompt. A
# path longer than a real tree's is not a path; a summary or failure scenario
# past these lengths is a payload, not a finding; 500 items is far past any real
# branch review. One item out of bounds refuses the whole result, because
# dropping it would let the text choose which findings survive.
# shellcheck disable=SC2016
_GAIA_REVIEW_JUDGE_PROGRAM='
def failed($reason): {verdict: "failed", reason: $reason, findings: []};
def fenced_blocks:
  reduce (split("\n")[]) as $line ({open: false, blocks: [], current: []};
    if .open then
      if $line == "```" then .blocks += [.current | join("\n")] | .current = [] | .open = false
      else .current += [$line] end
    elif $line == "```json" then .open = true
    else . end);
def valid_path:
  type == "string" and length >= 1 and length <= 1024
  and (startswith("/") | not)
  and (any(split("/")[]; . == "..") | not)
  and (test("[\\x00-\\x1f]") | not);
def valid_item:
  type == "object"
  and (.file | valid_path)
  and (.line | type == "number" and . == floor and . >= 1)
  and (.summary | type == "string" and length <= 2000)
  and (.failure_scenario | type == "string" and length <= 8000);
def judge_text:
  fenced_blocks as $fence
  | if $fence.open or ($fence.blocks | length) != 1 then failed("unusable result")
    else (try ($fence.blocks[0] | fromjson) catch null) as $parsed
      | if ($parsed | type) != "array" then failed("unusable result")
        elif ($parsed | length) == 0 then {verdict: "no findings", reason: null, findings: []}
        elif ($parsed | length) > 500 or (all($parsed[]; valid_item) | not) then failed("unusable result")
        else {verdict: "ran", reason: null,
              findings: ($parsed | map({file, line, summary, failure_scenario}))}
        end
    end;
if type != "object" then failed("unusable result")
elif .is_error != false or .subtype != "success" then failed("error result")
elif .local_command != "code_review" then failed("not the built-in")
elif (.result | type) != "string" then failed("unusable result")
# A child with no credentials still exits 0 with a success-shaped result.
elif .total_cost_usd == 0 and (.result | startswith("Not logged in")) then failed("not logged in")
else .result | judge_text
end'

_gaia_review_unusable='{"verdict":"failed","reason":"unusable result","findings":[]}'

gaia_review_judge() {
  local result_file="$1" verdict
  # -s and the length check: a file holding two JSON values is not one result,
  # and an empty file parses to nothing at all.
  if ! jq -e -s 'length == 1' "$result_file" >/dev/null 2>&1; then
    printf '%s\n' "$_gaia_review_unusable"
    return 0
  fi
  verdict="$(jq -c "$_GAIA_REVIEW_JUDGE_PROGRAM" "$result_file" 2>/dev/null)" || verdict=""
  if [ -z "$verdict" ]; then verdict="$_gaia_review_unusable"; fi
  printf '%s\n' "$verdict"
}

gaia_review_denials() {
  local result_file="$1" guard_log="$2"
  [ -f "$guard_log" ] || guard_log=/dev/null
  # The first jq filters to the one field, so the second never takes a result
  # file through an argument: a large result would pass the exec size limit.
  { jq -c 'if type == "object" and (.permission_denials | type) == "array" then .permission_denials else [] end' \
    "$result_file" 2>/dev/null || printf '[]\n'; } \
    | jq -c -s --rawfile guard "$guard_log" '
      (.[0] // []) as $reported
      | ($guard | split("\n") | map(select(length > 0))) as $lines
      | [$lines[] | (try fromjson catch null) | select(type == "object")] as $logged
      | ($reported | map({tool: (.tool_name // "unknown"),
          path: (.tool_input.file_path // .tool_input.path // .tool_input.command // null)})) as $from_result
      | ($logged | map({tool: (.tool // "unknown"), path: (.path // null)})) as $from_guard
      | {count: ([($reported | length), ($lines | length)] | max),
         tools: ([($from_result + $from_guard)[].tool] | unique),
         detail: ($from_result + $from_guard)}'
}

gaia_review_result_facts() {
  jq -c -s '
    if length == 1 and (.[0] | type) == "object" then .[0]
      | {cost: (if (.total_cost_usd | type) == "number" then .total_cost_usd else "unknown" end),
         model: (if (.modelUsage | type) == "object" and (.modelUsage | length) > 0
                 then (.modelUsage | to_entries | max_by(.value.costUSD // 0) | .key) else null end)}
    else {cost: "unknown", model: null} end' "$1" 2>/dev/null \
    || printf '{"cost":"unknown","model":null}\n'
}
