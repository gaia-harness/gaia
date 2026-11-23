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
#   - its structure is a list of simple commands joined by `&&`, `||`, `;` or a
#     newline, with no pipe, no background `&`, no redirect other than one that
#     discards or duplicates a stream (`2>&1`, `2>/dev/null`), no substitution,
#     no expansion (`$`, a backtick, a glob, a brace list), no subshell, no
#     backslash and no comment outside single quotes;
#   - every segment begins with the bare word `git`: an env prefix, a wrapper,
#     a path to git, or any other program falls through;
#   - its global options are only `-C <directory>` (once), `-c <key>=<value>`
#     for a key on the safe list in lib/git-command-config.sh, `--no-pager`,
#     `-P` and `--no-optional-locks`;
#   - the directory git runs in, the payload cwd or the `-C` value read against
#     it, belongs to this repository (the main checkout or a linked worktree).
#     A git call in another repository runs that repository's config and hooks,
#     which nothing here has read;
#   - the subcommand is on the list in lib/git-allow-list.sh and carries none of
#     its fall-through options;
#   - no deny rule the destructive-git guard owns matches the segment. Its
#     command-config rule needs no call here: only safe `-c` keys pass the
#     globals check, `--config-env` never does, and `git config` passes only in
#     its read forms.
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

# shellcheck source=lib/main-git-guard-parse.sh
. "$library_directory/main-git-guard-parse.sh" 2>/dev/null || exit 0
# shellcheck source=lib/main-git-guard-history.sh
. "$library_directory/main-git-guard-history.sh" 2>/dev/null || exit 0
# shellcheck source=lib/git-command-config.sh
. "$library_directory/git-command-config.sh" 2>/dev/null || exit 0
# shellcheck source=lib/git-allow-list.sh
. "$library_directory/git-allow-list.sh" 2>/dev/null || exit 0
# shellcheck source=/dev/null
. "$hook_root/.gaia/scripts/main-root-lib.sh" 2>/dev/null || exit 0
for required_function in parse_git_globals history_rule_reason \
    _history_option_is push_refspec_names_main push_refspec_targets_main reset_hard_moves_head \
    gaia_resolve_common_directory; do
  type "$required_function" >/dev/null 2>&1 || exit 0
done
[ "${#GAIA_GIT_ALLOWED_SUBCOMMANDS[@]}" -gt 0 ] && [ "${#GAIA_GIT_SAFE_CONFIG_KEYS[@]}" -gt 0 ] || exit 0

# split_command_segments <text>: put each simple command of <text> in the array
# `segments`, or return 1 when the text carries anything but simple commands
# joined by a list operator. A character walk rather than a pattern, because a
# separator or an expansion inside single quotes is text and outside them is
# shell, and a commit subject routinely carries `;`, `(` or `&` in quotes.
#
# Inside double quotes `$` and a backtick still expand, so they fall through
# there too. A backslash falls through wherever the shell reads it, because the
# word parser and the shell disagree on what it escapes inside double quotes.
# A brace list (`{a,b}`, `{1..3}`) expands to several words the parser reads as
# one, so an unquoted `{` whose span to the next `}` holds `,` or `..` falls
# through; `@{u}` and `HEAD^{tree}` hold neither and do not expand.
split_command_segments() {
  local text="$1" length index=0 copy_from=0 character next quote="" segment="" lookahead token span
  length=${#text}
  segments=()
  while [ "$index" -lt "$length" ]; do
    character="${text:$index:1}"
    if [ "$quote" = "'" ]; then
      [ "$character" = "'" ] && quote=""
      index=$((index + 1)); continue
    fi
    case "$character" in
      '$' | '`' | \\) return 1 ;;
    esac
    if [ "$quote" = '"' ]; then
      [ "$character" = '"' ] && quote=""
      index=$((index + 1)); continue
    fi
    # A stream redirect that writes no file, standing as its own word, is
    # dropped from the segment so the word parser never reads it as an operand.
    case "$character" in
      1 | 2 | '>' | '&')
        if [ "$index" -eq "$copy_from" ] || [[ "${text:$((index - 1)):1}" == [[:space:]] ]]; then
          lookahead="${text:$index:12}"
          for token in '2>&1' '2>/dev/null' '>/dev/null' '1>/dev/null' '&>/dev/null'; do
            case "$lookahead" in
              "$token" | "$token"[[:space:]\;]* | "$token&&"* | "$token||"*)
                segment="$segment${text:$copy_from:$((index - copy_from))} "
                index=$((index + ${#token}))
                copy_from=$index
                continue 2 ;;
            esac
          done
        fi
        ;;
    esac
    next="${text:$((index + 1)):1}"
    case "$character" in
      "'" | '"') quote="$character" ;;
      ';' | $'\n')
        segments+=("$segment${text:$copy_from:$((index - copy_from))}")
        segment=""; index=$((index + 1)); copy_from=$index; continue ;;
      '&' | '|')
        [ "$next" = "$character" ] || return 1
        segments+=("$segment${text:$copy_from:$((index - copy_from))}")
        segment=""; index=$((index + 2)); copy_from=$index; continue ;;
      '<' | '>' | '(' | ')' | '*' | '?' | '[' | '#') return 1 ;;
      '{')
        span="${text:$((index + 1))}"
        case "$span" in
          *'}'*)
            span="${span%%\}*}"
            case "$span" in *,* | *..*) return 1 ;; esac
            ;;
        esac
        ;;
    esac
    index=$((index + 1))
  done
  [ -z "$quote" ] || return 1
  segments+=("$segment${text:$copy_from:$((index - copy_from))}")
  return 0
}

# in_this_repository <directory>: 0 when git run in <directory> discovers the
# repository this hook belongs to, through any of its checkouts.
in_this_repository() {
  local own given
  own=$(gaia_resolve_common_directory "$hook_root" 2>/dev/null) || return 1
  given=$(gaia_resolve_common_directory "$1" 2>/dev/null) || return 1
  [ -n "$own" ] && [ "$own" = "$given" ]
}

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

# main_branch_rule_matches: 0 when block-main-destructive-git.sh's main-branch
# rules would deny the segment: a commit or push from main or master, a push
# whose refspec names main as source or destination, or a hard reset that moves
# HEAD. That hook denies these itself; reading them here keeps this file from
# ever returning an allow beside its deny.
main_branch_rule_matches() {
  local branch
  case "$git_subcommand" in
    commit | push)
      branch=$(git -C "$segment_run_directory" symbolic-ref --short HEAD 2>/dev/null) || branch=""
      case "$branch" in main | master) return 0 ;; esac
      ;;
  esac
  case "$git_subcommand" in
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

# remote_is_read_only: 0 for `git remote` with no operand, `-v`, `get-url` or
# `show`.
remote_is_read_only() {
  case "${git_args[0]:-}" in
    '' | -v | --verbose | get-url | show) return 0 ;;
  esac
  return 1
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

split_command_segments "$command" || exit 0
approved=0
for segment in ${segments[@]+"${segments[@]}"}; do
  segment="${segment#"${segment%%[![:space:]]*}"}"
  [ -n "$segment" ] || continue
  case "$segment" in git | git[[:space:]]*) ;; *) exit 0 ;; esac
  parse_git_globals "$segment"
  [ -n "$git_subcommand" ] || exit 0
  globals_are_approved || exit 0
  directory_is_approved || exit 0
  subcommand_is_approved || exit 0
  history_rule_reason
  [ -z "$history_reason" ] || exit 0
  main_branch_rule_matches && exit 0
  approved=1
done
[ "$approved" -eq 1 ] || exit 0

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "classify-git-command.sh: every segment is a listed git command in this repository"
  }
}'
exit 0
