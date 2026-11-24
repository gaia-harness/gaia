#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154 # the lists are read by the sourcing hook; git_subcommand and git_args come from lib/main-git-guard-parse.sh
#
# subagent-git-policy.sh: which git a sub-agent may not run, and which agents
# may: the subcommands the sub-agent rule in block-main-destructive-git.sh
# denies as the execution doctrine's "git that changes state"
# (.claude/doctrine/execution.md, `## Roles and git`). The doctrine also names
# stage and branch, which this list does not deny. Sourced, never executed;
# defines lists and functions, does no work at source time. Bash 3.2
# compatible.

[ -n "${GAIA_SUBAGENT_GIT_POLICY_SH:-}" ] && return 0
GAIA_SUBAGENT_GIT_POLICY_SH=1

# Subcommands a sub-agent may not run. `stash` is listed and then narrowed by
# GAIA_SUBAGENT_GIT_STASH_READ_VERBS below.
GAIA_SUBAGENT_DENIED_GIT_SUBCOMMANDS=(
  commit push reset checkout switch restore rebase merge pull clean cherry-pick revert am stash
)

# The `git stash` verbs that write nothing. Every other stash subcommand, a bare
# `git stash` included, writes to the working tree, the stack every checkout
# shares, the object store or a ref.
GAIA_SUBAGENT_GIT_STASH_READ_VERBS=(list show)

# The `agent_type` values the rule exempts. audit-loop-unit commits and pushes
# its own fix rounds, the doctrine's one sanctioned exception.
GAIA_SUBAGENT_GIT_EXEMPT_AGENTS=(audit-loop-unit)

# subagent_git_own_worktree <checkout root> <agent id>: 0 when the root is a
# linked worktree (a `.git` file) named `agent-<agent id>`, the name isolation
# gives the worktree it makes for that sub-agent. The id is unique, so a
# sub-agent that shares its parent's tree (or a depth-2 agent in another
# agent's tree) never matches and stays restricted. The commit rule's reason
# (siblings share one tree) does not hold for a tree only this agent uses.
subagent_git_own_worktree() {
  local checkout_root="$1" agent_id="$2"
  [ -n "$checkout_root" ] && [ -n "$agent_id" ] || return 1
  [ -f "$checkout_root/.git" ] || return 1
  [ "${checkout_root##*/}" = "agent-$agent_id" ]
}

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
