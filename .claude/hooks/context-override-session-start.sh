#!/usr/bin/env bash
# SessionStart hook (startup|resume): shows the person a context checkpoint
# override that is off, clamped or invalid, at every start while the file stays
# that way. The status comes from context-checkpoint-lib.sh; the text is owned
# here. It goes out as systemMessage, which only the person sees, and as
# additionalContext so Claude can answer questions about it.
# Silent when the override is absent or in range.
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

# thousands <whole number>: the number with comma separators.
thousands() {
  local digits="$1" grouped=""
  while [ "${#digits}" -gt 3 ]; do
    grouped=",${digits:${#digits}-3}$grouped"
    digits="${digits:0:${#digits}-3}"
  done
  printf '%s%s\n' "$digits" "$grouped"
}

# override_warning <main-root>: print the one-line warning for an override
# that is off, clamped or invalid and return 0; print nothing and return 1 when
# it is absent or in range. Each one names the file and the fix.
override_warning() {
  local file="${1:-}/.gaia/local/protected/checkpoint-override.json" status read_value
  local minimum maximum default_tokens
  read -r status _ read_value <<<"$(gaia_context_override_state "${1:-}")"
  minimum=$(thousands "$GAIA_CONTEXT_ASK_TOKENS_MINIMUM")
  maximum=$(thousands "$GAIA_CONTEXT_ASK_TOKENS_MAXIMUM")
  default_tokens=$(thousands "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT")
  case "$status" in
    off) printf 'GAIA context checkpoint is OFF: %s sets ask_tokens to 0, so the statusline, the context hooks and any branch whose audit loop has not yet frozen its line have no checkpoint and only Claude Code auto-compaction limits context; a branch whose audit loop already froze a line keeps it until the next branch. Not recommended: remove the key to restore the %s default.\n' "$file" "$default_tokens" ;;
    clamped-low) printf 'WARNING: GAIA context checkpoint override raised to its minimum: %s sets ask_tokens to %s, below the %s minimum, so %s is used. Set ask_tokens from %s to %s.\n' "$file" "$read_value" "$minimum" "$minimum" "$GAIA_CONTEXT_ASK_TOKENS_MINIMUM" "$GAIA_CONTEXT_ASK_TOKENS_MAXIMUM" ;;
    clamped-high) printf 'WARNING: GAIA context checkpoint override capped: %s sets ask_tokens to %s, above the %s limit, so %s is used. To go higher, set ask_tokens to 0 to turn the checkpoint off and let Claude Code auto-compact.\n' "$file" "$read_value" "$maximum" "$maximum" ;;
    invalid) printf 'WARNING: GAIA context checkpoint override is invalid: %s is not {"version":1,"context_checkpoint":{"ask_tokens":<whole number>}}, or jq is not installed, so the %s default is used. Fix or delete the file.\n' "$file" "$default_tokens" ;;
    *) return 1 ;;
  esac
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
