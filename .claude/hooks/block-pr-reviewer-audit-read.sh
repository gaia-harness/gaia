#!/usr/bin/env bash
# PreToolUse Read + Grep + Glob + Bash + Monitor hook: keeps the `pr-reviewer`
# agent away from audit state, so its review of a pull request stays unanchored
# by what the audit loop already found. The reviewer is read-only by tool
# grant; this makes "unanchored" structural rather than a promise in its prompt.
#
# WHO IT BINDS. Only a call whose payload carries `agent_type` exactly
# `pr-reviewer`. The harness sets `agent_type` on a sub-agent's tool calls and
# not on the main thread's, so the main thread and every other agent pass
# untouched and at once. The type is read through lib/payload-agent.sh (the one
# reader of which agent made a call), and a match is then confirmed against the
# real JSON parse, because that reader warns that a key nested inside tool_input
# can lookalike a top-level one.
#
# WHAT IT DENIES. A call whose Read `file_path`, Grep `path` or `glob`, Glob
# `path` or `pattern`, or Bash or Monitor command text names the audit state
# folder or the run folders under the local state root, in relative or absolute
# form (the escaped regex below). It fails closed on two near misses: a command
# token naming that root with a glob or variable that could expand into either
# folder, and a Grep or Glob search rooted at the state root itself, which
# reads both recursively. The deny line is
# `BLOCKED: pr-reviewer may not read audit state: <path>`, where <path> is the
# offending path or command token as the call named it.
#
# HONEST LIMITS. This is heuristic defense-in-depth, not a sandbox. It
# pattern-matches call text, so a path the shell assembles at run time
# (`d=audit; cat .gaia/local/"$d"` is caught, but `cat $(printf '%s' ...)`
# building the whole path is not), an indirection through another tool, or a
# subprocess that opens the file itself escapes it. The before/after check
# (.gaia/scripts/pr-review-guard.sh) is the backstop for writes: it compares
# the tree, the audit state and the commit statuses around the dispatch.
set -euo pipefail

payload=$(cat)
# Pure-bash prefilter: a payload without the literal cannot carry the reviewer's
# agent type, so every other call leaves before any library loads.
case "$payload" in
  *pr-reviewer*) ;;
  *) exit 0 ;;
esac
# jq-availability arm: refuse loudly rather than fail open when jq is absent.
# The literal is the one thing whose absence proves the call is not the
# reviewer's: only that agent type is bound here.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _library_directory=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_library_directory" ] && [ -f "$_library_directory/jq-availability.sh" ] && . "$_library_directory/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-pr-reviewer-audit-read.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the pr-reviewer audit-state read guard' "$payload" - 'pr-reviewer'

set +e
# shellcheck source=lib/payload-agent.sh
[ -n "$_library_directory" ] && [ -f "$_library_directory/payload-agent.sh" ] && . "$_library_directory/payload-agent.sh" 2>/dev/null
# shellcheck source=lib/hook-payload.sh
[ -n "$_library_directory" ] && [ -f "$_library_directory/hook-payload.sh" ] && . "$_library_directory/hook-payload.sh" 2>/dev/null
set -e
for _required in gaia_payload_agent_read:payload-agent gaia_hook_payload_read:hook-payload; do
  if ! type "${_required%%:*}" >/dev/null 2>&1; then
    printf 'BLOCKED: block-pr-reviewer-audit-read.sh cannot load lib/%s.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' "${_required#*:}" >&2
    exit 2
  fi
done

# Cheap discriminator first: anyone but the reviewer is allowed at once.
gaia_payload_agent_read "$payload"
[ "$GAIA_PAYLOAD_AGENT_TYPE" = 'pr-reviewer' ] || exit 0
confirmed_type=$(jq -r '.agent_type // "" | if type == "string" then . else "" end' <<<"$payload" 2>/dev/null) || confirmed_type=''
[ "$confirmed_type" = 'pr-reviewer' ] || exit 0

gaia_hook_payload_read "$payload" || exit 0

deny() {
  jq -n --arg reason "BLOCKED: pr-reviewer may not read audit state: $1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# The named folders, escaped so the dot is a dot and the text is a shape, never
# a bare path literal.
audit_state_pattern='\.gaia/local/(audit|runs)'
# The state root followed, within one path segment, by a glob or expansion
# character: it could expand into either folder.
expandable_pattern='\.gaia/local/?[^/[:space:]]*[*?[{$`]'

# strip_token_wrapping <token>: drop the quotes and shell separators around a
# command word so the deny line names the path itself.
strip_token_wrapping() {
  local token="$1"
  printf '%s' "$token" | tr -d '"'"'"'`;&|()<>'
}

# first_audit_token <text>: print the whitespace-delimited word of <text> that
# names audit state, or the whole text when no single word does. Returns 1 when
# nothing in <text> names it.
first_audit_token() {
  local text="$1" word
  local -a words
  if [[ ! "$text" =~ $audit_state_pattern && ! "$text" =~ $expandable_pattern ]]; then
    return 1
  fi
  read -r -a words <<<"$(printf '%s' "$text" | tr '\n' ' ')"
  for word in ${words[@]+"${words[@]}"}; do
    if [[ "$word" =~ $audit_state_pattern || "$word" =~ $expandable_pattern ]]; then
      printf '%s' "$(strip_token_wrapping "$word")"
      return 0
    fi
  done
  printf '%s' "$text"
}

# check_text <text>: deny when <text> names audit state.
check_text() {
  local hit
  [ -n "$1" ] || return 0
  hit=$(first_audit_token "$1") || return 0
  deny "$hit"
}

# state_root_search <directory>: true when a search rooted at <directory> would
# read the whole local state root, which holds both folders. Compared on the
# canonical directory, so `x/..` and symlinked spellings count.
state_root_search() {
  local directory="$1" resolved state_root
  [ -n "$directory" ] || return 1
  case "$directory" in
    /*) ;;
    *) directory="${GAIA_HOOK_CWD:-.}/$directory" ;;
  esac
  resolved=$(cd -P "$directory" 2>/dev/null && pwd -P) || return 1
  [ -n "$resolved" ] || return 1
  resolve_main_root
  [ -n "${main_root:-}" ] || return 1
  state_root=$(cd -P "$main_root/.gaia/local" 2>/dev/null && pwd -P) || return 1
  [ "$resolved" = "$state_root" ]
}

# resolve_main_root: set main_root from the shared resolver, once, for
# state_root_search only, so the Read, Bash and Monitor arms never pay for it. A
# checkout that cannot resolve one leaves that arm off and keeps the text arms.
main_root=''
_main_root_resolved=0
resolve_main_root() {
  [ "$_main_root_resolved" -eq 0 ] || return 0
  _main_root_resolved=1
  set +e
  _main_root_library="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.gaia/scripts/main-root-lib.sh"
  # shellcheck source=../../.gaia/scripts/main-root-lib.sh
  [ -f "$_main_root_library" ] && . "$_main_root_library" 2>/dev/null
  if type gaia_resolve_main_root >/dev/null 2>&1; then
    main_root=$(gaia_resolve_main_root "${GAIA_HOOK_CWD:-.}" 2>/dev/null) || main_root=''
  fi
  set -e
}

case "$GAIA_HOOK_TOOL_NAME" in
  Read)
    check_text "$GAIA_HOOK_FILE_PATH"
    ;;
  Grep)
    check_text "$GAIA_HOOK_PATH"
    check_text "$GAIA_HOOK_GLOB"
    if [ -n "$GAIA_HOOK_PATH" ] && [ -n "$GAIA_HOOK_GLOB" ]; then
      check_text "${GAIA_HOOK_PATH%/}/$GAIA_HOOK_GLOB"
    fi
    if state_root_search "${GAIA_HOOK_PATH:-}"; then deny "$GAIA_HOOK_PATH"; fi
    ;;
  Glob)
    # Glob's `path` and `pattern` are one search: judge each, then the join.
    glob_pattern=$(jq -r '.tool_input.pattern // "" | if type == "string" then . else "" end' <<<"$payload" 2>/dev/null) || glob_pattern=''
    check_text "$GAIA_HOOK_PATH"
    check_text "$glob_pattern"
    if [ -n "$GAIA_HOOK_PATH" ] && [ -n "$glob_pattern" ]; then
      check_text "${GAIA_HOOK_PATH%/}/$glob_pattern"
    fi
    if state_root_search "${GAIA_HOOK_PATH:-}"; then deny "$GAIA_HOOK_PATH"; fi
    ;;
  Bash | Monitor)
    check_text "$GAIA_HOOK_COMMAND"
    ;;
esac
exit 0
