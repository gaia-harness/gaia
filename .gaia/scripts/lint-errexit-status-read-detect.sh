#!/usr/bin/env bash
# SC2016 is intentional file-wide, for the reason lint-errexit-status-read.sh
# gives: the awk program below reaches awk as literal program text. SC2034
# too: the string it assigns is read by that script, never here.
# shellcheck disable=SC2016,SC2034
#
# The classifier half of lint-errexit-status-read.sh's shared detector: what
# arms errexit, what reads the status, and the per-line feed. Sourced only by
# that script, which appends this program to lint-errexit-status-read-walk.sh's
# into CORE_AWK; assigns that one string and does no other work at source time.
CORE_AWK_DETECTOR='
# eat_word(remaining_text): consume ONE shell word from the front of remaining_text and return what is
# left. Quote-aware, because a redirection operand may be quoted and may carry
# whitespace: a whitespace-delimited matcher stops mid-operand, and the leftover
# closing fragment then reads as a command word, which exempts a genuine defect
# with no message anywhere. That is the regression this function exists to not
# have, and `> "my log"` is the shape that produced it.
#
# `$(` is followed to its matching `)` rather than broken on, so an assignment
# whose value is itself a substitution (`out=$(a) FOO=$(b) run_thing`) is
# consumed as the one word it is. Stops at unquoted whitespace, at `;`, `|`, `&`,
# `(`, and `)`, and at a redirection`s `<` or `>`, each of which begins the next
# token rather than continuing this one.
#
# A PROCESS SUBSTITUTION operand (`>(tee log)`, `<(cat)`) is the one shape where
# a leading `<` or `>` does NOT begin the next token: the caller has already
# consumed the redirection operator, so what is left is the operand, and the
# operand is a nested command rather than a word. Broken on at its `(` the way
# the stop set would otherwise demand, the leftover `(` reads as a statement
# separator, the command word behind it is never reached, and the line is
# reported although the shell runs it. It is followed to its matching `)` with
# the same depth counter `$(` uses, and only at position 1, which is the only
# place a redirection operand can begin; mid-word a `<` or `>` still stops the
# word, so `> log>(x)` is unaffected.
#
# `#` is the one member of that set that depends on WHERE it sits: it opens a
# comment only at the start of a word and is an ordinary character inside one, so
# `> log#x run_thing` redirects to a file literally named `log#x`. walk() already
# draws that distinction, and reading it as a comment here would report a line the
# shell runs. Position 1 is the only word start this function can see, since the
# caller hands it a tail with its leading whitespace already stripped.
function eat_word(remaining_text,   text_length, i, character, quote_character, substitution_depth) {
  text_length = length(remaining_text)
  quote_character = ""
  substitution_depth = 0
  for (i = 1; i <= text_length; i++) {
    character = substr(remaining_text, i, 1)
    # Single quotes make every byte literal, backslash included, so this comes
    # before the escape handling, exactly as in walk().
    if (quote_character == "\047") { if (character == "\047") quote_character = ""; continue }
    if (character == "\\") { i++; continue }
    if (quote_character == "\"") { if (character == "\"") quote_character = ""; continue }
    if (character == "\047") { quote_character = "\047"; continue }
    if (character == "\"") { quote_character = "\""; continue }
    if (character == "$" && substr(remaining_text, i + 1, 1) == "(") { substitution_depth++; i++; continue }
    # A process substitution operand, at a word start only. See the docblock.
    if (i == 1 && (character == "<" || character == ">") && substr(remaining_text, i + 1, 1) == "(") { substitution_depth++; i++; continue }
    if (substitution_depth > 0) {
      if (character == "(") substitution_depth++
      else if (character == ")") substitution_depth--
      continue
    }
    if (character == " " || character == "\t") break
    if (character == "#") { if (i == 1) break; continue }
    if (index(";|&()<>", character) > 0) break
  }
  return substr(remaining_text, i)
}

# has_status_read(line): 1 when the line reads `$?`, quote-aware.
#
# A `$?` inside SINGLE quotes is literal text at this point in the script and is
# not a read at all. That discrimination is load-bearing rather than cosmetic:
# the ordinary way to capture an exit status for a cleanup handler is
# `trap \047rc=$?; ...\047 EXIT`, whose body the shell stores unexpanded and
# runs when the trap fires. Reading one as a status read would red the tree on
# correct code. Inside DOUBLE quotes a `$?` does expand, so `echo "rc
# $?"` is a read like any other, and a single quote appearing inside a
# double-quoted string is an ordinary character rather than a quote.
function has_status_read(line,   line_length, i, character, quote_character, previous_character) {
  quote_character = ""
  line_length = length(line)
  for (i = 1; i <= line_length; i++) {
    character = substr(line, i, 1)
    if (quote_character == "\047") { if (character == "\047") quote_character = ""; continue }
    if (character == "\\") { i++; continue }
    if (quote_character == "") {
      # A TRAILING COMMENT is not a status read, and reading one as a hit is a
      # wrong verdict on reachable code: `some_cmd   # returns $? to the caller`
      # holds no read at all, and the line runs whenever the assignment above it
      # succeeded. walk() already strips a word-start `#`; this function is what
      # decides the hit, so it has to strip one too or the two disagree about
      # what the line even contains. Carrying a pending assignment across
      # comment-only lines, which is deliberate, widens the window rather than
      # narrowing it.
      if (character == "#") {
        previous_character = (i > 1) ? substr(line, i - 1, 1) : " "
        if (previous_character == " " || previous_character == "\t" || previous_character == ";" || previous_character == "&" || previous_character == "|" || previous_character == "(") return 0
      }
      if (character == "\047") { quote_character = "\047"; continue }
      if (character == "\"") { quote_character = "\""; continue }
    } else if (character == "\"") { quote_character = ""; continue }
    if (character == "$" && substr(line, i + 1, 1) == "?") return 1
  }
  return 0
}

# arm(set_line): update the errexit state from a `set` line. Only an `e` in a short
# option bundle or an explicit `-o errexit` counts, so `set -u` and
# `set -o pipefail` leave the state alone.
function arm(set_line,   token_count, tokens, i, word) {
  token_count = split(set_line, tokens, /[ \t]+/)
  for (i = 2; i <= token_count; i++) {
    word = tokens[i]
    if (word == "-o") { if (tokens[i + 1] == "errexit") armed = 1; i++; continue }
    if (word == "+o") { if (tokens[i + 1] == "errexit") armed = 0; i++; continue }
    if (substr(word, 1, 2) == "--") continue
    if (substr(word, 1, 1) == "-" && index(word, "e") > 0) armed = 1
    if (substr(word, 1, 1) == "+" && index(word, "e") > 0) armed = 0
  }
}

function reset_state(  level) {
  W_quote_state = ""; W_depth = 0; W_in_backtick = 0; W_arithmetic_count = 0
  W_heredoc = ""; W_heredoc_tabs = 0
  continued = 0; pending = 0; isname = 0; statement_operator = 0; statement_substitution = 0; statement_substitution_count = 0
  for (level in W_quote_stack) delete W_quote_stack[level]
  for (level in W_arithmetic_levels) delete W_arithmetic_levels[level]
}

# check_desync(what): report a region the scan could not read to its end.
#
# An open quote, an unclosed substitution, or an unterminated heredoc left
# standing when the region ends means the tokenizer lost sync somewhere inside
# it, and everything after that point was carried as quoted text rather than
# classified. That failure is silent in the worst direction: the gate prints
# `clean` over lines it never read. A well-formed region always closes what it
# opens, so this fires only where the answer is genuinely unavailable, and
# saying so is the honest verdict.
function check_desync(what) {
  if (W_quote_state != "" || W_depth > 0 || W_in_backtick || continued || W_heredoc != "")
    printf "%s: ERROR: the scan lost track of shell state before the end of %s, so the remainder was never classified and this gate cannot certify it clean\n", file, what
}

# report(line_number, assignment_line): print a hit, unless the discriminator says this line is not
# executed shell.
#
# Each test answers for the line just handed to gaia_scan_feed, which the
# scan rules below call ahead of feed(), and each is inert when is_bats is
# 0, so the pre-existing surfaces reach the printf exactly as they did
# before the library existed.
#
# Suppression is read HERE rather than latched once per line because
# gaia_scan_suppressed MARKS the pragma it matches as used. Asking it on a line
# that turned out to carry no instance would consume a pragma that waived
# nothing, and the unused-pragma error the library owes for that pragma would
# never fire. The order matters for the same reason: a line inside a fixture
# region or inside a run-only helper carries no instance to waive, so a pragma
# over it is genuinely unused and must not be marked.
function report(line_number, assignment_line) {
  if (gaia_scan_skip()) return
  if (gaia_scan_run_only()) return
  if (gaia_scan_suppressed("lint-errexit-status-read")) return
  printf "%s:%d: `$?` read after the command-substitution assignment at line %d, with errexit armed: the assignment takes the substitution status, so a failure exits there and this line and every branch it feeds are dead\n", file, line_number, assignment_line
}

# pragma_offsurface(line_number): the honored-nowhere finding, emitted from the scan rule
# rather than from report() above.
#
# Read at the print point it would be silently inert over every pragma sitting
# above a CLEAN line, which is most of them: report() only runs where there is a
# hit. A pragma on a surface where nothing can consume it is the finding whether
# or not its target carries an instance, so it is answered per line.
function pragma_offsurface(line_number) {
  if (gaia_scan_pragma_here("lint-errexit-status-read"))
    printf "%s:%d: gaia-lint-ignore is honored only in *.bats; this pragma waives nothing here\n", file, line_number
}

# feed(line, line_number): run one line of shell through the detector.
function feed(line, line_number,   stripped, terminator_candidate, tail) {
  # An open heredoc swallows whole lines until its terminator: the body is data,
  # so nothing in it arms, disarms, or classifies. The terminator comparison
  # tolerates trailing whitespace deliberately. Bash does not, but the two
  # failure directions are not symmetric: ending a heredoc one line early costs
  # a few lines read as shell that were not, while never ending one swallows
  # every remaining line of the file and reports clean over all of them.
  if (W_heredoc != "") {
    terminator_candidate = line
    if (W_heredoc_tabs) sub(/^\t+/, "", terminator_candidate)
    sub(/[ \t]+$/, "", terminator_candidate)
    if (terminator_candidate == W_heredoc) W_heredoc = ""
    return
  }

  # A line can hold several statements. The loop walks them one at a time,
  # re-entering at each top-level `;` with the remainder, so an assignment and
  # the status read that follows it are seen the same way whether they sit on
  # two lines or one.
  while (1) {
  if (continued == 0) {
    stripped = line
    sub(/^[ \t]+/, "", stripped)

    # A blank or comment-only line executes nothing, so it neither breaks the
    # association between an assignment and the status read that follows it nor
    # changes the errexit state. That is what makes an intervening comment --
    # usually the one explaining what the dead branch is for -- still a hit.
    if (stripped == "" || substr(stripped, 1, 1) == "#") return

    if (stripped ~ /^set[ \t]/) arm(stripped)

    if (pending) {
      if (has_status_read(line)) report(line_number, pending_line)
      pending = 0
    }

    # A NAME (optionally subscripted) directly followed by `=`. A `local`/
    # `export`/`declare`/`readonly`/`typeset` prefix fails this test by
    # construction, which is the exclusion the header describes. Whether the
    # VALUE is a command substitution is walk()`s answer rather than a second
    # regex here, so `$((` arithmetic is told apart from `$(` by the same state
    # machine that has to tell them apart anyway.
    isname = (stripped ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/)
    candidate_line = line_number
    statement_operator = 0
    statement_substitution = 0
    statement_substitution_count = 0
    statement_space_offset = -1
  }

  if (walk(line)) {
    if (W_operator) statement_operator = 1
    if (W_substitution) statement_substitution = 1
    statement_substitution_count += W_substitution_count
    if (statement_space_offset == -1) statement_space_offset = W_space_offset
    continued = 1
    return
  }
  if (W_operator) statement_operator = 1
  if (W_substitution) statement_substitution = 1
  statement_substitution_count += W_substitution_count
  # Only the statement`s FIRST line contributes the word break. A continued
  # statement`s later lines have their own leading whitespace, which belongs to
  # no first word, so reading one would exempt a real defect. That a continued
  # statement is therefore never env-prefix-tested is the bound the header names.
  if (statement_space_offset == -1) statement_space_offset = W_space_offset
  continued = 0
  # An ENV-PREFIX assignment (`FOO=$(cmd) run_thing`) is not this class: the
  # status the shell takes is the prefixed COMMAND, so a failing substitution in
  # the prefix does not trip errexit at all (`set -e; FOO=$(false) echo hi` runs
  # and survives). Reported anyway it would be a wrong verdict carrying a repair
  # that makes no sense, which is the direction that gets a gate bypassed rather
  # than obeyed. Detect it from the tokenizer own record of the first top-level
  # whitespace: whatever follows is another word of the same simple command. A
  # further ASSIGNMENT or a REDIRECTION there is another prefix word of the same
  # simple command, so both are consumed and the search continues behind them.
  # Bounded to a statement that ends on its own line, since W_space_offset indexes
  # into that line.
  if (isname && statement_space_offset > 0) {
    tail = substr(line, statement_space_offset)
    sub(/^[ \t]+/, "", tail)
    # One loop over the whole prefix, rather than a test that inspects the first
    # token and stops. The shell accepts an arbitrary run of assignments and
    # redirections here, in any order, before the command word; a single-token
    # test stops at the first of them and reports a line the shell runs, with a
    # printed repair that cannot be applied to an env prefix at all. Four defects
    # landed on the single-token form across four review rounds, every one of
    # them a shape the previous widening had not enumerated, so the shape of the
    # test is what changed rather than its list.
    #
    # Two operators need the pattern rather than the loop. `>&` is consumed
    # whole, or the leftover `&` reads as a control operator and terminates the
    # walk one token early; `&>` and `&>>` are matched by their own alternative,
    # since their leading `&` matches no part of `[0-9]*[<>]`. walk() already
    # tells all three apart from a control-operator `&` by their neighbours, so
    # the two readings agree.
    #
    # `[0-9]*` rather than a bare `[<>]`: a redirection may carry an explicit
    # file descriptor (`2> log`, `2>&1`), and reading the digit as the first
    # letter of a command word is what made `out=$(cmd) 2> log` exempt itself
    # while the identical `> log` was reported.
    #
    # Each pass removes at least one character before eat_word() runs, so the
    # loop always terminates.
    while (1) {
      if (tail ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/) {
        sub(/^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/, "", tail)
      } else if (tail ~ /^(&>>?|[0-9]*[<>][>&|]?)/) {
        if (substr(tail, 1, 1) == "&") sub(/^&>>?/, "", tail)
        else sub(/^[0-9]*[<>][>&|]?/, "", tail)
        sub(/^[ \t]+/, "", tail)
      } else break
      tail = eat_word(tail)
      sub(/^[ \t]+/, "", tail)
    }
    # Whatever the prefix left. A COMMAND WORD means the shell takes that
    # command`s status and the assignment cannot trip errexit, so the statement
    # is exempt. NOTHING left means the assignment stands alone behind its
    # prefix and its own status is what the shell takes (`out=$(false) > log`
    # exits), which is the class; a statement separator or a comment is read the
    # same way, since neither is a command word of this statement.
    if (tail != "" && index(";|&#()", substr(tail, 1, 1)) == 0)
      isname = 0
  }
  # `statement_substitution_count < 2` is the last-substitution-wins term, and it states this
  # gate`s scoping exactly: report only where the substitution the gate FLAGS is
  # the one whose status the shell takes. With one, the flagged substitution IS
  # the last one, so the message printed below names the right command and the
  # repair is built around it. With two or more the status belongs to a later
  # one this walk holds no record of, and the same message names the wrong
  # command.
  #
  # Neither verdict is a statement of fact, because whether the last
  # substitution fails is a runtime question: reporting one substitution can
  # name a line the shell reaches, and exempting two can miss one it does not.
  # The split is drawn where the gate`s own message stops being true, which is
  # where the env-prefix exclusion above draws it too. The header`s undecidable
  # family names what the exemption misses.
  if (isname && statement_substitution && !statement_operator && armed && statement_substitution_count < 2) { pending = 1; pending_line = candidate_line }
  isname = 0

  # The walk stopped at a `;` with text after it: that text is the next
  # statement, and it shrinks by at least one character each time round, so the
  # loop always terminates.
  if (W_stop > 0 && W_stop <= length(line)) { line = substr(line, W_stop); continue }
  return
  }
}
'
