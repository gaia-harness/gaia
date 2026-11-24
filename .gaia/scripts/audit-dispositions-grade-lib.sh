# shellcheck shell=bash
#
# The grading program, the live lookups and stop inputs, the outcome
# reconciliation and the lapsed-veto check of audit-dispositions-check.sh.
# Sourced by it after audit-triage-lib.sh, filing-outcomes-lib.sh and
# audit-pr-sections-lib.sh, and it relies on their _roster_owned_indexes,
# _GAIA_TRIAGE_HONORED_JQ, _TRIAGE_MEMBERS, gaia_filing_refused_keys and
# _evaluator, and on the script's _error, _SECURITY_CLASS_JQ,
# _GAIA_DISPOSITIONS_DIRECTORY, ROOT and RUN_FOLDER. Defines functions and
# constants only; _load_vetoes sets VETOES. Never `cd`s.

# shellcheck disable=SC2016
_GRADE_JQ="$_GAIA_TRIAGE_HONORED_JQ$_SECURITY_CLASS_JQ"'
def key_array: [.member, .finding_class, .path, .line];
def key_object: {member, finding_class, path, line};
def trim: gsub("^\\s+|\\s+$"; "");
(if $version >= 3 then $stop.satisfied_vetoes else [] end) as $satisfied_vetoes
| [$vetoes[] | select(.effective_from_round <= $round) | select(key_array as $key | $satisfied_vetoes | any(. == $key) | not)] as $binding_vetoes
| ($binding_vetoes | map(key_array)) as $vetoed_keys
| any(.entries[] | select(.disposition == "fix") | key_array; . as $key | $stop.default_stop_keys | any(. == $key)) as $threshold_fix
| ($stop.human_accept or ($stop.default_stop and ($threshold_fix | not))) as $accept_allowed
| ($lookup | map({key: (key_array | tojson), value: .}) | from_entries) as $lookup_by_key
| [.entries[] | key_array] as $disposed_keys
| (if $version >= 2 then $carried else {filed: [], accepted: []} end) as $carried_keys
| (
    (.entries[] | . as $entry | key_array as $key | $lookup_by_key[($key | tojson)] as $lookup_entry | ($vetoed_keys | any(. == $key)) as $is_vetoed | (key_object | tojson) as $key_json
      | (if $lookup_entry == null and ($is_vetoed | not) and .disposition != "fix" then ["unknown-key"]
         else [
           (if $lookup_entry != null and .disposition != "fix"
               and ((($lookup_entry.severity | IN("major", "minor")) | not) or ($lookup_entry.security | if type == "boolean" then . else true end))
               and (((.disposition == "file" or ($version >= 2 and .disposition == "divert")) and $lookup_entry.authored == false) | not)
            then (if ($lookup_entry.severity | IN("major", "minor")) then "security-not-fix" else "critical-not-fix" end)
            else empty end),
           (if $lookup_entry != null and .disposition == "file" and $lookup_entry.authored == false
               and ($lookup_entry | security_class) and $visibility != "PRIVATE"
            then "security-file-not-private" else empty end),
           (if .disposition == "divert"
               and ($version < 2 or $lookup_entry == null or $lookup_entry.authored != false or (($lookup_entry | security_class) | not))
            then "divert-not-allowed" else empty end),
           (if .disposition != "fix" and ((if (.reason | type) == "string" then .reason else "" end) | trim) == ""
            then "empty-reason" else empty end),
           (if $is_vetoed and .disposition != "fix" then "vetoed-not-fix" else empty end),
           (if .disposition == "accept-residual" and $version >= 3 and ($accept_allowed or ($stop.accepted_keys // [] | any(. == $key)) | not)
            then "accept-residual-not-eligible" else empty end),
           (if .disposition == "fix" and $version >= 4 and ($is_vetoed | not) and $lookup_entry != null
               and ($stop.accepted_keys // [] | any(. == $key)) and (($lookup_entry | security_class) | not)
            then "human-accepted-fix" else empty end),
           (if .disposition == "waive-out-of-scope" and ((.basis | IN("triage-threshold", "cross-remit")) | not)
            then "missing-basis" else empty end),
           (if .disposition == "waive-out-of-scope" and .basis == "cross-remit" and ($lookup_entry == null or $lookup_entry.cross_remit != true)
            then "cross-remit-basis-mismatch" else empty end)
         ] end)
      | .[] | "violation: \(.) \($key_json)"),
    (([$lookup[]
        | select(if $version >= 2 then (triage_honored | not) else .authored != false end)
        | select(key_array as $key | ($carried_keys.filed | any(. == $key))
            or (($carried_keys.accepted | any(. == $key)) and (security_class | not)) | not)]
      + $binding_vetoes)
      | map(key_object) | unique_by(key_array) | .[] | select(key_array as $key | $disposed_keys | any(. == $key) | not)
      | "violation: undisposed \(tojson)"),
    (if ((.enforcement_paths_allowed // []) | if type == "array" then length > 0 else true end)
     then "violation: enforcement-paths-set \(.enforcement_paths_allowed | tojson)" else empty end)
  )
'

_NO_CARRIED='{"filed":[],"accepted":[]}'

# The stop inputs of a round graded before version 3, or whose live check had
# no accept-residual entry and no binding veto to ask the evaluator about.
_NO_STOP='{"default_stop":false,"default_stop_keys":[],"review_bases":{},"human_accept":false,"accepted_keys":[],"satisfied_vetoes":[]}'

# _sha256 <file>: the hex digest.
_sha256() {
  local digest_output
  if command -v shasum >/dev/null 2>&1; then
    digest_output="$(shasum -a 256 <"$1")" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest_output="$(sha256sum <"$1")" || return 1
  else
    return 1
  fi
  printf '%s\n' "${digest_output%% *}"
}

# _valid_dispositions <file>: rc 0 when the file has the shape the grader reads.
_valid_dispositions() {
  jq -e 'type == "object" and (.entries | type) == "array"
    and all(.entries[]; type == "object" and (.member | type) == "string" and (.finding_class | type) == "string"
      and (.path | type) == "string" and (.line | type) == "number"
      and (.disposition | IN("fix", "accept-residual", "waive-out-of-scope", "file", "divert")))' <"$1" >/dev/null 2>&1
}

# _load_vetoes: sets VETOES to the keys array (with effective_from_round), "[]"
# when the file is absent; rc 3 when present and malformed.
_load_vetoes() {
  local vetoes_file="$RUN_FOLDER/vetoes.json"
  VETOES="[]"
  [ -e "$vetoes_file" ] || return 0
  VETOES="$(jq -c -s 'if length == 1 and (.[0] | type == "object" and .version == 1 and (.keys | type) == "array"
      and all(.keys[]; type == "object" and (.member | type) == "string" and (.finding_class | type) == "string"
        and (.path | type) == "string" and (.effective_from_round | type == "number" and . == floor)))
    then .[0].keys else error("malformed vetoes.json") end' <"$vetoes_file" 2>/dev/null)" || { _error "unparseable $vetoes_file"; return 3; }
  [ -n "$VETOES" ] || { _error "unparseable $vetoes_file"; return 3; }
}

# _live_lookup <r>: the round's findings as the lookup array, the triage mark
# already bounded by the roster. rc 3 on failure.
_live_lookup() {
  local evaluator_output lookup owned
  evaluator_output="$(bash "$_GAIA_DISPOSITIONS_DIRECTORY/audit-loop-eval.sh" findings --root "$ROOT" --round "$1" 2>/dev/null)" || return 3
  lookup="$(printf '%s' "$evaluator_output" | jq -c '.entries | map({member, finding_class, path, line, severity, security, cross_remit, authored,
    triage: (.triage == true), triage_reason: (if (.triage_reason | type) == "string" then .triage_reason else "" end),
    failure_mode: (if (.failure_mode | type) == "string" then .failure_mode else "" end)})' 2>/dev/null)" || return 3
  [ -n "$lookup" ] || return 3
  owned="$(_roster_owned_indexes "$ROOT" "$_GAIA_DISPOSITIONS_DIRECTORY" "$lookup")" || return 3
  printf '%s' "$lookup" | jq -c --argjson owned "$owned" 'to_entries | map(.value + {triage: (.value.triage and (.key | IN($owned[])))})' 2>/dev/null || return 3
}

# _live_stop_inputs <round> <dispositions-file>: the round's stop inputs, in
# _NO_STOP's shape. The evaluator is asked only what the file can use: the
# stop when it holds an accept-residual entry, the human accept when it holds
# an accept-residual or fix entry, the veto state when a veto binds the round.
# rc 3 when the evaluator fails.
_live_stop_inputs() {
  local round="$1" stop="$_NO_STOP" answer
  if jq -e 'any(.entries[]; .disposition == "accept-residual")' "$2" >/dev/null 2>&1; then
    answer="$(_evaluator evaluate-round --round "$round" | jq -c 'select(type == "object")
      | {default_stop: (.default_stop == true), default_stop_keys: (.default_stop_keys // []), review_bases: (.review_bases // {})}')" || return 3
    [ -n "$answer" ] || return 3
    stop="$(jq -n -c --argjson stop "$stop" --argjson answer "$answer" '$stop + $answer')" || return 3
  fi
  if jq -e 'any(.entries[]; .disposition == "accept-residual" or .disposition == "fix")' "$2" >/dev/null 2>&1; then
    answer="$(_evaluator round-history | jq -c --argjson round "$round" '[.[] | select(.round == $round)]
      | {human_accept: any(.[]; .human_accept == true), accepted_keys: [.[] | .human_accepted_keys // [] | .[]]}')" || return 3
    [ -n "$answer" ] || return 3
    stop="$(jq -n -c --argjson stop "$stop" --argjson answer "$answer" '$stop + $answer')" || return 3
  fi
  if jq -e -n --argjson vetoes "$VETOES" --argjson round "$round" 'any($vetoes[]; .effective_from_round <= $round)' >/dev/null; then
    answer="$(_evaluator veto-state --round "$round" | jq -c '.satisfied | arrays')" || return 3
    [ -n "$answer" ] || return 3
    stop="$(jq -n -c --argjson stop "$stop" --argjson satisfied "$answer" '$stop + {satisfied_vetoes: $satisfied}')" || return 3
  fi
  printf '%s\n' "$stop"
}

# _repo_visibility: the visibility of the repository resolved once from ROOT,
# empty when either gh call fails (which reads as not PRIVATE). GH_REPO is
# unset so the environment cannot point either call at another repository.
_repo_visibility() {
  (
    unset GH_REPO
    repository="$(cd "$ROOT" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || exit 0
    [ -n "$repository" ] || exit 0
    gh repo view "$repository" --json visibility --jq .visibility 2>/dev/null || true
  )
}

# _carried_keys <round> <version>: {filed, accepted}, the identity keys disposed
# file or divert (the filer's refusals excepted) and, from version 3,
# accept-residual in any earlier round's dispositions file, read in one jq
# pass. An accepted key exempts a re-report only while it is not
# security-class, so an escalation must be disposed again. An unreadable file
# makes the pass carry nothing, so a lost file leaves more findings
# undisposed, never fewer.
_carried_keys() {
  local k=1 carried
  local -a earlier_files=()
  while [ "$k" -lt "$1" ]; do
    [ -f "$RUN_FOLDER/dispositions-$k.json" ] && earlier_files+=("$RUN_FOLDER/dispositions-$k.json")
    k=$((k + 1))
  done
  [ "${#earlier_files[@]}" -gt 0 ] || { printf '%s\n' "$_NO_CARRIED"; return 0; }
  carried="$(jq -c -n --argjson refused "$(gaia_filing_refused_keys "$RUN_FOLDER")" --argjson version "$2" \
    '[inputs | .entries[] | {key: [.member, .finding_class, .path, .line], disposition}] as $entries
      | {filed: [$entries[] | select(.disposition | IN("file", "divert")) | .key | select(. as $key | $refused | any(. == $key) | not)],
         accepted: [$entries[] | select($version >= 3 and .disposition == "accept-residual") | .key]}' \
    ${earlier_files[@]+"${earlier_files[@]}"} 2>/dev/null)" || carried=""
  printf '%s\n' "${carried:-$_NO_CARRIED}"
}

# _grade_pass <round> <lookup> <version> <carried> <visibility> <stop>
_grade_pass() {
  jq -r --argjson round "$1" --argjson lookup "$2" --argjson version "$3" --argjson carried "$4" --arg visibility "$5" --argjson stop "$6" \
    --argjson vetoes "$VETOES" --argjson triage_members "$_TRIAGE_MEMBERS" "$_GRADE_JQ" "$RUN_FOLDER/dispositions-$1.json" 2>/dev/null
}

# _grade <round> <lookup-json> <predicate-version> [<stop-json>]: prints
# violations; rc 0 none, 1 some, 3 input. The first pass assumes the repo is not PRIVATE, so the
# visibility probe runs only when a security-class file entry makes the answer
# matter.
_grade() {
  local violations carried="$_NO_CARRIED" stop="${4:-$_NO_STOP}"
  [ "$3" -ge 2 ] && carried="$(_carried_keys "$1" "$3")"
  violations="$(_grade_pass "$1" "$2" "$3" "$carried" unprobed "$stop")" || return 3
  case "$violations" in
    *"violation: security-file-not-private "*)
      if [ "$(_repo_visibility)" = PRIVATE ]; then
        violations="$(_grade_pass "$1" "$2" "$3" "$carried" PRIVATE "$stop")" || return 3
      fi
      ;;
  esac
  [ -z "$violations" ] && return 0
  printf '%s\n' "$violations"
  return 1
}

# _check_outcomes <round>: reconcile every file and divert entry with the
# filing script's outcome line for its key (the last one, when a round filed
# the key more than once). A refused-authored key a veto names passes: the
# veto routes it to fix. The caller has validated the dispositions file and
# loaded VETOES.
_check_outcomes() {
  local round="$1" dispositions_file="$RUN_FOLDER/dispositions-$1.json" outcome_file="$RUN_FOLDER/filing-outcomes-$1.jsonl" violations
  local -a outcome_source=(--argjson outcome_lines '[]')
  [ -e "$outcome_file" ] && outcome_source=(--slurpfile outcome_lines "$outcome_file")
  violations="$(jq -r ${outcome_source[@]+"${outcome_source[@]}"} --argjson vetoes "$VETOES" '
    ($vetoes | map([.member, .finding_class, .path, .line])) as $vetoed_keys
    | (if all($outcome_lines[]; type == "object" and (.key | type) == "object") then $outcome_lines
     else error("malformed outcome line") end
     | map({key: (.key | [.member, .finding_class, .path, .line]), outcome})) as $outcomes
    | .entries[] | select(.disposition == "file" or .disposition == "divert")
    | [.member, .finding_class, .path, .line] as $key | ({member, finding_class, path, line} | tojson) as $key_json
    | ([$outcomes[] | select(.key == $key)] | last) as $outcome
    | if $outcome == null then "violation: outcome-missing \($key_json)"
      elif $outcome.outcome == "refused-authored" then (if $vetoed_keys | any(. == $key) then empty else "violation: refused-authored \($key_json)" end)
      elif ($outcome.outcome | IN("filed", "matched", "diverted", "absent", "transient")) then empty
      else "violation: outcome-failed \($key_json)" end' "$dispositions_file" 2>/dev/null)" \
    || { _error "unparseable $dispositions_file or $outcome_file"; return 3; }
  [ -z "$violations" ] && return 0
  printf '%s\n' "$violations"
  return 1
}

# _lapsed_vetoes <last-round>: `violation: undisposed` for each veto whose
# effective_from_round is past <last-round>, the newest dispositions file,
# unless the evaluator's veto state at the latest recorded round calls it
# satisfied. check-all walks only existing files, so without this such a
# veto would lapse unread. rc 0 none, 1 some, 3 evaluator failure.
_lapsed_vetoes() {
  local lapsed used veto_state='{"satisfied":[]}' violations
  lapsed="$(jq -n -c --argjson vetoes "$VETOES" --argjson last_round "$1" \
    '[$vetoes[] | select(.effective_from_round > $last_round) | {member, finding_class, path, line}]')" || return 3
  [ "$lapsed" = "[]" ] && return 0
  used="$(_evaluator current-round)" || return 3
  [[ "$used" =~ ^[0-9]+$ ]] || return 3
  if [ "$used" -ge 1 ]; then veto_state="$(_evaluator veto-state --round "$used")" || return 3; fi
  violations="$(printf '%s' "$veto_state" | jq -r --argjson lapsed "$lapsed" '.satisfied as $satisfied
    | $lapsed[] | select([.member, .finding_class, .path, .line] as $key | $satisfied | any(. == $key) | not)
    | "violation: undisposed \(tojson)"')" || return 3
  [ -z "$violations" ] && return 0
  printf '%s\n' "$violations"
  return 1
}
