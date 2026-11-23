#!/usr/bin/env bash
# SessionStart hook: tells the person and Claude that this session is
# unattended while the autonomy switch is live. The switch is checkout-wide, so
# this notice is the only way a session learns it. It goes out as
# systemMessage, which only the person sees, and as additionalContext for
# Claude. Silent when autonomy-lib.sh reads the switch as off.
#
# The checkout comes from the payload cwd; when the payload has no absolute
# cwd, or no jq can read it, the hook's own working directory stands in (with
# no jq, autonomy-lib.sh reads the switch as off anyway). Every path exits 0:
# a notice that cannot be shown never blocks a session.

set -uo pipefail
trap 'exit 0' ERR

here="${BASH_SOURCE[0]}"
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac

payload=$(cat) || payload=""

# shellcheck source=../../.gaia/scripts/autonomy-lib.sh
. "$here/../../.gaia/scripts/autonomy-lib.sh" 2>/dev/null || exit 0

cwd=""
if command -v jq >/dev/null 2>&1; then
  cwd=$(jq -r '.cwd // "" | strings' <<<"$payload" 2>/dev/null) || cwd=""
fi
case "$cwd" in /*) ;; *) cwd=$PWD ;; esac

expires_at=$(autonomy_field expires_at "$cwd") || exit 0
may_merge=$(autonomy_field may_merge "$cwd") || exit 0
file=$(autonomy_file "$cwd") || exit 0

notice="GAIA unattended run: the autonomy switch $file is live until $expires_at (UTC), so every session in this checkout and its worktrees runs unattended. may_merge is $may_merge. Only a human turns it off, by deleting the file from their own terminal."
# The text is fixed wording, a timestamp, a boolean and a filesystem path, so
# escaping backslash and double quote is the whole JSON encoding.
notice=${notice//\\/\\\\}
notice=${notice//\"/\\\"}
printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$notice" "$notice"
exit 0
