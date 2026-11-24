# shellcheck shell=bash
#
# The frozen-snapshot helpers and the live and snapshot checks of
# audit-dispositions-check.sh. Sourced by it after audit-dispositions-grade-lib.sh,
# and it relies on that lib's _grade, _live_lookup, _live_stop_inputs, _sha256,
# _valid_dispositions and _NO_STOP, and on the script's _error, ROOT,
# RUN_FOLDER, SNAPSHOT_DIRECTORY, READ_DIRECTORY and
# _GAIA_DISPOSITIONS_DIRECTORY. Sets CHECKED_VERSION for the caller. Defines
# functions only. Never `cd`s.

# shellcheck disable=SC2034 # CHECKED_VERSION is read by check-all in the script that sources this lib

# _default_snapshot_directory: the branch's snapshot directory, read only; empty when
# the evaluator knows no state path for ROOT.
_default_snapshot_directory() {
  local state_path
  state_path="$(bash "$_GAIA_DISPOSITIONS_DIRECTORY/audit-loop-eval.sh" state-path --root "$ROOT" 2>/dev/null)" && printf '%s.d' "${state_path%.json}"
  return 0
}

# _snapshot_path <round>: the snapshot of a round in READ_DIRECTORY, which is
# --snapshot-dir when given and the branch's default directory otherwise.
_snapshot_path() { printf '%s/dispositions-%s.checked.json' "$READ_DIRECTORY" "$1"; }

# _has_snapshot <round>
_has_snapshot() { [ -n "$READ_DIRECTORY" ] && [ -e "$(_snapshot_path "$1")" ]; }

# _write_snapshot <round> <sha> <lookup> <stop>
_write_snapshot() {
  local temporary_file
  mkdir -p "$SNAPSHOT_DIRECTORY" 2>/dev/null || { _error "cannot create $SNAPSHOT_DIRECTORY"; return 3; }
  temporary_file="$(mktemp "$SNAPSHOT_DIRECTORY/.dispositions-$1.XXXXXX")" || { _error "cannot write in $SNAPSHOT_DIRECTORY"; return 3; }
  if jq -n -c --argjson round "$1" --arg sha "$2" --argjson lookup "$3" --argjson stop "$4" \
    '{version: 4, round: $round, dispositions_sha256: $sha, lookup: $lookup} + $stop' >"$temporary_file" \
    && mv -f "$temporary_file" "$(_snapshot_path "$1")"; then
    return 0
  fi
  rm -f "$temporary_file"
  _error "cannot write the snapshot for round $1"
  return 3
}

# _check_live <round>: the live check; writes the snapshot on a pass when asked.
_check_live() {
  local round="$1" dispositions_file="$RUN_FOLDER/dispositions-$1.json" lookup stop exit_status sha snapshot_file have
  [ -f "$dispositions_file" ] || { _error "no $dispositions_file"; return 3; }
  _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
  lookup="$(_live_lookup "$round")" || { _error "the evaluator could not read round $round"; return 3; }
  stop="$(_live_stop_inputs "$round" "$dispositions_file")" || { _error "the evaluator could not read round $round's stop inputs"; return 3; }
  CHECKED_VERSION=4
  exit_status=0
  _grade "$round" "$lookup" 4 "$stop" || exit_status=$?
  [ "$exit_status" -eq 3 ] && { _error "could not grade $dispositions_file"; return 3; }
  if [ -n "$SNAPSHOT_DIRECTORY" ]; then
    sha="$(_sha256 "$dispositions_file")" || { _error "no sha256 tool"; return 3; }
    snapshot_file="$(_snapshot_path "$round")"
    if [ -e "$snapshot_file" ]; then
      have="$(jq -r '.dispositions_sha256 // ""' <"$snapshot_file" 2>/dev/null)" || have=""
      if [ "$have" != "$sha" ]; then
        printf 'violation: edited-after-check {"round":%s}\n' "$round"
        return 1
      fi
    elif [ "$exit_status" -eq 0 ]; then
      _write_snapshot "$round" "$sha" "$lookup" "$stop" || return 3
    fi
  fi
  return "$exit_status"
}

# _check_snapshot <round>: re-grade from the frozen snapshot, under the
# predicate its version names; sets CHECKED_VERSION to that version.
_check_snapshot() {
  local round="$1" dispositions_file="$RUN_FOLDER/dispositions-$1.json" snapshot_file sha have lookup stop version snapshot_fields
  snapshot_file="$(_snapshot_path "$round")"
  CHECKED_VERSION=2
  _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
  snapshot_fields="$(jq -r --argjson no_stop "$_NO_STOP" 'if (.version | IN(1, 2, 3, 4)) and (.lookup | type) == "array" and (.dispositions_sha256 | type) == "string"
      and (.version < 3 or ((.default_stop | type) == "boolean" and (.default_stop_keys | type) == "array"
        and (.human_accept | type) == "boolean" and (.satisfied_vetoes | type) == "array"))
      then .version, .dispositions_sha256, (.lookup | tojson),
        (if .version >= 3 then $no_stop + {default_stop, default_stop_keys, human_accept, satisfied_vetoes, accepted_keys: (.accepted_keys // [])} else $no_stop end | tojson)
      else error("bad") end' <"$snapshot_file" 2>/dev/null)" \
    || { _error "unreadable snapshot $snapshot_file"; return 3; }
  { IFS= read -r version; IFS= read -r have; IFS= read -r lookup; IFS= read -r stop; } <<<"$snapshot_fields"
  CHECKED_VERSION="$version"
  sha="$(_sha256 "$dispositions_file")" || { _error "no sha256 tool"; return 3; }
  if [ "$have" != "$sha" ]; then
    printf 'violation: edited-after-check {"round":%s}\n' "$round"
    return 1
  fi
  _grade "$round" "$lookup" "$version" "$stop"
}
