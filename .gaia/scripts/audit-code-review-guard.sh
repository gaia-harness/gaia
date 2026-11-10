#!/usr/bin/env bash
# The review child's PreToolUse hook. The child's restricted launch ignores the
# project's settings, which also drops block-sensitive-read.sh, so the child's
# generated settings register this wrapper in its place. It adds the one thing
# that hook has no reason to do: a denial log the review record can count, since
# whether a hook-blocked read appears in the result's own denial list is a
# property of Claude Code, not of this repository.
#
#   audit-code-review-guard.sh <denial-log-file> [<review-root>]   (hook payload on stdin)
#
# The target is found relative to this script, never relative to the reviewed
# head: a capture reviewing an older commit runs this wrapper from the build
# checkout, and a head without the hook must not turn every read into a denial.
#
# errexit stays off: a wrapper that dies early exits non-zero, which the
# PreToolUse contract reads as a non-blocking error, so the guard would vanish
# with no denial. The hook's output and status otherwise pass through unchanged.

script_path="${BASH_SOURCE[0]}"
[ "$script_path" = "${script_path%/*}" ] && script_path="./$script_path"
target_hook="${script_path%/*}/../../.claude/hooks/block-sensitive-read.sh"
denial_log="${1:-}"
review_root="${2:-}"
payload="$(cat)"

log_denial() {
  [ -n "$denial_log" ] || return 0
  # The fixed line keeps the count honest when jq is what is missing; the hook's
  # own jq-availability arm is what denied in that case.
  printf '%s' "$payload" | jq -c '{tool: (.tool_name // "unknown"),
      path: (.tool_input.file_path // .tool_input.path // .tool_input.glob // .tool_input.command // null)}' \
    >>"$denial_log" 2>/dev/null \
    || printf '{"tool":"unknown","path":null}\n' >>"$denial_log"
}

# git prints a file it was only told to read: `git diff /dev/null .env` turns on
# --no-index with no flag spelled, and blame prints the file given to --contents, -S
# or --ignore-revs-file. The sensitive-read hook judges readers, not git, so this
# denies a Bash command with any token that:
#   - contains --con (every abbreviation of --contents, and --contains and --config
#     with them) or starts with --no-index;
#   - contains $, a backtick, <( or >( anywhere in its raw text, quoted or not;
#   - holds a brace expansion ({ with , or ..);
#   - is, whole or after its first =, a parent-directory path, an absolute path
#     outside the review root, or starts with ~ (it expands after this check);
#   - when the command names blame, starts with --ig or -S, or is a short-option
#     cluster holding S.
# Every check but the raw-text one matches the token with its quotes and backslashes
# removed, because the shell removes them before git sees it. It is a token deny-list,
# not a parser: it denies only these forms. Without a root every absolute path is
# outside it.
bash_command_leaves_root() {
  local command_text token stripped candidate is_blame=no
  command_text="$(printf '%s' "$payload" | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)"
  [ -n "$command_text" ] || return 1
  set -f
  for token in $command_text; do
    [ "$(printf '%s' "$token" | tr -d "'\"\\\\")" != blame ] || is_blame=yes
  done
  for token in $command_text; do
    stripped="$(printf '%s' "$token" | tr -d "'\"\\\\")"
    case "$stripped" in *--con* | --no-index*) set +f; return 0 ;; esac
    # Expansion, command and process substitution build their words or run a
    # command after this check, which is how a denied form or a file's contents
    # reaches git unseen. Which quotes leave a $ literal is shell parsing this check
    # does not attempt, so the raw token is read: a review cannot name a file with a
    # $ in its path, such as a route module, though the range diff still shows it.
    case "$token" in *'$'* | *'`'* | *'<('* | *'>('*) set +f; return 0 ;; esac
    # Brace expansion builds its words after this check too. The match is a { with a
    # , or .. anywhere after it, so `@{1}` or `@{upstream}` passes alone but not
    # before a .., as in `HEAD@{1}..HEAD`; the deny reason gives the two-revision form.
    case "$stripped" in *'{'*,* | *'{'*..*) set +f; return 0 ;; esac
    if [ "$is_blame" = yes ]; then
      case "$stripped" in --ig* | -S* | -[!-]*S*) set +f; return 0 ;; esac
    fi
    for candidate in "$stripped" "${stripped#*=}"; do
      case "$candidate" in
        .. | ../* | */../* | */..) set +f; return 0 ;;
        '~'*) set +f; return 0 ;;
        /*)
          if [ -z "$review_root" ] || { [ "$candidate" != "$review_root" ] && [ "${candidate#"$review_root"/}" = "$candidate" ]; }; then
            set +f
            return 0
          fi
          ;;
      esac
    done
  done
  set +f
  return 1
}

if bash_command_leaves_root; then
  log_denial
  cat <<'DENY_JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: the review child may not name a path outside the review root, use any option containing --con (such as --contents, --contains, --config), or put a $, backtick, <(, >(, or a { followed later by , or .. in any token. For a range that starts at a @{...} revision, such as HEAD@{1}..HEAD, give two revisions instead: git diff HEAD@{1} HEAD or git log HEAD ^HEAD@{1}. To read a file under the review root whose path holds a $, such as a route module, open it with the Read tool."
  }
}
DENY_JSON
  exit 0
fi

if [ ! -f "$target_hook" ]; then
  log_denial
  cat <<'DENY_JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: the review child's read guard cannot find block-sensitive-read.sh, so dotenv and secret paths are not being checked. This denial is fail-closed by design."
  }
}
DENY_JSON
  exit 0
fi

hook_output="$(printf '%s' "$payload" | bash "$target_hook")"
hook_status=$?
[ -z "$hook_output" ] || printf '%s\n' "$hook_output"

# Status 2 is the hook's own fail-loud arm, a blocking error with no JSON.
case "$hook_output" in
  *'"permissionDecision": "deny"'*) log_denial ;;
  *) [ "$hook_status" -ne 2 ] || log_denial ;;
esac
exit "$hook_status"
