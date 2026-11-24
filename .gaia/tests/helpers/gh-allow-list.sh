#!/usr/bin/env bash
# Shared bats primitive: is a `gh` command allowed without a permission prompt
# by the root `.claude/settings.json` allow list?
#
# Sourced from a suite's body, from any bats directory. A hook suite uses it to
# prove its hook still fires on a form the allow list lets through, so an allow
# rule never stands in for a PreToolUse deny.
#
# API:
#   gh_command_is_allowed COMMAND
#
# Returns 0 when a `Bash(<prefix>:*)` rule matches COMMAND at a word boundary
# (or a `Bash(<command>)` rule equals it), 1 otherwise. Reads
# `$REPO_ROOT/.claude/settings.json`, so the caller sets `REPO_ROOT`.

gh_command_is_allowed() {
  jq -e --arg command "$1" '
    .permissions.allow
    | map(select(startswith("Bash(") and endswith(")")) | .[5:-1])
    | any(. as $rule
        | if ($rule | endswith(":*"))
          then ($rule | .[:-2]) as $prefix
            | ($command == $prefix or ($command | startswith($prefix + " ")))
          else $command == $rule
          end)
  ' "$REPO_ROOT/.claude/settings.json" >/dev/null
}
