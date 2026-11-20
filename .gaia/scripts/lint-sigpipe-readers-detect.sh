#!/usr/bin/env bash
# SC2016 is intentional file-wide, for the reason lint-sigpipe-readers.sh gives:
# the awk program below reaches awk as literal program text. SC2034 too: the
# string it assigns is read by that script, never here.
# shellcheck disable=SC2016,SC2034
#
# Sourced only by lint-sigpipe-readers.sh; assigns READER_AWK and does no other
# work at source time.

# The class detector both arms share: what makes a reader short-circuiting,
# which segment of a pipeline it heads, what arms pipefail, and where a
# pipeline carries to the next line. Concatenated ahead of one of the two mains
# in lint-sigpipe-readers.sh rather than duplicated into each, so the two arms
# cannot drift on what the class IS while disagreeing only about which files
# carry it. The sibling
# .gaia/scripts/lint-errexit-status-read.sh joins its shared detector to a
# per-surface program the same way.
#
# Single-quoted, so every literal single quote inside is spelled \047 and no
# comment in it may carry an apostrophe.
readonly READER_AWK='
# A token that turns a reader into a short-circuiting one. TWO families, and
# both belong here because the class is the short circuit rather than the flag:
#
#   the quiet family  -q and every cluster carrying it (-qF, -qxF, -qvF, -nq),
#                     plus --quiet and --silent. The cluster form is what makes
#                     a plain substring test wrong.
#   the count family  -m and --max-count. A reader told to stop after N matches
#                     closes the pipe at the Nth exactly as a quiet one closes
#                     it at the first, so the upstream takes SIGPIPE and the
#                     pipeline status inverts identically. The count rides
#                     either inside the token (-m1, -nm1) or as the next
#                     argument (-m 1), and both spellings are the same defect.
function is_short_circuit_flag(token) {
  if (token == "--quiet" || token == "--silent" || token == "--max-count") return 1
  if (token ~ /^--max-count=/) return 1
  if (token ~ /^-[A-Za-z]+$/ && token ~ /q/) return 1
  if (token ~ /^-[A-Za-z]*m[0-9]*$/) return 1
  return 0
}

# Read one pipeline SEGMENT and answer with the reader heading it, or the empty
# string. The command word is the segment head, so a -q sitting in the quoted
# argument of some other command is never read as a flag of a reader.
function segment_reader(segment,   tokens, token_count, head_index, token_index, command_word) {
  sub(/;.*$/, "", segment)
  token_count = split(segment, tokens, /[[:space:]]+/)
  head_index = 1
  # Everything a reader can hide behind and still be the command that runs.
  # The assignment arm is the one that matters most in this tree: a locale or
  # encoding prefix is the ordinary spelling here, and without it the command
  # word reads as LC_ALL=C and the segment is graded as some other command. The
  # brace and paren arms cover a downstream compound command, where the wrapper
  # rather than the reader occupies the head: a pipeline into a brace group or
  # a subshell carries the class exactly as the bare form does.
  while (head_index <= token_count && (tokens[head_index] == "" || tokens[head_index] == "!" || tokens[head_index] == "&" ||
                    tokens[head_index] == "{" || tokens[head_index] == "(" ||
                    tokens[head_index] == "command" || tokens[head_index] == "env" ||
                    tokens[head_index] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) head_index++
  if (head_index > token_count) return ""
  command_word = tokens[head_index]
  # A subshell may open with no space after the paren, so the wrapper arrives
  # fused to the command word rather than as a token of its own.
  sub(/^\(+/, "", command_word)
  sub(/^.*\//, "", command_word)
  if (command_word != "grep" && command_word != "rg") return ""
  for (token_index = head_index + 1; token_index <= token_count; token_index++)
    if (is_short_circuit_flag(tokens[token_index])) return command_word " " tokens[token_index]
  return ""
}

# The `set` spellings that arm pipefail, as ONE string every reader shares: the
# arming test below that answers WHETHER a line arms it, and the locator inside
# that test that answers WHERE, so it can ask whether the occurrence sits inside
# a command substitution. Two copies with different trailing boundaries would
# let the predicate match one occurrence while the locator found an earlier one,
# and the depth test would then answer about a position the predicate never
# accepted, reading an armed block as unarmed. That is a false negative, the one
# direction this gate must not be wrong in, which is why the pattern is bound
# once rather than written twice.
#
# The option run before the -o that carries pipefail is optional and unbounded,
# and it admits both spellings a set line uses: a short flag cluster, and a
# long-form -o followed by its option NAME. So set -o pipefail, set -euo
# pipefail, set -e -o pipefail and set -o errexit -o pipefail all arm it. The
# bare option name is admitted only directly after a flag token, never on its
# own: set stops parsing options at its first non-option word, so
# set a b -o pipefail arms nothing and must not read as if it did.
#
# The trailing boundary admits a SEMICOLON alongside whitespace and end-of-line,
# so the one-line set -euo pipefail; cmd spelling arms what it really arms. What
# holds the substitution-scoped changed=$(set -o pipefail; ...) idiom back from
# arming the file or block around it is the depth test in arms_at_depth_zero
# below, and nothing else. A boundary narrow enough to exclude that idiom is
# narrow enough to miss the one-line spelling too: it excludes by accident what
# the depth test excludes on purpose, and a reader who repairs the accident
# without the depth test already in place reopens the very gap the depth test
# closes. That is the trade gaia-react/gaia#1941 records.
BEGIN {
  PIPEFAIL_RE = "(^|[^A-Za-z0-9_])set([[:space:]]+-[A-Za-z]+([[:space:]]+[A-Za-z]+)?)*[[:space:]]+-[A-Za-z]*o[[:space:]]+pipefail([[:space:]]|;|$)"
}

# Split one line into pipeline segments and fill hit_buffer with the reader heading
# each downstream one, answering how many there were. A doubled bar is a logical
# OR, not a pipe: masking it before the split is what keeps the command after
# one from reading as a downstream segment. Segment 1 is downstream only when
# the PREVIOUS line left a pipeline open, which the caller carries in previous_line_carries_pipe.
function scan_pipeline(current_line,   masked_line, segment_count, segments, i, hit) {
  hit_count = 0
  masked_line = current_line
  gsub(/\|\|/, "\002", masked_line)
  segment_count = split(masked_line, segments, "|")
  for (i = 1; i <= segment_count; i++) {
    if (i == 1 && !previous_line_carries_pipe) continue
    hit = segment_reader(segments[i])
    if (hit != "") { hit_count++; hit_buffer[hit_count] = hit }
  }
  return hit_count
}

# Whether this line leaves a pipeline open for the next one. A trailing
# backslash after the bar is redundant in bash but legal, so it is stripped
# before the test.
function carries_pipe(current_line,   tail) {
  tail = current_line
  sub(/[[:space:]]+$/, "", tail)
  sub(/\\$/, "", tail)
  sub(/[[:space:]]+$/, "", tail)
  return (tail ~ /\|$/ && tail !~ /\|\|$/)
}

# The command-substitution nesting depth at character `upto` of `text`, starting
# from the carried-in `substitution_depth` and clamped at zero. Clamped, not merely
# bounded: the header of lint-sigpipe-readers.sh states why that direction is the safe one. Both arms carry
# `substitution_depth` from one line to the next through carry_at below, and each resets
# it where its own unit of arming begins: the workflow arm at every run: key,
# the shell arm never, since that arm is handed one file per awk invocation and
# the file IS the unit.
function depth_at(text, upto,   i, depth, character) {
  depth = substitution_depth
  for (i = 1; i < upto; i++) {
    character = substr(text, i, 1)
    if (character == "$" && substr(text, i + 1, 1) == "(") { depth++; i++ }
    else if (character == ")" && depth > 0) depth--
  }
  return depth
}

# The line with every single-quoted span removed, a quote through the next
# quote. An unterminated quote stays, with everything after it, so that tail
# counts as raw. Double-quoted text is left alone, since a `$( )` inside double
# quotes is live.
function strip_single_quoted(text,   stripped_text, open_quote_position, rest, close_quote_position) {
  stripped_text = ""
  while ((open_quote_position = index(text, "\047")) > 0) {
    rest = substr(text, open_quote_position + 1)
    close_quote_position = index(rest, "\047")
    if (close_quote_position == 0) break
    stripped_text = stripped_text substr(text, 1, open_quote_position - 1)
    text = substr(rest, close_quote_position + 1)
  }
  return stripped_text text
}

# The depth this line hands the next one: the LOWER of the raw count and the
# count over the stripped copy, both walked from the same carried-in depth. The
# stripped count alone can rise above the raw one; the header of lint-sigpipe-readers.sh states why only
# the lower of the two keeps the carry from disarming anything the raw count
# arms.
function carry_at(current_line,   raw_depth, stripped_text, stripped_depth) {
  raw_depth = depth_at(current_line, length(current_line) + 1)
  stripped_text = strip_single_quoted(current_line)
  stripped_depth = depth_at(stripped_text, length(stripped_text) + 1)
  return (stripped_depth < raw_depth) ? stripped_depth : raw_depth
}

# Whether this line arms pipefail for the file or block AROUND it, which is the
# only arming either arm asks about: an arming inside a command substitution
# belongs to that subshell and dies with it.
#
# EVERY occurrence on the line is walked, not merely the first, and that is the
# whole reason this is a loop rather than one match(). match() answers with the
# leftmost occurrence, so a line carrying a substitution-scoped arming AHEAD of
# a real one, x=$(set -o pipefail; true); set -o pipefail, would be graded on
# the leftmost, the depth test would answer 1, and a genuinely armed block would
# read as unarmed. That is the false negative gaia-react/gaia#1936 closed, and
# the only thing that kept the shipped single-match form from reopening it was a
# trailing boundary narrow enough to reject the leftmost occurrence outright:
# the same boundary gaia-react/gaia#1941 had to widen. Walking every occurrence
# is what makes the boundary and the depth test independent of each other.
#
# Each occurrence arms when EITHER the raw prefix or the single-quote-stripped
# prefix sits at depth zero, the same minimum carry_at takes at end of line,
# taken at the arming position, so the stripped read can only add arming. The
# stripped prefix INCLUDES the character at pos: the match begins at its leading
# boundary character, which in the substitution-scoped x=$(set -o pipefail; ...)
# idiom is the paren of its dollar-paren, and depth_at reads that paren only as
# the lookahead after the dollar. Cutting one character earlier drops it and
# reads the scoped arming as file-level.
function arms_at_depth_zero(current_line,   remaining_text, offset, position, stripped_prefix) {
  remaining_text = current_line
  offset = 0
  while (match(remaining_text, PIPEFAIL_RE)) {
    position = offset + RSTART
    stripped_prefix = strip_single_quoted(substr(current_line, 1, position))
    if (depth_at(current_line, position) == 0 || depth_at(stripped_prefix, length(stripped_prefix) + 1) == 0) return 1
    offset = position
    remaining_text = substr(current_line, position + 1)
  }
  return 0
}
'
