# shellcheck shell=bash
#
# The offer mode of debt-batch-budget.sh, split out to keep that script under
# the harness line limit. Sourced, never executed, by that script in offer mode
# only, after it has parsed its arguments and defined $shared_definitions, the
# DEBT_BUDGET_* constants, die_usage and die_input. run_offer reads the parsed
# backlog_file, report_file, probe_report_file and withheld globals. The offer
# contract (inputs, eligibility, output, exit codes) is in that script's header.
#
# shellcheck disable=SC2154

# The offer program: a linear first-fit walk over the report's batch parts, each
# part scored with the shared definitions together with the members already
# kept. It never calls fitting(), whose subset enumeration is combinatorial.
# shellcheck disable=SC2016
offer_program="$shared_definitions"'
def report_error:
  if ($backlog_documents | length) != 1 or ($backlog_documents[0] | type) != "array"
  then "the backlog is not a single JSON array"
  elif ($report_documents | length) != 1 or ($report_documents[0] | type) != "object"
       or ($report_documents[0].candidates | type) != "array"
       or ($report_documents[0].clusters | type) != "array"
       or ($report_documents[0].clusters | any(.[]; type != "object" or (.members | type) != "array"))
  then "the report is not a backlog report"
  elif ($probe_documents | length) > 1
       or (($probe_documents | length) == 1 and ($probe_documents[0] | type) != "array")
  then "the probe report is not a single JSON array"
  else null end;

def run:
  $backlog_documents[0] as $backlog
  | $report_documents[0] as $report
  | ($probe_documents[0] // []) as $probe
  | (reduce ($backlog | to_entries[]) as $row ({};
      if ($row.value | type) == "object" and ($row.value.number | type) == "number"
         and (has($row.value.number | tostring) | not)
      then .[$row.value.number | tostring] = {issue: $row.value, position: $row.key}
      else . end)) as $by_number
  | ($report.candidates) as $candidates
  | ($candidates | map(tostring)) as $candidate_keys
  | ([$report.clusters[].members[]] | map(tostring)) as $cluster_keys
  | ($candidates | map(select((type) != "number" or ($by_number[tostring] | not)))
      | first // null) as $absent_candidate
  | ($report.clusters | map(.members[] | . as $member
        | select(($member | type) != "number" or ($candidate_keys | index($member | tostring) | not)))
      | first // null) as $stray_member
  | ($candidates | map(select(type == "number" and ($by_number[tostring] != null)
                              and ($by_number[tostring].issue.sev | type) != "number"))
      | first // null) as $unscored
  | ($withheld | map(select($by_number[tostring] | not)) | first // null) as $withheld_absent
  | if $absent_candidate != null then {error: "candidate \($absent_candidate) is not in the backlog"}
    elif $stray_member != null then {error: "cluster member \($stray_member) is not among the candidates"}
    elif $unscored != null then {error: "issue \($unscored) has no numeric sev"}
    elif $withheld_absent != null then {error: "withheld issue \($withheld_absent) is not in the backlog"}
    else
      (reduce ($probe[] | select(type == "object" and .status == "gone" and (.number | type) == "number") | .number)
         as $number ({}; .[$number | tostring] = true)) as $gone
      | (reduce $withheld[] as $number ({}; .[$number | tostring] = true)) as $held
      | def eligible($number):
          $by_number[$number | tostring].issue as $issue
          | $issue.sev == 1
            and $issue.difficulty != "hard"
            and $issue.footprint != "spec"
            and ($gone[$number | tostring] | not)
            and ($held[$number | tostring] | not);
        def position_of($number): $by_number[$number | tostring].position;
        (($report.clusters | map(.members | sort_by(position_of(.))))
          + ($candidates | map(select(. as $number | $cluster_keys | index($number | tostring) | not) | [.]))
        ) as $parts
      | ($parts | sort_by(position_of(.[0]))
          | map(select(all(.[]; eligible(.))))) as $eligible_parts
      | (reduce $eligible_parts[] as $part ({kept: [], parts: []};
          ($part | map(. as $number | member_of($by_number[$number | tostring].issue;
                                                position_of($number)))) as $added
          | (.kept + $added) as $trial
          | if total_of($trial; [range(0; ($trial | length))]) <= $limit
            then {kept: $trial, parts: (.parts + [$part])}
            else . end)) as $walk
      | if ($walk.parts | length) < 2
        then {members: [], total: 0, budget: $limit, parts: []}
        else ($walk.kept | sort_by(.position)) as $ordered
          | {members: ($ordered | map(.number)),
             total: total_of($walk.kept; [range(0; ($walk.kept | length))]),
             budget: $limit,
             parts: $walk.parts}
        end
    end;

report_error as $problem
| if $problem != null then {error: $problem}
  else run
  end
'

# run_offer: all three inputs reach jq through --slurpfile, never a shell string.
run_offer() {
  local file element withheld_json="[" seen=","
  for file in "$backlog_file" "$report_file"; do
    [ -f "$file" ] && [ -r "$file" ] || die_input "cannot read $file"
    jq -e true -- "$file" >/dev/null 2>&1 || die_input "$file is empty or not valid JSON"
  done
  if [ -n "$probe_report_file" ]; then
    [ -f "$probe_report_file" ] && [ -r "$probe_report_file" ] || die_input "cannot read $probe_report_file"
    jq -e true -- "$probe_report_file" >/dev/null 2>&1 || die_input "$probe_report_file is empty or not valid JSON"
  else
    probe_report_file=/dev/null
  fi

  if [ -n "$withheld" ]; then
    case "$withheld" in
      , | ,* | *, | *,,*) die_usage "--withheld needs comma-separated issue numbers without empty elements" ;;
    esac
    local -a elements
    IFS=, read -r -a elements <<<"$withheld"
    for element in ${elements[@]+"${elements[@]}"}; do
      case "$element" in
        "" | 0* | *[!0-9]*) die_usage "withheld numbers must be positive integers without leading zeros: $element" ;;
      esac
      case "$seen" in *",$element,"*) die_usage "withheld number $element is repeated" ;; esac
      seen="$seen$element,"
      withheld_json="$withheld_json$element,"
    done
    withheld_json="${withheld_json%,}"
  fi
  withheld_json="$withheld_json]"

  document="$(jq -n \
    --slurpfile backlog_documents "$backlog_file" \
    --slurpfile report_documents "$report_file" \
    --slurpfile probe_documents "$probe_report_file" \
    --argjson withheld "$withheld_json" \
    --argjson easy "$DEBT_BUDGET_COST_EASY" \
    --argjson medium "$DEBT_BUDGET_COST_MEDIUM" \
    --argjson hard "$DEBT_BUDGET_COST_HARD" \
    --argjson surcharge "$DEBT_BUDGET_WIDE_SURCHARGE" \
    --argjson limit "$DEBT_BUDGET_LIMIT" \
    "$offer_program")" || die_input "jq failed while building the offer"
  reason="$(printf '%s' "$document" | jq -r '.error // empty')" \
    || die_input "jq failed while reading its own result"
  [ -z "$reason" ] || die_usage "$reason"
  printf '%s\n' "$document"
}
