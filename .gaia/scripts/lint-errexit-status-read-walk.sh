#!/usr/bin/env bash
# SC2016 is intentional file-wide, for the reason lint-errexit-status-read.sh
# gives: the awk program below reaches awk as literal program text. SC2034
# too: the string it assigns is read by that script, never here.
# shellcheck disable=SC2016,SC2034
#
# The tokenizer half of lint-errexit-status-read.sh's shared detector: the
# quote, substitution and heredoc state walk. Sourced only by that script,
# which joins this program to lint-errexit-status-read-detect.sh's in that
# order, with no separator, into CORE_AWK; assigns that one string and does no
# other work at source time.
CORE_AWK_WALKER='
# Tokenizer state, carried ACROSS lines so a command substitution, a quoted
# string, or a heredoc body spanning several lines is followed rather than
# guessed at:
#   W_quote_state       the open quote character, "" outside quotes, and the sentinel "A"
#             inside an ANSI-C `$\047...\047` literal, which is not a quote
#             character of its own but is a frame with its own escape rules
#   W_quote_stack  the quote state to restore as each nesting level closes
#   W_depth   open `$(` / `(` nesting depth
#   W_in_backtick    1 inside a legacy backtick substitution
#   W_heredoc the delimiter of an open heredoc, "" when none
#   W_heredoc_tabs 1 when that heredoc was opened with `<<-`, which strips tabs
#   W_operator      set by walk() when an unquoted control operator is seen at depth 0
#   W_stop    offset just past a top-level `;`, so the caller can resume there
#   W_substitution     set by walk() when the line opens a real command substitution
#   W_substitution_count    how many TOP-LEVEL command substitutions the line opened, which
#             is a different question from whether it opened any. An
#             assignment-only statement takes the status of the LAST
#             substitution it ran, so with two or more, the one this gate flags,
#             the first, is not the one whose status the shell takes. Where the
#             second one SITS does not enter it: `out="$(a)$(b)"` and
#             `out=$(a) FOO=$(b)` are one statement to the shell, both reaching
#             the next line with `rc=0` when the last substitution succeeds, so
#             a word boundary is not a distinction this count may draw. The
#             depth-0 test excludes exactly the two kinds that cannot be the
#             last one this statement ran: a NESTED substitution, which
#             completes before the one containing it, and one inside a
#             process-substitution operand, which runs in an async subshell.
#
# Quoting is tracked INSIDE a substitution with the same machinery as outside
# it. Skipping the region and counting bare parentheses is the cheaper reading
# and it is wrong in the one direction that matters: a `)` inside a quoted
# string closes the region early, the walk resumes mid-string, and a lone
# apostrophe in the remaining literal opens a quote state that never closes.
# Because state is carried across lines, the rest of the FILE is then swallowed
# as quoted text and never classified, while this gate still prints `clean`.
# `.claude/hooks/lib/git-segments.sh` is the exemplar, where a `sed -E` pattern
# carries a `)` inside a bracket expression. No count is given: how many files
# reach the shape depends entirely on which counterfactual is measured, and three
# defensible readings give three different answers, so a number here would read
# as a measurement while naming none. The desync guard below is the second half of the answer: even a
# correct tokenizer has bounds, and a gate that cannot read a file has to say so
# rather than certify it.
#
# walk(line): advance the state across one line and return 1 when the statement
# continues onto the next one.
function walk(line,   line_length, i, character, j, delimiter_opener, delimiter, previous_character, next_character) {
  W_operator = 0
  W_stop = 0
  W_substitution = 0
  W_substitution_count = 0
  W_space_offset = 0
  W_word = 0
  line_length = length(line)
  for (i = 1; i <= line_length; i++) {
    character = substr(line, i, 1)

    # Where the first word of this statement ends, recorded only while the walk
    # is at a clean top level so whitespace inside a quoted string or a
    # substitution never counts. feed() reads it to tell an env-prefix apart from
    # a bare assignment.
    #
    # The `W_word` term is what makes it the FIRST WORD`s end rather than the
    # first whitespace on the line. Without it the latch fires on leading
    # indentation, `tail` becomes the whole statement, and since a statement that
    # got this far starts with `NAME=`, the exclusion sees an assignment and
    # skips itself. That is inert in the one direction nobody notices: every line
    # of a YAML `run:` body carries indentation, and that surface is the one
    # armed by DEFAULT, so the exclusion was dead across every workflow,
    # or composite action, plus any shell inside a function or
    # a loop.
    if (W_depth == 0 && W_quote_state == "" && !W_in_backtick) {
      if (character == " " || character == "\t") {
        if (W_word && W_space_offset == 0) W_space_offset = i
      } else {
        W_word = 1
      }
    }

    # ANSI-C quoting, the dollar-prefixed single-quote form, gets a frame of its
    # own (`W_quote_state == "A"`) because a backslash ESCAPES inside it. Read as an
    # ordinary single-quoted span, a literal carrying an escaped quote closes at
    # that quote and reopens at the real terminator, so the quote state is
    # inverted for the REST OF THE FILE through the carry above and every
    # remaining line goes unclassified. This arm and the opener below are the
    # same two decisions guard-awk-lib.sh states in its own header, deliberately
    # so: two tokenizers reading the same bytes differently is worse than either
    # bound.
    if (W_quote_state == "A") {
      if (character == "\\") { if (i == line_length) return 1; i++; continue }
      if (character == "\047") W_quote_state = ""
      continue
    }
    # Single quotes make every byte literal, backslash included, so this test
    # comes before the escape handling below.
    if (W_quote_state == "\047") { if (character == "\047") W_quote_state = ""; continue }

    if (character == "\\") {
      if (i == line_length) return 1
      i++
      continue
    }

    if (W_in_backtick) { if (character == "`") W_in_backtick = 0; continue }

    # A substitution opens from inside double quotes too, which is the ordinary
    # spelling of the very shape this gate matches (`out="$(cmd)"`). The saved
    # quote state is what returns the walk to the string when it closes.
    #
    # The ANSI-C opener comes first, because `$\047` is neither of the two
    # shapes below. It opens only from the UNQUOTED state and only on a `$` this
    # walk actually reached: an escaped `$` was consumed by the escape arm above,
    # a `$` inside single quotes never reaches here at all (so the quote after it
    # CLOSES that span rather than opening a frame), and inside double quotes
    # bash does not expand ANSI-C quoting, so `W_quote_state == ""` is the whole test.
    if (character == "$" && W_quote_state == "" && substr(line, i + 1, 1) == "\047") {
      W_quote_state = "A"
      i++
      continue
    }
    if (character == "$" && substr(line, i + 1, 1) == "(") {
      W_quote_stack[W_depth] = W_quote_state
      W_depth++
      W_quote_state = ""
      i++
      # `$((` is ARITHMETIC EXPANSION, not a command substitution. It runs no
      # command, so it cannot carry a non-zero status into the assignment and
      # errexit never fires on it; a `rc=$?` after `x=$((1 + 2))` is reachable
      # and simply always reads zero, which is a different thing from dead code
      # and would earn a message and a repair that make no sense. Consume the
      # second paren as its own level so the closing `))` balances by
      # construction rather than by coincidence, and leave W_substitution unset.
      if (substr(line, i + 1, 1) == "(") {
        W_quote_stack[W_depth] = ""
        W_depth++
        W_arithmetic_levels[W_depth] = 1
        W_arithmetic_count++
        i++
      } else {
        W_substitution = 1
        # Depth is already incremented, so 1 is this statement`s top level.
        if (W_depth == 1) W_substitution_count++
      }
      continue
    }
    if (character == "`") { W_in_backtick = 1; W_substitution = 1; if (W_depth == 0) W_substitution_count++; continue }

    if (W_quote_state == "\"") { if (character == "\"") W_quote_state = ""; continue }

    if (character == "\047") { W_quote_state = "\047"; continue }
    if (character == "\"")   { W_quote_state = "\"";   continue }

    # A heredoc body is DATA the shell hands to a command, not shell it runs, so
    # it is swallowed rather than read. Without this the body of a fixture a
    # test script writes is classified as executed code: a `set +e` in there
    # disarms the detector for the rest of the real script, an apostrophe blanks
    # the rest of the file through the carry above, and a body deliberately
    # carrying the defect is reported as one. That is the same fixture-versus-
    # executed-line argument the header makes for excluding `*.bats` and `*.md`,
    # and `*.sh` is scanned, so it has to be answered here rather than by
    # dropping the surface.
    #
    # This runs at ANY substitution depth, above the depth guard below, because
    # a heredoc body occupies lines of this file no matter what opened it.
    # `AUDIT_GLOBAL_RULES_PATHS="$(cat <<\047EOF\047` is the live shape here:
    # gated at depth zero the body is read as shell inside the substitution, so
    # a lone apostrophe in that body opens a quote that never closes and the
    # rest of the file goes unclassified. Skipped inside `$(( ))`, where `<<` is a left shift rather
    # than a redirection.
    if (character == "<" && substr(line, i + 1, 1) == "<" && W_arithmetic_count == 0) {
      # `<<<` is a herestring: its operand is a word on this same line, not a
      # body on the lines below.
      if (substr(line, i + 2, 1) == "<") { i += 2; continue }
      j = i + 2
      W_heredoc_tabs = 0
      if (substr(line, j, 1) == "-") { W_heredoc_tabs = 1; j++ }
      while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
      delimiter = ""
      delimiter_opener = substr(line, j, 1)
      # A quoted delimiter (`<<'"'"'EOF'"'"'`) suppresses expansion in the body; either
      # spelling names the same terminator.
      if (delimiter_opener == "\047" || delimiter_opener == "\"") {
        j++
        while (j <= line_length && substr(line, j, 1) != delimiter_opener) { delimiter = delimiter substr(line, j, 1); j++ }
        j++
      } else {
        while (j <= line_length && substr(line, j, 1) ~ /[A-Za-z0-9_.\/-]/) { delimiter = delimiter substr(line, j, 1); j++ }
      }
      if (delimiter != "") W_heredoc = delimiter
      i = j - 1
      continue
    }

    # A PROCESS SUBSTITUTION operand (`>(cmd)`, `<(cmd)`) is a nested command, so
    # its body is a region exactly as `$(` opens one. Left unrecognised, a `$(`
    # inside that body reads as one of THIS statement`s own top-level
    # substitutions and the count above exempts a live defect: the body runs in
    # an async subshell and never supplies the parent statement`s status, so
    # `out=$(false) > >(echo "$(true)")` still exits on the assignment. W_substitution is
    # deliberately left unset, since the operand is not a substitution of this
    # statement. Reached only with W_quote_state empty and outside a backtick, both quote
    # arms above having already continued, and only at depth 0, which is the
    # only place an operand of THIS statement can begin.
    # The bare `(( ))` arithmetic COMMAND, the sibling of the `$(( ))` form
    # above: `<<` inside it is a left shift, not a redirection, and without this
    # the digits of `(( n = n << 3 ))` read as a heredoc delimiter and the rest
    # of the file is skipped as body. Two levels, the same way `$((` pushes two,
    # so the closing `))` balances by construction. Command position is what
    # separates it from a `(` inside an operand, and `for` belongs in the
    # keyword list because the C-style `for (( ... ))` header is the arithmetic
    # spelling with live sites in this tree.
    if (W_depth == 0 && character == "(" && substr(line, i + 1, 1) == "(" \
        && (substr(line, 1, i - 1) ~ /(^|[;&|(){}[:space:]])(if|while|until|then|else|elif|do|for)[[:space:]]+$/ \
            || substr(line, 1, i - 1) ~ /(^|[;&|(){}])[[:space:]]*$/)) {
      W_quote_stack[W_depth] = W_quote_state
      W_depth++
      W_quote_stack[W_depth] = ""
      W_depth++
      W_arithmetic_levels[W_depth] = 1
      W_arithmetic_count++
      W_quote_state = ""
      i++
      continue
    }

    if (W_depth == 0 && (character == "<" || character == ">") && substr(line, i + 1, 1) == "(") {
      W_quote_stack[W_depth] = W_quote_state
      W_depth++
      W_quote_state = ""
      i++
      continue
    }

    if (W_depth > 0) {
      if (character == "(") { W_quote_stack[W_depth] = ""; W_depth++; continue }
      if (character == ")") {
        if (W_arithmetic_levels[W_depth]) { delete W_arithmetic_levels[W_depth]; W_arithmetic_count-- }
        W_depth--
        W_quote_state = W_quote_stack[W_depth]
        continue
      }
      # Everything else inside a substitution belongs to the inner command: its
      # operators and its comments belong to it, not to the outer statement.
      # Its HEREDOCS are
      # handled above rather than here, because a heredoc body occupies lines of
      # THIS file whatever nesting opened it.
      continue
    }

    # An unquoted `#` opens a comment only at the start of a word; mid-word it is
    # an ordinary character.
    if (character == "#") {
      if (i == 1) break
      previous_character = substr(line, i - 1, 1)
      if (previous_character == " " || previous_character == "\t" || previous_character == ";" || previous_character == "&" || previous_character == "|" || previous_character == "(") break
      continue
    }
    # `;` SEPARATES two commands rather than joining them into one, so errexit
    # still fires on the first: `out=$(cmd); rc=$?` is the same defect written on
    # one line. Stop the walk there and hand the caller the offset, so the
    # remainder is classified as the statement it is.
    if (character == ";") { W_stop = i + 1; return 0 }
    # `||`, `&&`, a pipeline, and a background `&` all mean the assignment is not
    # a bare simple command whose failure kills the shell. `||` in particular is
    # what the repair this gate advertises is built from, so marking the
    # statement here is what keeps the gate from redding the tree on its own fix.
    #
    # A `&` that belongs to a REDIRECTION is none of those. `&>log`, `2>&1`, and
    # `<&3` are file-descriptor syntax on the same simple command, so the
    # assignment still stands alone and errexit still fires on it. Read as a
    # control operator they disqualify the statement and the defect goes
    # unreported. The three spellings are distinguishable by their neighbours:
    # `&` before a `>`, or after a `>` or `<`.
    if (character == "&") {
      next_character = substr(line, i + 1, 1)
      previous_character = (i > 1) ? substr(line, i - 1, 1) : ""
      if (next_character == ">" || previous_character == ">" || previous_character == "<") continue
      W_operator = 1
      continue
    }
    # A `|` that belongs to a `>|` CLOBBER redirection is not a pipeline either,
    # the same distinction the `&` test above draws for `&>`, `2>&1`, and `<&3`.
    # The assignment still stands alone on one simple command and errexit still
    # fires on it; read as a pipeline it disqualifies the statement and the
    # defect goes unreported, which is the silent direction.
    if (character == "|") {
      if (i > 1 && substr(line, i - 1, 1) == ">") continue
      W_operator = 1
      continue
    }
  }
  return (W_quote_state != "" || W_depth > 0 || W_in_backtick) ? 1 : 0
}
'
