# shellcheck shell=bash
#
# The PR-body renderer, the residual counter and the residual recorder of
# audit-dispositions-check.sh, split out to keep that script small. Sourced by
# it, and it relies on the caller's _error, _load_vetoes, _valid_dispositions,
# _round_lookup, _has_snapshot, _snapshot_path, _evaluator, _divert_line, _carried_keys,
# _RESIDUAL_REASON_JQ, _SECURITY_CLASS_JQ, _TEMPORARY_FILES, _TRIAGE_MEMBERS,
# _GAIA_DISPOSITIONS_DIRECTORY, ROOT, RUN_FOLDER, VETOES, FINDING_FILE and DECISION. Runs nothing at source time. Never `cd`s.

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
# An accept row drops a key any veto names, whatever its round: the veto
# repairs it, so it is no longer a residual. Waiver rows drop a key only for
# the rounds its veto binds.
# shellcheck disable=SC2016
_ROWS_JQ="$_ROW_TEXT_JQ$_RESIDUAL_REASON_JQ"'
def key_array: [.member, .finding_class, .path, .line];
def in_bound: . != null and .security == false and .severity != "critical";
($vetoes | map(select(.effective_from_round <= $round) | [.member, .finding_class, .path, .line])) as $vetoed_keys
| ($vetoes | map([.member, .finding_class, .path, .line])) as $ever_vetoed_keys
| ($lookup | map({key: (key_array | tojson), value: .}) | from_entries) as $lookup_by_key
| [.entries[] | key_array] as $disposed_keys
| [ (.entries[] | select(.disposition != "fix")
      | select(key_array as $key | ($vetoed_keys | any(. == $key))
          or (.disposition == "accept-residual" and ($ever_vetoed_keys | any(. == $key))) | not)
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
         reason: (if $section == "divert" then "" elif $section == "accept" then text(residual_reason($lookup_entry)) else text(.reason) end)}),
    ($lookup[] | select(.triage == true and (.member | IN($triage_members[])) and in_bound)
      | select(key_array as $key | ($disposed_keys | any(. == $key)) or ($vetoed_keys | any(. == $key)) | not)
      | {round: $round, section: "triage", member, path, line, finding_class, reason: text(.triage_reason)}) ]
'

# _RECORDED_JQ: the recorded residuals as PR-body rows, read as raw lines so a
# line that does not parse is skipped. A human's waive renders as a triage
# waiver and a human's fix renders nothing; every other row is an accept. The
# latest row for a member's key decides it, so a corrected decision replaces the
# earlier one. A key some round disposed fix, or a veto names, is dropped: a
# finding is never both fixed and accepted. So is a row whose key a later
# round re-reports security-class, which needs its own disposition.
# shellcheck disable=SC2016
_RECORDED_JQ="$_ROW_TEXT_JQ"'
[inputs | fromjson?
  | select(type == "object" and (.member | type) == "string" and (.finding_class | type) == "string"
      and (.path | type) == "string" and (.line | type) == "number")]
| to_entries | group_by(.value | [.member, .finding_class, .path, (.line | line_of)]) | map(max_by(.key) | .value)
| [.[] | select(.decision != "fix")
  | select([.finding_class, .path, (.line | line_of)] as $key | $dropped | any(. == $key) | not)
  | select((if (.round | type) == "number" then .round else 0 end) as $round | [.member, .finding_class, .path, (.line | line_of)] as $key
      | $escalated | any(.[0] > $round and .[1:] == $key) | not)
  | {round: 0, section: (if .decision == "waive" then "triage" else "accept" end), member, path, line: (.line | line_of),
     finding_class, reason: text(.reason), source: (if (.source | type) == "string" then .source else "" end)}]
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

# _recorded_rows <vetoes> <fixed-keys> <escalated>: the recorded-residuals file
# as accept rows, "[]" when it is absent. <escalated> holds [round, member,
# finding_class, path, line] per security-class finding. rc 3 when jq fails.
_recorded_rows() {
  local recorded_file="$RUN_FOLDER/recorded-residuals.jsonl" dropped
  [ -f "$recorded_file" ] || { printf '[]\n'; return 0; }
  dropped="$(jq -c -n --argjson vetoes "$1" --argjson fixed "$2" "$_ROW_TEXT_JQ"'
    $fixed + [$vetoes[] | [.finding_class, .path, (.line | line_of)]]' 2>/dev/null)" || return 3
  jq -c -R -n --argjson dropped "$dropped" --argjson escalated "$3" "$_RECORDED_JQ" <"$recorded_file" 2>/dev/null || return 3
}

# _ESCALATED_JQ: $escalated plus one round's security-class findings as
# [round, member, finding_class, path, line], read from a lookup or the open
# round's live read.
# shellcheck disable=SC2016
_ESCALATED_JQ="$_ROW_TEXT_JQ$_SECURITY_CLASS_JQ"'$escalated + [.[] | select(security_class) | [$round, .member, .finding_class, .path, (.line | line_of)]]'

# _section_rows: every round's candidate rows and the recorded ones, one per
# (section, key) with the latest round winning, sorted for rendering. The
# caller has loaded VETOES. rc 3 on an unreadable input.
_section_rows() {
  local dispositions_file base round chunks="" one lookup fixed="[]" round_fixed recorded escalated="[]" history open_entries
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
    escalated="$(printf '%s' "$lookup" | jq -c --argjson round "$round" --argjson escalated "$escalated" "$_ESCALATED_JQ")" || return 3
  done
  history="$(_evaluator round-history)" || { _error "the evaluator could not read the round history"; return 3; }
  open_entries="$(_open_round_entries "$history")" || { _error "the evaluator could not read the open round's findings"; return 3; }
  if [ "$open_entries" != null ]; then
    escalated="$(printf '%s' "$open_entries" | jq -c --argjson round "$(printf '%s' "$history" | jq 'length')" --argjson escalated "$escalated" "$_ESCALATED_JQ")" || return 3
  fi
  recorded="$(_recorded_rows "$VETOES" "$fixed" "$escalated")" || { _error "unreadable $RUN_FOLDER/recorded-residuals.jsonl"; return 3; }
  chunks="$chunks$recorded"$'\n'
  printf '%s' "$chunks" | jq -c -s 'add // [] | sort_by(-.round) | unique_by([.section, .path, .line, .finding_class]) | sort_by(.path, .line, .finding_class)'
}

_command_pr_sections() {
  local rows texts text_file clean absent pending divert_count divert_line=""
  _load_vetoes || return 3
  rows="$(_section_rows)" || return 3
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

# _command_residual_count: {"total","ask"} over the accepted residuals
# pr-sections renders, withheld ones included. ask counts what the residual
# question lists: rows of a round whose default stop held with no human
# accept (from its version-3 snapshot, else the live evaluator) and
# filing-replay rows. Worthiness rows are out: no member owns them, so a veto
# on one could never be cleared. ask is 0 after a closing latest round, since
# a spent accept admits no unit to fix anything chosen. rc 3 when an input or
# the evaluator fails.
_command_residual_count() {
  local rows history round round_stop asking="[]"
  _load_vetoes || return 3
  rows="$(_section_rows)" || return 3
  history="$(_evaluator round-history)" || { _error "the evaluator could not read the round history"; return 3; }
  for round in $(printf '%s' "$rows" | jq -r '[.[] | select(.section == "accept" and .round > 0) | .round] | unique | .[]'); do
    round_stop=""
    if _has_snapshot "$round"; then
      round_stop="$(jq -c 'select(.version == 3) | [.default_stop == true, .human_accept == true]' <"$(_snapshot_path "$round")" 2>/dev/null)" || round_stop=""
    fi
    if [ -z "$round_stop" ]; then
      round_stop="$(_evaluator evaluate-round --round "$round" | jq -c --argjson history "$history" --argjson round "$round" \
        '[.default_stop == true, any($history[]; .round == $round and .human_accept == true)]')" ||
        { _error "the evaluator could not read round $round"; return 3; }
    fi
    [ "$round_stop" = "[true,false]" ] && asking="$(jq -n -c --argjson asking "$asking" --argjson round "$round" '$asking + [$round]')"
  done
  printf '%s' "$rows" | jq -c --argjson history "$history" --argjson asking "$asking" '[.[] | select(.section == "accept")] as $accepted
    | {total: ($accepted | length),
       ask: (if ($history | last | .closing) == true then 0
             else [$accepted[] | select((.round == 0 and .source == "filing-replay") or (.round as $round | $asking | any(. == $round)))] | length end)}'
}

# _open_round_entries <round-history>: the latest round's findings read live,
# with severity and security, while that round is still open (no dispositions
# file, and the bound hook has not stored its keys, which it does at the next
# dispatch, before the next round's members overwrite the sidecars); "null"
# once it is not. rc 3 on an unreadable input.
_open_round_entries() {
  local latest entries
  latest="$(printf '%s' "$1" | jq 'length')" || return 3
  if [ "$latest" -ge 1 ] && [ ! -f "$RUN_FOLDER/dispositions-$latest.json" ] && printf '%s' "$1" | jq -e 'last | .keys == null' >/dev/null; then
    entries="$(_evaluator findings --round "$latest" | jq -c '.entries | map({member, finding_class, path, line, severity, security})')" || return 3
    [ -n "$entries" ] || return 3
    printf '%s\n' "$entries"
  else
    printf 'null\n'
  fi
}

# _undecided_keys: `violation: undecided` for each finding of a round that has
# no dispositions file (a needs-human stop), unless a recorded row written in that
# round or later decides its member's key, a later round's dispositions file names it, or _carried_keys
# carries it into that round. An accepted key carries only while its re-report
# is not security-class, which only the open round's live read shows, so in an
# older round it needs a decision again. A stored round's keys come from the
# round history; the open round's are read live. rc 0 none, 1 some, 3 an
# unreadable input.
_undecided_keys() {
  local history open_entries recorded="[]" disposed="[]" carried="{}" dispositions_file base round violations
  history="$(_evaluator round-history)" || return 3
  open_entries="$(_open_round_entries "$history")" || return 3
  for dispositions_file in "$RUN_FOLDER"/dispositions-*.json; do
    base="${dispositions_file##*/}"
    [[ "$base" =~ ^dispositions-([0-9]+)\.json$ ]] && [ -f "$dispositions_file" ] || continue
    round=$((10#${BASH_REMATCH[1]}))
    disposed="$(jq -c --argjson disposed "$disposed" --argjson round "$round" \
      '$disposed + [{round: $round, keys: [.entries[]? | [.member, .finding_class, .path, .line]]}]' "$dispositions_file" 2>/dev/null)" || return 3
  done
  for round in $(printf '%s' "$history" | jq -r --argjson disposed "$disposed" '.[].round | select(. as $round | $disposed | any(.round == $round) | not)'); do
    carried="$(jq -c -n --argjson carried "$carried" --argjson one "$(_carried_keys "$round" 3)" --arg round "$round" '$carried + {($round): $one}')" || return 3
  done
  if [ -f "$RUN_FOLDER/recorded-residuals.jsonl" ]; then
    recorded="$(jq -c -R -n "$_ROW_TEXT_JQ"'[inputs | fromjson? | select(type == "object")
      | [(if (.round | type) == "number" then .round else 0 end), .member, .finding_class, .path, (.line | line_of)]]' \
      <"$RUN_FOLDER/recorded-residuals.jsonl" 2>/dev/null)" || return 3
  fi
  violations="$(printf '%s' "$history" | jq -r --argjson open "$open_entries" --argjson disposed "$disposed" --argjson carried "$carried" \
    --argjson recorded "$recorded" "$_ROW_TEXT_JQ$_SECURITY_CLASS_JQ"'
    def key_array: [.member, .finding_class, .path, .line];
    length as $latest
    | .[] | .round as $round | select($disposed | any(.round == $round) | not)
    | $carried[$round | tostring] as $round_carried
    | (if .keys == null and $round == $latest and $open != null then $open | map(key_array) else .keys end) | arrays | .[] | . as $key
    | select([.[0], .[1], .[2], (.[3] | line_of)] as $full | $recorded | any(.[0] >= $round and .[1:] == $full) | not)
    | select($disposed | any(.round > $round and (.keys | any(. == $key))) | not)
    | select($round_carried.filed | any(. == $key) | not)
    | select(($round_carried.accepted | any(. == $key)) and $round == $latest and $open != null
        and any($open[]; key_array == $key and (security_class | not)) | not)
    | "violation: undecided \({round: $round, member: .[0], finding_class: .[1], path: .[2], line: .[3]} | tojson)"')" || return 3
  [ -z "$violations" ] && return 0
  printf '%s\n' "$violations"
  _error "record the human's decision for each undecided finding: write its {member, finding_class, path, line} plus a reason to a JSON file, then run: bash $_GAIA_DISPOSITIONS_DIRECTORY/audit-dispositions-check.sh record-residual --root $ROOT --run-folder $RUN_FOLDER --finding <file> --decision accept|waive|fix (accept and waive only while the round is open and the finding is not security-class)"
  return 1
}

# _command_record_residual: append one row for the finding in FINDING_FILE to
# the run's recorded residuals, unless its member's key already has a latest
# row saying the same. Without DECISION it is a filing-replay row. With it, it
# is a human's decision on a round no dispositions file covers, its reason the
# finding's own reason when it carries one, else its failure mode. An accept or
# waive is refused unless the open round's live read reports the key and it is
# not security-class: severity and security come from that read, never from
# the caller's file, so once the round is closed only fix is left. Every row
# stores `round`, the latest round in the history when it was written, and
# decides its key in that round and earlier ones only, so a later re-report
# needs a new decision. The reason is stored as given; pr-sections normalizes
# it on read. rc 3 on an unreadable or refused finding.
_command_record_residual() {
  local recorded_file="$RUN_FOLDER/recorded-residuals.jsonl" open_entries="null" history latest row
  history="$(_evaluator round-history)" || { _error "the evaluator could not read the round history"; return 3; }
  latest="$(printf '%s' "$history" | jq 'length')" || { _error "the evaluator could not read the round history"; return 3; }
  if [ "$DECISION" = accept ] || [ "$DECISION" = waive ]; then
    open_entries="$(_open_round_entries "$history")" || { _error "the evaluator could not read the open round's findings"; return 3; }
  fi
  row="$(jq -c --arg decision "$DECISION" --argjson open "$open_entries" --argjson round "$latest" "$_SECURITY_CLASS_JQ"'
    def text($value): if ($value | type) == "string" and ($value | test("\\S")) then $value else "" end;
    . as $finding
    | if type == "object" and (.member | type) == "string" and (.finding_class | type) == "string"
       and (.path | type) == "string" and (.line | type) == "number"
       and ((($decision | IN("accept", "waive")) | not)
            or ($open != null and any($open[]; [.member, .finding_class, .path, .line] == ($finding | [.member, .finding_class, .path, .line])
                and (security_class | not))))
    then if $decision == "" then {source: "filing-replay", round: $round, member, finding_class, path, line,
           reason: (if (.failure_mode | type) == "string" then .failure_mode else "" end)}
         else {source: "human", decision: $decision, round: $round, member, finding_class, path, line,
               reason: (text(.reason) | if . == "" then text($finding.failure_mode) else . end)} end
    else error("unreadable finding") end' "$FINDING_FILE" 2>/dev/null)" ||
    { _error "unreadable or refused finding $FINDING_FILE: an accept or waive needs the open round to report it as not security-class; otherwise record --decision fix"; return 3; }
  [ -n "$row" ] || { _error "unreadable finding $FINDING_FILE"; return 3; }
  if [ -f "$recorded_file" ] && jq -e -R -n --argjson row "$row" "$_ROW_TEXT_JQ"'
      def full: [.member, .finding_class, .path, (.line | line_of)];
      [inputs | fromjson? | select(type == "object") | select(full == ($row | full))] | last
      | . != null and .source == $row.source and .decision == $row.decision and .round == $row.round' <"$recorded_file" >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$RUN_FOLDER" 2>/dev/null || { _error "cannot create $RUN_FOLDER"; return 3; }
  printf '%s\n' "$row" >>"$recorded_file" || { _error "cannot write $recorded_file"; return 3; }
}
