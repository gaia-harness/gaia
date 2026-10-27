#!/usr/bin/env bash
# The data-proof walker behind the shared verb-arming decision, and the
# liveness scan after it (verb-arming-live-helpers.sh states its contract).
# Sourced by lib/verb-arming.sh, lazily, only once a raw arming match has
# already hit; sourced by nothing else. Does no work at source time beyond
# loading its sibling files.
#
#   gaia_verb_arm_view <text>
#
# ASSIGNS GAIA_VERB_ARM_VIEW. It does not print the view, and no caller may
# read it through `$( )`: command substitution strips every trailing newline,
# and a tool call ending in one is the common heredoc shape, so a stdout return
# channel would break the same-length property below for exactly the inputs
# that need it most.
#
# SAME LENGTH, ALWAYS. The view is the same CHARACTER length as <text>, because
# the mask is an overwrite rather than a deletion. Character length is the
# dimension that matters, which is why the mask run is sized outside the
# byte-locale the scan runs in.
#
# WHAT COUNTS AS DATA. Exactly one shape, and deliberately small. A heredoc
# body is data when all of the following hold, the first six on its opener
# line and the seventh on the body itself:
#
#   1. the command word is the literal `cat` or `tee`, written out, never
#      reached through an expansion;
#   2. the output goes to a file: a `>` or `>>` redirect to a word, or a `tee`
#      file operand. Never into a pipe, another command, or a file descriptor;
#   3. the line carries no command substitution, parameter expansion, or
#      backtick anywhere;
#   4. the delimiter is a single unambiguous word, `<<` or `<<-`, quoted or
#      unquoted;
#   5. the delimiter line actually appears later in the text;
#   6. the heredoc belongs to that first command: no `&`, `;` or `(` stands
#      between the command word and the heredoc operator. Conditions 1 and 2
#      each read the line as a whole, so without this one a line whose first
#      command is `cat > f` lends its proof to a second command's heredoc after
#      a separator, and the shell runs what that second command is handed;
#   7. the body runs nothing: either the delimiter is quoted or escaped, which
#      turns substitution off, or the body carries no command-substitution
#      opener: no `$(` and no backtick.
#      With an unquoted delimiter the shell runs a command substitution inside
#      the body before `cat` ever sees it, so that body is not data.
#
# The body runs from the newline ENDING the opener line, not from the heredoc
# operator, so anything still on the opener line after the operator is ordinary
# command text and keeps its arming power. That newline is masked with the body
# it introduces, because it is the separator a body's first line would arm on.
# The newline that ends the last body line is left alone: nothing after it is
# body, and leaving it is the direction that suppresses less.
#
# NOTHING ELSE IS PROOF. Quoted spans are never suppressed: a `bash -c` runs
# what it is handed from inside one, and a runner reached through a variable
# defeats any list of interpreter names, so there is no safe narrowing.
# Comments are never suppressed: a `#` that is not word-initial opens no
# comment, and the arming patterns already decline a word-initial one because
# they require whitespace before the verb. The walk still RECOGNIZES quoted
# spans and comments, for one purpose: knowing that a `<<` inside one opens no
# heredoc. Recognizing is not suppressing.
#
# ABSTENTION IS WHOLE-INPUT. On any of a text longer than the character bound,
# a text dense enough to exhaust the re-reading budget, an unterminated quoted
# span, a `$'…'` word, a heredoc whose delimiter never appears, or any
# construct not modelled here, the view is the identity and nothing anywhere is
# suppressed. The burden of proof rests on suppression: an
# over-armed hook costs an unrelated tool call a decision nobody asked for,
# while an under-armed one lets a real merge past a gate.
#
# THE BOUND. 16,384 characters, owned by lib/verb-arming.sh and defaulted here
# so this file is sourceable on its own under `set -u`. It covers the observed
# population: in a corpus of 33,498 real Bash tool calls no call that armed ran
# longer, and two ran past 8,192. Past the bound the view is the identity and
# the raw match stands, because a hook that misses its deadline is cancelled
# and the tool call then proceeds uninspected, which is the fail-open direction.
#
# COST. The walk jumps span to span with parameter-expansion prefix strips
# rather than reading a character at a time: `${s:$i:1}` costs O(i), so a
# per-character index is quadratic, which at this bound is the difference
# between roughly a hundredth of a second and roughly a second per hook on
# stock bash 3.2. It has to be affordable on ordinary traffic rather than on
# merges, because commits and pushes are most of what raw-matches at all. Size
# alone does not bound the walk, so a second bound does; see the re-reading
# budget below.
#
# WHAT THIS DOES NOT CLOSE, stated so no reader takes the arming contract for
# whole:
#
#   - Quoted prose still over-arms. A quoted string carrying a list operator
#     or a newline before the verb arms every consumer. Fail-closed, and there
#     is no safe narrowing. A substitution opener there is the liveness scan's
#     question, not this walk's.
#   - A verb whose characters are quoted still under-arms outside the first
#     command, because the tokenizer arm reads the first command only.
#   - Dollar-quoted words are unmodelled. The walk abandons suppression on one
#     rather than approximating it.
#   - The tokenizer arm's bounded prefix can create an arm no data proof
#     removes, because truncation at that bound can leave a word reading as the
#     verb. That arm is not subject to this walk at all.

_GAIA_VA_TAB=$'\t'
# A lone backslash is unwritable as a `case` pattern without either escaping it
# into something else or drawing a false "did you mean to escape a quote"
# reading; held in a variable it is unambiguous in both places it is compared.
_GAIA_VA_BACKSLASH=$'\\'

# Character sets the walk jumps to, as glob bracket expressions held in
# variables: a bracket carrying a newline, a backslash and both quote
# characters is unreadable written inline, and a literal `$'\n'` cannot appear
# in a `case` pattern at all.
#
# Top level: both quote characters, a backslash (escapes the next character), a
# backtick (opens a substitution span), a `#` (may open a comment), a `<` (may
# open a heredoc), a `$` (may open a dollar-quoted word), and a newline (ends a
# line, which is where heredoc bodies begin). The apostrophe and the backtick
# are spelled as octal escapes rather than written out: a literal backtick in a
# `$'…'` word reads as an unclosed substitution to a tokenizer that does not
# model this quoting form, and a `\'` reads as the word's own terminator, which
# desyncs the tree's shell linters over the whole rest of the file.
_GAIA_VA_TOP_SET=$'["\047\\\\\140#<$\n]'
# Inside a double-quoted span: the closing quote, and a backslash, which
# escapes the character after it there.
_GAIA_VA_DOUBLE_QUOTE_SET=$'["\\\\]'
# A run ending in one of these leaves the next character word-initial, which is
# what decides whether a `#` opens a comment.
_GAIA_VA_WORD_SET=$'[ \t;&|(\n]'
# The blanks that may sit between a heredoc operator and its delimiter, and
# their complement, so the run is skipped in one strip rather than one per
# character.
_GAIA_VA_BLANK_SET=$'[ \t]'
_GAIA_VA_NONBLANK_SET=$'[! \t]'

# How much re-reading the walk pays for before it gives up, counted in
# characters.
#
# The character bound bounds SIZE, and size is not what the walk costs. Every
# parameter expansion of the remaining text costs a pass over the whole of it,
# so the price is the number of steps times what is still to come, and two
# texts of the same size differ by two orders of magnitude depending on how
# densely they carry the characters a step lands on. The dense end is where a
# hook misses its deadline, gets cancelled, and lets the tool call through
# uninspected, so it needs a bound in the dimension the cost is actually in
# rather than a step count, which would be far too tight on a short dense text
# and far too loose on a long one.
#
# 2,000,000 puts the worst case a text at the character bound can reach in the
# same range as an ordinary one, and leaves real traffic untouched by a wide
# margin. A heredoc's body is skipped whole rather than stepped through, so a
# report written to a file spends two steps whatever its body costs, and even
# a two-hundred-line script that goes on to write one stays inside.
_GAIA_VA_MAXIMUM_WORK=2000000

# A `>` or `>>` redirect to a word. The leading exclusion is what keeps a file
# descriptor out: `2>err` redirects stderr and leaves the body on stdout, and
# `>&2` is a descriptor duplication with no file anywhere.
_GAIA_VA_REDIRECT_REGEX='(^|[^0-9&>])>>?[[:space:]]*[^[:space:]&<>|;]'
# A `tee` file operand: flags, then a word that is neither a flag nor a
# redirection. `tee <<EOF` and `tee -a <<EOF` name no file and fail it.
_GAIA_VA_TEE_REGEX='^[[:space:]]*tee([[:space:]]+-[^[:space:]]*)*[[:space:]]+[^-<>[:space:]]'

# The run of `x` every mask is filled from, grown on demand and reused for the
# life of the process. Taken from a doubling cache rather than from
# `${body//?/x}`, whose pattern substitution rescans the whole body per
# replacement and is quadratic in body length. ASCII, so its length is the same
# character count in every locale.
_gaia_va_xrun=x
_gaia_va_run=""
_gaia_va_delimiter_offset=-1
_gaia_va_locale_previous=""
_gaia_va_locale_was_set=""

_gaia_va_make_run() {
  local run_length="$1"
  [ "$run_length" -gt 0 ] || { _gaia_va_run=""; return 0; }
  while [ "${#_gaia_va_xrun}" -lt "$run_length" ]; do
    _gaia_va_xrun="$_gaia_va_xrun$_gaia_va_xrun"
  done
  _gaia_va_run="${_gaia_va_xrun:0:$run_length}"
}

# The scan runs under LC_ALL=C, where every offset and length is a byte. Every
# character it looks for is ASCII and a multibyte character's bytes are all
# non-ASCII, so byte offsets cut in the same places character offsets would.
# The mask run is the one quantity that cannot be sized that way, since the
# view's length contract is in characters, so the walk steps back into the
# caller's locale to measure each body and returns.
_gaia_va_locale_bytes() {
  _gaia_va_locale_was_set="${LC_ALL+set}"
  _gaia_va_locale_previous="${LC_ALL-}"
  LC_ALL=C
}

_gaia_va_locale_characters() {
  if [ "$_gaia_va_locale_was_set" = set ]; then LC_ALL="$_gaia_va_locale_previous"; else unset LC_ALL; fi
}

# _gaia_va_find_delimiter <text> <delimiter> <strip_tabs>: set _gaia_va_delimiter_offset to the offset in
# <text> at which the delimiter LINE begins, or return 1 when no such line
# exists. <strip_tabs> is 1 for the `<<-` form, whose delimiter line may carry
# leading tabs the shell removes.
_gaia_va_find_delimiter() {
  local search_text="$1" delimiter="$2" strip_tabs="$3"
  local newline=$'\n' prefix probe consumed line stripped_line
  _gaia_va_delimiter_offset=-1
  if [ "$strip_tabs" = 0 ]; then
    case "$search_text" in
      "$delimiter"|"$delimiter$newline"*) _gaia_va_delimiter_offset=0; return 0 ;;
    esac
    # One prefix strip locates the first delimiter line: `%%` removes the
    # longest suffix that matches, which is the one starting at the earliest
    # occurrence. Quoting the delimiter inside the pattern keeps a glob
    # character in it literal.
    prefix="${search_text%%"$newline$delimiter$newline"*}"
    if [ "${#prefix}" -ne "${#search_text}" ]; then _gaia_va_delimiter_offset=$(( ${#prefix} + 1 )); return 0; fi
    case "$search_text" in
      *"$newline$delimiter") _gaia_va_delimiter_offset=$(( ${#search_text} - ${#delimiter} )); return 0 ;;
    esac
    return 1
  fi
  # The `<<-` form needs the tabs stripped before the comparison, which no
  # single pattern expresses, so walk the lines.
  probe="$search_text"
  consumed=0
  while :; do
    case "$probe" in
      *"$newline"*) line="${probe%%"$newline"*}" ;;
      *) line="$probe" ;;
    esac
    stripped_line="$line"
    while :; do
      case "$stripped_line" in
        "$_GAIA_VA_TAB"*) stripped_line="${stripped_line#?}" ;;
        *) break ;;
      esac
    done
    if [ "$stripped_line" = "$delimiter" ]; then _gaia_va_delimiter_offset="$consumed"; return 0; fi
    case "$probe" in
      *"$newline"*) ;;
      *) return 1 ;;
    esac
    probe="${probe#*"$newline"}"
    consumed=$(( consumed + ${#line} + 1 ))
  done
}

# _gaia_va_opener_is_data <opener-line> <pre-operator-text>: 0 when the line
# meets every condition in the whitelist this file's header states, 1
# otherwise. Conditions 4 and 5 are decided where the delimiter is parsed and
# where its line is located; this decides 1, 2, 3 and 6.
_gaia_va_opener_is_data() {
  local line="$1" text_before_operator="$2"
  # Condition 6. Conditions 1 and 2 each read the line as a whole, the command
  # word at its start and a redirect anywhere on it, so a line whose FIRST
  # command is `cat > f` and whose heredoc belongs to a SECOND command after a
  # separator satisfies both while the shell hands that body to the second
  # command and runs it. `cat > f.txt && bash <<EOF` with a merge in the body
  # is the shape that costs: masking it there disarms every gate on a merge the
  # shell executes, which is the one direction this walk may never fail in.
  # Only the text ahead of the operator separates the two readings, and a
  # separator after the operator is not the same question: the heredoc there
  # already belongs to the first command. `|` needs no arm of its own, since
  # condition 3 rejects it anywhere on the line.
  case "$text_before_operator" in
    *'&'*|*';'*|*'('*) return 1 ;;
  esac
  # Condition 3, read as "no `$` at all" rather than as a list of expansion
  # openers. Narrower than the whitelist's letter, and narrower is the safe
  # direction: `$@`, `$?` and `$$` expand too, and enumerating them invites the
  # next one to be missed. A pipe anywhere fails condition 2 for the same
  # reason, without needing to know whether it is quoted.
  case "$line" in
    *'$'*|*'`'*|*'|'*) return 1 ;;
  esac
  # Condition 1. The command word has to BE `cat` or `tee`: a quoted spelling,
  # a path, or any prefix ahead of it means the walk cannot say what runs.
  case "$line" in
    'cat '*|"cat$_GAIA_VA_TAB"*|'tee '*|"tee$_GAIA_VA_TAB"*) ;;
    *) return 1 ;;
  esac
  # Condition 2.
  [[ "$line" =~ $_GAIA_VA_REDIRECT_REGEX ]] && return 0
  case "$line" in
    'tee'*) [[ "$line" =~ $_GAIA_VA_TEE_REGEX ]] && return 0 ;;
  esac
  return 1
}

# The view and the liveness scan live in sibling files, loaded from this
# file's own directory so a worktree loads its own copies. A sibling that is
# missing or does not parse leaves its entry point undefined, which the loader
# in lib/verb-arming.sh reads as no walker (or no scan) and answers with the
# identity view, the same degrade an absent walker gets.
_gaia_va_walk_directory="${BASH_SOURCE[0]%/*}"
[ "$_gaia_va_walk_directory" != "${BASH_SOURCE[0]}" ] || _gaia_va_walk_directory=.
# shellcheck source=/dev/null
. "$_gaia_va_walk_directory/verb-arming-view.sh"
# shellcheck source=/dev/null
. "$_gaia_va_walk_directory/verb-arming-live-helpers.sh"
# shellcheck source=/dev/null
. "$_gaia_va_walk_directory/verb-arming-live-view.sh"
