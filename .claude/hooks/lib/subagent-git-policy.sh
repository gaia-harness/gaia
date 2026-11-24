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

# subagent_git_own_tree_command <agent id> <command>: 0 when the command can
# only act on the sub-agent's own isolated worktree. The commit rule's reason
# (siblings share one tree) does not hold for a tree only this agent uses.
#   - The acting directory's checkout root is a linked worktree (a `.git` file)
#     named `agent-<agent id>`, the name isolation gives the worktree it makes
#     for that sub-agent. The id is unique, so a sub-agent in its parent's tree,
#     or a depth-2 agent in another agent's, never matches.
#   - Every segment is a bare `git <subcommand>` whose only global option is one
#     `-C <literal path>` resolving to that same root (`.claude/rules/shell-cwd.md`
#     prescribes `git -C`; a quoted `$X` the shell would expand is not literal).
#     The command carries no backtick, which the `| & ; ( )` split cannot open.
#     A `cd`, `pushd`, `sh -c`, env prefix (`GIT_DIR=`), `-c core.worktree=`,
#     `--git-dir` or `--work-tree` could carry git into the parent's tree, so
#     any of them fails this test.
# Needs acting_directory, parse_git_globals, git_global_words and git_cwd from
# lib/main-git-guard-parse.sh.
subagent_git_own_tree_command() {
  local agent_id="$1" command="$2" directory checkout_root segment target_root
  [ -n "$agent_id" ] || return 1
  directory=$(acting_directory)
  checkout_root=$(git ${directory:+-C "$directory"} rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -f "$checkout_root/.git" ] && [ "${checkout_root##*/}" = "agent-$agent_id" ] || return 1
  case "$command" in *'`'*) return 1 ;; esac
  while IFS= read -r segment; do
    segment="${segment#"${segment%%[![:space:]]*}"}"
    [ -n "$segment" ] || continue
    [[ "$segment" =~ ^git[[:space:]] ]] || return 1
    parse_git_globals "$segment"
    [ -n "${git_global_words[*]+set}" ] || continue
    [ "${#git_global_words[@]}" -eq 2 ] && [ "${git_global_words[0]}" = -C ] || return 1
    [[ "$git_cwd" =~ ^[A-Za-z0-9._/+@,:=-]+$ ]] || return 1
    case "$git_cwd" in /*) ;; *) git_cwd="${directory:-$PWD}/$git_cwd" ;; esac
    target_root=$(git -C "$git_cwd" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ "$target_root" = "$checkout_root" ] || return 1
  done < <(printf '%s\n' "$command" | tr '|&;()' '\n')
  return 0
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
