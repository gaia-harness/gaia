#!/usr/bin/env bash
# audit-dispositions-check.sh: the deterministic check on an audit round's
# dispositions file, and the renderers of its PR-body records.
#
# Inside an audit-loop unit the Opus orchestrator disposes every finding of a
# round in <run-folder>/dispositions-<r>.json. The main thread no longer reads
# each disposition, so this script forbids the dispositions only a human may
# make. The orchestrator writes the dispositions file and is the
# actor this check bounds, which is why nothing it grades comes from that file:
# severity, the security flag, cross-remit, authorship and the triage mark are
# read from the members' findings sidecars by identity key (member,
# finding_class, path, line), through `audit-loop-eval.sh findings`, and the
# round's default stop, its human accept and its veto state from the
# evaluator's `evaluate-round`, `round-history` and `veto-state`. Relabelling a Critical
# as Major, or claiming eligibility, inside the dispositions entry changes
# nothing.
#
# Usage:
#   audit-dispositions-check.sh check          --root <R> --run-folder <D> --round <r> [--snapshot-dir <S>]
#   audit-dispositions-check.sh check-all      --root <R> --run-folder <D> [--snapshot-dir <S>]
#   audit-dispositions-check.sh check-outcomes --root <R> --run-folder <D> --round <r>
#   audit-dispositions-check.sh waiver-table   --root <R> --run-folder <D> --rounds <a>-<b> [--snapshot-dir <S>]
#   audit-dispositions-check.sh pr-sections    --root <R> --run-folder <D> [--snapshot-dir <S>]
#   audit-dispositions-check.sh residual-count --root <R> --run-folder <D> [--snapshot-dir <S>]
#   audit-dispositions-check.sh record-residual --root <R> --run-folder <D> --finding <file> [--decision accept|waive|fix]
#   audit-dispositions-check.sh undecided      --root <R> --run-folder <D>
#
# Dispositions: fix, accept-residual, waive-out-of-scope, file, divert.
#
# Rules (a violation prints `violation: <token> <compact key json>` on stdout):
#   critical-not-fix            a Critical (severity critical) key disposed anything but fix,
#                               or file or divert when the finding is from outside the branch
#   security-not-fix            the same for a security:true key (a finding with no
#                               boolean security field reads as true)
#   security-file-not-private   a Critical or security:true key from outside the branch
#                               disposed file while the repo is not confirmed PRIVATE
#                               (`gh repo view` visibility, probed only when such an
#                               entry exists; a failed probe is not PRIVATE): it diverts,
#                               never a public or internal issue
#   divert-not-allowed          divert on a key that is branch-authored or not
#                               security-class (security not false, or severity critical)
#   empty-reason                a non-fix disposition with an empty or blank reason
#   vetoed-not-fix              a waiver-vetoed key (must be fixed) for this round
#                               (effective_from_round <= r) that is not fix, unless the
#                               evaluator's veto state calls the veto satisfied; a synthetic
#                               fix entry for a waiver-vetoed key no member re-reported passes
#   accept-residual-not-eligible  (version 3) accept-residual on a round with no human accept where
#                               the default stop does not hold, or where the file disposes
#                               fix a key in default_stop_keys (the stop's formula:
#                               audit-loop-eval.sh, DEFAULT STOP)
#   undisposed                  a finding of any authorship, or an unsatisfied waiver-vetoed
#                               key for this round, with no entry in the file, unless the
#                               finding carries an honored triage mark or was disposed file,
#                               divert or accept-residual in an earlier round; check-all
#                               without --snapshot-dir also prints it for an unsatisfied veto
#                               whose round is past every dispositions file
#   undecided                   (check-all without --snapshot-dir, and undecided after a unit stop
#                               that can leave the round without its file) an open-round finding with
#                               no honored triage mark that neither a row recorded on that round nor an earlier round's file, divert or accept-residual decides
#   enforcement-paths-set       enforcement_paths_allowed is non-empty (a finding that
#                               needs one stops the unit with needs-human)
#   missing-basis               waive-out-of-scope without basis triage-threshold|cross-remit
#   cross-remit-basis-mismatch  basis cross-remit on a finding not flagged cross_remit
#   unknown-key                 a non-fix entry with no matching finding and no binding
#                               veto: reads as Critical and security (fail closed). A fix
#                               entry passes, since it can only add work, never hide a
#                               finding: a satisfied or retired veto's synthetic fix entry
#                               refuses no later round
#   edited-after-check          the dispositions file no longer matches its snapshot
#   outcome-missing             (check-outcomes) a file or divert entry with no line in
#                               <D>/filing-outcomes-<r>.jsonl, the filing script's record
#   outcome-failed              (check-outcomes) that line's outcome is failed, or a
#                               value the filing script never writes; absent and
#                               transient pass, since neither is a merge blocker
#   refused-authored            (check-outcomes) that line's outcome is refused-authored
#                               and vetoes.json does not name the exact key: the filer found
#                               the site branch-authored, so the entry is re-disposed
#                               accept-residual where that is eligible, or a veto names the
#                               key and the next round fixes it
#
# Triage mark. A sidecar entry with `triage: true` is honored as disposed only
# when its member is on the triage allowlist (empty unless this checkout
# defines one, so elsewhere no mark is honored), the roster at
# <R>/.gaia/audit-ci.yml gives its
# path to that member, its security is exactly false and its severity is not
# critical; otherwise it is graded and disposed like any finding. The roster half
# is applied when the lookup is built (an unreadable roster honors nothing), so
# the lookup's `triage` is already roster-bounded. A dispositions entry for the
# key wins over the mark.
#
# Carry-forward. A key disposed file, divert or accept-residual in
# dispositions-<k>.json, k < r, is not undisposed in round r: the filing
# script's outcome (and its retry file, for a transient one) is what keeps a
# filed key pending, and an accepted key needs no new entry while its re-report
# is not security-class, matching the A(r) model's disposed set. A key disposed fix earlier carries nothing, and neither
# does a key the filer refused as branch-authored. A vetoed key still needs
# its entry: the undisposed rule adds the binding vetoes after the carry.
#
# check-outcomes reconciles one round. check-all runs it for every round
# graded under a version-2 or later predicate (a live round or such a snapshot);
# check never runs it, because the unit files only after its check passes.
#
# Exit codes: 0 pass, 1 violation, 2 usage, 3 unreadable input (jq absent, the
# evaluator failing, an unparseable dispositions, vetoes, outcomes or snapshot
# file, the secret screen failing to run).
#
# Frozen snapshots. A member's sidecar is overwritten every round, so once
# round r+1's members write, round r's findings are gone and a re-grade of an
# old dispositions file would read every key as unknown. With --snapshot-dir a
# passing live `check` writes <S>/dispositions-<r>.checked.json (version 3: the
# file's sha256, the per-key lookup it graded, triage mark and failure mode
# included, and the stop inputs default_stop, default_stop_keys, review_bases,
# human_accept and satisfied_vetoes), and `check-all` re-grades from that
# snapshot, never from live sidecars and never through the evaluator. The
# snapshot directory is in the guarded loop state directory; only the bound
# hook's invocation passes --snapshot-dir, and only that invocation writes. Without --snapshot-dir, every subcommand that grades
# or renders reads the frozen snapshots from the branch's state directory (the state file's path
# minus .json, plus .d) and writes nothing: a round with a snapshot is
# re-graded from it, a round without one from live findings, so the read-only
# last guard passes on a multi-round branch whose earlier sidecars were
# overwritten. A branch with no state directory has no snapshots to read. An
# existing snapshot is never overwritten by a different file.
#
# Forward-only grading. A snapshot is re-graded under the predicate it passed.
# Version 1: only a branch-authored finding (authored not false) is
# mandatory, divert does not exist, no triage mark or carry-forward applies,
# and no outcome reconciliation runs. Version 2 adds those, but has no
# accept-residual eligibility, no veto satisfaction and no carry of an
# accepted key. Live rounds and version-3 snapshots use the current predicate.
#
# Vetoes apply forward only. vetoes.json entries carry effective_from_round, so
# a waiver veto recorded after a unit returned binds the rounds it applies to
# and never re-fails the earlier dispositions file that held the original
# waiver.
#
# Visibility. The repository is resolved once from <R> and the visibility read
# names it explicitly, with GH_REPO unset for both calls. No environment
# variable, cached file or other local state is consulted; only an exact
# `PRIVATE` answer counts.
#
# Honest limits. A member that misclassifies a finding as security:false is not
# caught here, and neither is a triage mark on a finding the marking member
# misgrades. vetoes.json sits in the Claude-writable run folder (the main
# thread writes it) and is trusted as written; a forged veto can only demand
# more fix, never fewer. The outcomes file is Claude-writable too: a forged
# `filed` line passes check-outcomes, which bounds an orchestrator that skips
# the filing script, not one that forges its record.
#
# waiver-table prints a markdown table of every non-fix entry for a round range
# except divert, which is a count line under the table; severity and security
# come from the snapshot when present, else from live findings; `unknown` when
# neither knows the key. pr-sections prints the PR-body records from the same
# lookup: accepted residuals and cross-remit waivers in the keyed form
# /gaia-residue parses, triage-threshold waivers and honored triage marks as
# key-less one-liners deduplicated by key, waiver-vetoed keys excluded for the
# rounds the veto binds, diverts as a count only, and the not-filed section
# from the outcomes files and <D>/filing-retry/. A waiver or triage line
# renders only when the lookup says security false and severity not critical, and
# every rendered reason passes `file-tech-debt.sh screen-text` first; a reason
# that fails renders as a withheld count. It also renders <D>/recorded-residuals.jsonl
# (rows record-residual and the worthiness step append) as accepted residuals,
# a human's waive as a triage waiver and a human's fix as nothing, even with no
# dispositions file.
# record-residual appends the row for a finding the filer refused on replay,
# or with --decision a human's decision on a round no dispositions file covers,
# the latest row per member's key deciding it, and prints nothing; no
# dispositions eligibility rule grades it, but an accept or waive needs the
# open round's live read to show it not security-class. An accept row
# takes the finding's failure mode as its reason when the lookup has one, and
# drops a key any veto names, whatever its round, or a round after the row's
# `round` re-reports security-class. residual-count prints
# {"total","ask"}: total counts the accepted-residual rows pr-sections renders,
# run-wide, and ask the subset the residual question lists.

set -uo pipefail

case "${BASH_SOURCE[0]}" in
  */*) _GAIA_DISPOSITIONS_DIRECTORY="${BASH_SOURCE[0]%/*}" ;;
  *) _GAIA_DISPOSITIONS_DIRECTORY="." ;;
esac
# jq defs shared with the render library, defined here so grading never depends
# on it loading; security_class also bounds a human's recorded accept or waive.
# shellcheck disable=SC2016
_RESIDUAL_REASON_JQ='
def residual_reason($lookup_entry):
  if ($lookup_entry.failure_mode | type) == "string" and ($lookup_entry.failure_mode | test("\\S")) then $lookup_entry.failure_mode else .reason end;
'
_SECURITY_CLASS_JQ='def security_class: ((.severity | IN("major", "minor")) | not) or (.security | if type == "boolean" then . else true end);'

# shellcheck source=/dev/null
. "$_GAIA_DISPOSITIONS_DIRECTORY/filing-outcomes-lib.sh"
# shellcheck source=/dev/null
. "$_GAIA_DISPOSITIONS_DIRECTORY/audit-pr-sections-lib.sh"
# Fail loud: grading on with _TRIAGE_MEMBERS unbound would honor nothing.
# shellcheck source=/dev/null
. "$_GAIA_DISPOSITIONS_DIRECTORY/audit-triage-lib.sh" 2>/dev/null ||
  { printf 'audit-dispositions-check: cannot load %s/audit-triage-lib.sh\n' "$_GAIA_DISPOSITIONS_DIRECTORY" >&2; exit 3; }

_usage() {
  printf 'usage: audit-dispositions-check.sh check|check-all|check-outcomes|waiver-table|pr-sections|residual-count|record-residual|undecided --root <R> --run-folder <D> [--round <r>|--rounds <a>-<b>] [--snapshot-dir <S>] [--finding <file> [--decision accept|waive|fix]]\n' >&2
  return 2
}

_error() { printf 'audit-dispositions-check: %s\n' "$*" >&2; }

_TEMPORARY_FILES=()
# shellcheck disable=SC2329
_cleanup() {
  [ "${#_TEMPORARY_FILES[@]}" -eq 0 ] || rm -f "${_TEMPORARY_FILES[@]}"
  return 0
}
trap _cleanup EXIT

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
           (if .disposition == "accept-residual" and $version >= 3 and ($accept_allowed | not)
            then "accept-residual-not-eligible" else empty end),
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
_NO_STOP='{"default_stop":false,"default_stop_keys":[],"review_bases":{},"human_accept":false,"satisfied_vetoes":[]}'

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

# _evaluator <subcommand> [args...]: audit-loop-eval.sh on ROOT, stderr dropped.
_evaluator() {
  local subcommand="$1"
  shift
  bash "$_GAIA_DISPOSITIONS_DIRECTORY/audit-loop-eval.sh" "$subcommand" --root "$ROOT" "$@" 2>/dev/null
}

# _live_stop_inputs <round> <dispositions-file>: the round's stop inputs, in
# _NO_STOP's shape. The evaluator is asked only what the file can use: the
# stop and the human accept when it holds an accept-residual entry, the veto
# state when a veto binds the round. rc 3 when the evaluator fails.
_live_stop_inputs() {
  local round="$1" stop="$_NO_STOP" answer
  if jq -e 'any(.entries[]; .disposition == "accept-residual")' "$2" >/dev/null 2>&1; then
    answer="$(_evaluator evaluate-round --round "$round" | jq -c 'select(type == "object")
      | {default_stop: (.default_stop == true), default_stop_keys: (.default_stop_keys // []), review_bases: (.review_bases // {})}')" || return 3
    [ -n "$answer" ] || return 3
    stop="$(jq -n -c --argjson stop "$stop" --argjson answer "$answer" '$stop + $answer')" || return 3
    answer="$(_evaluator round-history | jq -c --argjson round "$round" 'any(.[]; .round == $round and .human_accept == true)')" || return 3
    [ -n "$answer" ] || return 3
    stop="$(jq -n -c --argjson stop "$stop" --argjson human_accept "$answer" '$stop + {human_accept: $human_accept}')" || return 3
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
    '{version: 3, round: $round, dispositions_sha256: $sha, lookup: $lookup} + $stop' >"$temporary_file" \
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
  CHECKED_VERSION=3
  exit_status=0
  _grade "$round" "$lookup" 3 "$stop" || exit_status=$?
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
  snapshot_fields="$(jq -r --argjson no_stop "$_NO_STOP" 'if (.version | IN(1, 2, 3)) and (.lookup | type) == "array" and (.dispositions_sha256 | type) == "string"
      and (.version < 3 or ((.default_stop | type) == "boolean" and (.default_stop_keys | type) == "array"
        and (.human_accept | type) == "boolean" and (.satisfied_vetoes | type) == "array"))
      then .version, .dispositions_sha256, (.lookup | tojson),
        (if .version >= 3 then $no_stop + {default_stop, default_stop_keys, human_accept, satisfied_vetoes} else $no_stop end | tojson)
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

_valid_round() { [[ "${ROUND:-}" =~ ^[0-9]+$ ]] && [ "$ROUND" -ge 1 ]; }

_command_check() {
  _valid_round || { _usage; return 2; }
  _load_vetoes || return 3
  if [ -z "$SNAPSHOT_DIRECTORY" ] && _has_snapshot "$ROUND"; then
    _check_snapshot "$ROUND"
    return $?
  fi
  _check_live "$ROUND"
}

_command_check_outcomes() {
  local dispositions_file
  _valid_round || { _usage; return 2; }
  _load_vetoes || return 3
  dispositions_file="$RUN_FOLDER/dispositions-$ROUND.json"
  [ -f "$dispositions_file" ] || { _error "no $dispositions_file"; return 3; }
  _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
  _check_outcomes "$ROUND"
}

# _fold <status>: folds one exit status into WORST, 3 over 1 over 0.
_fold() {
  if [ "$1" -eq 3 ] || [ "$WORST" -eq 3 ]; then WORST=3
  elif [ "$1" -ne 0 ]; then WORST=1; fi
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

_command_check_all() {
  local dispositions_file base round exit_status last_round=0
  WORST=0
  _load_vetoes || return 3
  for dispositions_file in "$RUN_FOLDER"/dispositions-*.json; do
    [ -e "$dispositions_file" ] || continue
    base="${dispositions_file##*/}"
    [[ "$base" =~ ^dispositions-([0-9]+)\.json$ ]] || continue
    round="${BASH_REMATCH[1]}"
    round=$((10#$round))
    [ "$round" -gt "$last_round" ] && last_round="$round"
    exit_status=0
    CHECKED_VERSION=2
    if _has_snapshot "$round"; then
      _check_snapshot "$round" || exit_status=$?
    else
      _check_live "$round" || exit_status=$?
    fi
    _fold "$exit_status"
    # A round whose dispositions file did not read has nothing to reconcile.
    if [ "$CHECKED_VERSION" -ge 2 ] && [ "$exit_status" -ne 3 ]; then
      exit_status=0
      _check_outcomes "$round" || exit_status=$?
      _fold "$exit_status"
    fi
  done
  # The bound hook's call passes --snapshot-dir and skips this, or it would
  # deny the unit dispatched to repair the veto.
  if [ -z "$SNAPSHOT_DIRECTORY" ]; then
    exit_status=0
    _lapsed_vetoes "$last_round" || exit_status=$?
    _fold "$exit_status"
    exit_status=0
    _undecided_keys || exit_status=$?
    _fold "$exit_status"
  fi
  return "$WORST"
}

# _round_lookup <round>: the snapshot's lookup when one exists, else the live
# one, else "[]" (every key then reads unknown).
_round_lookup() {
  local lookup=""
  if _has_snapshot "$1"; then
    lookup="$(jq -c 'if (.lookup | type) == "array" then .lookup else error("bad") end' <"$(_snapshot_path "$1")" 2>/dev/null)" || lookup=""
  fi
  [ -n "$lookup" ] || lookup="$(_live_lookup "$1")" || lookup="[]"
  printf '%s\n' "$lookup"
}

# _divert_line <count>: the only form a divert takes outside the local record.
_divert_line() {
  printf 'Diverted security findings: %s (local records under .gaia/local/audit/security/)\n' "$1"
}

# shellcheck disable=SC2016
_TABLE_JQ="$_RESIDUAL_REASON_JQ"'
def key_array: [.member, .finding_class, .path, .line];
def cell: tostring | gsub("\\|"; "\\|") | gsub("\\s+"; " ");
($lookup | map({key: (key_array | tojson), value: .}) | from_entries) as $lookup_by_key
| .entries[] | select(.disposition != "fix" and .disposition != "divert") | . as $entry | $lookup_by_key[(key_array | tojson)] as $lookup_entry
| "| \("\(.path):\(.line) \(.finding_class)" | cell) | \(.member | cell) | \(($lookup_entry.severity // "unknown") | cell)"
  + " | \(($lookup_entry | if . == null then "unknown" else (.security | if type == "boolean" then . else true end) end) | cell)"
  + " | \(.disposition | cell) | \((if .disposition == "accept-residual" then residual_reason($lookup_entry) else .reason end)
    | if type == "string" then . else "" end | cell) |"
'

_command_waiver_table() {
  local first_round last_round round dispositions_file lookup divert_count=0 round_diverts
  [[ "${ROUNDS:-}" =~ ^([0-9]+)-([0-9]+)$ ]] || { _usage; return 2; }
  first_round=$((10#${BASH_REMATCH[1]}))
  last_round=$((10#${BASH_REMATCH[2]}))
  printf '| key | member | severity | security | disposition | reason |\n|---|---|---|---|---|---|\n'
  round="$first_round"
  while [ "$round" -le "$last_round" ]; do
    dispositions_file="$RUN_FOLDER/dispositions-$round.json"
    if [ -f "$dispositions_file" ]; then
      _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
      lookup="$(_round_lookup "$round")"
      jq -r --argjson lookup "$lookup" "$_TABLE_JQ" "$dispositions_file" || return 3
      round_diverts="$(jq '[.entries[] | select(.disposition == "divert")] | length' "$dispositions_file")" || return 3
      divert_count=$((divert_count + round_diverts))
    fi
    round=$((round + 1))
  done
  [ "$divert_count" -eq 0 ] || { printf '\n'; _divert_line "$divert_count"; }
}

main() {
  local subcommand="${1-}"
  [ $# -gt 0 ] && shift
  ROOT="" RUN_FOLDER="" ROUND="" ROUNDS="" SNAPSHOT_DIRECTORY="" READ_DIRECTORY="" FINDING_FILE="" DECISION=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || { _usage; return 2; }; ROOT="$2"; shift 2 ;;
      --run-folder) [ $# -ge 2 ] || { _usage; return 2; }; RUN_FOLDER="$2"; shift 2 ;;
      --round) [ $# -ge 2 ] || { _usage; return 2; }; ROUND="$2"; shift 2 ;;
      --rounds) [ $# -ge 2 ] || { _usage; return 2; }; ROUNDS="$2"; shift 2 ;;
      --snapshot-dir) [ $# -ge 2 ] || { _usage; return 2; }; SNAPSHOT_DIRECTORY="$2"; shift 2 ;;
      --finding) [ $# -ge 2 ] || { _usage; return 2; }; FINDING_FILE="$2"; shift 2 ;;
      --decision) [ $# -ge 2 ] && [[ "$2" =~ ^(accept|waive|fix)$ ]] || { _usage; return 2; }; DECISION="$2"; shift 2 ;;
      *) _usage; return 2 ;;
    esac
  done
  case "$subcommand" in
    check | check-all | check-outcomes | waiver-table | pr-sections | residual-count | record-residual | undecided) ;;
    *) _usage; return 2 ;;
  esac
  [ -n "$RUN_FOLDER" ] || { _usage; return 2; }
  [ -n "$ROOT" ] || { _usage; return 2; }
  [ "$subcommand" != record-residual ] || [ -n "$FINDING_FILE" ] || { _usage; return 2; }
  [ -z "$DECISION" ] || [ "$subcommand" = record-residual ] || { _usage; return 2; }
  command -v jq >/dev/null 2>&1 || { _error "jq is required and was not found on PATH"; return 3; }
  READ_DIRECTORY="$SNAPSHOT_DIRECTORY"
  [ -n "$READ_DIRECTORY" ] || READ_DIRECTORY="$(_default_snapshot_directory)"
  case "$subcommand" in
    check) _command_check ;;
    check-all) _command_check_all ;;
    check-outcomes) _command_check_outcomes ;;
    waiver-table) _command_waiver_table ;;
    pr-sections) _command_pr_sections ;;
    residual-count) _command_residual_count ;;
    record-residual) _command_record_residual ;;
    undecided) _command_undecided ;;
  esac
}

main "$@"
exit $?
