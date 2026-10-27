#!/usr/bin/env bash
# The main-branch destructive-git guard's denial, branch reads, and git word
# parser. Sourced only by block-main-destructive-git.sh, which owns the walk
# that calls these and reads the globals they set; defines functions and does
# no other work at source time.

# shellcheck disable=SC2154,SC2034  # main_root comes from, and the parse globals go to, block-main-destructive-git.sh

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

current_branch() {
  local cwd="$1"
  if [[ -n "$cwd" ]]; then
    git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || echo ""
  else
    git symbolic-ref --short HEAD 2>/dev/null || echo ""
  fi
}

# resolve_directory_kind <directory>: classify a directory WORD the command scan produced,
# and print the classification. One of:
#
#   same <directory>      the word names THIS repository
#   foreign <directory>   the word names a readable directory inside ANOTHER
#                   repository
#   unknown         the word names no readable repository at all: it carries a
#                   variable or a substitution the scan cannot expand, it
#                   points nowhere, or there is no resolver to ask
#
# Both readable answers carry <directory> in its tilde-expanded form, which is what a
# caller reads a branch out of. A caller that read the raw word instead would
# resolve a tilde path here and then read a branch out of the literal `~`
# spelling, which answers nothing and allows.
#
# Always succeeds, so a caller assigning its output under errexit is not
# abandoned by a directory that does not resolve.
#
# Three answers rather than two, because the two non-`same` cases are
# different questions and only one of them is unanswerable. `unknown` is what
# this guard fails closed on: the checkout the segment acts in is genuinely
# undecided, so the hook's rules test every candidate it could be. `foreign` is
# decided, the word expanded and simply named another repository, and
# collapsing it into `unknown` denied a sibling-repository commit against THIS
# checkout's branch whenever a home command shared the tool call, since the
# hook's foreign stand-down is a WHOLE-CALL verdict and answers home there.
# What each caller then does with a `foreign` word is what it did before the
# ambiguity arm existed; the classification is the only thing restored here.
resolve_directory_kind() {
  local directory="$1" given_common_directory own_common_directory
  [ -n "$directory" ] || { printf 'unknown'; return 0; }
  # The tilde arrives as a literal character, never expanded, because it reached
  # this hook as text inside the tool call rather than through a shell. SC2088
  # fires on the quoted tilde, but these are case PATTERNS matching that literal
  # character, not an expansion attempt.
  # shellcheck disable=SC2088
  case "$directory" in
    '~') directory="$HOME" ;;
    '~/'*) directory="$HOME/${directory:2}" ;;
  esac
  command -v gaia_resolve_common_directory >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  given_common_directory=$(gaia_resolve_common_directory "$directory" 2>/dev/null) || { printf 'unknown'; return 0; }
  [ -n "$given_common_directory" ] || { printf 'unknown'; return 0; }
  own_common_directory=$(gaia_resolve_common_directory 2>/dev/null) || { printf 'unknown'; return 0; }
  if [ -n "$own_common_directory" ] && [ "$given_common_directory" = "$own_common_directory" ]; then
    printf 'same %s' "$directory"
  else
    printf 'foreign %s' "$directory"
  fi
  return 0
}

# ambiguous_main_branch: print main or master when a checkout the acting
# segment could be standing in, but which a directory word left unresolved,
# is on one of them; print nothing otherwise. Always succeeds, so a caller
# assigning its output under errexit is never abandoned.
#
# Two candidates. This hook's own working directory is where the shell stands
# when no `cd` moved it, or when one moved it back. The main checkout is where
# an unreadable word most often points FROM a linked worktree, which is the
# ordinary session shape here: neither the tracked directory nor this hook's
# own is that checkout from inside a worktree, so without it every
# `cd "$SOMEWHERE" && git commit` spelled there reads a branch that is not the
# one the commit lands on, which is the whole failure this flag exists for.
#
# The segment's own directory is not retested here: the caller tests it, and
# whenever this function is consulted it holds the same value the tracked `cd`
# does, so a third probe would spend a subprocess to ask a settled question.
ambiguous_main_branch() {
  local candidate_branch
  candidate_branch=$(current_branch "")
  if [ "$candidate_branch" = main ] || [ "$candidate_branch" = master ]; then
    printf '%s' "$candidate_branch"
    return 0
  fi
  candidate_branch=$(current_branch "$main_root")
  if [ "$candidate_branch" = main ] || [ "$candidate_branch" = master ]; then
    printf '%s' "$candidate_branch"
  fi
  return 0
}

# command_has_unquoted_group <string>: 0 when the command carries a `(` or `)`
# outside quotes.
#
# A `cd` inside a subshell moves nothing once the group closes, and the hook's segment
# walk splits on those characters without recording which one it split at,
# so a tracked `cd` cannot be scoped to the group it belongs to. Tracking stands
# down for the whole command instead, leaving every segment read against this
# hook's own working directory.
#
# Quoting is modelled rather than pattern-matched because the distinction is
# load-bearing: a parenthesis inside a quoted value is ordinary text, and a
# commit subject routinely carries one, so a test that merely looked for the
# character would stand tracking down on an ordinary commit and deny it.
#
# What the stand-down reaches beyond a real subshell is an ordinary unquoted
# command substitution, which carries the same characters: a `cd` into a linked
# worktree followed by a push whose refspec comes from one is read against this
# hook's own working directory rather than the worktree's, and denied. That is a
# false deny rather than a miss, and the escape is running the command with the
# `!` prefix.
#
# The leading `case` is a fast path for the ordinary command that carries no
# parenthesis at all, which keeps the character walk off every invocation.
command_has_unquoted_group() {
  local text="$1" BLOCK=256 base=0 text_length block block_length k character quote_character="" escape_pending=0
  case "$text" in
    *'('* | *')'*) ;;
    *) return 1 ;;
  esac
  text_length=${#text}
  while [ "$base" -lt "$text_length" ]; do
    block="${text:$base:$BLOCK}"
    base=$((base + BLOCK))
    k=0
    block_length=${#block}
    while [ "$k" -lt "$block_length" ]; do
      character="${block:$k:1}"
      k=$((k + 1))
      if [ "$escape_pending" = 1 ]; then escape_pending=0; continue; fi
      if [ "$character" = "\\" ] && [ "$quote_character" != "'" ]; then escape_pending=1; continue; fi
      if [ -n "$quote_character" ]; then
        [ "$character" = "$quote_character" ] && quote_character=""
        continue
      fi
      case "$character" in
        '"' | "'") quote_character="$character" ;;
        '(' | ')') return 0 ;;
      esac
    done
  done
  return 1
}

# split_git_words <string>: split one segment into shell-like words in the
# array `words`, modelling quoting the way the shell does -- a quote opens a span in
# which whitespace is ordinary text, and a backslash escapes the character after
# it -- and handing the words back unquoted.
#
# `read -ra` splits on whitespace alone, so a quoted global-option value
# carrying whitespace arrived as fragments and the fragment after the space
# landed in the slot the subcommand is read from, leaving every rule armed on
# git_subcommand reading a subcommand that was never spelled.
#
# A word accumulates into `chunk` and reaches `word` once per block rather than
# once per character, and the walk indexes inside a block rather than into the
# whole string. `word="$word$character"` costs O(word) and a quoted span has no length
# bound, so a multi-kilobyte commit message made the naive walk quadratic: a
# synchronous stall on a blocking hook, at a size an ordinary `-m` body reaches.
split_git_words() {
  local text="$1" NEWLINE=$'\n' TAB=$'\t'
  local BLOCK=256 base=0 text_length block block_length k character
  local quote_character="" escape_pending=0 word="" chunk="" have=0
  words=()
  text_length=${#text}
  while [ "$base" -lt "$text_length" ]; do
    block="${text:$base:$BLOCK}"
    base=$((base + BLOCK))
    k=0
    block_length=${#block}
    while [ "$k" -lt "$block_length" ]; do
      character="${block:$k:1}"
      k=$((k + 1))
      if [ "$escape_pending" = 1 ]; then escape_pending=0; chunk="$chunk$character"; have=1; continue; fi
      # A backslash is literal inside single quotes, as in the shell itself.
      if [ "$character" = "\\" ] && [ "$quote_character" != "'" ]; then escape_pending=1; continue; fi
      if [ -n "$quote_character" ]; then
        if [ "$character" = "$quote_character" ]; then quote_character=""; else chunk="$chunk$character"; fi
        have=1
        continue
      fi
      case "$character" in
        '"' | "'") quote_character="$character"; have=1 ;;
        ' ' | "$TAB" | "$NEWLINE")
          [ "$have" = 1 ] && words+=("$word$chunk")
          word=""; chunk=""; have=0 ;;
        *) chunk="$chunk$character"; have=1 ;;
      esac
    done
    word="$word$chunk"
    chunk=""
  done
  [ "$have" = 1 ] && words+=("$word$chunk")
  return 0
}

# parse_git_globals <segment>: split one segment's git invocation at its
# subcommand. Only a `-C` between `git` and the subcommand word is git's own
# directory option. Past the subcommand it belongs to the subcommand
# (`git switch -C <branch>`, `git commit -C <commit>`) and names no directory,
# and reading it as one aimed every check at a directory named for a branch or
# a commit, so both of those passed. Sets git_cwd (the last global `-C` path, so
# `git -C <a> -C <b> commit` cannot slip past the commit and push rules on the
# first one), normalized_segment (the segment minus its global `-C` pairs, for the commit and
# push regexes), git_subcommand (the subcommand word), and git_args (the words after
# it).
#
# Honest limits, and they bind every rule the hook arms on git_subcommand rather than any
# one of them. These spellings reach the subcommand slot carrying something
# other than the subcommand, so the guard reads no subcommand and allows:
#
#   - a value-taking global option absent from the table below, whose value is a
#     bare word. The table mirrors the options git itself takes a separated
#     value for, and one missing from it hands its own value to the slot.
#   - a separator, a quote, or a value produced by an expansion (`$VAR`,
#     `$(...)`, a backtick, `~`), which is ordinary word text to a scan that
#     models quoting but does not expand.
#   - a quoted value carrying one of the `| & ; ( )` characters the hook's segment
#     walk cuts on, since that cut happens before this parser sees the segment.
#
# Closing any of them needs the shell's own evaluation of the command, which a
# PreToolUse hook reading `tool_input.command` as text does not have.
parse_git_globals() {
  local -a words kept
  local i=0 word_count current_word globals=0
  git_cwd="" git_subcommand=""
  git_args=()
  split_git_words "$1"
  word_count=${#words[@]}
  while [ "$i" -lt "$word_count" ]; do
    current_word="${words[$i]}"
    if [ "$globals" -eq 1 ]; then
      case "$current_word" in
        -C) git_cwd="${words[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
        # Every global git takes a SEPARATED value for. An option missing here
        # falls to the `-*` arm and its value reaches the catch-all that assigns
        # the subcommand, which is the disarm, so this table tracking git's own
        # is what keeps the arming honest. The `=`-joined spellings need no
        # entry: they are one word, so the subcommand still lands next.
        # `--exec-path` is deliberately absent: without `=` it takes no value,
        # git prints its exec path and exits, and nothing after it runs.
        -c | --git-dir | --work-tree | --namespace | --config-env | --attr-source)
          kept+=("$current_word" "${words[$((i + 1))]:-}"); i=$((i + 2)); continue ;;
        -*) ;;
        *) globals=2; git_subcommand="$current_word"; git_args=("${words[@]:$((i + 1))}") ;;
      esac
    elif [ "$globals" -eq 0 ] && [ "$current_word" = git ]; then
      globals=1
    fi
    kept+=("$current_word")
    i=$((i + 1))
  done
  normalized_segment=""
  [ "${#kept[@]}" -eq 0 ] || normalized_segment="${kept[*]}"
}

# push_refspec_names_main: 0 when the words after a `push` subcommand carry a
# refspec whose SOURCE is main, master, or HEAD. It reads the operands rather
# than a fixed position: the ref was pinned to the word after the remote, so an
# option written ahead of the remote shifted both and the push was allowed.
# The hook's rule 2 still caught the shape when a force flag
# was present, which is what left the plain push as the hole.
#
# The first operand is the remote and every operand after it is a refspec, so a
# push naming several is read whole rather than at its first one. A `--` ends
# git's option parsing and is not itself an operand. A leading `+` on a refspec
# is the force marker and is not part of the ref name.
#
# Honest limits. An option absent from the value-taking table below leaves its
# value read as an operand, which shifts the remote and every refspec after it;
# where that value happens to spell a branch the result is a false deny rather
# than a false allow, which is the safe direction for a guard whose escape is
# running the command with the `!` prefix. A refspec naming main only as its
# DESTINATION (`feature:main`) is not read here: that is the reading this rule
# has always had, and narrowing or widening it is a separate question from where
# the ref sits.
push_refspec_names_main() {
  local argument seen_remote=0 skip_next=0 refspec
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
    case "$refspec" in
      HEAD | main | master) return 0 ;;
      HEAD:* | main:* | master:*) return 0 ;;
    esac
  done
  return 1
}

# reset_hard_moves_head <directory> <ambiguous>: 0 when the segment
# parse_git_globals just read is a `git reset --hard` whose target is a commit
# other than the one HEAD holds in <directory>. The target is resolved rather
# than matched as text, because every spelling of an earlier commit (`HEAD~1`,
# `HEAD^`, `@~1`, a SHA, a branch) drops the same commits, and a text match
# denies one spelling and passes the rest.
#
# No target, or a literal `HEAD` or `@`, discards only uncommitted changes and
# passes. A target that resolves nowhere denies: git would refuse it anyway, so
# that is the safe direction. With <ambiguous> set the checkout the reset runs
# in is unknown, so no comparison with its HEAD can be trusted and only the
# literal spellings pass.
#
# Honest limits: `--keep`, `--merge`, `--soft` and the default `--mixed` also
# move HEAD, but they keep uncommitted work and are not read here; neither is a
# target produced by an expansion, which reaches this function as text naming
# no commit and therefore denies.
reset_hard_moves_head() {
  local directory="$1" ambiguous="$2" argument hard=0 target="" skip_next=0 target_commit head_commit
  local -a in_directory=()
  [ -n "$directory" ] && in_directory=(-C "$directory")
  for argument in ${git_args[@]+"${git_args[@]}"}; do
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$argument" in
      --hard) hard=1; continue ;;
      --) break ;;
      *'>' | *'<') skip_next=1; continue ;;
      *[\<\>]*) continue ;;
      -*) continue ;;
    esac
    [ -n "$target" ] || target="$argument"
  done
  [ "$hard" -eq 1 ] || return 1
  case "$target" in '' | HEAD | @) return 1 ;; esac
  [ "$ambiguous" -eq 1 ] && return 0
  target_commit=$(git ${in_directory[@]+"${in_directory[@]}"} rev-parse --verify -q "${target}^{commit}" 2>/dev/null) || return 0
  head_commit=$(git ${in_directory[@]+"${in_directory[@]}"} rev-parse --verify -q HEAD 2>/dev/null) || return 0
  [ "$target_commit" != "$head_commit" ]
}
