#!/usr/bin/env bash
# The destructive-git guard's stash rule. Sourced by block-main-destructive-git.sh
# after lib/main-git-guard-parse.sh, where stash_rule_reason reads the globals
# parse_git_globals sets for the segment the walk is on (git_subcommand,
# git_args), and by .gaia/scripts/stash-reap-lib.sh for stash_subject_branch.
# Defines functions and does no other work at source time.
#
# Why. Every linked worktree shares one stash stack: `refs/stash` and its reflog
# live in the common git dir. A `git stash pop`, `apply`, `drop`, `branch` or
# `clear` run in one tree can take an entry another tree made, so that
# session's uncommitted work lands in this tree or is deleted, and neither
# session sees a signal. A bare pop is the natural path: it takes `stash@{0}`,
# whoever pushed it, and a peer's lint-staged backup sits there while its
# commit runs.
#
# The rule. Those verbs act only on entries whose subject names the acting
# checkout's branch. git writes the branch into every entry it creates
# (`WIP on <branch>: ...`, `On <branch>: <message>`), and a refname cannot hold
# a colon, so the text up to the first colon is the branch. `clear` passes only
# when every entry names the branch. Reading (`list`, `show`) and creating
# (bare `git stash`, `push`, `save`, `create`, `store`) take nothing, so they
# pass. An empty stack has nothing to take, so every verb passes.
#
# Fail closed. A detached HEAD, an unreadable stack, a reference that does not
# resolve, a subject naming no branch (`(no branch)`, a hand-written `stash
# store -m`) and a checkout the walk could not identify all deny.
#
# The person's path. GAIA guards what Claude does on its own, never a person's
# deliberate direction, but the hook cannot tell a request from Claude's own
# choice, and any override Claude could type would be one it could type
# unasked. So the denial names the entry's branch and asks the person to run
# the command themselves with the ! prefix, the same route the guard's other
# user-decision denials name.
#
# Honest limit: the stack is read at hook time, so an entry a peer pushes
# between this read and the command's own run can still shift a bare
# `stash@{0}`. Naming the entry by hash (`git stash apply <hash>`) closes that
# window; an index cannot.

# shellcheck disable=SC2154,SC2034  # git_subcommand and git_args come from parse_git_globals; stash_reason goes to block-main-destructive-git.sh

# _stash_git <directory> <git arguments...>: git in <directory>, or in this
# process's directory when it is empty.
_stash_git() {
  local directory="$1"
  shift
  if [ -n "$directory" ]; then git -C "$directory" "$@"; else git "$@"; fi
}

# stash_subject_branch <subject>: print the branch a stash subject names, rc 1
# when it names none.
stash_subject_branch() {
  local rest
  case "$1" in
    'WIP on '*) rest="${1#WIP on }" ;;
    'On '*) rest="${1#On }" ;;
    *) return 1 ;;
  esac
  case "$rest" in *:*) ;; *) return 1 ;; esac
  rest="${rest%%:*}"
  case "$rest" in '' | '(no branch)') return 1 ;; esac
  printf '%s' "$rest"
}

# _stash_entry_operand: print the entry the verb names, empty for the default
# `stash@{0}`. `branch` takes the new branch name first.
_stash_entry_operand() {
  local argument skip_operand=0
  [ "${git_args[0]:-}" = branch ] && skip_operand=1
  for argument in "${git_args[@]:1}"; do
    case "$argument" in
      --) continue ;;
      -*) continue ;;
    esac
    if [ "$skip_operand" -eq 1 ]; then skip_operand=0; continue; fi
    printf '%s' "$argument"
    return 0
  done
  return 0
}

# _stash_deny <message>: set stash_reason, with the shared tail.
_stash_deny() {
  stash_reason="$1 Every worktree shares one stash stack (wiki/concepts/Worktrees.md), so taking another branch's entry moves that session's uncommitted work into this tree or deletes it. To set work aside, use a WIP commit instead."
}

_STASH_NAME_OWN="Find this branch's own entries with 'git stash list' and name one ('git stash pop stash@{n}' or its hash)."

# stash_rule_reason <directory> <ambiguous>: set stash_reason to the deny reason
# for the stash segment parse_git_globals just read, or to empty. <directory> is
# the checkout the segment acts on (empty: this process's), <ambiguous> is 1
# when the walk could not tell which checkout that is.
stash_rule_reason() {
  local directory="$1" ambiguous="$2" verb="${git_args[0]:-}" branch operand reference
  local entry_hash subject entry_branch listing line
  stash_reason=""
  [ "$git_subcommand" = stash ] || return 0
  case "$verb" in
    pop | apply | drop | branch | clear) ;;
    *) return 0 ;;
  esac
  _stash_git "$directory" rev-parse -q --verify refs/stash >/dev/null 2>&1 || return 0
  if [ "$ambiguous" = 1 ]; then
    _stash_deny "This command names a directory this guard cannot read, so it cannot tell which branch 'git stash $verb' runs on, and the entry it takes may be another session's. Spell the directory literally."
    return 0
  fi
  branch=$(_stash_git "$directory" symbolic-ref --short -q HEAD 2>/dev/null) || branch=""
  if [ -z "$branch" ]; then
    _stash_deny "'git stash $verb' on a detached HEAD cannot be matched to a branch, so the guard cannot tell whether the entry is this session's. Check out the branch first."
    return 0
  fi
  if [ "$verb" = clear ]; then
    if ! listing=$(_stash_git "$directory" log -g --format=%s refs/stash 2>/dev/null); then
      _stash_deny "'git stash clear' was refused because the stash stack could not be read."
      return 0
    fi
    while IFS= read -r line; do
      entry_branch=$(stash_subject_branch "$line") || entry_branch=""
      if [ "$entry_branch" != "$branch" ]; then
        _stash_deny "'git stash clear' deletes every entry, and the stack holds one made on '${entry_branch:-no branch}', not on this checkout's branch '$branch'. If the user asked to clear it, tell them so and ask them to run it themselves with the ! prefix."
        return 0
      fi
    done <<<"$listing"
    return 0
  fi
  operand=$(_stash_entry_operand)
  reference="${operand:-stash@{0\}}"
  case "$reference" in
    *[!0-9]*) ;;
    *) reference="stash@{$reference}" ;;
  esac
  if ! entry_hash=$(_stash_git "$directory" rev-parse -q --verify "$reference^{commit}" 2>/dev/null) \
     || ! subject=$(_stash_git "$directory" log -1 --format=%s "$entry_hash" 2>/dev/null); then
    _stash_deny "'git stash $verb' was refused because '$reference' could not be read, so the guard cannot tell whose entry it is."
    return 0
  fi
  if ! entry_branch=$(stash_subject_branch "$subject"); then
    _stash_deny "'git stash $verb' would take $reference, whose subject names no branch, so the guard cannot tell whose entry it is. $_STASH_NAME_OWN If the user asked for this entry, ask them to run the command themselves with the ! prefix."
    return 0
  fi
  if [ "$entry_branch" != "$branch" ]; then
    _stash_deny "'git stash $verb' would take $reference, which was made on '$entry_branch', not on this checkout's branch '$branch'. $_STASH_NAME_OWN If the user asked for this entry by name, tell them it was made on '$entry_branch' and ask them to run the command themselves with the ! prefix."
  fi
  return 0
}
