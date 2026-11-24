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
#   audit-dispositions-check.sh record-residual --root <R> --run-folder <D> --finding <file> [--decision accept|waive|fix|fixed|discard]
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
#   accept-residual-not-eligible  (version 3) accept-residual on a key no human accepted for the round
#                               (audit-accept-finding), when the round has no human accept and either the
#                               default stop does not hold or the file disposes fix a key in
#                               default_stop_keys (the stop's formula: audit-loop-eval.sh, DEFAULT STOP)
#   human-accepted-fix          (version 4) fix on a key a human accepted at or before the round
#                               (audit-accept-finding) that no binding veto names, unless the
#                               round's finding is security-class
#   undisposed                  a finding of any authorship, or an unsatisfied waiver-vetoed
#                               key for this round, with no entry in the file, unless the
#                               finding carries an honored triage mark or was disposed file,
#                               divert or accept-residual in an earlier round; check-all
#                               without --snapshot-dir also prints it for an unsatisfied veto
#                               whose round is past every dispositions file
#   undecided                   (check-all without --snapshot-dir; undecided after a stop that can skip
#                               the file) an open-round finding with no honored triage mark, same-round row,
#                               earlier file|divert, or earlier accept-residual (void once security-class)
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
# passing live `check` writes <S>/dispositions-<r>.checked.json (version 4: the
# file's sha256, the per-key lookup it graded, triage mark and failure mode
# included, and the stop inputs default_stop, default_stop_keys, review_bases,
# human_accept, accepted_keys and satisfied_vetoes), and `check-all` re-grades from that
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
# accepted key. Version 3 has no human-accepted-fix rule. Live rounds and
# version-4 snapshots use the current predicate.
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
# a human's waive as a triage waiver, a human's fixed as a fixed row naming its
# commit, and a human's fix as nothing, even with no dispositions file.
# record-residual appends the row for a finding the filer refused on replay,
# or with --decision a human's decision on a round no dispositions file covers,
# the latest row per member's key deciding it, and prints nothing; no
# dispositions eligibility rule grades it, but an accept or waive needs the
# open round's live read to show it not security-class, and a fixed needs that
# read to show it cross_remit too, with its path changed since the round's tree. A discard,
# on an enforcement-draft key, withdraws its veto (audit-recorded-decision-lib.sh). An accept row
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
# shellcheck source=/dev/null
. "$_GAIA_DISPOSITIONS_DIRECTORY/exclusive-lock-lib.sh"
# Fail loud: grading on with _TRIAGE_MEMBERS unbound would honor nothing.
# shellcheck source=/dev/null
. "$_GAIA_DISPOSITIONS_DIRECTORY/audit-triage-lib.sh" 2>/dev/null ||
  { printf 'audit-dispositions-check: cannot load %s/audit-triage-lib.sh\n' "$_GAIA_DISPOSITIONS_DIRECTORY" >&2; exit 3; }
# shellcheck source=/dev/null
. "$_GAIA_DISPOSITIONS_DIRECTORY/audit-dispositions-grade-lib.sh"
# shellcheck source=/dev/null
. "$_GAIA_DISPOSITIONS_DIRECTORY/audit-dispositions-snapshot-lib.sh"

_usage() {
  printf 'usage: audit-dispositions-check.sh check|check-all|check-outcomes|waiver-table|pr-sections|residual-count|record-residual|undecided --root <R> --run-folder <D> [--round <r>|--rounds <a>-<b>] [--snapshot-dir <S>] [--finding <file> [--decision accept|waive|fix|fixed|discard]]\n' >&2
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
      --decision) [ $# -ge 2 ] && [[ "$2" =~ ^(accept|waive|fix|fixed|discard)$ ]] || { _usage; return 2; }; DECISION="$2"; shift 2 ;;
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
