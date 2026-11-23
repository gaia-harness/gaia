#!/usr/bin/env bash
# The destructive-git guard's history rules: the git subcommands that rewrite
# or destroy shared history, the reflog that recovers it, or the ignored local
# state GAIA keeps beside the checkout. Sourced only by
# block-main-destructive-git.sh, after lib/main-git-guard-parse.sh, and reads
# the globals parse_git_globals sets for the segment the walk is on
# (git_subcommand, git_args). Defines functions and does no other work at
# source time.
#
# Why these rules exist. classify-git-command.sh approves ordinary git calls
# without a prompt, so an autonomous driver does not stall on an ordinary commit,
# push, rebase or branch, and these rules deny what no approval may cover: a
# PreToolUse deny from any hook overrides that allow. Each rule
# below names an operation whose damage reaches past the feature branch the
# agent is working on: main itself, the remote, the means of recovery, or
# machine-local state git cannot restore. Policy: wiki/concepts/Git Workflow.md
# (`## 4. Approved by a classifier, bounded by hooks`).
#
# Every rule reads the parsed operands, never the raw text, so a flag written
# inside a quoted commit message is not an invocation. A long option matches in
# any prefix git's option parser accepts (`--mirr` is `--mirror`). The honest limits of
# parse_git_globals (an unexpanded variable, a value-taking global option the
# table lacks) bind these rules too: such a spelling reads no subcommand and
# allows.
#
# Not covered here, on purpose: `git checkout -- .`, `git restore .`,
# `git stash clear` and `git stash drop` discard uncommitted work, but on the
# agent's own branch that is ordinary, recoverable-by-redo work; the execution
# doctrine already keeps executors off state-changing git. Force-pushing a
# feature branch, deleting a tag, and `git worktree remove --force` are allowed:
# none reaches main or another person's history.

# shellcheck disable=SC2154,SC2034  # git_subcommand and git_args come from parse_git_globals; history_reason goes to block-main-destructive-git.sh

# _history_is_main_ref <ref>: 0 when <ref> names main or master as a branch,
# bare, fully spelled, or as `heads/main`, which git resolves to refs/heads/main.
_history_is_main_ref() {
  case "$1" in
    main | master | heads/main | heads/master | refs/heads/main | refs/heads/master) return 0 ;;
  esac
  return 1
}

# _history_option_is <argument> <--long...>: 0 when <argument>, any `=value`
# dropped, is one of the long options or a prefix of one. git's option parser
# runs an unambiguous prefix as the full option, and rejects an ambiguous one,
# so a prefix match never denies a command git would run as something else.
_history_option_is() {
  local option="${1%%=*}" long
  shift
  case "$option" in
    --?*) ;;
    *) return 1 ;;
  esac
  for long in "$@"; do
    case "$long" in "$option"*) return 0 ;; esac
  done
  return 1
}

# _history_has_option <--long...>: 0 when any operand is one of the long
# options, in a spelling _history_option_is accepts.
_history_has_option() {
  local argument
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    _history_option_is "$argument" "$@" && return 0
  done
  return 1
}

# push_refspec_targets_main: 0 when the words after a `push` subcommand carry a
# refspec whose DESTINATION is main or master, or that names main or master in
# its fully spelled form. Complements push_refspec_names_main in
# lib/main-git-guard-parse.sh, which reads only the source and the bare names:
# `git push origin feature:main` lands a feature branch on main without a pull
# request, `+feature:main` force-overwrites it with no `--force` word for rule 2
# to read, `:main` deletes it, and `--delete refs/heads/main` deletes it in a
# spelling the bare-name test does not know. A refspec with no colon pushes to
# the branch of the same name, so its source is its destination. A bare `:`
# pushes every branch both sides share, main included, and a glob destination
# (`refs/heads/*`) covers main when the pattern matches it.
#
# Same operand walk as push_refspec_names_main: the first operand is the remote,
# a leading `+` is the force marker, `--` is not an operand, and the
# value-taking options are skipped with their value.
push_refspec_targets_main() {
  local argument seen_remote=0 skip_next=0 refspec destination
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$argument" in
      --) continue ;;
      -o | --push-option | --repo | --receive-pack | --exec)
        skip_next=1; continue ;;
      -*) continue ;;
    esac
    if [ "$seen_remote" -eq 0 ]; then seen_remote=1; continue; fi
    refspec="${argument#+}"
    [ "$refspec" = : ] && return 0
    case "$refspec" in
      *:*) destination="${refspec#*:}" ;;
      *) destination="$refspec" ;;
    esac
    _history_is_main_ref "$destination" && return 0
    case "$destination" in
      *'*'*)
        # shellcheck disable=SC2053  # false positive: the unquoted right side is the glob git expands
        [[ refs/heads/main == $destination || refs/heads/master == $destination ]] && return 0
        ;;
    esac
  done
  return 1
}

# _history_force_create_names_main <letter> [<--long>]: 0 when the branch named
# by the force-create option (`checkout -B`, `switch -C` or
# `--force-create`) is main or master: that resets the existing branch to
# another commit. The short option takes its value attached (`-Bmain`) or as
# the next word, and may close a bundle (`-fB main`).
_history_force_create_names_main() {
  local letter="$1" long="${2:-}" argument take_next=0 name
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    if [ "$take_next" -eq 1 ]; then
      _history_is_main_ref "$argument" && return 0
      take_next=0
      continue
    fi
    case "$argument" in
      --*=*)
        if [ -n "$long" ] && _history_option_is "$argument" "$long"; then
          _history_is_main_ref "${argument#*=}" && return 0
        fi
        ;;
      --*)
        if [ -n "$long" ] && _history_option_is "$argument" "$long"; then take_next=1; fi
        ;;
      -*"$letter"*)
        name="${argument#*"$letter"}"
        if [ -z "$name" ]; then take_next=1; else _history_is_main_ref "$name" && return 0; fi
        ;;
    esac
  done
  return 1
}

# _history_update_ref_names_head: 0 when the ref `git update-ref` writes, its
# first operand past `-m <reason>`, is HEAD: on the main checkout that moves main.
_history_update_ref_names_head() {
  local argument skip_next=0
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$argument" in
      -m) skip_next=1; continue ;;
      -*) continue ;;
    esac
    [ "$argument" = HEAD ]
    return
  done
  return 1
}

# _history_symbolic_ref_writes_main: 0 when `git symbolic-ref` deletes or
# re-points main or master: `-d` or `--delete` with a main operand, or a main
# name as the first operand when a target follows it. A read (`symbolic-ref
# refs/heads/main`) and `symbolic-ref HEAD refs/heads/main` (a switch) pass.
_history_symbolic_ref_writes_main() {
  local argument operand_count=0 first=""
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    case "$argument" in
      -d | --delete) _history_names_main && return 0 ;;
      -*) ;;
      *)
        operand_count=$((operand_count + 1))
        [ "$operand_count" -eq 1 ] && first="$argument"
        ;;
    esac
  done
  [ "$operand_count" -ge 2 ] && _history_is_main_ref "$first"
}

# _history_has_short_flag <letter...>: 0 when any operand is a single-dash
# short-flag bundle carrying one of the letters (`-x`, `-fdx`, `-Xdf`).
_history_has_short_flag() {
  local argument letter
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    case "$argument" in
      --*) continue ;;
      -?*)
        for letter in "$@"; do
          case "$argument" in *"$letter"*) return 0 ;; esac
        done
        ;;
    esac
  done
  return 1
}

# _history_has_word <word...>: 0 when any operand equals one of the words.
_history_has_word() {
  local argument word
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    for word in "$@"; do
      [ "$argument" = "$word" ] && return 0
    done
  done
  return 1
}

# _history_names_main: 0 when any operand names main or master (see
# _history_is_main_ref).
_history_names_main() {
  local argument
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    _history_is_main_ref "$argument" && return 0
  done
  return 1
}

# _history_config_reason: the hooksPath rule. A `git config` that sets
# core.hooksPath to anything but `.githooks`, or unsets it, switches off the
# pre-commit floor for every later commit, the persistent form of the inline
# `-c core.hooksPath=` override block-no-verify.sh denies. Reads pass, and so
# does the one write GAIA itself prescribes (`git config core.hooksPath
# .githooks`, from the root `prepare` script and /setup-gaia). Git config keys
# are case-insensitive. An empty value is a write, not a read: it points the
# hooks at no directory, so no hook runs. Removing or renaming the `core`
# section unsets the key with it. Honest limit: an edit of `.git/config` by any
# other route is not a `git config` invocation and is not read here.
_history_config_reason() {
  local argument key_seen=0 value_seen=0 value="" lowered is_unset=0 section_edit=0 skip_next=0
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    lowered=$(printf '%s' "$argument" | tr '[:upper:]' '[:lower:]')
    case "$lowered" in
      --*=*) ;;
      --*) if _history_option_is "$lowered" --comment; then skip_next=1; continue; fi ;;
    esac
    case "$lowered" in
      -l) return 0 ;;
    esac
    # A subcommand word counts only ahead of the key: after it, `get` is a value.
    if [ "$key_seen" -eq 0 ]; then
      case "$lowered" in
        get | list) return 0 ;;
        unset) is_unset=1; continue ;;
        remove-section | rename-section) section_edit=1; continue ;;
      esac
    fi
    if _history_option_is "$lowered" --get --get-all --get-regexp --get-urlmatch --list; then
      return 0
    fi
    if _history_option_is "$lowered" --unset --unset-all; then is_unset=1; continue; fi
    if _history_option_is "$lowered" --remove-section --rename-section; then section_edit=1; continue; fi
    if [ "$section_edit" -eq 1 ] && [ "$lowered" = core ]; then
      key_seen=1
      is_unset=1
      break
    fi
    if [ "$key_seen" -eq 1 ] && [ "$value_seen" -eq 0 ]; then
      case "$argument" in
        -*) ;;
        *) value="$argument"; value_seen=1 ;;
      esac
      continue
    fi
    [ "$lowered" = core.hookspath ] && key_seen=1
  done
  [ "$key_seen" -eq 1 ] || return 0
  if [ "$is_unset" -eq 0 ] && { [ "$value" = .githooks ] || [ "$value" = ./.githooks ]; }; then
    return 0
  fi
  # A key with no value and no write flag is a read (`git config core.hooksPath`).
  if [ "$is_unset" -eq 0 ] && [ "$value_seen" -eq 0 ]; then
    return 0
  fi
  history_reason="Pointing core.hooksPath anywhere but .githooks, or unsetting it, switches off GAIA's git hooks for every later commit (wiki/concepts/Pre-commit Hooks.md). The only write Claude may make is 'git config core.hooksPath .githooks'. If the hooks should stay off on this machine, that is the user's decision: ask them to run it themselves."
}

# _history_config_command_reason: the `git config` half of the command-config
# rule. Denies a write that pairs a listed key with a value that runs something,
# and a section rename into a section such a key lives in. A read or an unset
# writes nothing that runs, so it passes. Every operand word is tried as the
# key, with the word after it as the value, so a value-taking option this
# function does not know (`--default <v>`, `--file <f>`) cannot hide the key.
_history_config_command_reason() {
  local index=0 count=${#git_args[@]} word lowered operand_seen=0 rename=0 renamed_from=""
  while [ "$index" -lt "$count" ]; do
    word="${git_args[$index]}"
    lowered=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
    case "$lowered" in
      --*=*) ;;
      --*) if _history_option_is "$lowered" --comment; then index=$((index + 2)); continue; fi ;;
    esac
    if _history_option_is "$lowered" --get --get-all --get-regexp --get-urlmatch --list \
       --unset --unset-all || [ "$lowered" = -l ]; then
      return 0
    fi
    if _history_option_is "$lowered" --rename-section; then rename=1; index=$((index + 1)); continue; fi
    case "$word" in
      -*) index=$((index + 1)); continue ;;
    esac
    if [ "$operand_seen" -eq 0 ]; then
      operand_seen=1
      case "$lowered" in
        get | list | unset) return 0 ;;
        rename-section) rename=1; index=$((index + 1)); continue ;;
      esac
    fi
    if [ "$rename" -eq 1 ]; then
      if [ -z "$renamed_from" ]; then
        renamed_from="$word"
      elif gaia_git_config_section_runs_command "$word"; then
        history_reason="Renaming a config section to '$word' can turn its keys into ones git runs as a command (an alias, a pager, an ssh command), and ordinary git calls run without a permission prompt here, so that is an unprompted shell (wiki/concepts/Git Workflow.md). Ask the user to run it themselves if they want it."
        return 0
      fi
    elif [ $((index + 1)) -lt "$count" ] \
       && [ "$(gaia_git_config_key_class "$word" "${git_args[$((index + 1))]}")" = runs-command ]; then
      history_reason="Setting '$word' makes git run its value as a command on later git calls, and ordinary git calls run without a permission prompt here, so that is an unprompted shell (wiki/concepts/Git Workflow.md). Run the command directly, where its own permission rule applies, or ask the user to set the key themselves."
      return 0
    fi
    index=$((index + 1))
  done
  return 0
}

# command_config_rule_reason: set history_reason when the segment makes git run
# a program from config: a `-c` or `--config-env` override of a key
# lib/git-command-config.sh lists, a `-c core.hooksPath` other than .githooks
# (git runs that directory's hooks on any subcommand), or a `git config` write
# of a listed key. The block-main-destructive-git.sh walk asks this before its
# foreign-repository skip, because the command runs whichever repository the
# segment names.
command_config_rule_reason() {
  local setting key value class
  history_reason=""
  for setting in ${git_config_settings[@]+"${git_config_settings[@]}"}; do
    key="${setting%%=*}"
    value=""
    case "$setting" in *=*) value="${setting#*=}" ;; esac
    class=$(gaia_git_config_key_class "$key" "$value")
    if [ "$class" = runs-command ] \
       || { [ "$class" = hookspath ] && [ "$value" != .githooks ] && [ "$value" != ./.githooks ]; }; then
      history_reason="'git -c $key=...' makes git run a program or a shell command from config, and ordinary git calls run without a permission prompt here, so that is an unprompted shell (wiki/concepts/Git Workflow.md). Run the command directly, where its own permission rule applies; for a pager, use 'git --no-pager'."
      return 0
    fi
  done
  for setting in ${git_config_environment_settings[@]+"${git_config_environment_settings[@]}"}; do
    key="${setting%%=*}"
    if [ -n "$(gaia_git_config_key_class "$key" '!')" ]; then
      history_reason="'git --config-env=$key=...' sets a key git runs as a program or a shell command, from a variable this guard cannot read, and ordinary git calls run without a permission prompt here (wiki/concepts/Git Workflow.md). Run the command directly, where its own permission rule applies."
      return 0
    fi
  done
  [ "$git_subcommand" = config ] && _history_config_command_reason
  return 0
}

# history_rule_reason: set history_reason to the deny reason for the segment
# parse_git_globals just read, or to empty when no history rule applies. Sets a
# global rather than printing, so the caller pays no subshell per git segment.
history_rule_reason() {
  history_reason=""
  case "$git_subcommand" in
    push)
      if _history_has_option --mirror; then
        history_reason="'git push --mirror' makes the remote an exact copy of this clone: it overwrites main and deletes every remote branch this clone lacks (wiki/concepts/Git Workflow.md). Push the feature branch by its own name, 'git push -u origin <branch-name>', and open a PR."
      elif _history_has_option --all --branches; then
        history_reason="'git push --all' pushes every local branch, main included, so local commits on main reach the remote without the pull request and audit every change passes through (wiki/concepts/Git Workflow.md). Push the feature branch by its own name, 'git push -u origin <branch-name>'."
      fi
      ;;
    clean)
      if _history_has_short_flag x X; then
        history_reason="'git clean -x' (or -X) deletes ignored files, and in a GAIA checkout those are machine-local state git cannot restore: the .env files, GAIA's local working state (audit markers, ledgers, setup state) and the notebook (specs, plans, research and their catalog). Drop the -x: 'git clean -fd' removes untracked files and leaves ignored ones alone."
      fi
      ;;
    config)
      _history_config_reason
      ;;
    update-ref)
      if _history_has_option --stdin; then
        history_reason="'git update-ref --stdin' writes refs this guard cannot read, so it cannot tell whether main is among them (wiki/concepts/Git Workflow.md). Use 'git branch' or 'git switch' on the feature branch instead."
      elif _history_names_main || _history_update_ref_names_head; then
        history_reason="'git update-ref' on main or master, or on HEAD, which is main in the main checkout, moves or deletes the shared branch outside every guard that protects it (wiki/concepts/Git Workflow.md). Main changes only through a merged pull request; on a feature branch use 'git branch' or 'git switch'."
      fi
      ;;
    branch | checkout | switch | worktree | symbolic-ref)
      if { [ "$git_subcommand" = branch ] && _history_names_main \
             && { _history_has_short_flag d D f m M c C \
                  || _history_has_option --delete --force --move --copy; }; } \
         || { [ "$git_subcommand" = checkout ] && _history_force_create_names_main B; } \
         || { [ "$git_subcommand" = switch ] && _history_force_create_names_main C --force-create; } \
         || { [ "$git_subcommand" = worktree ] && _history_force_create_names_main B; } \
         || { [ "$git_subcommand" = symbolic-ref ] && _history_symbolic_ref_writes_main; }; then
        history_reason="Deleting, renaming, copying over or force-moving the local main or master branch is the user's decision, not Claude's (wiki/concepts/Git Workflow.md): it is the base every feature branch, worktree and cleanup step reads. Ask the user to run it themselves if they want it."
      fi
      ;;
    reflog)
      if _history_has_word expire delete drop; then
        history_reason="'git reflog expire', 'git reflog delete' and 'git reflog drop' erase the record that recovers a dropped commit or a bad reset (wiki/concepts/Git Workflow.md). Nothing in GAIA needs them; leave the reflog to git's own expiry."
      fi
      ;;
    gc)
      if _history_has_option --prune; then
        history_reason="'git gc --prune' deletes unreachable objects on a cutoff it sets, the last copy of a dropped stash or a commit no reflog still names (wiki/concepts/Git Workflow.md). Run 'git gc' with no prune option, or leave it to git's automatic maintenance."
      fi
      ;;
    prune)
      history_reason="'git prune' deletes unreachable objects, the last copy of a dropped stash or a commit no reflog still names (wiki/concepts/Git Workflow.md). Leave it to git's automatic maintenance."
      ;;
    filter-branch | filter-repo)
      history_reason="'git $git_subcommand' rewrites history across branches, and a rewrite of shared history pulls commits out from under every clone built on it (wiki/concepts/Git Workflow.md). History rewrites are the user's decision: ask them to run it themselves."
      ;;
  esac
  return 0
}
