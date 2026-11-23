#!/usr/bin/env bash
# shellcheck shell=bash
#
# audit-fix-verify.sh: deterministic check of one audit fix round. The main
# thread records a working-tree baseline after the audit members return, a
# fresh fixer sub-agent edits the tree, and this script judges the fixer's
# delta from that baseline. The main thread never trusts the fixer's own
# account of what it did: it commits and runs the Quality Gate only on a pass.
# Members only report, so the baseline refuses a tree the member wave left
# dirty and only the fixer's delta is ever judged.
#
# The verifier judges the fixer from a pinned copy of itself. The baseline
# subcommand copies this script and the libraries it sources into
# <run-folder>/verifier-bin-<r>/ (beside the baseline file) and records their
# digest in the baseline; the main thread runs check, settled, round-check and
# drift from that copy by its run-folder path, never from the working tree the
# fixer edits. Each of those subcommands refuses (bad-input, or exit 1 for
# settled, drift and round-check) when the files beside it no longer hash to the
# recorded digest.
# An edit to the working-tree verifier therefore takes effect from the next
# round's baseline, not within the round that made it.
#
# Usage:
#   audit-fix-verify.sh baseline    --root <R> --round <r> --out <baseline-file>
#                                   (also writes verifier-bin-<r>/ beside it)
#   audit-fix-verify.sh check       --root <R> --round <r> --attempt <k>
#                                   --dispositions <f> --dispositions-sha <hex>
#                                   --baseline <f> --baseline-sha <hex>
#                                   --result <fixer-file> --out <verifier-file>
#                                   [--extra-declared <paths-file>]...
#   audit-fix-verify.sh settled     --root <R> --baseline <f> --verifier <verifier-file>
#                                   --result <fixer-file> [--extra-declared <paths-file>]...
#   audit-fix-verify.sh drift       --root <R> --baseline <f>
#   audit-fix-verify.sh round-check --run-folder <dir> --round <r>
#
# Exit codes: 0 pass, 1 findings (check prints each to stderr on its own line as
# `kind: detail`; settled prints each finding the same way, `head-moved` bare;
# drift and round-check print their own one-line messages), 2
# usage or missing jq, 3 baseline refusal (index differs from HEAD, or the repo
# state cannot be read; no output file is written), 4 baseline refusal because
# the member wave left the tree dirty (a modified tracked file or an untracked, non-ignored
# file; stdout is `member-wave-dirty` then one `dirty <path>` line per path, no
# output file is written, and the caller stops without committing). Git-ignored
# paths never trip it. `check` writes its verifier file on every outcome,
# failures included.
#
# Attempt rule: k starts at 1 for the fixer's first write in a round and
# increases by 1 on every SendMessage continuation (verifier retry or gate
# repair alike). The fixer rewrites fixer-<r>-audit.json with "attempt": k and
# --attempt must equal it. verifier-<r>-<k>.json, gate-<r>-<k>.log and
# gate-<r>-<k>.paths use the same k.
#
# The main thread records the sha256 of the dispositions and baseline files
# before the fixer dispatch and passes them as --dispositions-sha and
# --baseline-sha, so the fixer cannot widen enforcement_paths_allowed or the
# baseline's dirty set (both would be bad-input).
#
# --extra-declared names a newline-separated paths file the main thread
# recorded as changed by the Quality Gate's autofix (gate-<r>-<k>.paths), so a
# re-verification after a gate repair does not fail on edits the fixer did not
# make.
#
# Run-folder file shapes (this header is their single owner), all under
# <MAIN>/.gaia/local/runs/<B>/:
#
#   dispositions-<r>.json (the round's orchestrator: the unit):
#     {"schema":1,"round":r,"tree":"<hex>","root":"<abs resolved root>",
#      "enforcement_paths_allowed":["<path>"],
#      "entries":[{"member","finding_class","path","line","severity","title",
#        "failure_mode","suggested_fix","direction",
#        "disposition":"fix|accept-residual|waive-out-of-scope|file|divert","reason",
#        "basis":"triage-threshold|cross-remit","enforcement_draft":true}]}
#     enforcement_paths_allowed lists an enforcement path only when an entry
#     marked fix names that path. basis is required on waive-out-of-scope
#     entries; this verifier does not read it, the dispositions check does.
#     enforcement_draft marks a vetoed key's fix entry on an enforcement path:
#     the fixer may draft that edit, and this verifier still fails it as
#     enforcement-path, so the round never commits it.
#
#   vetoes.json (Bash at the main-checkout path, or record-residual --decision fix):
#     {"version":1,"keys":[{"member","finding_class","path","line","vetoed_at",
#       "unit","effective_from_round","direction"}]}
#     direction (optional) is the human's repair: the unit copies it into the
#     key's fix entry, and the fixer follows it over suggested_fix. No check reads it.
#     effective_from_round is the <s> that audit-loop-eval.sh next-unit prints
#     when the veto is written (the first round the next unit opens), so a
#     veto never re-fails the dispositions file that held the original waiver.
#
#   unit-<u>.json (the unit; absent while the unit runs, so its appearance
#   marks the unit returned):
#     {"version":1,"unit":u,"start_round":s,"through_round":t,"k":K,
#      "rounds":[{"round":r,"opened":true|false,...}],
#      "marker_state":{"<member>":"cleared|pending|declined"},
#      "stop_reason":"clean|window-end|checkpoint-deny|dispositions-check-failed|needs-human|member-wave-dirty|failure",
#      "stop_detail":"...","dispositions_files":["<path>"],
#      "waiver_table":"<markdown, informational>","residual_path":"...",
#      "diverted_count":<int>,"diverted_records":["<path>"],
#      "filing_outcomes":["<path>"],"filing_pending":<int>,
#      "accepted_residual_count":<int>}
#     accepted_residual_count is `.total` of audit-dispositions-check.sh
#     residual-count when the unit ends: a run-wide total, informational, never
#     summed across unit files (the main thread reads residual-count itself).
#     A unit that opened no round writes one element
#     {"round":<start>,"opened":false,"reason":"<stop_reason>"}.
#
#   baseline-<r>.json (the baseline subcommand):
#     {"schema":1,"round":r,"root":"...","head":"<commit>",
#      "index_digest":"<sha256 of git ls-files -s -z output>",
#      "verifier_files":["<file name in verifier-bin-<r>/>"],
#      "verifier_digest":"<sha256 over each pinned file's sha256 and name>",
#      "dirty":{"<path>":"<blob hash of working content, deleted, or unreadable>"},
#      "untracked":["<path>"]}
#
#   fixer-<r>-audit.json (the fixer):
#     {"schema":1,"round":r,"attempt":k,
#      "results":[{"member","finding_class","path","line",
#        "disposition":"fixed|disputed|cannot_fix","reason","changed_paths":[]}],
#      "changed_paths":[],"reverted_paths":[]}
#
#   verifier-<r>-<k>.json (the check subcommand):
#     {"schema":1,"round":r,"attempt":k,"pass":true|false,
#      "errors":[{"kind","detail"}],
#      "judged":{"paths":{"<path>":"<blob hash, deleted, or unreadable>"},
#        "result_sha":"<sha256 of the fixer file>"}|null}
#     judged is set only on a pass: each path differing from HEAD, untracked
#     paths included and hashed, as the check read them. settled compares the
#     tree and the fixer file against it before the round stages anything, and
#     fails on head-moved, result-moved, tree-moved (one line per path; paths in
#     --extra-declared files are exempt) or bad-input.
#     kinds: missing-disposition, undeclared-path, undeclared-revert,
#     forbidden-path, enforcement-path, head-moved, index-changed,
#     audit-artifact-written, bad-input.
#     audit-artifact-written fires on a file under the shared audit directory
#     newer than the baseline unless it provably belongs to another branch.
#     A sidecar, ledger or scope file is skipped when its name lacks this
#     branch's slug. A marker or refusal is skipped only when its body's tree is
#     a well-formed object id that differs from this root's HEAD tree and from
#     the tree of its working content, its sha differs from HEAD, and the digest
#     in its file name is none of this branch's branch-own digests (at HEAD and
#     for the working content). A body with no tree, a malformed tree, or a
#     digest this branch's members own counts, as does every marker when the
#     branch-own digests cannot be resolved. Another branch's concurrent
#     audit never fails this branch's round.
#
# Known limits: check judges an untracked path on presence only, never content
# (settled hashes it), and a mode-only change on a baseline-dirty path is invisible because the
# comparison is on content hashes. Both fail toward missing a delta the
# fixer's own declaration would have to name; the Quality Gate and the audit
# re-run still read the tree.

# Files the baseline pins into the run folder: this script and every library it
# sources from its own directory.
PIN_FILES=(
  audit-fix-verify.sh
  main-root-lib.sh
  audit-key-lib.sh
  audit-fix-verify-state-lib.sh
  audit-fix-verify-check-lib.sh
)

# Paths a fixer may never touch, declared or not.
# shellcheck disable=SC2034 # read by audit-fix-verify-check-lib.sh, sourced below
FORBIDDEN_PATHS=(
  'CHANGELOG.md'                              # the main thread owns the entry; the unit never edits it
)

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage:
  audit-fix-verify.sh baseline    --root <R> --round <r> --out <baseline-file>
  audit-fix-verify.sh check       --root <R> --round <r> --attempt <k> --dispositions <f> --dispositions-sha <hex> --baseline <f> --baseline-sha <hex> --result <f> --out <f> [--extra-declared <paths-file>]...
  audit-fix-verify.sh settled     --root <R> --baseline <f> --verifier <f> --result <f> [--extra-declared <paths-file>]...
  audit-fix-verify.sh drift       --root <R> --baseline <f>
  audit-fix-verify.sh round-check --run-folder <dir> --round <r>
EOF
  exit 2
}

die_usage() {
  printf 'audit-fix-verify: %s\n' "$1" >&2
  usage
}

command -v jq >/dev/null 2>&1 || {
  printf 'audit-fix-verify: jq is required and was not found on PATH\n' >&2
  exit 2
}

ROOT=''
ROUND=''
ATTEMPT=''
OUTPUT_FILE=''
DISPOSITIONS_FILE=''
DISPOSITIONS_SHA=''
BASELINE_FILE=''
BASELINE_SHA=''
RESULT=''
VERIFIER_FILE=''
RUNFOLDER=''
EXTRA_DECLARED_FILES=''

TEMPORARY_DIRECTORY=''
# shellcheck disable=SC2329 # invoked through the EXIT trap
cleanup() { if [ -n "$TEMPORARY_DIRECTORY" ]; then rm -rf "$TEMPORARY_DIRECTORY"; fi; }
trap cleanup EXIT

# A library missing from beside this script (a partial pin, a partial copy)
# stops here rather than running on with its functions undefined.
for _library in audit-fix-verify-state-lib.sh audit-fix-verify-check-lib.sh; do
  [ -r "$_here/$_library" ] || {
    printf 'audit-fix-verify: %s is required beside this script and was not found\n' "$_library" >&2
    exit 2
  }
done
unset _library
# shellcheck source=audit-fix-verify-state-lib.sh
. "$_here/audit-fix-verify-state-lib.sh" || exit 2
# shellcheck source=audit-fix-verify-check-lib.sh
. "$_here/audit-fix-verify-check-lib.sh" || exit 2

command_baseline() {
  local pin_directory pin_digest file_name
  if [ -z "$ROOT" ] || [ -z "$OUTPUT_FILE" ] || ! _is_uint "$ROUND"; then
    die_usage 'baseline needs --root, --round <int> and --out'
  fi
  TEMPORARY_DIRECTORY="$(mktemp -d)" || exit 1
  if ! _git diff --cached --quiet 2>/dev/null; then
    printf 'audit-fix-verify: baseline refused: the index differs from HEAD (staged change or unreadable repo) in %s\n' "$ROOT" >&2
    exit 3
  fi
  if ! snapshot_state "$TEMPORARY_DIRECTORY/cur"; then
    printf 'audit-fix-verify: baseline refused: cannot read repo state (or a path contains a newline) in %s\n' "$ROOT" >&2
    exit 3
  fi
  # Members run in parallel on one tree and only report, so no edit is
  # attributable to one of them: any dirt after the wave stops the unit.
  {
    jq -r 'keys[]' "$TEMPORARY_DIRECTORY/cur/dirty.json"
    cat "$TEMPORARY_DIRECTORY/cur/untracked.txt"
  } | LC_ALL=C sort -u >"$TEMPORARY_DIRECTORY/wave-dirty.txt"
  if [ -s "$TEMPORARY_DIRECTORY/wave-dirty.txt" ]; then
    printf 'member-wave-dirty\n'
    while IFS= read -r file_name; do
      printf 'dirty %s\n' "$file_name"
    done <"$TEMPORARY_DIRECTORY/wave-dirty.txt"
    printf 'audit-fix-verify: baseline refused: the member wave left the tree dirty in %s\n' "$ROOT" >&2
    exit 4
  fi
  pin_directory="$(dirname "$OUTPUT_FILE")/verifier-bin-$ROUND"
  rm -rf "$pin_directory"
  mkdir -p "$pin_directory" || exit 1
  for file_name in "${PIN_FILES[@]}"; do
    cp "$_here/$file_name" "$pin_directory/$file_name" || {
      printf 'audit-fix-verify: cannot pin %s into %s\n' "$file_name" "$pin_directory" >&2
      exit 1
    }
  done
  pin_digest="$(_pin_digest "$pin_directory" "${PIN_FILES[@]}")" || {
    printf 'audit-fix-verify: cannot hash the pinned verifier in %s\n' "$pin_directory" >&2
    exit 1
  }
  jq -n --argjson round "$ROUND" --arg root "$ROOT" \
    --arg head "$(cat "$TEMPORARY_DIRECTORY/cur/head")" --arg index_digest "$(cat "$TEMPORARY_DIRECTORY/cur/index_digest")" \
    --slurpfile dirty "$TEMPORARY_DIRECTORY/cur/dirty.json" \
    --rawfile untracked "$TEMPORARY_DIRECTORY/cur/untracked.txt" \
    --arg pin_digest "$pin_digest" \
    '{schema: 1, round: $round, root: $root, head: $head, index_digest: $index_digest,
      verifier_files: $ARGS.positional, verifier_digest: $pin_digest,
      dirty: $dirty[0], untracked: ($untracked | split("\n") | map(select(. != "")))}' \
    --args "${PIN_FILES[@]}" |
    _atomic_write "$OUTPUT_FILE" || {
    printf 'audit-fix-verify: cannot write %s\n' "$OUTPUT_FILE" >&2
    exit 1
  }
  exit 0
}

command_drift() {
  local exit_status=0 file_path
  if [ -z "$ROOT" ] || [ -z "$BASELINE_FILE" ]; then
    die_usage 'drift needs --root and --baseline'
  fi
  TEMPORARY_DIRECTORY="$(mktemp -d)" || exit 1
  jq -e '.schema == 1 and (.dirty | type == "object") and (.untracked | type == "array")' "$BASELINE_FILE" >/dev/null 2>&1 || {
    printf 'bad-input: baseline does not parse: %s\n' "$BASELINE_FILE" >&2
    exit 1
  }
  _verify_pin "$BASELINE_FILE" || {
    printf 'bad-input: the verifier files beside this script differ from the digest pinned in %s\n' "$BASELINE_FILE" >&2
    exit 1
  }
  snapshot_state "$TEMPORARY_DIRECTORY/cur" || {
    printf 'bad-input: cannot read repo state in %s\n' "$ROOT" >&2
    exit 1
  }
  compute_delta "$BASELINE_FILE" "$TEMPORARY_DIRECTORY/cur" || exit 1
  if [ "$(cat "$TEMPORARY_DIRECTORY/cur/head")" != "$(jq -r '.head' "$BASELINE_FILE")" ]; then
    printf 'head-moved\n' >&2
    exit_status=1
  fi
  if [ "$(cat "$TEMPORARY_DIRECTORY/cur/index_digest")" != "$(jq -r '.index_digest' "$BASELINE_FILE")" ]; then
    printf 'index-changed\n' >&2
    exit_status=1
  fi
  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    printf 'drift: %s\n' "$file_path" >&2
    exit_status=1
  done < <(cat "$TEMPORARY_DIRECTORY/cur/d_mod" "$TEMPORARY_DIRECTORY/cur/d_rev" "$TEMPORARY_DIRECTORY/cur/d_unt")
  exit "$exit_status"
}

command_round_check() {
  local exit_status=0 log_file attempt_number
  if [ -z "$RUNFOLDER" ] || ! _is_uint "$ROUND"; then
    die_usage 'round-check needs --run-folder and --round <int>'
  fi
  if [ -e "$RUNFOLDER/baseline-$ROUND.json" ] && ! _verify_pin "$RUNFOLDER/baseline-$ROUND.json"; then
    printf 'bad-input: the verifier files beside this script differ from the digest pinned in baseline-%s.json\n' "$ROUND" >&2
    exit 1
  fi
  for log_file in "$RUNFOLDER"/gate-"$ROUND"-*.log; do
    [ -e "$log_file" ] || continue
    attempt_number="${log_file##*/gate-"$ROUND"-}"
    attempt_number="${attempt_number%.log}"
    _is_uint "$attempt_number" || continue
    if ! jq -e '.pass == true' "$RUNFOLDER/verifier-$ROUND-$attempt_number.json" >/dev/null 2>&1; then
      printf 'gate-%s-%s.log exists without a passing verifier-%s-%s.json\n' "$ROUND" "$attempt_number" "$ROUND" "$attempt_number" >&2
      exit_status=1
    fi
  done
  exit "$exit_status"
}

[ $# -ge 1 ] || usage
SUBCOMMAND="$1"
shift
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die_usage "option $1 needs a value"
  # shellcheck disable=SC2034 # the check and settled options are read by audit-fix-verify-check-lib.sh
  case "$1" in
    --root) ROOT="$2" ;;
    --round) ROUND="$2" ;;
    --attempt) ATTEMPT="$2" ;;
    --out) OUTPUT_FILE="$2" ;;
    --dispositions) DISPOSITIONS_FILE="$2" ;;
    --dispositions-sha) DISPOSITIONS_SHA="$2" ;;
    --baseline) BASELINE_FILE="$2" ;;
    --baseline-sha) BASELINE_SHA="$2" ;;
    --result) RESULT="$2" ;;
    --verifier) VERIFIER_FILE="$2" ;;
    --run-folder) RUNFOLDER="$2" ;;
    --extra-declared) EXTRA_DECLARED_FILES="$EXTRA_DECLARED_FILES$2"$'\n' ;;
    *) die_usage "unknown option $1" ;;
  esac
  shift 2
done

case "$SUBCOMMAND" in
  baseline) command_baseline ;;
  check) command_check ;;
  settled) command_settled ;;
  drift) command_drift ;;
  round-check) command_round_check ;;
  *) die_usage "unknown subcommand $SUBCOMMAND" ;;
esac
