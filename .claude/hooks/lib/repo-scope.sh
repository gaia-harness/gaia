#!/usr/bin/env bash
# Shared helper: decide whether a Bash command acts on a DIFFERENT git repo
# than the one these hooks are installed in (the "home repo").
#
# Template-distributed and portable: the home repo is whatever repo the
# session's working directory sits in, never a hardcoded slug. Adopters get the
# same cross-repo isolation for free: a guard installed in project A never
# fires on a `git`/`gh` command aimed at a sibling project B.
#
# A repository is not a directory. Every linked worktree of the home repo, and
# a checkout whose directory is not named for the repository, is still the
# home repo, so neither a toplevel nor a directory name can stand in for its
# identity: a linked worktree's toplevel is its own directory, and both
# comparisons read `--repo <home>` or `git -C <main-checkout>` as foreign.
#
# Usage (from a PreToolUse Bash hook, after extracting $command):
#   _library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _library_directory=''
#   [ -n "$_library_directory" ] && [ -f "$_library_directory/repo-scope.sh" ] && . "$_library_directory/repo-scope.sh"
#   if type command_targets_foreign_repo >/dev/null 2>&1 \
#      && command_targets_foreign_repo "$command"; then exit 0; fi   # foreign: allow
#
# Fail-closed: returns 0 (true, "foreign") ONLY when it can POSITIVELY resolve
# a target in a different repository (or an explicit `gh -R/--repo
# owner/repo` whose repo name is none of the home repo's) for at least one
# command in the tool call and no command in it acts on this one. Any ambiguity,
# parse failure, an identity it cannot resolve, OR a deliberately
# under-specified form it cannot model exactly (e.g. multiple `git -C` flags,
# where git's last-wins semantics defeat a single capture) returns 1 so the
# caller still enforces.
#
# Honest limits: a command is recognised as git or gh by its literal name, as
# the consumers' own arming matches are. A name the shell assembles by
# expansion (`g$'i't`, a glob such as `/usr/bin/gi?`) is not read as either
# program, so after a foreign command it can read foreign. The word scan
# models neither heredocs nor ANSI-C quoting; the quote desync either can cause
# is caught only where the commands it hides name git or gh.

# shellcheck disable=SC2034  # the guard's walk state is read by repo-scope-segment.sh

# The repository name a git remote URL or a gh [HOST/]OWNER/REPO value ends
# in, lowercased because GitHub resolves names case-insensitively, with a
# trailing `/` and `.git` dropped. The last `/` or `:` segment covers every
# remote spelling git accepts: `https://host/owner/repo.git`,
# `git@host:owner/repo.git`, `ssh://host:22/owner/repo`, a local path.
_gaia_repo_scope_repo_name() {
  local repository_name
  repository_name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  repository_name="${repository_name%/}"
  repository_name="${repository_name%.git}"
  printf '%s' "${repository_name##*[/:]}"
}

# The shared main-checkout resolver, loaded from this library's own on-disk
# location (never cwd: a hook suite runs from a sandbox with no .gaia/).
# Errexit is suspended across the load and restored to what it was, for the
# reason .claude/hooks/lib/verb-arming.sh gives at its own repo-scope load: a
# parse error abandons the shell from a condition context too, and in the
# errexit consumers that exit is the deny code.
_gaia_repo_scope_load_main_root() {
  local root errexit_was
  type gaia_resolve_common_directory >/dev/null 2>&1 && return 0
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)" || return 1
  [ -f "$root/.gaia/scripts/main-root-lib.sh" ] || return 1
  errexit_was=0
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  # shellcheck source=/dev/null
  . "$root/.gaia/scripts/main-root-lib.sh" 2>/dev/null
  if [ "$errexit_was" = 1 ]; then set -e; fi
  type gaia_resolve_common_directory >/dev/null 2>&1
}

# Set by command_targets_foreign_repo to the directory a `cd` earlier in the tool
# call moves the deciding command into, once that directory resolves as this
# repository, and empty otherwise. A home verdict on a `cd` into a linked
# worktree means "this repository" but not "this checkout", so a caller that
# reads per-checkout state (the branch) reads it there rather than from its own
# working directory.
#
# Honest limit: a command's own `git -C` or `gh -R` decides where that command
# acts, so neither publishes, and a caller reads its own directory for that
# spelling. That is the pre-existing reading for it, never a looser one.
GAIA_REPO_SCOPE_LEAD_CD=""

# A word naming git or gh as a program, wherever it sits in the word: `git`,
# `/usr/bin/git`, `(gh`, `$(git`, a `bash -c` script holding either. `.` and
# word characters are not boundaries, so `.gitignore`, `github` and `repo.git`
# do not match.
_GAIA_REPO_SCOPE_TOOL_REGEX='(^|[^[:alnum:]_.])(git|gh)([^[:alnum:]_.]|$)'

# A word that can move a command off the directory the hook runs in: a
# directory change, git's `-C`, or gh's repository flag. A call holding none of
# them has no command that can be foreign.
_GAIA_REPO_SCOPE_MOVE_REGEX='(^|[^[:alnum:]_.])(cd|pushd|popd|-C|-R|--repo)([^[:alnum:]_.]|$)'

# The tool pattern above, read against the raw text of the rest of a call
# rather than a scanned word. The scan drops quote characters, backslashes, and
# line continuations, so any of them may sit inside or around a name the scan
# hands back (`g\it`, `"gh"`); each is also a boundary character. So a stretch
# of raw text this does not match yields no word the tool pattern matches.
_GAIA_REPO_SCOPE_DROPPED="[\""$'\047'"\\"$'\n'"]*"
_GAIA_REPO_SCOPE_TOOL_RAW_REGEX='(^|[^[:alnum:]_.])g'"$_GAIA_REPO_SCOPE_DROPPED"'(h|i'"$_GAIA_REPO_SCOPE_DROPPED"'t)([^[:alnum:]_.]|$)'

# Sets the caller's `flat` to `$1` with every quote character, backslash, and
# line continuation removed. The scan's words are that text split at
# whitespace and separators, less what quoting keeps literal, so a pattern
# absent from `flat` is absent from every word the scan hands back.
_gaia_repo_scope_flatten() {
  local backslash=\\ newline=$'\n' single_quote=$'\047'
  flat="${1//"$backslash$newline"/}"
  flat="${flat//[\"$single_quote\\]/}"
}

# The verdict covers the whole tool call, and it is HOME when ANY command in
# the call acts on the home repository: foreign only when every command is
# foreign-acting or touches no repository at all. Judging the call by one
# command let a foreign first `gh` exempt a home commit after it, a trailing
# `git -C <sibling>` exempt a home commit before it, and a leading `cd
# <sibling>` exempt a commit made after `cd -`. The rule
# "nothing may follow a foreign command" was rejected because it enforces on a
# sibling merge followed only by sibling commands or by `echo`.
#
# The accepted cost: a foreign command sharing its call with a home one, even a
# read-only `git status`, is enforced as home. Running the foreign command as
# its own tool call is the sidestep.
command_targets_foreign_repo() {
  local _previous_lc_all _had_lc_all exit_status=1

  GAIA_REPO_SCOPE_LEAD_CD=""
  git rev-parse --show-toplevel >/dev/null 2>&1 || return 1

  # The scan reports byte offsets, and the walk slices the command at them, so
  # both have to count bytes rather than characters.
  _previous_lc_all="${LC_ALL-}"
  _had_lc_all="${LC_ALL+set}"
  LC_ALL=C
  if _gaia_repo_scope_verdict "$1"; then exit_status=0; fi
  if [ "$_had_lc_all" = set ]; then LC_ALL="$_previous_lc_all"; else unset LC_ALL; fi
  return "$exit_status"
}

# Walks every command in the tool call with the first-command scan, carrying the
# directory each `cd` moves the rest of the call into. Returns 0 (foreign) only
# when at least one command is foreign and none is home.
#
# A `cd` moves that directory only where the shell is certain to run it in the
# calling shell and every later command is certain to run after it. The scan
# splits at newlines, `&` and `|` without modelling what groups them, so a `cd`
# inside a subshell, a `$( )`, a function body, a heredoc body, a loop or an
# `if` would otherwise move it for
# commands the shell runs in the original directory, and read a home command
# after it as foreign. So once any command opens one of those constructs the
# walk goes opaque and every later `cd` makes the directory unknown, which is
# home. A `cd` beside `|` or `&` is only skipped (its directory is unknown)
# without going opaque, so a later absolute `cd` knows the directory again. A
# `cd` reached through `&&` runs only if everything before it
# succeeded, so its move ends with its and-or list, and a `||` after a move
# makes the directory unknown.
_gaia_repo_scope_verdict() {
  local command_text="$1"
  local NEWLINE=$'\n'
  local position=0 command_length=${#command_text} rest foreign=0 kind closing_character following_character walked=0 tool_end
  # Read by the walk's helpers through bash's dynamic scope.
  local directory="" directory_known=1 remotes="" remotes_read=0 home_common="" home_common_read=0
  local flat opaque=0 separator_before=start separator_after list_moved=0 conditional_move=0

  # The walk is a character loop in bash, so a large call costs real time on a
  # blocking hook's path; these checks skip it wherever it cannot change the
  # answer.
  _gaia_repo_scope_flatten "$command_text"
  [[ "$flat" =~ $_GAIA_REPO_SCOPE_MOVE_REGEX ]] || return 1
  _gaia_repo_scope_tool_end "$command_text"

  while [ "$position" -lt "$command_length" ]; do
    # Nothing left names either program, so nothing left can be home or
    # foreign.
    [ "$position" -lt "$tool_end" ] || break
    # Each scan slices the whole call, so the walk costs its length once per
    # command. Past this many commands it stops and enforces rather than stall
    # the hook: an over-enforcement, never a guess of foreign.
    walked=$((walked + 1))
    [ "$walked" -le "$_GAIA_REPO_SCOPE_WALK_MAXIMUM" ] || return 1
    if gaia_scan_first_command "$command_text" "$position"; then
      separator_after=end
      if [ "$GAIA_FIRST_COMMAND_CLOSED" = 1 ]; then
        closing_character="${command_text:$((GAIA_FIRST_COMMAND_END - 1)):1}"
        following_character="${command_text:$GAIA_FIRST_COMMAND_END:1}"
        case "$closing_character$following_character" in
          '&&') separator_after=and ;;
          '||') separator_after=or ;;
          '&'*) separator_after='bg' ;;
          '|'*) separator_after=pipe ;;
          *) separator_after=seq ;;
        esac
      fi
      kind=0
      _gaia_repo_scope_segment || kind=$?
      [ "$kind" = 1 ] && _gaia_repo_scope_swallowed && kind=2
      [ "$kind" = 1 ] && _gaia_repo_scope_substitutes && kind=2
      [ "$kind" = 2 ] && return 1
      [ "$kind" = 1 ] && foreign=1
      _gaia_repo_scope_opens_group && opaque=1
      case "$separator_after" in
        or) [ "$list_moved" = 1 ] && directory_known=0 ;;
        seq|bg)
          [ "$conditional_move" = 1 ] && directory_known=0
          list_moved=0; conditional_move=0
          ;;
      esac
      separator_before="$separator_after"
    fi
    [ "$GAIA_FIRST_COMMAND_CLOSED" = 1 ] || break
    position="$GAIA_FIRST_COMMAND_END"
    # A comment runs to the end of its line, and the next line is a command.
    # A comment that closed a command already ended its list above. One on a
    # line of its own, after a trailing `&&`, `||` or `|`, does not: bash
    # carries that list or pipeline onto the next line, so the separator the
    # walk last read still stands.
    if [ "${command_text:$((position - 1)):1}" = "#" ]; then
      rest="${command_text:$position}"
      case "$rest" in *"$NEWLINE"*) ;; *) break ;; esac
      rest="${rest%%"$NEWLINE"*}"
      position=$((position + ${#rest} + 1))
    fi
  done
  [ "$foreign" = 1 ]
}

# Commands the walk reads before it stops and enforces. Measured on bash 3.2
# and 5, a call of 140KB costs under a second at this depth, where an unbounded
# walk over 4,000 commands took ten.
_GAIA_REPO_SCOPE_WALK_MAXIMUM=128

# Sets the caller's `tool_end` to the byte offset just past the last stretch of
# the call the raw tool pattern matches, 0 when there is none. Past it no
# command names git or gh. Counting stops after as many matches as the walk
# would read commands, and the whole call is kept, since a walk that long stops
# on its own.
_gaia_repo_scope_tool_end() {
  local remaining_text="$1" matched_text prefix match_count=0
  tool_end=0
  while [[ "$remaining_text" =~ $_GAIA_REPO_SCOPE_TOOL_RAW_REGEX ]]; do
    match_count=$((match_count + 1))
    if [ "$match_count" -gt "$_GAIA_REPO_SCOPE_WALK_MAXIMUM" ]; then tool_end=${#1}; return 0; fi
    matched_text="${BASH_REMATCH[0]}"
    prefix="${remaining_text%%"$matched_text"*}"
    tool_end=$((tool_end + ${#prefix} + ${#matched_text}))
    remaining_text="${remaining_text:$((${#prefix} + ${#matched_text}))}"
  done
}

# 0 when a word after the first of the command the scan just read names git
# or gh beside a command separator or a newline. The scan models neither a
# heredoc nor ANSI-C quoting, so an apostrophe in a heredoc body, or a `$'\''`,
# can open a quoted span the shell never opened and carry the commands after
# it into one word of this command. A foreign command holding one would hide
# them, so it enforces instead. A single-line `--body` that only mentions git
# stays foreign; one that also holds a `;`, `&`, `|` or a newline enforces, so
# a multi-line body naming git or gh enforces, and `-F` or `--body-file` is the
# way around it.
_gaia_repo_scope_swallowed() {
  local i word_count=${#GAIA_FIRST_COMMAND_WORDS[@]} token NEWLINE=$'\n'
  i=1
  while [ "$i" -lt "$word_count" ]; do
    token="${GAIA_FIRST_COMMAND_WORDS[$i]}"
    i=$((i + 1))
    case "$token" in
      *';'* | *'&'* | *'|'* | *"$NEWLINE"*)
        [[ "$token" =~ $_GAIA_REPO_SCOPE_TOOL_REGEX ]] && return 0
        ;;
    esac
  done
  return 1
}

# 0 when a word after the first of the command the scan just read opens a
# command substitution, a backtick, or a process substitution, and a word after
# the first names git or gh. The openers include zsh's `=( )` and bash 5.3's
# `${ cmd; }`, whose unquoted opener the scan hands back as a word ending in
# `${`. A `${| cmd; }` needs no arm: the scan splits it at the pipe, so its
# payload is a command of its own. The shell runs that payload in its own directory
# before the command itself, so the command's `git -C` or `gh -R` never
# reaches it, and a foreign command holding one enforces.
# The scan keeps a quoted substitution as one word and
# splits an unquoted one at its spaces, so the opener and the name are looked
# for across the words rather than within one. That over-enforces a foreign
# command whose substitution runs something else while another word only
# mentions git, and a single-quoted one the shell leaves literal: the safe
# direction.
_gaia_repo_scope_substitutes() {
  local i word_count=${#GAIA_FIRST_COMMAND_WORDS[@]} token opener=0 tool=0
  i=1
  while [ "$i" -lt "$word_count" ]; do
    token="${GAIA_FIRST_COMMAND_WORDS[$i]}"
    i=$((i + 1))
    # shellcheck disable=SC2016 # literal openers matched in the word, not expansions
    case "$token" in
      *'$('* | *'`'* | *'<('* | *'>('* | *'=('* | *'${') opener=1 ;;
    esac
    [[ "$token" =~ $_GAIA_REPO_SCOPE_TOOL_REGEX ]] && tool=1
  done
  [ "$opener" = 1 ] && [ "$tool" = 1 ]
}

# 0 when the command the scan just read opens or closes a construct that scopes
# a `cd` away from the commands after it: a subshell, a group, a function body
# or definition, a command or process substitution, a heredoc, or a compound
# command's keyword. The scan drops quotes, so a parenthesis inside a quoted
# commit subject counts too: that only makes later `cd`s unknown, which
# enforces.
_gaia_repo_scope_opens_group() {
  local token
  case "${GAIA_FIRST_COMMAND_WORDS[0]}" in
    if|then|else|elif|fi|for|while|until|do|done|case|'esac'|select|function|'!')
      return 0 ;;
  esac
  for token in ${GAIA_FIRST_COMMAND_WORDS[@]+"${GAIA_FIRST_COMMAND_WORDS[@]}"}; do
    case "$token" in
      *'('* | *')'* | *'{'* | *'}'* | *'`'* | *\<\<*) return 0 ;;
    esac
  done
  return 1
}

# The rest of the library lives in sibling files, loaded from this file's own
# directory so a worktree loads its own copies: the guard's per-command reader,
# the first-command scan, and the act-on-home half. Every consumer reaches all
# of them through this one source. A sibling that is missing or does not parse
# leaves its functions undefined, and a call to one returns non-zero, which the
# guard reads as home (enforce) and the act-on-home entry points read as a
# reason to decline. Errexit is suspended across the three sources for the
# reason given at _gaia_repo_scope_load_main_root.
_gaia_repo_scope_directory="${BASH_SOURCE[0]%/*}"
[ "$_gaia_repo_scope_directory" != "${BASH_SOURCE[0]}" ] || _gaia_repo_scope_directory=.
_gaia_repo_scope_errexit_was=0
case $- in *e*) _gaia_repo_scope_errexit_was=1 ;; esac
set +e
# shellcheck source=/dev/null
. "$_gaia_repo_scope_directory/repo-scope-segment.sh" 2>/dev/null
# shellcheck source=/dev/null
. "$_gaia_repo_scope_directory/repo-scope-scan.sh" 2>/dev/null
# shellcheck source=/dev/null
. "$_gaia_repo_scope_directory/repo-scope-home.sh" 2>/dev/null
if [ "$_gaia_repo_scope_errexit_was" = 1 ]; then set -e; fi
unset _gaia_repo_scope_errexit_was
