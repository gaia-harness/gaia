#!/usr/bin/env bash
# The first-command word scan, and the gh pr merge scan built on it.
# Sourced only by repo-scope.sh, whose header states the contract every
# consumer relies on; defines functions and globals and does no other work at
# source time.

# shellcheck disable=SC2034  # the scan's globals are read by repo-scope.sh and its consumers

# ---------------------------------------------------------------------------
# First-command scan, shared by every consumer that acts on the home repo.
#
# Split the command into shell-like words. This is a real scan rather than a
# set of patterns over the raw text, and the difference is the whole point: a
# quote character opens a span in which whitespace, separators and the other
# quote character are all ordinary text, and a backslash escapes the
# character after it. Pattern-matching the raw text got this wrong once per
# spelling, always in the direction of reading part of one value, or part of
# a following command, as the pull-request reference or as the repository.
#
# The scan reads the FIRST command in the tool call and hands back its words.
# Whatever sits ahead of a command decides how that command should be read,
# and reading it needs the shell's own semantics: a comment hides a command,
# a heredoc body is not a quoted span so its lines read as commands, `cd` and
# `(cd` and `pushd` decide which repository the command lands in, and each of
# those is a construct rather than a spelling, so every rule naming one left
# the next one open. Requiring the command to come first closes the whole
# class at once: there is no prefix left to misread, and every word a caller
# sees comes from the invocation itself.
#
# The words that come out are unquoted, so nothing downstream needs to know
# quotes exist, and a `;` inside a squash subject stays text.
#
# Sets GAIA_FIRST_COMMAND_WORDS to the first command's words. Returns 0 when
# it read at least one word, 1 when the string held no command at all.
#
# An optional second argument is the byte offset to start reading at, and
# GAIA_FIRST_COMMAND_END is set to the byte offset just past the character that
# closed the command (the string's length when nothing did), so a caller can
# walk every command in a tool call by scanning again from there. The character
# before that offset is the `#` when a comment closed it, whose text runs to the
# end of its line and is the caller's to skip.
#
# Also sets GAIA_FIRST_COMMAND_CLOSED: 0 when no separator and no comment closed
# the first command, 1 when one did with something after it. A caller asking
# whether a second command was spelled with a separator cannot ask that of the
# text, because the spellings that matter break any literal scan of it
# (`gh pr "merge" <n>`, a line continuation inside the verb, a subshell, a brace
# group). This scan tokenizes the way the shell does, so it answers that
# question exactly, and publishing the answer costs one assignment rather than
# a second parser.
#
# What it does NOT report is EXPANSION. A command substitution, a backtick and
# a process substitution are ordinary word text to a scan that models words, so
# a string carrying one reaches the end with this flag still 0 while the shell
# runs the payload. A caller that needs "nothing else runs at all" has to rule
# that class out itself; this flag is one half of that question, not the whole
# of it.
GAIA_FIRST_COMMAND_WORDS=()
GAIA_FIRST_COMMAND_CLOSED=0
GAIA_FIRST_COMMAND_END=0

gaia_scan_first_command() {
  local command_text="$1" start="${2:-0}"
  # Named once, above the loop: a `case` pattern cannot hold a `$'\n'`
  # literal, and a command substitution in one would run per scanned
  # character. The newline is the load-bearing member of the set below: a
  # caller's arming match counts one as a separator, so without it here the
  # scan would run past the end of a command that match already treats as
  # several. The scan also cuts at a lone `&`, which those arming matches do
  # not accept before their verb; that asymmetry costs a background-started
  # command its handling and never a wrong one, so it is the safe direction
  # to differ in.
  local NEWLINE=$'\n'
  local TAB=$'\t'
  local word="" chunk="" have_word=0 quote_character="" quote_stop_set="" escape_pending=0 piece_closed=0
  local _previous_lc_all _had_lc_all BLOCK command_length base block k block_length character rest run

  GAIA_FIRST_COMMAND_WORDS=()

  # `${command_text:$i:1}` costs O(i), so indexing the whole string per character makes
  # the scan quadratic, and the callers are hooks, so that cost is a
  # synchronous stall on every merge. The command is whatever the tool call
  # carried, and a block that writes a multi-kilobyte pull-request body before
  # merging is ordinary, so the input is not small. Two things keep it cheap
  # and neither changes what the state machine reads: bytes instead of
  # characters, since every character this scan looks for is ASCII and a
  # multibyte character's bytes are all non-ASCII, so they land in the current
  # word intact; and one slice per block rather than per character, which
  # leaves only a small quadratic term. macOS still ships bash 3.2, where both
  # constants are several times CI's.
  #
  # A third: a word accumulates into `chunk` and reaches `word` once per
  # block, not one character at a time. `word="$word$character"` costs O(word), and
  # nothing bounds how long one word gets, since inside a quoted span
  # whitespace, separators and newlines are all ordinary text, so a quoted
  # `--body` is one word however long the prose is. Appending per character
  # made the scan quadratic in that body's size: seconds of synchronous stall
  # on a deny-capable gate at a size an ordinary pull-request body reaches.
  # Flushing per block bounds the per-character append by BLOCK and pays the
  # O(word) append BLOCK times less often. The cost of that is that every read
  # of the word has to spell `$word$chunk`, which is why the pushes below do.
  _previous_lc_all="${LC_ALL-}"
  _had_lc_all="${LC_ALL+set}"
  LC_ALL=C
  BLOCK=256
  command_length=${#command_text}
  base="$start"
  GAIA_FIRST_COMMAND_END="$command_length"
  while [ "$base" -lt "$command_length" ]; do
    block="${command_text:$base:$BLOCK}"
    base=$((base + BLOCK))
    k=0
    block_length=${#block}
    while [ "$k" -lt "$block_length" ]; do
      character="${block:$k:1}"
      k=$((k + 1))
      # A backslash-newline is a line CONTINUATION: the shell drops both
      # characters rather than making the newline text. Appending it would put
      # a lone newline in the word stream, and a caller reading the first
      # non-flag word as its reference would resolve a newline instead of a
      # command written across two lines.
      if [ "$escape_pending" = 1 ]; then
        escape_pending=0
        [ "$character" = "$NEWLINE" ] && continue
        chunk="$chunk$character"; have_word=1; continue
      fi
      # Inside single quotes a backslash is literal, as in the shell itself.
      # `have_word` is deliberately NOT set here: at the backslash it is not
      # yet known whether a word follows it or a line continuation does, and
      # marking one either way puts an empty word into the stream on the
      # continuation. The escaped-character branch above marks it once a
      # character survives.
      if [ "$character" = "\\" ] && [ "$quote_character" != "'" ]; then
        escape_pending=1; continue
      fi
      if [ -n "$quote_character" ]; then
        if [ "$character" = "$quote_character" ]; then
          quote_character=""; quote_stop_set=""
        else
          chunk="$chunk$character"
          # `character` was ordinary text inside the span, so the run after it is
          # ordinary until the next character that means anything here: the
          # closing quote, and in a double-quoted span a backslash. Take that
          # whole run in one operation instead of a character at a time, which
          # is what makes a long quoted body cost about what reading it costs.
          # `rest` is a tail of the BLOCK-sized slice, never of the whole
          # command, so this pattern match is bounded too; matching over the
          # full string would trade the quadratic append for a superlinear
          # match and buy much less.
          rest="${block:$k}"
          # shellcheck disable=SC2295 # $quote_stop_set is a PATTERN here, not a literal
          run="${rest%%$quote_stop_set*}"
          if [ -n "$run" ]; then chunk="$chunk$run"; k=$((k + ${#run})); fi
        fi
        have_word=1
        continue
      fi
      case "$character" in
        '"'|"'")
          quote_character="$character"; have_word=1
          # The stop set the bulk run above cuts at, built once per span
          # rather than per character. A backslash is literal inside single
          # quotes, which is the same rule the escape branch above already
          # applies, so it is not a stop there.
          if [ "$character" = "'" ]; then quote_stop_set="[']"; else quote_stop_set='[\\"]'; fi
          ;;
        ' '|"$TAB")
          [ "$have_word" = 1 ] && GAIA_FIRST_COMMAND_WORDS+=("$word$chunk")
          word=""; chunk=""; have_word=0
          ;;
        '&'|'|'|';'|"$NEWLINE")
          [ "$have_word" = 1 ] && GAIA_FIRST_COMMAND_WORDS+=("$word$chunk")
          word=""; chunk=""; have_word=0
          # An empty piece is no command at all: leading whitespace or a
          # newline, or the second character of `&&` / `||`. Keep scanning so
          # the FIRST real command is still the one that gets handed back.
          [ "${#GAIA_FIRST_COMMAND_WORDS[@]}" -eq 0 ] && continue
          piece_closed=1; GAIA_FIRST_COMMAND_END=$((base - BLOCK + k)); break 2
          ;;
        '#')
          # A word-initial unquoted `#` opens a COMMENT, so the shell drops it
          # and everything after it to the newline and the command never
          # receives any of it. Read as ordinary text those words reach a
          # caller's parser, and a `--repo` among them wins, because that
          # parser keeps the LAST one it sees. A foreign command whose
          # trailing comment names this repository would then resolve THIS
          # repository. Mid-word the character is ordinary text, which is the
          # shell's rule too and is what keeps `fix#<n>` intact.
          #
          # Stopping the scan is the same retreat the separators take, and it
          # is required rather than convenient: skipping ahead to the newline
          # would let a comment that HIDES a leading command promote the words
          # after it into the first command. The command a caller wants has to
          # be that first command anyway, so nothing beyond the comment was
          # readable.
          [ "$have_word" = 1 ] && { chunk="$chunk$character"; continue; }
          piece_closed=1; GAIA_FIRST_COMMAND_END=$((base - BLOCK + k)); break 2
          ;;
        *) chunk="$chunk$character"; have_word=1 ;;
      esac
    done
    word="$word$chunk"; chunk=""
  done
  if [ "$_had_lc_all" = set ]; then LC_ALL="$_previous_lc_all"; else unset LC_ALL; fi
  # shellcheck disable=SC2034 # read by the merge gate, never in this file
  GAIA_FIRST_COMMAND_CLOSED="$piece_closed"
  # The whole command was one piece, so its trailing word closes it.
  if [ "$piece_closed" = 0 ]; then
    [ "$have_word" = 1 ] && GAIA_FIRST_COMMAND_WORDS+=("$word$chunk")
  fi

  [ "${#GAIA_FIRST_COMMAND_WORDS[@]}" -gt 0 ] || return 1
  return 0
}

# `gh pr merge` form of the scan above, for the two consumers that act on the
# home repo off a merge. Requires the FIRST command in the tool call to BE the
# merge, then reads that invocation's own flags.
#
# Sets GAIA_GH_MERGE_REFERENCE to the pull-request reference the merge names (empty
# when it names none, which is gh's current-branch default) and
# GAIA_GH_MERGE_REPO to its `-R`/`--repo` value (empty when it carries none,
# which means gh resolves from cwd). Returns 0 when both are populated from a
# merge invocation it read completely, 1 when it abstains: the tool call's
# first command is not the merge, or the merge carries a flag shape this
# parser does not model.
#
# The cost of the first-command requirement is that `<something> && <merge>`
# in one tool call is not read. That shape is not how this repository merges
# (the merge workflow runs the merge as its own step), and the alternative is
# a prefix nobody can read exactly, whose misreads all land on a write to a
# repository the command never named.
GAIA_GH_MERGE_REFERENCE=""
GAIA_GH_MERGE_REPO=""

gaia_scan_gh_merge() {
  local command_text="$1"
  local i word_count token flag skip_next skip_flag value_flags

  GAIA_GH_MERGE_REFERENCE=""
  GAIA_GH_MERGE_REPO=""

  gaia_scan_first_command "$command_text" || return 1
  # The first command has to BE the merge; a caller's arming match only proved
  # the phrase appears somewhere a command could start, which a comment, a
  # heredoc body line, and a quoted value all satisfy.
  [ "${#GAIA_FIRST_COMMAND_WORDS[@]}" -ge 3 ] || return 1
  [ "${GAIA_FIRST_COMMAND_WORDS[0]}" = "gh" ] || return 1
  [ "${GAIA_FIRST_COMMAND_WORDS[1]}" = "pr" ] || return 1
  [ "${GAIA_FIRST_COMMAND_WORDS[2]}" = "merge" ] || return 1

  # Every value-taking flag, and only those. Checked against gh's own help
  # output rather than recalled: -m is --merge, a BOOLEAN, so listing it here
  # would make `-m 1498` skip the reference and resolve the current branch
  # instead. -A/--author-email and -F/--body-file do take values, so omitting
  # them would make the value itself the reference.
  value_flags=" -R --repo -A --author-email -b --body -F --body-file -t --subject --match-head-commit "
  skip_next=0
  skip_flag=""
  word_count=${#GAIA_FIRST_COMMAND_WORDS[@]}
  i=3
  while [ "$i" -lt "$word_count" ]; do
    token="${GAIA_FIRST_COMMAND_WORDS[$i]}"
    i=$((i + 1))
    if [ "$skip_next" = 1 ]; then
      skip_next=0
      [ "$skip_flag" = repo ] && GAIA_GH_MERGE_REPO="$token"
      skip_flag=""
      continue
    fi
    case "$token" in
      # A single-dash CLUSTER, which gh's flag library accepts and this parser
      # does not model. pflag reads a one-dash token letter by letter, and the
      # first value-taking shorthand in it swallows the rest of the token or
      # the next word: `-sRother-org/other-repo` is a squash merge of another
      # repository, and `-st 1234 5` gives `1234` to the subject rather than
      # making it the reference. Read here as one unknown flag, the first
      # spelling leaves the repository check unarmed and the second makes a
      # subject the reference, and both end in a write onto something in THIS
      # repository the merge never named.
      #
      # Rejecting the whole shape rather than the letter `R` is deliberate:
      # matching R alone would close the spelling that was reported and leave
      # the one that was not, which is how the ten rounds before this went. A
      # token whose FIRST letter is value-taking is not a cluster (the rest is
      # that flag's value), so it falls through to the arms below.
      -[!-RAbFt]?*)
        return 1
        ;;
      -*=*)
        # `--flag=value` carries its value in the same word.
        flag="${token%%=*}"
        case "$value_flags" in
          *" $flag "*)
            case "$flag" in
              -R|--repo) GAIA_GH_MERGE_REPO="${token#*=}" ;;
            esac
            ;;
        esac
        ;;
      # A shorthand with its value attached: `-Rowner/repo` is the same
      # invocation as `-R owner/repo`. Only the repository shorthand is read
      # back; an attached value on another value-taking shorthand stays one
      # word and consumes nothing, which the arm below gets right by doing
      # nothing with it.
      -R?*)
        GAIA_GH_MERGE_REPO="${token#-R}"
        ;;
      -*)
        case "$value_flags" in
          *" $token "*)
            skip_next=1
            case "$token" in
              -R|--repo) skip_flag=repo ;;
            esac
            ;;
        esac
        ;;
      *)
        # The first non-flag word is the reference, and the scan continues:
        # gh accepts flags in any position, so `merge 5 --repo other-org/gaia`
        # is an ordinary invocation and stopping here would leave the
        # repository read unarmed for every trailing spelling of the flag.
        [ -n "$GAIA_GH_MERGE_REFERENCE" ] || GAIA_GH_MERGE_REFERENCE="$token"
        ;;
    esac
  done
  return 0
}

# Whole-command form, for a consumer with no scanner of its own. It reads the
# merge invocation with the scan above and hands its `-R`/`--repo` value to
# the act-on-home slug comparison.
#
# Every abstention of the scan's is foreign here, which is this entry point's
# safe direction: a tool call whose first command is not the merge carries a
# prefix that decides which repository the merge lands in, and a flag shape
# the parser does not model can name another repository outright. Neither is
# a value this entry point parsed, so neither is one it lets a caller act on.
#
# That covers the redirections a regex over the raw text cannot: a leading
# `cd`, a `pushd`, a subshell `(cd ...`, a `cd` to a path that does not
# resolve. It equally covers a `-R` belonging to a LATER command in the same
# tool call (`gh pr merge 42 && grep -R app/routes .`), which no shape test on
# the value can tell from gh's own repository flag, since a path argument
# carries a slash exactly as a slug does. The scan tells them apart by knowing
# which command the flag belongs to, and a merge that carries none reads home
# because it is the first command, so nothing redirected cwd ahead of it.
command_targets_foreign_repo_slug() {
  local command_text="$1"

  gaia_scan_gh_merge "$command_text" || return 0

  # An empty value means the merge named no explicit target. The comparison
  # reads that as home, which is correct here precisely because the scan
  # proved the merge is the first command in the tool call.
  if repo_slug_is_foreign "$GAIA_GH_MERGE_REPO"; then return 0; fi
  return 1
}
