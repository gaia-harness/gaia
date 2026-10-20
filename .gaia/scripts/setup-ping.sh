#!/usr/bin/env bash
# shellcheck shell=bash
#
# setup-ping.sh: /setup-gaia's closing adoption ping. Sends the setup event
# when the run carries a setup type or decided an id that was owed at its
# start; otherwise prints PING_SKIPPED and sends nothing.
#
#   bash .gaia/scripts/setup-ping.sh --owed "<OWED_AT_START>" [--type <SETUP_TYPE>] [--repo <REPO_CHOICE>]
#
# --owed is the space-separated id list the run cached at its start. An empty
# --type or --repo value counts as absent. Exit 0 always, except a usage
# error (2): the ping never fails setup.
#
# Run it with the working directory at the project root. It is a script, not
# an inline snippet, because Claude's Bash tool runs zsh on macOS and zsh does
# not word-split an unquoted parameter expansion: an inline
# `for id in $OWED_AT_START` loop there runs once over the whole list, so two
# or more owed ids never match and the ping is skipped. The bash shebang fixes
# the splitting whatever shell launches it.

owed=''
setup_type=''
repo_choice=''
usage_line='usage: setup-ping.sh --owed "<ids>" [--type <type>] [--repo <choice>]'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --owed) [ "$#" -ge 2 ] || { echo "$usage_line" >&2; exit 2; }; owed="$2"; shift 2 ;;
    --type) [ "$#" -ge 2 ] || { echo "$usage_line" >&2; exit 2; }; setup_type="$2"; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || { echo "$usage_line" >&2; exit 2; }; repo_choice="$2"; shift 2 ;;
    *) echo "$usage_line" >&2; exit 2 ;;
  esac
done

# A drift failure leaves the list empty, which counts as nothing newly decided.
decided_now=" $(.gaia/cli/gaia setup drift --json 2>/dev/null | jq -r '(.decided // {}) | keys | join(" ")' 2>/dev/null) "
newly_decided=''
for id in $owed; do
  case "$decided_now" in *" $id "*) newly_decided="$newly_decided $id" ;; esac
done

if [ -z "$setup_type" ] && [ -z "$newly_decided" ]; then
  echo PING_SKIPPED
  exit 0
fi

sandbox="$(.gaia/cli/gaia sandbox status --json 2>/dev/null | jq -r 'if .outcome == "enabled" then "on" else "off" end' 2>/dev/null)"
set --
[ -n "$setup_type" ] && set -- "$@" --type "$setup_type"
[ -n "$repo_choice" ] && set -- "$@" --repo "$repo_choice"
.gaia/cli/gaia ping --event setup --sandbox "${sandbox:-off}" "$@" || true
exit 0
