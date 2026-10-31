# shellcheck shell=bash
#
# The PR-body renderer and the residual recorder of audit-dispositions-check.sh,
# split out to keep that script small. Sourced by it, and it relies on the
# caller's _error, _load_vetoes, _valid_dispositions, _round_lookup,
# _divert_line, _TEMPORARY_FILES, _TRIAGE_MEMBERS, _GAIA_DISPOSITIONS_DIRECTORY,
# RUN_FOLDER and FINDING_FILE. Runs nothing at source time. Never `cd`s.

# The text normalization every rendered reason goes through. A `-->` would end
# the keyed comment the residue tally parses, and a line break would shift the
# screen's one-row-per-line verdicts onto the wrong rows.
# shellcheck disable=SC2016
_ROW_TEXT_JQ='
def trim: gsub("^\\s+|\\s+$"; "");
def one: gsub("<!--|-->"; "") | gsub("\\s+"; " ") | trim | if . == "" then "no reason recorded" else . end;
def text($value): (if ($value | type) == "string" then $value else "" end) | one;
def line_of: if type == "number" and . >= 1 then . else 1 end;
'

# _ROWS_JQ: one round's PR-body candidate rows. A waiver or triage row exists
# only inside the render bound (the lookup says security false and severity
# not critical); divert rows carry no reason, since only their count is rendered.
# shellcheck disable=SC2016
_ROWS_JQ="$_ROW_TEXT_JQ"'
def key_array: [.member, .finding_class, .path, .line];
def in_bound: . != null and .security == false and .severity != "critical";
($vetoes | map(select(.effective_from_round <= $round) | [.member, .finding_class, .path, .line])) as $vetoed_keys
| ($lookup | map({key: (key_array | tojson), value: .}) | from_entries) as $lookup_by_key
| [.entries[] | key_array] as $disposed_keys
| [ (.entries[] | select(.disposition != "fix") | select(key_array as $key | $vetoed_keys | any(. == $key) | not)
      | $lookup_by_key[(key_array | tojson)] as $lookup_entry
      | (if .disposition == "accept-residual" then "accept"
         elif .disposition == "divert" then "divert"
         elif .disposition != "waive-out-of-scope" then ""
         elif (($lookup_entry | in_bound) | not) then ""
         elif .basis == "cross-remit" then "cross"
         elif .basis == "triage-threshold" then "triage"
         else "" end) as $section
      | select($section != "")
      | {round: $round, section: $section, member, path, line, finding_class,
         reason: (if $section == "divert" then "" else text(.reason) end)}),
    ($lookup[] | select(.triage == true and (.member | IN($triage_members[])) and in_bound)
      | select(key_array as $key | ($disposed_keys | any(. == $key)) or ($vetoed_keys | any(. == $key)) | not)
      | {round: $round, section: "triage", member, path, line, finding_class, reason: text(.triage_reason)}) ]
'

# _RECORDED_JQ: the recorded residuals as accept rows, read as raw lines so a
# line that does not parse is skipped. A key some round disposed fix, or a veto
# names, is dropped: a finding is never both fixed and accepted.
# shellcheck disable=SC2016
_RECORDED_JQ="$_ROW_TEXT_JQ"'
[inputs | fromjson?
  | select(type == "object" and (.member | type) == "string" and (.finding_class | type) == "string"
      and (.path | type) == "string" and (.line | type) == "number")
  | select([.finding_class, .path, (.line | line_of)] as $key | $dropped | any(. == $key) | not)
  | {round: 0, section: "accept", member, path, line: (.line | line_of), finding_class, reason: text(.reason)}]
'

# shellcheck disable=SC2016
_SECTIONS_JQ='
def line_number: if (.line | type) == "number" and .line >= 1 then .line else 1 end;
def keyed: "- `\(.path):\(line_number)` \(.reason). <!-- gaia-debt-key: v1 class=\(.finding_class) path=\(.path) line=\(line_number) -->";
def triage: "- \(.path):\(line_number) \(.finding_class): \(.reason)";
def withheld($count; $noun): "- \($count) \($noun) withheld: reason failed the secret screen";
def section($head; $rows; fmt; $noun):
  if ($rows | length) == 0 then empty
  else ($rows | map(select(.clean))) as $shown | (($rows | length) - ($shown | length)) as $withheld_count
    | ([$head, ""] + ($shown | map(fmt)) + (if $withheld_count > 0 then [withheld($withheld_count; $noun)] else [] end)) | join("\n") end;
. as $rows
| ([$rows[] | select(.section != "divert")] | to_entries | map(.value + {clean: ($clean[.key] == true)})) as $screened
| [ section("## Accepted residuals (recorded, not fixed)"; ($screened | map(select(.section == "accept"))); keyed; "accepted residual(s)"),
    section("## Out-of-scope machinery findings (recorded, not filed)"; ($screened | map(select(.section == "cross"))); keyed; "waived finding(s)"),
    section("## Waived below triage threshold (not filed)"; ($screened | map(select(.section == "triage"))); triage; "waived finding(s)"),
    (if $divert_line == "" then empty else $divert_line end),
    (if ($absent | length) == 0 and $pending == 0 then empty
     else (["## Not filed (no issue backend)", ""]
       + ($absent | map("- \(.member) \(.path):\(line_number) (\(.finding_class)): not filed, no issue backend"))
       + (if $pending > 0 then ["- \($pending) finding(s) pending: the issue backend was unreachable; retried next round"] else [] end))
       | join("\n") end) ]
| join("\n\n")
'

# _absent_outcomes: the keys whose latest outcome across the rounds' outcome
# files is a file disposition left absent (no issue backend). Lines that do
# not parse are skipped: this renders a record, it does not grade one.
_absent_outcomes() {
  local outcome_file base round chunks=""
  for outcome_file in "$RUN_FOLDER"/filing-outcomes-*.jsonl; do
    [ -e "$outcome_file" ] || continue
    base="${outcome_file##*/}"
    [[ "$base" =~ ^filing-outcomes-([0-9]+)\.jsonl$ ]] || continue
    round=$((10#${BASH_REMATCH[1]}))
    chunks="$chunks$(jq -c -R --argjson round "$round" 'fromjson? | select(type == "object" and (.key | type) == "object") | . + {round: $round}' <"$outcome_file" 2>/dev/null)"$'\n'
  done
  printf '%s' "$chunks" | jq -c -s 'sort_by(.round) | group_by(.key | [.member, .finding_class, .path, .line]) | map(last)
    | map(select(.outcome == "absent" and .disposition == "file") | .key | {member, finding_class, path, line})
    | sort_by(.path, .line, .finding_class)'
}

# _pending_count: the retry files the filing script keeps for transient outcomes.
_pending_count() {
  local retry_file count=0
  for retry_file in "$RUN_FOLDER"/filing-retry/*.json; do
    [ -f "$retry_file" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# _screen_reasons <texts> <scratch-file>: a JSON array of booleans, true for
# each line of <texts> that passes the secret screen. rc 3 when the screen
# cannot run.
_screen_reasons() {
  local text_file="$2" reason_text verdicts="" screen_status
  [ -n "$1" ] || { printf '[]\n'; return 0; }
  while IFS= read -r reason_text; do
    printf '%s\n' "$reason_text" >"$text_file"
    screen_status=0
    bash "$_GAIA_DISPOSITIONS_DIRECTORY/file-tech-debt.sh" screen-text --text-file "$text_file" >/dev/null 2>&1 || screen_status=$?
    case "$screen_status" in
      0) verdicts="$verdicts,true" ;;
      1) verdicts="$verdicts,false" ;;
      *) _error "the secret screen could not run (exit $screen_status)"; return 3 ;;
    esac
  done <<<"$1"
  printf '[%s]\n' "${verdicts#,}"
}

# _recorded_rows <vetoes> <fixed-keys>: the recorded-residuals file as accept
# rows, "[]" when it is absent. rc 3 when jq fails.
_recorded_rows() {
  local recorded_file="$RUN_FOLDER/recorded-residuals.jsonl" dropped
  [ -f "$recorded_file" ] || { printf '[]\n'; return 0; }
  dropped="$(jq -c -n --argjson vetoes "$1" --argjson fixed "$2" "$_ROW_TEXT_JQ"'
    $fixed + [$vetoes[] | [.finding_class, .path, (.line | line_of)]]' 2>/dev/null)" || return 3
  jq -c -R -n --argjson dropped "$dropped" "$_RECORDED_JQ" <"$recorded_file" 2>/dev/null || return 3
}

_command_pr_sections() {
  local dispositions_file base round chunks="" one lookup rows texts text_file clean absent pending divert_count divert_line=""
  local fixed="[]" round_fixed recorded
  _load_vetoes || return 3
  for dispositions_file in "$RUN_FOLDER"/dispositions-*.json; do
    [ -e "$dispositions_file" ] || continue
    base="${dispositions_file##*/}"
    [[ "$base" =~ ^dispositions-([0-9]+)\.json$ ]] || continue
    round=$((10#${BASH_REMATCH[1]}))
    _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
    lookup="$(_round_lookup "$round")"
    one="$(jq -c --argjson round "$round" --argjson vetoes "$VETOES" --argjson lookup "$lookup" \
      --argjson triage_members "$_TRIAGE_MEMBERS" "$_ROWS_JQ" "$dispositions_file")" || return 3
    chunks="$chunks$one"$'\n'
    round_fixed="$(jq -c "$_ROW_TEXT_JQ"'[.entries[] | select(.disposition == "fix") | [.finding_class, .path, (.line | line_of)]]' "$dispositions_file")" || return 3
    fixed="$(jq -c -n --argjson fixed "$fixed" --argjson round_fixed "$round_fixed" '$fixed + $round_fixed')" || return 3
  done
  recorded="$(_recorded_rows "$VETOES" "$fixed")" || { _error "unreadable $RUN_FOLDER/recorded-residuals.jsonl"; return 3; }
  chunks="$chunks$recorded"$'\n'
  rows="$(printf '%s' "$chunks" | jq -c -s 'add // [] | sort_by(-.round) | unique_by([.section, .path, .line, .finding_class]) | sort_by(.path, .line, .finding_class)')" || return 3
  texts="$(printf '%s' "$rows" | jq -r '.[] | select(.section != "divert") | .reason')" || return 3
  text_file="$(mktemp "${TMPDIR:-/tmp}/audit-dispositions-reason.XXXXXX")" || { _error "cannot create a scratch file"; return 3; }
  _TEMPORARY_FILES+=("$text_file")
  clean="$(_screen_reasons "$texts" "$text_file")" || return 3
  absent="$(_absent_outcomes)" || return 3
  pending="$(_pending_count)"
  divert_count="$(printf '%s' "$rows" | jq '[.[] | select(.section == "divert")] | length')" || return 3
  [ "$divert_count" -eq 0 ] || divert_line="$(_divert_line "$divert_count")"
  printf '%s' "$rows" | jq -r --argjson clean "$clean" --argjson absent "$absent" --argjson pending "$pending" \
    --arg divert_line "$divert_line" "$_SECTIONS_JQ" || return 3
}

# _command_record_residual: append one filing-replay row for the finding in
# FINDING_FILE to the run's recorded residuals, once per key. The reason is
# stored as given; pr-sections normalizes it on read. rc 3 on an unreadable
# finding.
_command_record_residual() {
  local recorded_file="$RUN_FOLDER/recorded-residuals.jsonl" row
  row="$(jq -c '
    if type == "object" and (.member | type) == "string" and (.finding_class | type) == "string"
       and (.path | type) == "string" and (.line | type) == "number"
    then {source: "filing-replay", member, finding_class, path, line, reason: (if (.failure_mode | type) == "string" then .failure_mode else "" end)}
    else error("unreadable finding") end' "$FINDING_FILE" 2>/dev/null)" || { _error "unreadable finding $FINDING_FILE"; return 3; }
  [ -n "$row" ] || { _error "unreadable finding $FINDING_FILE"; return 3; }
  if [ -f "$recorded_file" ] && jq -e -R -n --argjson row "$row" "$_ROW_TEXT_JQ"'
      [inputs | fromjson? | select(type == "object") | [.finding_class, .path, (.line | line_of)]]
      | any(. == ($row | [.finding_class, .path, (.line | line_of)]))' <"$recorded_file" >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$RUN_FOLDER" 2>/dev/null || { _error "cannot create $RUN_FOLDER"; return 3; }
  printf '%s\n' "$row" >>"$recorded_file" || { _error "cannot write $recorded_file"; return 3; }
}
