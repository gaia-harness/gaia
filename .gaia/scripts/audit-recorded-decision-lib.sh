# shellcheck shell=bash
#
# The veto write behind a human's recorded fix decision, the owner lookups that
# gate a cross-remit one and its repair paths, the commit lookup behind a fixed one, and the gate
# and veto removal behind a discard one. Sourced by audit-pr-sections-lib.sh.
# Relies on the caller's _error, _evaluator, _round_lookup, _SECURITY_CLASS_JQ,
# gaia_exclusive_lock_take, _roster_owners, _GAIA_DISPOSITIONS_DIRECTORY, ROOT,
# RUN_FOLDER and FINDING_FILE. Runs nothing at source time. Never `cd`s.

# _finding_path_owned: true when the roster at ROOT gives FINDING_FILE's path
# to a member (_roster_owners), whose review is what satisfies a cross-remit
# fix's veto. Prints null when the roster cannot be read, which refuses a fix
# and a security-class fixed alike.
_finding_path_owned() {
  local owners
  owners="$(_roster_owners "$ROOT" "$_GAIA_DISPOSITIONS_DIRECTORY" "$(jq -c '[.path]' "$FINDING_FILE" 2>/dev/null)")" || owners=null
  printf '%s' "$owners" | jq 'if type == "object" then length > 0 else null end' 2>/dev/null || printf 'null\n'
}

# _repair_paths_owned: rc 0 when FINDING_FILE names no repair_paths, or the
# roster at ROOT gives every one of them to a member, whose review is what
# satisfies the veto there. rc 3 after naming the refusal otherwise, an
# unreadable roster included, or a path on audit-fix-verify-state-lib.sh's
# ENFORCEMENT_PATHS (the fixer can never land an edit there).
_repair_paths_owned() {
  local repair_paths owners enforcement_path repair_path
  repair_paths="$(jq -c '.repair_paths // [] | if type == "array" and all(.[]; type == "string" and . != "") then . else error("bad") end' "$FINDING_FILE" 2>/dev/null)" ||
    { _error "repair_paths in $FINDING_FILE must be an array of non-empty paths"; return 3; }
  [ "$repair_paths" != "[]" ] || return 0
  # The list is read from its one owner, in a child shell so nothing else it holds leaks in.
  while IFS= read -r repair_path; do
    while IFS= read -r enforcement_path; do
      [ "$repair_path" != "$enforcement_path" ] || {
        _error "fix refused: repair path $repair_path is an enforcement path the fixer can never edit; drop it from repair_paths, or repair it by hand"; return 3; }
    done < <(bash -c '. "$1" && printf "%s\n" "${ENFORCEMENT_PATHS[@]}"' _ "$_GAIA_DISPOSITIONS_DIRECTORY/audit-fix-verify-state-lib.sh")
  done < <(printf '%s' "$repair_paths" | jq -r '.[]')
  owners="$(_roster_owners "$ROOT" "$_GAIA_DISPOSITIONS_DIRECTORY" "$repair_paths")" || owners="{}"
  printf '%s' "$owners" | jq -e --argjson paths "$repair_paths" '. as $owners | type == "object" and all($paths[]; . as $path | $owners | has($path))' >/dev/null 2>&1 ||
    { _error "fix refused: the roster gives a repair path to no member, so no review could satisfy the veto there; name only owned repair_paths"; return 3; }
}

# _veto_lock <directory>: gaia_exclusive_lock_take, so parallel record-residual
# calls never drop each other's veto; a dead holder's lock is taken over. rc 1 after ~5s.
_veto_lock() {
  local attempt=0 holder
  until gaia_exclusive_lock_take "$1"; do
    holder="$(cat "$1/owner" 2>/dev/null)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$1"; continue; fi
    attempt=$((attempt + 1)); [ "$attempt" -le 50 ] || return 1; sleep 0.1
  done
}

# _veto_recorded_fix <row>: a human's fix decision binds the next unit as a
# veto (vetoes.json, shape in audit-fix-verify.sh's header). A row alone binds
# nothing: a member whose clearance survives the commits after its round is
# never re-dispatched, so the next unit could stop clean with the fix unmade.
# The key's direction is the reason in FINDING_FILE, never the row's: the row
# falls back to the failure mode, which would brief the fixer with the defect
# as if it were the human's repair. FINDING_FILE's optional repair_paths names
# the other files the repair lands in, which the veto then reads as its fix.
# A key keeps one entry: a repeat decision updates it in place, replacing the
# direction and repair_paths (a blank reason or no repair_paths clears them) and
# moving effective_from_round forward to the new start round, so the fix counts
# from the redo; a second entry would block the clean stop on its own after a
# review satisfied the first. Copies an older file holds collapse into one.
# Writing the veto before the row lets a retry finish a failed call. rc 3 when
# FINDING_FILE is unreadable or its repair_paths is not an array of non-empty
# strings, next-unit fails, the lock stays held, vetoes.json is unreadable or
# malformed, or the write fails. A hung live call's lock is cleared by removing vetoes.json.lock.
_veto_recorded_fix() {
  local vetoes_file="$RUN_FOLDER/vetoes.json" next_unit veto_document='{"version":1,"keys":[]}' temporary_file="$RUN_FOLDER/vetoes.json.$$" direction repair_paths
  direction="$(jq -r 'if (.reason | type) == "string" and (.reason | test("\\S")) then .reason else "" end' "$FINDING_FILE" 2>/dev/null)" ||
    { _error "unreadable finding $FINDING_FILE, so the fix decision was not recorded"; return 3; }
  repair_paths="$(jq -c '.repair_paths // [] | if type == "array" and all(.[]; type == "string" and . != "") then unique else error("bad") end' "$FINDING_FILE" 2>/dev/null)" ||
    { _error "repair_paths in $FINDING_FILE must be an array of non-empty paths, so the fix decision was not recorded"; return 3; }
  next_unit="$(_evaluator next-unit)" && [[ "$next_unit" =~ ^([0-9]+)\ ([0-9]+)$ ]] ||
    { _error "the evaluator could not print the next unit, so the fix decision was not recorded"; return 3; }
  _veto_lock "$vetoes_file.lock" || { _error "cannot lock $vetoes_file"; return 3; }
  if [ -e "$vetoes_file" ]; then
    veto_document="$(jq -c 'if type == "object" and .version == 1 and (.keys | type) == "array" then . else error("malformed") end' <"$vetoes_file" 2>/dev/null)" ||
      { rm -rf "$vetoes_file.lock"; _error "unparseable $vetoes_file"; return 3; }
  fi
  if ! jq -n --argjson vetoes "$veto_document" --argjson row "$1" --argjson unit "${BASH_REMATCH[1]}" --argjson from "${BASH_REMATCH[2]}" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg direction "$direction" --argjson repair_paths "$repair_paths" '($row | [.member, .finding_class, .path, .line]) as $key
    | (if $direction == "" then {} else {direction: $direction} end) as $directed
    | (if ($repair_paths | length) == 0 then {} else {repair_paths: $repair_paths} end) as $repaired
    | def samekey: [.member, .finding_class, .path, .line] == $key;
    [$vetoes.keys[] | select(samekey)] as $existing
    | (if ($existing | length) == 0
       then $row | {member, finding_class, path, line, vetoed_at: $now, unit: $unit, effective_from_round: $from}
       else $existing | max_by(.effective_from_round) | if .effective_from_round < $from then .effective_from_round = $from | .unit = $unit else . end end
       | del(.direction, .repair_paths) + $directed + $repaired) as $entry
    | $vetoes | .keys = (if ($existing | length) == 0 then .keys + [$entry]
        else reduce .keys[] as $kept ([]; if ($kept | samekey | not) then . + [$kept] elif any(.[]; samekey) then . else . + [$entry] end) end)' \
    >"$temporary_file" 2>/dev/null || ! mv "$temporary_file" "$vetoes_file"; then
    rm -f "$temporary_file"; rm -rf "$vetoes_file.lock"; _error "cannot write $vetoes_file"; return 3
  fi
  rm -rf "$vetoes_file.lock"
}

# _fixed_commit <round-history>: the latest commit on HEAD touching the path in
# FINDING_FILE when that path differs between the open round's tree (the
# history's last entry) and HEAD's, else nothing. Any git failure prints
# nothing, so the fixed decision is refused rather than recorded unproven.
_fixed_commit() {
  local finding_path round_tree head_tree diff_status=0
  finding_path="$(jq -r 'if (.path | type) == "string" then .path else "" end' "$FINDING_FILE" 2>/dev/null)" || return 0
  round_tree="$(printf '%s' "$1" | jq -r 'last | .tree // ""' 2>/dev/null)" || return 0
  head_tree="$(git -C "$ROOT" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)" || return 0
  [ -n "$finding_path" ] && [ -n "$round_tree" ] || return 0
  git -C "$ROOT" diff --quiet "$round_tree" "$head_tree" -- ":(literal)$finding_path" 2>/dev/null || diff_status=$?
  [ "$diff_status" -eq 1 ] || return 0
  git -C "$ROOT" log -1 --format=%H HEAD -- ":(literal)$finding_path" 2>/dev/null
}

# _discard_allowed <round-history>: rc 0 when a human may discard the drafted
# repair of FINDING_FILE's key: vetoes.json names the key, the latest round's
# dispositions file holds it as a fix entry carrying enforcement_draft (the
# enforcement-draft stop), and some round's lookup reports it while none
# reports it Critical or security-class. Severity comes from the lookups,
# never from the caller's file or the dispositions entry, which Claude writes.
# A key no lookup reports is refused, since its severity is unknown. rc 3 on a
# refusal, after naming it.
_discard_allowed() {
  local key latest round lookups="" round_lookup
  key="$(jq -c 'if (.line | type) == "number" then [.member, .finding_class, .path, .line] else error("bad") end' "$FINDING_FILE" 2>/dev/null)" ||
    { _error "unreadable finding $FINDING_FILE"; return 3; }
  latest="$(printf '%s' "$1" | jq 'length')" || { _error "the evaluator could not read the round history"; return 3; }
  jq -e --argjson key "$key" 'any(.keys[]?; [.member, .finding_class, .path, .line] == $key)' "$RUN_FOLDER/vetoes.json" >/dev/null 2>&1 ||
    { _error "discard refused: vetoes.json does not name this key"; return 3; }
  jq -e --argjson key "$key" 'any(.entries[]?; [.member, .finding_class, .path, .line] == $key and .disposition == "fix" and .enforcement_draft == true)' \
    "$RUN_FOLDER/dispositions-$latest.json" >/dev/null 2>&1 ||
    { _error "discard refused: dispositions-$latest.json holds no enforcement_draft fix entry for this key"; return 3; }
  for ((round = 1; round <= latest; round++)); do
    round_lookup="$(_round_lookup "$round")" || round_lookup="[]"
    lookups="$lookups$round_lookup"$'\n'
  done
  printf '%s' "$lookups" | jq -e -s --argjson key "$key" "$_SECURITY_CLASS_JQ"'
    [.[][]? | select([.member, .finding_class, .path, .line] == $key)] | length > 0 and all(.[]; security_class | not)' >/dev/null 2>&1 ||
    { _error "discard refused: some round reports this key as Critical or security-class, or no round reports it; such a key takes Keep (commit the draft) or Redo (restore it, then record-residual --decision fix)"; return 3; }
}

# _veto_withdraw <row>: removes every vetoes.json entry for the row's key under
# the same lock as _veto_recorded_fix. rc 3 when the lock stays held,
# vetoes.json is unreadable or malformed, or the write fails.
_veto_withdraw() {
  local vetoes_file="$RUN_FOLDER/vetoes.json" temporary_file="$RUN_FOLDER/vetoes.json.$$"
  _veto_lock "$vetoes_file.lock" || { _error "cannot lock $vetoes_file"; return 3; }
  if ! jq --argjson row "$1" 'if type == "object" and .version == 1 and (.keys | type) == "array" then . else error("malformed") end
    | ($row | [.member, .finding_class, .path, .line]) as $key | .keys |= map(select([.member, .finding_class, .path, .line] != $key))' \
    "$vetoes_file" >"$temporary_file" 2>/dev/null || ! mv "$temporary_file" "$vetoes_file"; then
    rm -f "$temporary_file"; rm -rf "$vetoes_file.lock"; _error "cannot write $vetoes_file"; return 3
  fi
  rm -rf "$vetoes_file.lock"
}
