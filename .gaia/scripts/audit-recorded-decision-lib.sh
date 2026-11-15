# shellcheck shell=bash
#
# The veto write behind a human's recorded fix decision and the commit lookup
# behind a fixed one. Sourced by audit-pr-sections-lib.sh. Relies on the caller's
# _error, _evaluator, gaia_exclusive_lock_take, ROOT, RUN_FOLDER and
# FINDING_FILE. Runs nothing at source time. Never `cd`s.

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
# Writing the veto before the row lets a retry finish a failed call. rc 3 when
# next-unit fails, the lock stays held, vetoes.json is unreadable or malformed,
# or the write fails. A hung live call's lock is cleared by removing vetoes.json.lock.
_veto_recorded_fix() {
  local vetoes_file="$RUN_FOLDER/vetoes.json" next_unit veto_document='{"version":1,"keys":[]}' temporary_file="$RUN_FOLDER/vetoes.json.$$"
  next_unit="$(_evaluator next-unit)" && [[ "$next_unit" =~ ^([0-9]+)\ ([0-9]+)$ ]] ||
    { _error "the evaluator could not print the next unit, so the fix decision was not recorded"; return 3; }
  _veto_lock "$vetoes_file.lock" || { _error "cannot lock $vetoes_file"; return 3; }
  if [ -e "$vetoes_file" ]; then
    veto_document="$(jq -c 'if type == "object" and .version == 1 and (.keys | type) == "array" then . else error("malformed") end' <"$vetoes_file" 2>/dev/null)" ||
      { rm -rf "$vetoes_file.lock"; _error "unparseable $vetoes_file"; return 3; }
  fi
  if ! jq -n --argjson vetoes "$veto_document" --argjson row "$1" --argjson unit "${BASH_REMATCH[1]}" --argjson from "${BASH_REMATCH[2]}" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '($row | [.member, .finding_class, .path, .line]) as $key
    | if any($vetoes.keys[]; [.member, .finding_class, .path, .line] == $key and .effective_from_round == $from) then $vetoes
      else $vetoes | .keys += [$row | {member, finding_class, path, line, vetoed_at: $now, unit: $unit, effective_from_round: $from}] end' \
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
