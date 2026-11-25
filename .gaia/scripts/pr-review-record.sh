#!/usr/bin/env bash
# The sole writer of a pull request's review record, <run>/pr-review.json. Every
# write goes through install_record (a temp file plus mv), so a reader never sees
# half a record. The reviewer's findings are fixed at `outcome`: the record
# carries their digest, and every subcommand that reads the record recomputes it,
# so an edit made outside this script is caught on the next call.
#
#   open          --root --run-folder --pr --head --bundle [--retry]
#   attempt-open  --run-folder
#   attempt-close --run-folder --n (--classifier-exit <0|1> | --dispatch-failed)
#   outcome       --run-folder --findings <reviewer-output-file>
#   not-run       --run-folder --reason <reason>
#   dispose       --run-folder --id --disposition [--reason] [--issue] [--basis] [--severity] [--security]
#   route-fix     --root --run-folder --id
#   fixed         --root --run-folder --id [--commit]
#   dropped       --run-folder --id --by --evidence
#   fix-commit    --run-folder --sha
#   read          --run-folder
#
# Exit: 0 done, 1 a rule refusal (the line is printed on stdout), 2 usage, 3 the
# reviewer's file failed its schema (the refusal line is printed and recorded on
# the attempt), 4 a fix needs a human, 5 the record is unreadable or its findings
# changed after `outcome`.
#
# The branch name and the main root come from --run-folder, which must end in
# /.gaia/local/runs/<branch>; a --root must resolve to that same main root. The
# record stores no bundle path, so `open` copies the bundle's changed-file list
# beside the record (pr-review-changed-files.txt) for `outcome` to check each
# finding's file against.
#
# HONEST LIMIT. This is a local file under the git-ignored run folder: a
# tree-writing actor can rewrite it whole. The digest catches an edit of the
# findings, not a replaced record, which the gates meet as a record keyed to
# another pull request or head.
#
# Bash 3.2 compatible. jq programs are single-quoted so their `$` reach jq.
# SC2034: the argument variables are read by the sourced record library.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERDICT_LIBRARY="$SCRIPT_DIRECTORY/../../.claude/hooks/lib/pr-review-verdict.sh"
RECORD_LIBRARY="$SCRIPT_DIRECTORY/pr-review-record-lib.sh"

# A failed source under bash 3.2 ends the shell before any `||` runs, so the
# file test comes first.
for library in "$VERDICT_LIBRARY" "$RECORD_LIBRARY" "$SCRIPT_DIRECTORY/audit-loop-state-lib.sh"; do
  [ -f "$library" ] || {
    printf 'pr-review-record: missing library: %s\n' "$library" >&2
    exit 1
  }
done
# shellcheck source=/dev/null
. "$SCRIPT_DIRECTORY/audit-loop-state-lib.sh"
# shellcheck source=/dev/null
. "$VERDICT_LIBRARY"
# shellcheck source=/dev/null
. "$RECORD_LIBRARY"

die_usage() {
  printf 'pr-review-record: %s\n' "$1" >&2
  exit 2
}

SUBCOMMAND="${1-}"
[ $# -gt 0 ] && shift
ROOT="" RUN_FOLDER="" PR="" HEAD_SHA="" BUNDLE="" RETRY=0 ATTEMPT="" CLASSIFIER_EXIT="" DISPATCH_FAILED=0
FINDINGS_FILE="" REASON="" FINDING_ID="" DISPOSITION="" ISSUE="" BASIS="" SEVERITY="" SECURITY="" MEMBER=""
EVIDENCE="" COMMIT="" SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --retry) RETRY=1; shift; continue ;;
    --dispatch-failed) DISPATCH_FAILED=1; shift; continue ;;
  esac
  [ $# -ge 2 ] || die_usage "$1 needs a value"
  case "$1" in
    --root) ROOT="$2" ;;
    --run-folder) RUN_FOLDER="$2" ;;
    --pr) PR="$2" ;;
    --head) HEAD_SHA="$2" ;;
    --bundle) BUNDLE="$2" ;;
    --n) ATTEMPT="$2" ;;
    --classifier-exit) CLASSIFIER_EXIT="$2" ;;
    --findings) FINDINGS_FILE="$2" ;;
    --reason) REASON="$2" ;;
    --id) FINDING_ID="$2" ;;
    --disposition) DISPOSITION="$2" ;;
    --issue) ISSUE="$2" ;;
    --basis) BASIS="$2" ;;
    --severity) SEVERITY="$2" ;;
    --security) SECURITY="$2" ;;
    --by) MEMBER="$2" ;;
    --evidence) EVIDENCE="$2" ;;
    --commit) COMMIT="$2" ;;
    --sha) SHA="$2" ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift 2
done

case "$RUN_FOLDER" in /*) ;; *) die_usage "--run-folder must be an absolute path" ;; esac
RUN_FOLDER="${RUN_FOLDER%/}"
case "$RUN_FOLDER" in
  */.gaia/local/runs/?*) ;;
  *) die_usage "--run-folder must end in /.gaia/local/runs/<branch>" ;;
esac
MAIN_ROOT="${RUN_FOLDER%%/.gaia/local/runs/*}"
NORMALIZED_BRANCH="${RUN_FOLDER#"$MAIN_ROOT"/.gaia/local/runs/}"
[ -n "$MAIN_ROOT" ] || die_usage "--run-folder has no main root"
_gaia_loop_keyable "$NORMALIZED_BRANCH" || die_usage "--run-folder names an unkeyable branch: $NORMALIZED_BRANCH"
RECORD_FILE="$(pr_review_record_path "$MAIN_ROOT" "$NORMALIZED_BRANCH")"
[ "$RECORD_FILE" = "$RUN_FOLDER/pr-review.json" ] || die_usage "--run-folder is not the run folder of branch $NORMALIZED_BRANCH"
CHANGED_FILES_COPY="$RUN_FOLDER/pr-review-changed-files.txt"

now_stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# install_record: stdin becomes the record, or nothing changes. The check catches
# a jq failure upstream, which pipefail alone would report only after the temp
# file already held a truncated value.
install_record() {
  local temporary_file
  mkdir -p "$RUN_FOLDER"
  temporary_file="$(mktemp "$RUN_FOLDER/.pr-review.json.XXXXXX")"
  cat >"$temporary_file"
  if jq -e 'type == "object" and .version == 1' "$temporary_file" >/dev/null 2>&1; then
    mv -f "$temporary_file" "$RECORD_FILE"
  else
    rm -f "$temporary_file"
    printf 'pr-review-record: refused to write a malformed record\n' >&2
    return 1
  fi
}

# refuse <line>: a rule refusal, exit 1. The record stays as it was.
refuse() {
  printf '%s\n' "$1"
  exit 1
}

# record_state: absent, unreadable, tampered or ok. -s so a file holding two JSON
# values is unreadable rather than reading as its last. The digest binds the
# findings at `outcome`; a record with no outcome holds no findings.
record_state() {
  [ -e "$RECORD_FILE" ] || { printf 'absent\n'; return 0; }
  if ! jq -e -s 'length == 1 and (.[0] | type == "object" and .version == 1 and (.attempts | type) == "array"
      and (.findings | type) == "array" and (.review_fix_commits | type) == "array")' "$RECORD_FILE" >/dev/null 2>&1; then
    printf 'unreadable\n'
    return 0
  fi
  if [ "$(jq -r '.outcome' "$RECORD_FILE")" = null ]; then
    if jq -e '.findings == []' "$RECORD_FILE" >/dev/null 2>&1; then printf 'ok\n'; else printf 'tampered\n'; fi
    return 0
  fi
  if [ "$(pr_review_findings_digest "$(cat "$RECORD_FILE")")" = "$(jq -r '.findings_sha256' "$RECORD_FILE")" ]; then
    printf 'ok\n'
  else
    printf 'tampered\n'
  fi
}

# require_record: every subcommand that reads the record starts here, so a hand
# edit is caught before anything else runs on it.
require_record() {
  case "$(record_state)" in
    ok) ;;
    absent) refuse "no review record" ;;
    unreadable)
      printf 'pr-review-record: record unreadable: %s\n' "$RECORD_FILE" >&2
      exit 5
      ;;
    *)
      printf 'record findings changed after outcome\n' >&2
      exit 5
      ;;
  esac
}

require_pr() {
  [[ "$PR" =~ ^[1-9][0-9]{0,9}$ ]] || die_usage "--pr must be a positive integer"
}
require_attempt() {
  [[ "$ATTEMPT" =~ ^[1-9][0-9]*$ ]] || die_usage "--n must be a positive integer"
}
# require_open_record: the review has no outcome yet.
require_open_record() {
  [ "$(jq -r '.outcome' "$RECORD_FILE")" = null ] || refuse "the review already has an outcome"
}

fresh_record() {
  jq -n --argjson pr "$PR" --arg head "$HEAD_SHA" --slurpfile meta "$BUNDLE/meta.json" '{version: 1, pr: $pr, reviewed_head: $head,
    spec: $meta[0].spec, spec_author_not_collaborator: ($meta[0].spec_author_not_collaborator == true),
    changelog_present: ($meta[0].changelog_present == true), attempts: [], outcome: null, not_run_reason: null,
    findings: [], findings_sha256: null, review_fix_commits: []}'
}

# open: a record whose review already has an outcome ends the dispatch for the
# pull request, whatever the head has since done. A record for another pull
# request is replaced.
cmd_open() {
  require_pr
  [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ || "$HEAD_SHA" =~ ^[0-9a-f]{64}$ ]] || die_usage "--head must be a full commit sha"
  [ -f "$BUNDLE/meta.json" ] && [ -f "$BUNDLE/changed-files.txt" ] || die_usage "--bundle must hold meta.json and changed-files.txt"
  jq -e '(.spec | IN("present", "none"))' "$BUNDLE/meta.json" >/dev/null 2>&1 || die_usage "--bundle meta.json has no spec of present or none"
  require_main_root_match
  local state outcome
  state="$(record_state)"
  case "$state" in
    unreadable) exit 5 ;;
    tampered)
      printf 'record findings changed after outcome\n' >&2
      exit 5
      ;;
  esac
  if [ "$state" = ok ] && [ "$(jq -r '.pr' "$RECORD_FILE")" = "$PR" ]; then
    outcome="$(jq -r '.outcome' "$RECORD_FILE")"
    if [ "$RETRY" -eq 1 ]; then
      [ "$outcome" = not-run ] || refuse "retry needs a not-run record"
    else
      if [ "$outcome" != null ]; then
        printf 'exists\n'
        return 0
      fi
      # An outcome-less record the head has moved past is reviewed at the new head:
      # the attempts stay, the head, the changed-file list and the bundle's spec
      # fields follow the bundle (a body edit can add or drop a closed issue).
      if [ "$(jq -r '.reviewed_head' "$RECORD_FILE")" != "$HEAD_SHA" ]; then
        cp "$BUNDLE/changed-files.txt" "$CHANGED_FILES_COPY.tmp.$$" || die_usage "cannot copy the bundle's changed-file list"
        mv -f "$CHANGED_FILES_COPY.tmp.$$" "$CHANGED_FILES_COPY"
        jq --arg head "$HEAD_SHA" --slurpfile meta "$BUNDLE/meta.json" '.reviewed_head = $head
          | .spec = $meta[0].spec
          | .spec_author_not_collaborator = ($meta[0].spec_author_not_collaborator == true)
          | .changelog_present = ($meta[0].changelog_present == true)' "$RECORD_FILE" | install_record
      fi
      printf 'opened\n'
      return 0
    fi
  elif [ "$RETRY" -eq 1 ]; then
    refuse "retry needs a not-run record"
  fi
  mkdir -p "$RUN_FOLDER"
  cp "$BUNDLE/changed-files.txt" "$CHANGED_FILES_COPY.tmp.$$" || die_usage "cannot copy the bundle's changed-file list"
  mv -f "$CHANGED_FILES_COPY.tmp.$$" "$CHANGED_FILES_COPY"
  fresh_record | install_record
  printf 'opened\n'
}

cmd_attempt_open() {
  require_record
  require_open_record
  local open_number
  open_number="$(jq -r '[.attempts[] | select(.state == "open") | .n] | first // empty' "$RECORD_FILE")"
  # A session that ended mid-dispatch left its attempt open; the resumed run
  # takes it over rather than spend the second.
  if [ -n "$open_number" ]; then
    printf '%s\n' "$open_number"
    return 0
  fi
  [ "$(jq '.attempts | length' "$RECORD_FILE")" -lt 2 ] || die_usage "a third attempt is refused: the review gets two"
  jq '.attempts += [{n: ((.attempts | length) + 1), state: "open", classifier_exit: null, dispatch_failed: false, refusal: null}]' \
    "$RECORD_FILE" | install_record
  jq -r '.attempts | last | .n' "$RECORD_FILE"
}

cmd_attempt_close() {
  require_attempt
  if [ "$DISPATCH_FAILED" -eq 1 ]; then
    [ -z "$CLASSIFIER_EXIT" ] || die_usage "--dispatch-failed and --classifier-exit are exclusive"
  else
    [[ "$CLASSIFIER_EXIT" =~ ^[01]$ ]] || die_usage "--classifier-exit must be 0 or 1"
  fi
  require_record
  jq -e --argjson n "$ATTEMPT" 'any(.attempts[]; .n == $n and .state == "open")' "$RECORD_FILE" >/dev/null ||
    die_usage "attempt $ATTEMPT is not open"
  jq --argjson n "$ATTEMPT" --argjson failed "$DISPATCH_FAILED" --arg classifier_exit "$CLASSIFIER_EXIT" '
    .attempts |= map(if .n == $n then .state = "closed"
      | .dispatch_failed = ($failed == 1)
      | .classifier_exit = (if $failed == 1 then null else ($classifier_exit | tonumber) end) else . end)' \
    "$RECORD_FILE" | install_record
}

cmd_read() {
  require_record
  cat "$RECORD_FILE"
}

cmd_fix_commit() {
  [[ "$SHA" =~ ^[0-9a-f]{40}$ || "$SHA" =~ ^[0-9a-f]{64}$ ]] || die_usage "--sha must be a full commit sha"
  require_record
  jq --arg sha "$SHA" '.review_fix_commits |= (. + [$sha] | unique)' "$RECORD_FILE" | install_record
}

case "$SUBCOMMAND" in
  open) cmd_open ;;
  attempt-open) cmd_attempt_open ;;
  attempt-close) cmd_attempt_close ;;
  outcome) cmd_outcome ;;
  not-run) cmd_not_run ;;
  dispose) cmd_dispose ;;
  route-fix) cmd_route_fix ;;
  fixed) cmd_fixed ;;
  dropped) cmd_dropped ;;
  fix-commit) cmd_fix_commit ;;
  read) cmd_read ;;
  *) die_usage "usage: pr-review-record.sh open|attempt-open|attempt-close|outcome|not-run|dispose|route-fix|fixed|dropped|fix-commit|read ..." ;;
esac
