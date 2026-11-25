#!/usr/bin/env bash
# PreToolUse Bash hook: approve a git command it can vouch for, so an unattended
# run does not stall on a prompt for an ordinary commit or push. It returns
# `permissionDecision: allow` or nothing at all. Nothing means the normal
# permission flow runs: a settings rule, else the prompt. It never denies:
# block-main-destructive-git.sh and block-no-verify.sh do, and a PreToolUse
# deny from any hook beats this hook's allow (wiki/concepts/Git Workflow.md,
# `## 4. Approved by a classifier, bounded by hooks`). Settings deny and ask
# rules still apply after an allow.
#
# A command is approved only when every one of these holds:
#   - its structure is a list of simple commands joined by `&&`, `||`, `;`, a
#     newline or a pipe, with no background `&`, no redirect other than one that
#     discards or duplicates a stream (`2>&1`, `2>/dev/null`), no substitution,
#     no expansion (a backtick, a glob, a brace list, any `$` but `$?` outside a
#     git segment and a variable whose latest assignment, in an earlier
#     segment, is a literal outside a pipe and before any `&&`, `||` or pipe),
#     no subshell, no
#     backslash and no comment outside single quotes. `git commit -F -` may read
#     a heredoc whose delimiter is quoted, so its body never expands;
#   - at least one segment begins with the bare word `git`, and every other
#     segment is one lib/compound-segment-programs.sh approves: a git segment
#     with an env prefix, a wrapper or a path to git falls through;
#   - its global options are only `-C <directory>` (once), `-c <key>=<value>`
#     for a key on the safe list in lib/git-command-config.sh, `--no-pager`,
#     `-P` and `--no-optional-locks`;
#   - the directory git runs in, the payload cwd or the `-C` value read against
#     it, belongs to this repository (the main checkout or a linked worktree).
#     A git call in another repository runs that repository's config and hooks,
#     which nothing here has read;
#   - the subcommand is on the list in lib/git-allow-list.sh and carries none of
#     its fall-through options;
#   - neither the destructive-git guard's history and command-config rules nor
#     the branch questions main_branch_rule_matches reads (a superset of the
#     guard's main-branch and hard-reset rules) match the segment, with every
#     variable read as its assigned literal; the guard's peer-session checkout
#     rule is left to that hook, whose deny beats this allow.
#
# Fail to fall-through, never fail to allow: a missing library, a missing jq, a
# parse this file cannot finish, and every form not listed above exit 0 with no
# output.
#
# Honest limit: an approved commit, push, merge or checkout runs the
# repository's tracked hooks under `.githooks/` and whatever they call. Those
# are the project's own reviewed code; editing them is an ordinary file edit,
# and no rule here vouches for the edit.

# shellcheck disable=SC2154  # the parse globals are set in lib/main-git-guard-parse.sh
set -uo pipefail
# Byte indexing keeps the character walk below linear in a long commit message.
export LC_ALL=C

command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat)

library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || exit 0
hook_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0

# shellcheck source=lib/hook-payload.sh
. "$library_directory/hook-payload.sh" 2>/dev/null || exit 0
type gaia_hook_payload_read >/dev/null 2>&1 || exit 0
gaia_hook_payload_read "$payload" || exit 0
[ "$GAIA_HOOK_TOOL_NAME" = Bash ] || exit 0
command=$GAIA_HOOK_COMMAND
case "$command" in git | git[[:space:]]* | *[[:space:]]git[[:space:]]* | *[\;\&\|]git[[:space:]]*) ;; *) exit 0 ;; esac

# main-root-lib.sh loads first, with its output discarded, so a function it also
# defines is replaced by the hook library's definition below and nothing it
# prints at the top level can reach this hook's stdout. That is all the order
# buys: a function it defines under another name, such as `jq`, `git`, `tr` or
# `type`, survives and can still speak for this hook. `Edit(.gaia/**)` lets
# Claude rewrite that file unprompted, and the settings rules that allow
# `bash .gaia/scripts/*` already reach the same code, so the limit is accepted.
# shellcheck source=/dev/null
. "$hook_root/.gaia/scripts/main-root-lib.sh" >/dev/null 2>&1 || exit 0
# shellcheck source=lib/main-git-guard-parse.sh
. "$library_directory/main-git-guard-parse.sh" 2>/dev/null || exit 0
# shellcheck source=lib/main-git-guard-history.sh
. "$library_directory/main-git-guard-history.sh" 2>/dev/null || exit 0
# shellcheck source=lib/git-command-config.sh
. "$library_directory/git-command-config.sh" 2>/dev/null || exit 0
# shellcheck source=lib/git-allow-list.sh
. "$library_directory/git-allow-list.sh" 2>/dev/null || exit 0
# shellcheck source=lib/git-command-segments.sh
. "$library_directory/git-command-segments.sh" 2>/dev/null || exit 0
# shellcheck source=lib/compound-segment-programs.sh
. "$library_directory/compound-segment-programs.sh" 2>/dev/null || exit 0
for required_function in parse_git_globals history_rule_reason command_config_rule_reason \
    _history_option_is push_refspec_names_main push_refspec_targets_main reset_hard_moves_head \
    gaia_resolve_common_directory split_command_segments in_this_repository non_git_segment_is_approved; do
  type "$required_function" >/dev/null 2>&1 || exit 0
done
[ "${#GAIA_GIT_ALLOWED_SUBCOMMANDS[@]}" -gt 0 ] && [ "${#GAIA_GIT_SAFE_CONFIG_KEYS[@]}" -gt 0 ] || exit 0

# globals_are_approved: 0 when every global option of the segment
# parse_git_globals just read is one this file vouches for. Sets
# segment_directory to the one `-C` value, or empty.
globals_are_approved() {
  local index=0 count=${#git_global_words[@]} word key safe_key seen_directory=0
  segment_directory=""
  while [ "$index" -lt "$count" ]; do
    word="${git_global_words[$index]}"
    case "$word" in
      -C)
        [ "$seen_directory" -eq 0 ] || return 1
        seen_directory=1
        segment_directory="${git_global_words[$((index + 1))]:-}"
        [ -n "$segment_directory" ] || return 1
        index=$((index + 2)); continue ;;
      -c)
        key="${git_global_words[$((index + 1))]:-}"
        case "$key" in *=*) key="${key%%=*}" ;; *) return 1 ;; esac
        key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
        for safe_key in ${GAIA_GIT_SAFE_CONFIG_KEYS[@]+"${GAIA_GIT_SAFE_CONFIG_KEYS[@]}"}; do
          [ "$key" = "$safe_key" ] && { index=$((index + 2)); continue 2; }
        done
        return 1 ;;
      --no-pager | -P | --no-optional-locks) index=$((index + 1)); continue ;;
    esac
    return 1
  done
  return 0
}

# directory_is_approved: 0 when the directory the segment runs git in belongs to
# this repository. A relative `-C` reads against the payload cwd, which is the
# directory the Bash tool runs the command in.
directory_is_approved() {
  local directory
  case "$GAIA_HOOK_CWD" in /*) ;; *) return 1 ;; esac
  directory="$GAIA_HOOK_CWD"
  if [ -n "$segment_directory" ]; then
    case "$segment_directory" in
      '~'*) return 1 ;;
      /*) directory="$segment_directory" ;;
      *) directory="$GAIA_HOOK_CWD/$segment_directory" ;;
    esac
  fi
  segment_run_directory="$directory"
  in_this_repository "$directory"
}

# pull_fast_forwards_only: 0 when the `git pull` segment carries `--ff-only` and
# no option that lets it merge or rebase instead.
pull_fast_forwards_only() {
  local argument fast_forward_only=0 operand_count=0
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    case "$argument" in
      --ff-only) fast_forward_only=1 ;;
      --ff | --no-ff | --rebase* | -r) return 1 ;;
      -*) ;;
      *) operand_count=$((operand_count + 1)) ;;
    esac
  done
  # A remote followed by a branch fast-forwards the current branch onto that
  # branch, so on main it is a branch question; a bare remote follows upstream.
  [ "$operand_count" -le 1 ] && [ "$fast_forward_only" -eq 1 ]
}

# rebase_names_branch: 0 when the `git rebase` segment names the branch to
# rebase (`<upstream> <branch>`, or `--root <branch>`). Git checks that branch
# out first, so HEAD read before the segment says nothing about which branch
# moves or what a later segment runs on.
rebase_names_branch() {
  rebase_branch_operands
  [ "${#rebase_branch_words[@]}" -gt 0 ]
}

# reset_names_commit: 0 when the `git reset` segment carries an operand before
# any `--` other than HEAD or @, so it may move HEAD onto another commit.
reset_names_commit() {
  local argument
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    case "$argument" in
      --) return 1 ;;
      -*) ;;
      HEAD | @) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# checkout_names_pathspec: 0 when the `git checkout` segment carries a pathspec:
# a `--` separator, or more operands than a branch switch takes (one, or two
# with -b, -B or --orphan, whose second is the start point). Such a checkout
# writes paths from a tree-ish or the index, which an edit prompt would guard.
checkout_names_pathspec() {
  local argument operand_count=0 allowed=1
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    case "$argument" in
      --) return 0 ;;
      --orphan | --orphan=*) allowed=2 ;;
      --*) ;;
      -*[bB]*) allowed=2 ;;
      -*) ;;
      *) operand_count=$((operand_count + 1)) ;;
    esac
  done
  [ "$operand_count" -gt "$allowed" ]
}

# main_branch_rule_matches: 0 when the segment must not be approved on a branch
# question: a commit-creating subcommand from main or master (or from a branch
# an earlier checkout, switch, symbolic-ref or settings-rule segment of this
# command may have changed, since HEAD is read once before any segment runs), a push whose
# refspec names main as source or destination, a hard reset that moves HEAD, or
# a fetch or pull refspec or --refmap, whose destination can force-move local
# main, or, from main, a reset or a pull naming a branch, which moves it onto
# another commit, or, from any branch, a rebase naming the branch to rebase.
# block-main-destructive-git.sh denies some of these itself; reading them here
# keeps this file from ever returning an allow beside its deny.
main_branch_rule_matches() {
  local branch argument
  [ "$git_subcommand" = rebase ] && rebase_names_branch && return 0
  case "$git_subcommand" in
    commit | push | merge | cherry-pick | revert | rebase | pull | reset) # subset of .claude/hooks/lib/subagent-git-policy.sh#GAIA_SUBAGENT_DENIED_GIT_SUBCOMMANDS
      if [ "$git_subcommand" = reset ] && ! reset_names_commit; then
        :
      elif [ "$git_subcommand" != pull ] || ! pull_fast_forwards_only; then
        [ "$branch_may_have_changed" -eq 1 ] && return 0
        branch=$(git -C "$segment_run_directory" symbolic-ref --short HEAD 2>/dev/null) || branch=""
        case "$branch" in main | master) return 0 ;; esac
      fi
      ;;
  esac
  case "$git_subcommand" in
    fetch | pull)
      for argument in ${git_args[@]+"${git_args[@]}"}; do
        _history_option_is "$argument" --refmap && return 0
        case "$argument" in -*) ;; *:*) return 0 ;; esac
      done
      return 1 ;;
    push) push_refspec_names_main || push_refspec_targets_main ;;
    reset) reset_hard_moves_head "$segment_run_directory" 0 ;;
    *) return 1 ;;
  esac
}

# option_matches <argument> <spec>: 0 when one operand matches one fall-through
# spec from lib/git-allow-list.sh.
option_matches() {
  local argument="$1" spec="$2" value
  case "$spec" in
    --*=*)
      case "$argument" in --*=*) ;; *) return 1 ;; esac
      _history_option_is "$argument" "${spec%%=*}" || return 1
      value="${argument#*=}"
      case "$value" in "${spec#*=}"*) return 0 ;; esac
      return 1 ;;
    --*) _history_option_is "$argument" "$spec"; return ;;
    -?)
      case "$argument" in
        --*) return 1 ;;
        -*"${spec#-}"*) return 0 ;;
      esac
      return 1 ;;
  esac
  return 1
}

# config_is_read_only: 0 when the `git config` operands write nothing.
config_is_read_only() {
  local argument lowered operand_count=0 skip_next=0 read_flag=0
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    lowered=$(printf '%s' "$argument" | tr '[:upper:]' '[:lower:]')
    case "$lowered" in
      --*=*) ;;
      --*) if _history_option_is "$lowered" --comment; then skip_next=1; continue; fi ;;
    esac
    if _history_option_is "$lowered" --unset --unset-all --add --replace-all \
         --rename-section --remove-section --edit || [ "$lowered" = -e ]; then
      return 1
    fi
    if _history_option_is "$lowered" --get --get-all --get-regexp --get-urlmatch --list \
         || [ "$lowered" = -l ]; then
      read_flag=1; continue
    fi
    case "$lowered" in
      --file | -f | --blob | --default | --type) skip_next=1; continue ;;
      -*) continue ;;
    esac
    operand_count=$((operand_count + 1))
    if [ "$operand_count" -eq 1 ]; then
      case "$lowered" in
        get | list) read_flag=1; continue ;;
        set | unset | rename-section | remove-section | edit) return 1 ;;
      esac
    fi
  done
  [ "$read_flag" -eq 1 ] && return 0
  [ "$operand_count" -le 1 ]
}

# remote_is_read_only: 0 for `git remote` with no operand, `get-url` or `show`,
# each optionally after `-v`. Any other word is a write subcommand.
remote_is_read_only() {
  local argument
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    case "$argument" in
      -v | --verbose) continue ;;
      get-url | show) return 0 ;;
    esac
    return 1
  done
  return 0
}

# subcommand_is_approved: 0 when the segment's subcommand is on the allow list
# and no operand matches one of its fall-through specs.
subcommand_is_approved() {
  local entry name spec argument
  local -a specs
  for entry in ${GAIA_GIT_ALLOWED_SUBCOMMANDS[@]+"${GAIA_GIT_ALLOWED_SUBCOMMANDS[@]}"}; do
    name="${entry%% *}"
    [ "$name" = "$git_subcommand" ] || continue
    read -r -a specs <<<"${entry#"$name"}"
    for spec in ${specs[@]+"${specs[@]}"}; do
      case "$spec" in
        @no-pathspec)
          checkout_names_pathspec && return 1
          continue ;;
        @read-only)
          case "$git_subcommand" in
            config) config_is_read_only || return 1 ;;
            remote) remote_is_read_only || return 1 ;;
            *) return 1 ;;
          esac
          continue ;;
      esac
      for argument in ${git_args[@]+"${git_args[@]}"}; do
        [ "$argument" = -- ] && break
        option_matches "$argument" "$spec" && return 1
      done
    done
    return 0
  done
  return 1
}

# commit_reads_stdin: 0 when the segment is a `git commit` whose message is
# `-F -` or `--file -`, the only reader a heredoc may feed.
commit_reads_stdin() {
  local argument previous=""
  [ "$git_subcommand" = commit ] || return 1
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    [ "$argument" = -- ] && return 1
    case "$previous|$argument" in
      '-F|-' | '--file|-' | '|-F-' | '|--file=-') return 0 ;;
    esac
    case "$argument" in -F | --file) previous="$argument" ;; *) previous="" ;; esac
  done
  return 1
}

split_command_segments "$command" || exit 0
approved=0
branch_may_have_changed=0
for segment_index in "${!segments[@]}"; do
  segment="${segments[$segment_index]}"
  segment="${segment#"${segment%%[![:space:]]*}"}"
  [ -n "$segment" ] || continue
  case "$segment" in
    git | git[[:space:]]*) ;;
    *)
      [ "${segment_heredocs[$segment_index]}" = 0 ] && non_git_segment_is_approved "$segment" || exit 0
      [ "$segment_runs_program" -eq 0 ] || branch_may_have_changed=1
      continue ;;
  esac
  # `$?` reads as text to the git word parser, so a git segment carrying it falls through.
  case "$segment" in *'$?'*) exit 0 ;; esac
  parse_git_globals "$segment"
  [ -n "$git_subcommand" ] || exit 0
  if [ "${segment_heredocs[$segment_index]}" = 1 ]; then commit_reads_stdin || exit 0; fi
  globals_are_approved || exit 0
  directory_is_approved || exit 0
  subcommand_is_approved || exit 0
  history_rule_reason
  [ -z "$history_reason" ] || exit 0
  command_config_rule_reason
  [ -z "$history_reason" ] || exit 0
  main_branch_rule_matches && exit 0
  case "$git_subcommand" in checkout | switch | symbolic-ref) branch_may_have_changed=1 ;; esac
  approved=1
done
[ "$approved" -eq 1 ] || exit 0

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "classify-git-command.sh: every git segment is a listed git command in this repository and every other segment approved"
  }
}'
exit 0
