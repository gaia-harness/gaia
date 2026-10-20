#!/bin/bash
# GAIA project-scoped statusline.
#
# Reads JSON from stdin (Claude Code convention), prints a single line: the
# left side, then the GAIA nudges right-aligned beside it. Each side lives in
# its own sourced sibling, gaia-statusline-left.sh and gaia-statusline-right.sh;
# this script resolves the session's state, writes the context reading, picks
# the left side, and composes the two.
#
# Left-side resolution (first match wins):
#   1. User has `statusLine.command` in `~/.claude/settings.json` → run that
#      (so the adopter's existing global statusline appears unchanged), unless
#      the machine chose GAIA's bar in /setup-gaia (statusline.left "gaia").
#   2. No global command → the default left side (project, branch with a
#      linked-worktree marker, model and effort, a colored context bar).
#   3. Last resort, when that cannot render → bare "Claude Code" label.
#
# Whatever the left side is, the right side always renders, and every render
# also writes the session's context reading for the audit-loop bound hook (see
# context-reading.sh).
#
# The hot path stays no-network: no network calls, no `pnpm` calls. It is no
# longer under 50ms, and that target is retired rather than quietly missed:
# resolving the main checkout root canonically (`gaia_resolve_main_root`, a
# handful of `git` invocations behind an env scrub) costs more than the
# hand-rolled `git rev-parse` forks it replaces, and that is the right trade
# at this size. Making the resolver itself cheaper would return most of it
# and is worth doing, but it is the resolver library's change to make, not
# this consumer's.
# A background refresher (.gaia/scripts/check-updates.sh) writes the cache.
#
# Partial failures are silent; a broken statusline disappears in Claude Code,
# which is the worst UX. Do NOT add `set -e`.

# Resolve script directory so the resolver library is found regardless of
# caller cwd. This is the script's INSTALL path, which is not necessarily the
# session's checkout; the state paths below are anchored on the resolved main
# root instead.
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAIA_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
PROJECT_ROOT="$(cd "$GAIA_DIRECTORY/.." && pwd)"

# Read JSON input once.
input=$(cat)

# ---------- Where this session's state lives ----------
# Every path below is anchored on the MAIN checkout, resolved from the
# SESSION's directory (carried on the StatusLine payload) through the one
# canonical resolver. Not from this script's install path: a maintainer
# wrapper execs the shipped script from the main checkout while the session
# runs in a linked worktree, so the install path answers for the wrong
# checkout. Every state file is registry scope "shared", so main is
# where they physically live for every tree, provisioned or not.
#
# Resolver failure degrades silently, this consumer's documented disposition:
# fall back to this script's own checkout. A tree git cannot resolve has no
# linked worktrees either, so the install path is the only checkout there --
# which keeps a scaffolded-but-not-yet-`git init` project rendering.
# One jq call extracts every stdin field this script uses (session directory,
# the context reading, model and effort); fields are joined by a control
# character no value contains. `used_tokens` is pinned as
# round(used_percentage / 100 * context_window_size), never the payload's
# total_input_tokens, which counts something else. The percentage is rounded to
# six decimals so the writer's validation accepts it; a field that is absent or
# the wrong type comes out empty. Silent on jq failure: every field then reads
# empty, nothing is written, and the render continues.
session_id=""
session_directory=""
context_percentage=""
context_window_size=""
context_used_tokens=""
model_name=""
effort_level=""
fields=$(printf '%s' "$input" | jq -r '
  def printable_string: if type == "string" then gsub("[\u0000-\u001f]"; "") else "" end;
  (.context_window | if type == "object" then . else {} end) as $context
  | (if ($context.used_percentage | type) == "number" and $context.used_percentage >= 0 and $context.used_percentage <= 999
     then ($context.used_percentage * 1000000 | round) / 1000000 else null end) as $percentage
  | (if ($context.context_window_size | type) == "number" and $context.context_window_size >= 1 and $context.context_window_size <= 999999999999
     then ($context.context_window_size | floor) else null end) as $window_size
  | [ (.session_id | printable_string),
      ((.workspace.current_dir // .cwd) | printable_string),
      (if $percentage != null and $window_size != null then ($percentage | if . < 0.001 then "0" else tostring end) else "" end),
      (if $percentage != null and $window_size != null then ($window_size | tostring) else "" end),
      (if $percentage != null and $window_size != null then ($percentage / 100 * $window_size | round | tostring) else "" end),
      (.model.display_name | printable_string),
      (.effort.level | printable_string) ]
  | join("\u001f")' 2>/dev/null) || fields=""
IFS=$'\037' read -r session_id session_directory context_percentage context_window_size context_used_tokens model_name effort_level <<<"$fields"
[ -n "$session_directory" ] || session_directory="$PROJECT_ROOT"

if [ -f "$GAIA_DIRECTORY/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIRECTORY/scripts/main-root-lib.sh" 2>/dev/null || true
fi
STATE_ROOT=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  STATE_ROOT="$(gaia_resolve_main_root "$session_directory" 2>/dev/null || true)"
fi
[ -n "$STATE_ROOT" ] || STATE_ROOT="$PROJECT_ROOT"

# Whether this session is on a linked worktree, resolved once. Failure
# direction: render. "No" and "indeterminate" (git unavailable, predicate
# unresolvable) both read "false", and an unsourced library fails the
# command -v guard -- all three keep the right side rendering, same as today.
IS_WORKTREE="false"
if command -v gaia_is_linked_worktree >/dev/null 2>&1; then
  if gaia_is_linked_worktree "$session_directory"; then
    IS_WORKTREE="true"
  fi
fi

# ---------- Context reading (written on every render) ----------
# The audit-loop bound hook reads the main session's context from a file only
# this script can produce, so the write comes first: before the left side,
# before any early exit, and regardless of IS_WORKTREE, GAIA_STATUSLINE_NESTED
# or the right side's setup-gaia gating. A sibling that is absent (an older checkout)
# or a write that fails never prints and never stops the render. The lib is
# sourced as "$GAIA_DIRECTORY/scripts/...", not from SCRIPT_DIRECTORY: a maintainer wrapper
# execs a patched copy that sits in a different directory.
# The session's effort level is written beside the context reading, from the
# same render but independent of the context_window fields: usage.sh record
# reads it for the close rows, and only this script sees the level.
if [ -f "$GAIA_DIRECTORY/scripts/context-checkpoint-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIRECTORY/scripts/context-checkpoint-lib.sh" 2>/dev/null || true
fi
if [ -f "$GAIA_DIRECTORY/statusline/context-reading.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIRECTORY/statusline/context-reading.sh" 2>/dev/null || true
fi
if command -v gaia_statusline_write_context >/dev/null 2>&1; then
  gaia_statusline_write_context "$STATE_ROOT" "$session_id" "$context_percentage" "$context_window_size" "$context_used_tokens" >/dev/null 2>&1 || true
fi
if command -v gaia_statusline_write_effort >/dev/null 2>&1; then
  gaia_statusline_write_effort "$STATE_ROOT" "$session_id" "$effort_level" >/dev/null 2>&1 || true
fi

# ---------- Left side ----------
# First match wins: the user's own global `statusLine.command`, then the ported
# default (project, branch, model and effort, context bar), then the bare label.
# A machine whose opt-ins file (main's .gaia/local/settings.json, written by
# /setup-gaia) says statusline.left "gaia" skips the global command. Any other
# value, a missing key, or a file without version 1 or that does not parse
# keeps the global command, which is the behavior with no file at all.
left=""
left_choice=""
if [ -f "$STATE_ROOT/.gaia/local/settings.json" ] && command -v jq >/dev/null 2>&1; then
  left_choice=$(jq -r 'if type == "object" and .version == 1 and (.statusline | type) == "object" and .statusline.left == "gaia" then "gaia" else empty end' "$STATE_ROOT/.gaia/local/settings.json" 2>/dev/null)
fi
if [ "$GAIA_STATUSLINE_NESTED" != "1" ] && [ "$left_choice" != "gaia" ]; then
  user_command=""
  if [ -f "$HOME/.claude/settings.json" ] && command -v jq >/dev/null 2>&1; then
    user_command=$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)
  fi
  # Skip if it points back at this wrapper (avoid recursion).
  case "$user_command" in
    *gaia-statusline.sh*) user_command="" ;;
  esac
  if [ -n "$user_command" ]; then
    left=$(printf '%s' "$input" | GAIA_STATUSLINE_NESTED=1 bash -c "$user_command" 2>/dev/null)
  fi
fi

if [ -z "$left" ] && [ -f "$GAIA_DIRECTORY/statusline/gaia-statusline-left.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIRECTORY/statusline/gaia-statusline-left.sh" 2>/dev/null || true
  if command -v gaia_statusline_left >/dev/null 2>&1; then
    if gaia_statusline_left "$STATE_ROOT" "$session_directory" "$IS_WORKTREE" "$model_name" "$effort_level" "$context_percentage" "$context_window_size" "$context_used_tokens" 2>/dev/null; then
      left="$_GAIA_STATUSLINE_LEFT"
    fi
  fi
fi

[ -z "$left" ] && left="Claude Code"

CHECK_SCRIPT="$STATE_ROOT/.gaia/scripts/check-updates.sh"
DEBT_REFRESH_SCRIPT="$STATE_ROOT/.gaia/scripts/debt-count-refresh.sh"

# ---------- Right side ----------
right=""
right_padding=0
if [ -f "$GAIA_DIRECTORY/statusline/gaia-statusline-right.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIRECTORY/statusline/gaia-statusline-right.sh" 2>/dev/null || true
  if command -v gaia_statusline_right >/dev/null 2>&1; then
    if gaia_statusline_right "$GAIA_DIRECTORY" "$STATE_ROOT" "$IS_WORKTREE" "$left" 2>/dev/null; then
      right="$_GAIA_STATUSLINE_RIGHT"
      right_padding="$_GAIA_STATUSLINE_RIGHT_PADDING"
    fi
  fi
fi

# Fire the background refreshers; never block. Both are run from the MAIN
# checkout's copy, so both write the one shared cache this script has just
# read. Firing a worktree's own copy would refresh a cache nobody reads: each
# refresher derives its paths from its own install path, so the worktree's
# copy writes the worktree's `.gaia/local` -- and a segment fed by a cache that
# never refreshes is the silent death this script's shape exists to end, one
# hop further along.
#
# Gated on IS_WORKTREE independently of the right side's own gating, which
# has already returned: a linked worktree cannot act on
# either refresher's output, so neither fires from one. Main's own next
# render fires both past the TTL; no compensating fire is needed.

# The update-check refresher.
if [ -x "$CHECK_SCRIPT" ] && [ "$IS_WORKTREE" != "true" ]; then
  (cd "$STATE_ROOT" && nohup bash "$CHECK_SCRIPT" >/dev/null 2>&1 &) >/dev/null 2>&1
fi

# The independent debt-count refresher. Detached so the hot path stays
# no-network (the count above is read from the pinned cache only).
if [ -x "$DEBT_REFRESH_SCRIPT" ] && [ "$IS_WORKTREE" != "true" ]; then
  (cd "$STATE_ROOT" && nohup bash "$DEBT_REFRESH_SCRIPT" >/dev/null 2>&1 &) >/dev/null 2>&1
fi

# ---------- Compose with right-alignment ----------
if [ -z "$right" ]; then
  printf '%b' "$left"
  exit 0
fi

spaces=$(printf '%*s' "$right_padding" '')
printf '%b%s%s' "$left" "$spaces" "$right"
