#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154 # the lists are read by the sourcing hook; git_subcommand and git_args come from lib/main-git-guard-parse.sh
#
# subagent-git-policy.sh: which git a sub-agent may not run, and which agents
# may. The one definition of the execution doctrine's "git that changes state"
# for the sub-agent rule in block-main-destructive-git.sh
# (.claude/doctrine/execution.md, `## Roles and git`). Sourced, never executed;
# defines lists and one function, does no work at source time. Bash 3.2
# compatible.

[ -n "${GAIA_SUBAGENT_GIT_POLICY_SH:-}" ] && return 0
GAIA_SUBAGENT_GIT_POLICY_SH=1

# Subcommands a sub-agent may not run. `stash` is listed and then narrowed by
# GAIA_SUBAGENT_GIT_STASH_READ_VERBS below.
GAIA_SUBAGENT_DENIED_GIT_SUBCOMMANDS=(
  commit push reset checkout switch restore rebase merge cherry-pick revert am stash
)

# The `git stash` verbs that write nothing. Every other stash form, a bare
# `git stash` included, pushes or drops an entry on the stack every checkout
# shares.
GAIA_SUBAGENT_GIT_STASH_READ_VERBS=(list show)

# The `agent_type` values the rule exempts. audit-loop-unit commits and pushes
# its own fix rounds, the doctrine's one sanctioned exception.
GAIA_SUBAGENT_GIT_EXEMPT_AGENTS=(audit-loop-unit)

# subagent_git_exempt <agent type>: 0 when that agent type may run state-changing git.
subagent_git_exempt() {
  local exempt_agent
  for exempt_agent in ${GAIA_SUBAGENT_GIT_EXEMPT_AGENTS[@]+"${GAIA_SUBAGENT_GIT_EXEMPT_AGENTS[@]}"}; do
    [ "$1" = "$exempt_agent" ] && return 0
  done
  return 1
}

# subagent_git_segment_denied: 0 when the segment parse_git_globals last read
# is git a sub-agent may not run.
subagent_git_segment_denied() {
  local denied_subcommand read_verb
  for denied_subcommand in ${GAIA_SUBAGENT_DENIED_GIT_SUBCOMMANDS[@]+"${GAIA_SUBAGENT_DENIED_GIT_SUBCOMMANDS[@]}"}; do
    [ "$git_subcommand" = "$denied_subcommand" ] || continue
    [ "$git_subcommand" = stash ] || return 0
    for read_verb in ${GAIA_SUBAGENT_GIT_STASH_READ_VERBS[@]+"${GAIA_SUBAGENT_GIT_STASH_READ_VERBS[@]}"}; do
      [ "${git_args[0]:-}" = "$read_verb" ] && return 1
    done
    return 0
  done
  return 1
}
