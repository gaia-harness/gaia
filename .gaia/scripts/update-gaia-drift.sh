#!/usr/bin/env bash
# shellcheck shell=bash
#
# update-gaia-drift.sh: report the setup features a release lists that this
# project has not decided yet, one token per line.
#
#   bash .gaia/scripts/update-gaia-drift.sh --features <path to the target bundle's .gaia/setup-features.json>
#
# Tokens: `SETUP <id>`, `OWED_ADMIN <id>`, `APPLY <id> <reference>`,
# `ASK <id> <reference>`, or one `DRIFT_FAILED <reason>`. Exit 0 always, except
# a usage error (2): drift never fails an update.
#
# Run it with the working directory at the project root, after the merge: it
# calls the working tree's `.gaia/cli/gaia`, which is the updated CLI. It is a
# script because the update worktree's runtime refuses the captured
# substitutions this logic needs when they sit in a command's text.

features=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --features) [ "$#" -ge 2 ] || { echo "usage: update-gaia-drift.sh --features <path>" >&2; exit 2; }; features="$2"; shift 2 ;;
    *) echo "usage: update-gaia-drift.sh --features <path>" >&2; exit 2 ;;
  esac
done
[ -n "$features" ] || { echo "usage: update-gaia-drift.sh --features <path>" >&2; exit 2; }

drift_error_file="$(mktemp)"
if ! drift_json="$(.gaia/cli/gaia setup drift --json --features "$features" 2>"$drift_error_file")" \
  || ! printf '%s' "$drift_json" | jq -e '.undecided | type == "array"' >/dev/null 2>&1; then
  drift_reason="$(head -n 1 "$drift_error_file")"
  rm -f "$drift_error_file"
  echo "DRIFT_FAILED ${drift_reason:-drift output unreadable}"
  exit 0
fi
rm -f "$drift_error_file"

# The admin probe runs once, and only when a project-scope admin feature is
# due to be applied or asked. No GitHub origin or a failed probe is not an admin.
is_admin=false
if printf '%s' "$drift_json" | jq -e 'any(.undecided[]; (.action == "apply" or .action == "ask") and .scope == "project" and .admin == true)' >/dev/null 2>&1; then
  remote_json="$(.gaia/cli/gaia setup detect-remote --json 2>/dev/null)" || remote_json=''
  remote_owner="$(printf '%s' "$remote_json" | jq -r 'select(.found == true and .host == "github.com") | .owner // empty' 2>/dev/null)"
  remote_repo="$(printf '%s' "$remote_json" | jq -r 'select(.found == true and .host == "github.com") | .repo // empty' 2>/dev/null)"
  if [ -n "$remote_owner" ] && [ -n "$remote_repo" ]; then
    admin_json="$(.gaia/cli/gaia setup check-admin --owner "$remote_owner" --repo "$remote_repo" --json 2>/dev/null)" || admin_json=''
    if printf '%s' "$admin_json" | jq -e '.admin == true and .auth_status == "ok"' >/dev/null 2>&1; then
      is_admin=true
    fi
  fi
fi

printf '%s' "$drift_json" | jq -r --argjson is_admin "$is_admin" '
  .undecided[]
  | if .action == "setup" then "SETUP \(.id)"
    elif .scope == "project" and .admin == true and ($is_admin | not) then "OWED_ADMIN \(.id)"
    elif .action == "apply" then "APPLY \(.id) \(.reference)"
    elif .action == "ask" then "ASK \(.id) \(.reference)"
    else "SETUP \(.id)"
    end'
exit 0
