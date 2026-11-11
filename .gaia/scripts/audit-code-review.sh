#!/usr/bin/env bash
# Runs Claude Code's built-in /code-review once per branch in a headless child,
# bounds it, judges its result and leaves the review record.
#
#   audit-code-review.sh run --root <abs> --pr <n> --run-folder <abs>
#   audit-code-review.sh settings --root <abs> --attempt-dir <abs> --guard-script <abs>
#   audit-code-review.sh child-argv --target <t> --settings-file <abs>
#   audit-code-review.sh wait-ms
#
# `run` exits 0 on a recorded outcome or an unreadable record it leaves as found,
# 3 on `review moved the tree` (the audit unit stops for a human), 1 when it could
# not start or finish recording, 2 on usage. Its last stdout line on every exit it can
# trap is `code-review exit <status>`, which is what the unit waits on.
# `child-argv` prints the child's argv one argument per line, so the hand-run
# captures measure the shipped flags instead of a copy of them.
#
# Bash 3.2 compatible. Never `cd`s except where a call says why.
set -euo pipefail

# Measured from real runs, never from the environment: an override would be the
# setting this feature forbids. A value left UNMEASURED blocks a spawn, except the
# last, which only documents.
# The Claude Code version whose read-only probe passed: the tree unmoved, the
# dotenv read denied.
REVIEW_CHILD_PROVEN=2.1.319
REVIEW_TARGET_FORMAT='<base-sha>...<head-sha>'
# Twice the longer of the 271 second whole-branch capture and the 9 minute
# whole-tree benchmark, so 18 minutes. The review's cost grows with the diff, and a
# kill at this bound costs the attempt, not the branch.
REVIEW_TIMEOUT_SECONDS=1080
# Documents whether a hook-blocked read reaches the result's denial list. Nothing
# branches on it: the denial count takes the larger source either way.
# shellcheck disable=SC2034
REVIEW_HOOK_DENIALS_VISIBLE=yes

# --max-findings and the tool-registration fix for a restricted launch both shipped by
# 2.1.296. The result shape was observed only on 2.1.319, and the judge fails
# closed over any untested range.
REVIEW_VERSION_FLOOR=2.1.296
# Claude Code exits promptly on TERM; the grace only has to cover a flush.
SUPERVISOR_GRACE_SECONDS=5
# Covers both attempts' grace periods and the record writes around them.
WAIT_MARGIN_SECONDS=120
MAXIMUM_ATTEMPTS=2

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_LIBRARY_DIRECTORY="$SCRIPT_DIRECTORY/../../.claude/hooks/lib"

die_usage() {
  printf 'audit-code-review: %s\n' "$1" >&2
  exit 2
}

# Resolved from this script, so the working directory never picks the library. The
# file test comes first for bash 3.2: under set -e a failed source there ends the
# shell before any `||` runs and the exit trap sees status 0, which `run` would
# report as a recorded outcome.
load_child_library() {
  local library_path="$SCRIPT_DIRECTORY/audit-code-review-child.sh"
  [ -f "$library_path" ] || {
    printf 'audit-code-review: missing library: %s\n' "$library_path" >&2
    exit 1
  }
  # shellcheck source=/dev/null
  . "$library_path"
}

timeout_is_measured() {
  case "$REVIEW_TIMEOUT_SECONDS" in
    UNMEASURED | '' | *[!0-9]*) return 1 ;;
  esac
}

cmd_wait_ms() {
  timeout_is_measured || exit 1
  printf '%s\n' "$(((MAXIMUM_ATTEMPTS * REVIEW_TIMEOUT_SECONDS + WAIT_MARGIN_SECONDS) * 1000))"
}

cmd_settings() {
  load_child_library
  local root="" attempt_directory="" guard_script=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die_usage "$1 needs a value"
    case "$1" in
      --root) root="$2" ;;
      --attempt-dir) attempt_directory="$2" ;;
      --guard-script) guard_script="$2" ;;
      *) die_usage "unknown argument: $1" ;;
    esac
    shift 2
  done
  case "$root" in /*) ;; *) die_usage "--root must be an absolute path" ;; esac
  case "$attempt_directory" in /*) ;; *) die_usage "--attempt-dir must be an absolute path" ;; esac
  case "$guard_script" in /*) ;; *) die_usage "--guard-script must be an absolute path" ;; esac
  print_child_settings "$root" "$attempt_directory" "$guard_script"
}

cmd_child_argv() {
  load_child_library
  local target="" settings_file=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die_usage "$1 needs a value"
    case "$1" in
      --target) target="$2" ;;
      --settings-file) settings_file="$2" ;;
      *) die_usage "unknown argument: $1" ;;
    esac
    shift 2
  done
  [ -n "$target" ] && [ -n "$settings_file" ] || die_usage "--target and --settings-file are required"
  set_child_argv "$target" "$settings_file"
  printf '%s\n' ${CHILD_ARGV[@]+"${CHILD_ARGV[@]}"}
}

record() {
  bash "$SCRIPT_DIRECTORY/audit-code-review-record.sh" "$@"
}

record_not_run() {
  record outcome --run-folder "$RUN_FOLDER" --pr "$PR" --outcome 'not run' --reason "$1" ${2:+--claude-version "$2"}
}

# version_at_or_above <version> <floor>: numeric per field, so 2.1.1000 beats 2.1.296.
version_at_or_above() {
  local major minor patch floor_major floor_minor floor_patch
  IFS=. read -r major minor patch <<<"$1"
  IFS=. read -r floor_major floor_minor floor_patch <<<"$2"
  [ "$major" -gt "$floor_major" ] && return 0
  [ "$major" -lt "$floor_major" ] && return 1
  [ "$minor" -gt "$floor_minor" ] && return 0
  [ "$minor" -lt "$floor_minor" ] && return 1
  [ "$patch" -ge "$floor_patch" ]
}

log_user_settings_hint() {
  printf 'audit-code-review: %s: the review child ignores user settings under its restricted launch, so a provider or auth set in user env or apiKeyHelper does not reach it\n' "$1" >&2
}

# Claude Code's Bash tool leaves CLAUDE_CODE_OAUTH_TOKEN out of the environment it
# hands a command, so a session authenticated by that token alone spawns a child
# with no credentials. Observed on Claude Code 2.1.316, not documented.
log_login_hint() {
  printf 'audit-code-review: not logged in: run claude and /login, so a keychain entry or credentials file exists; an env token alone may not reach the review child\n' >&2
}

# run_attempt <n>: sets ATTEMPT_ENDING to recorded (the outcome is written) or to
# the closed reason of a failed attempt. Exits 3 itself on a moved tree.
run_attempt() {
  local attempt_number="$1" attempt_directory result_file before after supervisor_pid child_status=0
  local facts cost model verdict verdict_kind reason denials_file guard_log findings_file
  attempt_directory="$RUN_FOLDER/code-review-attempt-$attempt_number"
  result_file="$attempt_directory/result.json"
  guard_log="$attempt_directory/guard-denials.jsonl"
  denials_file="$attempt_directory/denials.json"
  findings_file="$attempt_directory/findings.json"
  # A replaced stale record restarts the numbering, and a guard log left from that
  # earlier attempt would count as denials of this one.
  rm -rf "$attempt_directory"
  mkdir -p "$attempt_directory"
  print_child_settings "$ROOT" "$attempt_directory" "$ROOT/.gaia/scripts/audit-code-review-guard.sh" \
    >"$attempt_directory/child-settings.json"
  before="$(tree_snapshot "$ROOT")"
  record attempt-open --run-folder "$RUN_FOLDER" --n "$attempt_number"

  set_child_argv "$TARGET" "$attempt_directory/child-settings.json"
  start_supervised "$REVIEW_TIMEOUT_SECONDS" "$SUPERVISOR_GRACE_SECONDS" "$ROOT" "$result_file" "$attempt_directory/stderr.txt" \
    ${CHILD_ARGV[@]+"${CHILD_ARGV[@]}"}
  supervisor_pid=$!
  printf '%s\n' "$supervisor_pid" >"$attempt_directory/pgid"
  printf '%s\n' "$$" >"$attempt_directory/script.pid"
  wait "$supervisor_pid" || child_status=$?

  if ! wait_group_gone "$supervisor_pid"; then
    printf 'audit-code-review: process group %s outlived the deadline; recording nothing while it lives\n' "$supervisor_pid" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  . "$SCRIPT_DIRECTORY/audit-code-review-judge.sh"
  facts="$(gaia_review_result_facts "$result_file")"
  cost="$(printf '%s' "$facts" | jq -r '.cost')"
  model="$(printf '%s' "$facts" | jq -r '.model // empty')"
  gaia_review_denials "$result_file" "$guard_log" >"$denials_file"

  after="$(tree_snapshot "$ROOT")"
  if [ "$before" != "$after" ]; then
    record attempt-close --run-folder "$RUN_FOLDER" --n "$attempt_number" --exit "$child_status" --cost "$cost" \
      --reason 'review moved the tree' --model "$model" --denials "$denials_file"
    record_not_run 'review moved the tree'
    exit 3
  fi

  verdict_kind=failed
  case "$child_status" in
    0)
      verdict="$(gaia_review_judge "$result_file")"
      verdict_kind="$(printf '%s' "$verdict" | jq -r '.verdict')"
      reason="$(printf '%s' "$verdict" | jq -r '.reason // empty')"
      ;;
    124) reason='timed out' ;;
    126 | 127) reason='launch failed' ;;
    *) reason='nonzero exit' ;;
  esac

  record attempt-close --run-folder "$RUN_FOLDER" --n "$attempt_number" --exit "$child_status" --cost "$cost" \
    --reason "$reason" --model "$model" --denials "$denials_file"

  case "$verdict_kind" in
    ran)
      printf '%s' "$verdict" | jq -c '.findings' >"$findings_file"
      record outcome --run-folder "$RUN_FOLDER" --pr "$PR" --outcome ran --findings "$findings_file"
      ATTEMPT_ENDING=recorded
      ;;
    'no findings')
      if [ "$(jq -r '.count' "$denials_file")" -gt 0 ]; then
        record outcome --run-folder "$RUN_FOLDER" --pr "$PR" --outcome 'ran, no findings'
      else
        record outcome --run-folder "$RUN_FOLDER" --pr "$PR" --outcome 'ran, clean'
      fi
      ATTEMPT_ENDING=recorded
      ;;
    *)
      case "$reason" in
        'launch failed' | 'nonzero exit' | 'error result') log_user_settings_hint "$reason" ;;
        'not logged in') log_login_hint; log_user_settings_hint "$reason" ;;
      esac
      ATTEMPT_ENDING="$reason"
      ;;
  esac
}

emit_exit_line() {
  local exit_status=$?
  printf 'code-review exit %s\n' "$exit_status"
}

cmd_run() {
  trap emit_exit_line EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  # After the traps, so a missing library still ends in the line the unit waits on.
  load_child_library

  ROOT="" PR="" RUN_FOLDER=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die_usage "$1 needs a value"
    case "$1" in
      --root) ROOT="$2" ;;
      --pr) PR="$2" ;;
      --run-folder) RUN_FOLDER="$2" ;;
      *) die_usage "unknown argument: $1" ;;
    esac
    shift 2
  done
  case "$ROOT" in /*) ;; *) die_usage "--root must be an absolute path" ;; esac
  case "$RUN_FOLDER" in /*) ;; *) die_usage "--run-folder must be an absolute path" ;; esac
  [[ "$PR" =~ ^[1-9][0-9]{0,9}$ ]] || die_usage "--pr must be a positive integer"
  [ "$(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || die_usage "--root must be a git work tree"

  # A record nobody can read is left as found, and publication reports it. Nothing
  # is recorded, so nothing here may start a child.
  local read_status=0
  record read --run-folder "$RUN_FOLDER" >/dev/null 2>&1 || read_status=$?
  if [ "$read_status" -eq 5 ]; then
    printf 'audit-code-review: unreadable review record; no review started\n' >&2
    exit 0
  fi

  if [ "$REVIEW_CHILD_PROVEN" = UNMEASURED ]; then record_not_run 'child isolation unproven'; exit 0; fi
  if [ "$REVIEW_TARGET_FORMAT" = UNMEASURED ]; then record_not_run 'target unproven'; exit 0; fi
  if ! timeout_is_measured; then record_not_run 'timeout unmeasured'; exit 0; fi

  local version_output claude_version base head provenance attempt_count fork_status open_answer open_status=0
  if ! command -v claude >/dev/null 2>&1; then record_not_run 'launch failed'; log_user_settings_hint 'launch failed'; exit 0; fi
  version_output="$(claude --version 2>/dev/null)" || version_output=""
  claude_version="$(printf '%s\n' "$version_output" | sed -nE '1s/^([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p')"
  if [ -z "$claude_version" ]; then record_not_run 'below version floor'; exit 0; fi
  if ! version_at_or_above "$claude_version" "$REVIEW_VERSION_FLOOR"; then
    record_not_run 'below version floor' "$claude_version"
    exit 0
  fi

  # The resolver the members' full base comes from, so the review and the members
  # read the same range. Both values enter the prompt, hence the shape check.
  # shellcheck source=/dev/null
  . "$HOOK_LIBRARY_DIRECTORY/audit-base-provenance.sh"
  # shellcheck source=/dev/null
  . "$HOOK_LIBRARY_DIRECTORY/cross-repo-refusal.sh"
  provenance="$(audit_resolve_base_provenance "$ROOT" default-branch)" || provenance=""
  base="${provenance##*$'\t'}"
  head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || head=""
  if [[ ! "$base" =~ ^[0-9a-f]{40}$ ]] || [[ ! "$head" =~ ^[0-9a-f]{40}$ ]]; then
    record_not_run 'base unresolved' "$claude_version"
    exit 0
  fi
  TARGET="${REVIEW_TARGET_FORMAT//<base-sha>/$base}"
  TARGET="${TARGET//<head-sha>/$head}"

  open_answer="$(record open --root "$ROOT" --run-folder "$RUN_FOLDER" --pr "$PR" --base "$base" --head "$head" \
    --claude-version "$claude_version" --wait-seconds "$((REVIEW_TIMEOUT_SECONDS + WAIT_MARGIN_SECONDS))")" || open_status=$?
  if [ "$open_status" -ne 0 ]; then
    printf 'audit-code-review: could not open the review record (status %s); no review started\n' "$open_status" >&2
    exit 1
  fi
  [ "$open_answer" != ended ] || exit 0
  attempt_count="$(record read --run-folder "$RUN_FOLDER" | jq '.attempts | length')"
  if [ "$attempt_count" -ge "$MAXIMUM_ATTEMPTS" ]; then
    record_not_run 'interrupted'
    exit 0
  fi

  ATTEMPT_ENDING=""
  while [ "$attempt_count" -lt "$MAXIMUM_ATTEMPTS" ]; do
    attempt_count=$((attempt_count + 1))
    # Right before spawning, not once at entry: a pull request can change under a
    # retry. gh derives the repository from its working directory, the one reason
    # this file changes directory, and only inside this subshell. A fork head's
    # hook and settings copies would run under the maintainer's credentials.
    fork_status=0
    ( cd "$ROOT" && gaia_pr_is_cross_repository "$PR" ) >/dev/null 2>&1 || fork_status=$?
    if [ "$fork_status" -ne 1 ]; then
      record_not_run 'fork or unanswered fork check'
      exit 0
    fi
    run_attempt "$attempt_count"
    if [ "$ATTEMPT_ENDING" = recorded ]; then exit 0; fi
    case "$ATTEMPT_ENDING" in
      'timed out' | 'nonzero exit' | 'error result' | 'not the built-in' | 'unusable result') ;;
      *) break ;;
    esac
  done
  record_not_run "$ATTEMPT_ENDING"
  exit 0
}

SUBCOMMAND="${1-}"
[ $# -gt 0 ] && shift
case "$SUBCOMMAND" in
  run) cmd_run "$@" ;;
  settings) cmd_settings "$@" ;;
  child-argv) cmd_child_argv "$@" ;;
  wait-ms) cmd_wait_ms ;;
  *) die_usage "usage: audit-code-review.sh run|settings|child-argv|wait-ms ..." ;;
esac
