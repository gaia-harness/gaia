# shellcheck shell=bash
#
# The veto write behind a human's recorded fix decision, the owner lookup that
# gates a cross-remit one, the commit lookup behind a fixed one, and the gate
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
# as if it were the human's repair. A repeat decision replaces the direction
# on every entry for the key, whatever its effective_from_round, and a blank
# reason clears it.
# Writing the veto before the row lets a retry finish a failed call. rc 3 when
# FINDING_FILE is unreadable, next-unit fails, the lock stays held, vetoes.json
# is unreadable or malformed, or the write fails. A hung live call's lock is cleared by removing vetoes.json.lock.
_veto_recorded_fix() {
  local vetoes_file="$RUN_FOLDER/vetoes.json" next_unit veto_document='{"version":1,"keys":[]}' temporary_file="$RUN_FOLDER/vetoes.json.$$" direction
  direction="$(jq -r 'if (.reason | type) == "string" and (.reason | test("\\S")) then .reason else "" end' "$FINDING_FILE" 2>/dev/null)" ||
    { _error "unreadable finding $FINDING_FILE, so the fix decision was not recorded"; return 3; }
  next_unit="$(_evaluator next-unit)" && [[ "$next_unit" =~ ^([0-9]+)\ ([0-9]+)$ ]] ||
    { _error "the evaluator could not print the next unit, so the fix decision was not recorded"; return 3; }
  _veto_lock "$vetoes_file.lock" || { _error "cannot lock $vetoes_file"; return 3; }
  if [ -e "$vetoes_file" ]; then
    veto_document="$(jq -c 'if type == "object" and .version == 1 and (.keys | type) == "array" then . else error("malformed") end' <"$vetoes_file" 2>/dev/null)" ||
      { rm -rf "$vetoes_file.lock"; _error "unparseable $vetoes_file"; return 3; }
  fi
  if ! jq -n --argjson vetoes "$veto_document" --argjson row "$1" --argjson unit "${BASH_REMATCH[1]}" --argjson from "${BASH_REMATCH[2]}" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg direction "$direction" '($row | [.member, .finding_class, .path, .line]) as $key
    | (if $direction == "" then {} else {direction: $direction} end) as $directed
    | def samekey: [.member, .finding_class, .path, .line] == $key;
    def same: samekey and .effective_from_round == $from;
    def redirect: (del(.direction)) + $directed;
    ($vetoes | .keys |= map(if samekey then redirect else . end)) as $redirected
    | if any($vetoes.keys[]; same) then $redirected
      else $redirected | .keys += [$row | {member, finding_class, path, line, vetoed_at: $now, unit: $unit, effective_from_round: $from} + $directed] end' \
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
    { _error "discard refused: no round reports this key as a Major or Minor non-security finding; a Critical or security-class key takes Keep (commit the draft) or Redo (restore it, then record-residual --decision fix)"; return 3; }
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
