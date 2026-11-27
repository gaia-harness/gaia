#!/usr/bin/env bash
# SessionStart hook (startup|resume): shows the person a context checkpoint
# override that is off, clamped or invalid, and an audit loop round cap that is
# capped or invalid, at every start while the file stays that way. The statuses
# come from context-checkpoint-lib.sh and audit-loop-automatic-lib.sh; the text
# is owned here. One message carries both when both apply. It goes out as systemMessage, which only the person sees, and as
# additionalContext so Claude can answer questions about it.
# Silent when the override is absent or in range and the cap is absent or ok.
#
# The main root comes from the payload cwd; with no jq to read the payload, the
# hook's own working directory stands in. Every path exits 0: a warning that
# cannot be shown never blocks a session.

set -uo pipefail
trap 'exit 0' ERR

here="${BASH_SOURCE[0]}"
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
scripts="$here/../../.gaia/scripts"

payload=$(cat) || payload=""

# shellcheck source=/dev/null
. "$scripts/main-root-lib.sh" 2>/dev/null || exit 0
# shellcheck source=/dev/null
. "$scripts/context-checkpoint-lib.sh" 2>/dev/null || exit 0
# shellcheck source=/dev/null
. "$scripts/audit-loop-signals-lib.sh" 2>/dev/null || exit 0
# shellcheck source=/dev/null
. "$scripts/audit-loop-automatic-lib.sh" 2>/dev/null || exit 0

# thousands <whole number>: the number with comma separators.
thousands() {
  local digits="$1" grouped=""
  while [ "${#digits}" -gt 3 ]; do
    grouped=",${digits:${#digits}-3}$grouped"
    digits="${digits:0:${#digits}-3}"
  done
  printf '%s%s\n' "$digits" "$grouped"
}

# file_warning <main-root>: print the one-line warning for an override
# that is off, clamped or invalid and return 0; print nothing and return 1 when
# it is absent or in range. Each one names the file and the fix.
file_warning() {
  local file="${1:-}/.gaia/local/protected/checkpoint-override.json" status read_value
  local minimum maximum default_tokens
  read -r status _ read_value <<<"$(gaia_context_override_state "${1:-}")"
  minimum=$(thousands "$GAIA_CONTEXT_ASK_TOKENS_MINIMUM")
  maximum=$(thousands "$GAIA_CONTEXT_ASK_TOKENS_MAXIMUM")
  default_tokens=$(thousands "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT")
  case "$status" in
    off) printf 'GAIA context checkpoint is OFF: %s sets ask_tokens to 0, so only Claude Code auto-compaction limits context, except that an audit loop which already froze a line keeps it until the next branch. Not recommended: remove the key to restore the %s default.\n' "$file" "$default_tokens" ;;
    clamped-low) printf 'WARNING: GAIA context checkpoint override raised to its minimum: %s sets ask_tokens to %s, below the %s minimum, so %s is used. Set ask_tokens from %s to %s.\n' "$file" "$read_value" "$minimum" "$minimum" "$GAIA_CONTEXT_ASK_TOKENS_MINIMUM" "$GAIA_CONTEXT_ASK_TOKENS_MAXIMUM" ;;
    clamped-high) printf 'WARNING: GAIA context checkpoint override capped: %s sets ask_tokens to %s, above the %s limit, so %s is used. To go higher, set ask_tokens to 0 to turn the checkpoint off and let Claude Code auto-compact.\n' "$file" "$read_value" "$maximum" "$maximum" ;;
    invalid) printf 'WARNING: GAIA context checkpoint override is invalid: %s is not {"version":1,"context_checkpoint":{"ask_tokens":<whole number>}}, or jq is not installed, so the %s default is used. Fix or delete the file.\n' "$file" "$default_tokens" ;;
    *) return 1 ;;
  esac
}

# cap_notice <main-root>: print the one-line notice for a round cap that is
# capped or invalid and return 0; print nothing and return 1 otherwise. A file
# that is not a version 1 object (or cannot be read) is the file warning's, not
# a second notice.
cap_notice() {
  local file="${1:-}/.gaia/local/protected/checkpoint-override.json" cap_status _cap cap_value
  read -r cap_status _cap cap_value <<<"$(gaia_loop_round_cap_state "${1:-}")"
  case "$cap_status" in
    capped) printf 'WARNING: GAIA audit loop round cap capped: %s sets audit_loop.round_cap to %s, above the %s limit, so %s is used.\n' "$file" "$cap_value" "$_GAIA_LOOP_HARD_CAP" "$_GAIA_LOOP_HARD_CAP" ;;
    invalid)
      jq -e 'type == "object" and .version == 1' "$file" >/dev/null 2>&1 || return 1
      printf 'WARNING: GAIA audit loop round cap is invalid: %s sets audit_loop.round_cap to %s, not a whole number from 1 to %s, so automatic continue and the hand-off are off and every checkpoint asks. Fix or delete the key.\n' "$file" "$cap_value" "$_GAIA_LOOP_HARD_CAP"
      ;;
    *) return 1 ;;
  esac
}

# override_warning <main-root>: the file warning and the cap notice, in one
# message separated by one space; return 1 when neither applies.
override_warning() {
  local file_text cap_text
  file_text=$(file_warning "$1") || file_text=""
  cap_text=$(cap_notice "$1") || cap_text=""
  [ -n "$file_text$cap_text" ] || return 1
  if [ -n "$file_text" ] && [ -n "$cap_text" ]; then
    printf '%s %s\n' "$file_text" "$cap_text"
  else
    printf '%s%s\n' "$file_text" "$cap_text"
  fi
}

cwd=""
if command -v jq >/dev/null 2>&1; then
  cwd=$(jq -r '.cwd // "" | strings' <<<"$payload" 2>/dev/null) || cwd=""
fi
case "$cwd" in /*) ;; *) cwd="" ;; esac
if [ -n "$cwd" ]; then
  main_root=$(gaia_resolve_main_root "$cwd" 2>/dev/null) || exit 0
else
  main_root=$(gaia_resolve_main_root 2>/dev/null) || exit 0
fi
[ -n "$main_root" ] || exit 0

warning=$(override_warning "$main_root") || exit 0
# The text is one line built from fixed wording, numbers and a filesystem
# path, so escaping backslash and double quote is the whole JSON encoding.
warning=${warning//\\/\\\\}
warning=${warning//\"/\\\"}
printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$warning" "$warning"
exit 0
