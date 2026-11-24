#!/usr/bin/env bash
# Shared bats primitive: is a `gh` command allowed without a permission prompt
# by the root `.claude/settings.json`?
#
# A hook suite uses it to prove its hook still runs on a form the allow list
# lets through without a prompt.
#
# API:
#   gh_command_is_allowed COMMAND
#
# Returns 0 when a `Bash(...)` allow rule matches COMMAND and no `ask` or `deny`
# `Bash(...)` rule does, 1 otherwise. A `<prefix>:*` rule matches at a word
# boundary; any other rule is a glob over the whole command. Reads
# `$REPO_ROOT/.claude/settings.json`, so the caller sets `REPO_ROOT`.

gh_command_matches_rule() {
  local command_text="$1" rule="$2" prefix
  case "$rule" in
    *:\*)
      prefix=${rule%:\*}
      [ "$command_text" = "$prefix" ] || [[ $command_text == "$prefix "* ]]
      ;;
    *)
      # shellcheck disable=SC2053
      [[ $command_text == $rule ]]
      ;;
  esac
}

gh_command_is_allowed() {
  local command_text="$1" rule allowed=1
  while IFS= read -r rule; do
    gh_command_matches_rule "$command_text" "$rule" && allowed=0
  done < <(jq -r '.permissions.allow[] | select(startswith("Bash(") and endswith(")")) | .[5:-1]' "$REPO_ROOT/.claude/settings.json")
  while IFS= read -r rule; do
    gh_command_matches_rule "$command_text" "$rule" && return 1
  done < <(jq -r '(.permissions.ask + .permissions.deny)[] | select(startswith("Bash(") and endswith(")")) | .[5:-1]' "$REPO_ROOT/.claude/settings.json")
  return "$allowed"
}
