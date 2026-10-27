#!/usr/bin/env bash
# The liveness scan's contract, constants and span helpers. Its entry point,
# gaia_verb_arm_live_view, is in verb-arming-live-view.sh.
# Sourced only by verb-arming-walk.sh, whose header states the view's
# contract; defines functions and constants and does no other work at source
# time.

# shellcheck disable=SC2154  # constants come from verb-arming-walk.sh

# ---------------------------------------------------------------------------
# The liveness scan
# ---------------------------------------------------------------------------
#
#   gaia_verb_arm_live_view <text>
#
# ASSIGNS GAIA_VERB_ARM_LIVE: <text> with the first character of every
# substitution opener the parsing shell never runs overwritten by `x`. An
# opener that arms is one the shell runs, and textually `separator_regex` in
# lib/verb-arming.sh cannot tell those apart from one cited in prose, so the
# arming decision asks this view whether its opener survived. Same length, in
# bytes and so in characters, because every overwrite is one ASCII byte for
# another.
#
# DEAD, and nothing else:
#
#   - inside a single-quoted span, wherever single quotes quote: at top level
#     and inside a substitution, never inside double quotes, where an
#     apostrophe is an ordinary character;
#   - escaped by a backslash;
#   - inside the body of a heredoc whose delimiter is quoted or escaped, read
#     by a bare `cat` or `tee` (flags allowed, nothing else) at top level or
#     directly inside `$( )`, with nothing after the delimiter on the opener
#     line and no second heredoc on it. That is the shape a pull-request,
#     issue, or commit body takes when it is passed as
#     `--body "$(cat <<'EOF' ... EOF)"`. Inside `<( )` the body is handed to
#     whatever reads the file, often an interpreter, so it stays live.
#
# The openers are the ones `separator_regex` carries; one added there needs its first
# character in _GAIA_VA_LIVE_OPENER_SET, or it is never masked, which only
# over-arms.
#
# ABSTENTION IS WHOLE-INPUT, as in the data-proof walk: an unterminated span, a
# dollar-quoted word, a `${` whose body is empty, starts with a space or `|`,
# or can nest, quote or run a command, a `)` in a context that holds the word
# `case` (a case arm's bare `)` would close the
# substitution early and desync every quote after it), a backslash before `$`,
# a backtick, or a backslash anywhere under backticks (the shell strips it
# before parsing the inner command, so the escape is gone), a backtick under
# backticks inside quotes, a comment, a heredoc body, or a nested substitution
# (bash closes the outer backquote there, zsh does not), a `#` straight after
# a subshell's `)` (a comment there, where after a substitution's `)` it
# continues the word), a `<<` inside parentheses (an arithmetic shift, or a
# heredoc feeding a subshell's output), a body inside `$( )` whose
# substitution bash 3.2's heredoc-blind paren matcher could close before the
# body ends (_gaia_va_b32_body_safe, read from each enclosing `$(`), a heredoc
# the text never closes, and running out of the re-reading budget all leave
# every opener live. Abstaining over-arms, which is today's answer; a wrong
# mask under-arms, which lets a merge past a gate.
#
# WHAT THIS DOES NOT CLOSE. The body of a quoted-delimiter heredoc read by
# `cat` is data to `cat`, not to whatever later executes the text cat
# produced: `eval`, `bash -c`, a pipe or here-string into an interpreter, or
# a file later sourced all run an opener in the body that this scan masks,
# the same nested-interpreter under-arm a quoted verb already has, and so
# does a `cat` or `tee` redefined earlier in the call (a function, an alias,
# a PATH entry), since the scan reads the name, not what it resolves to. Openers the shell never runs inside
# double quotes (`<(`, `>(`) stay live, as do openers in comments.

# Top level and inside a substitution: both quotes, a backslash, a backtick, a
# `$`, both parentheses, the first characters of the process-substitution
# openers, a `#`, the list operators, and a newline.
_GAIA_VA_LIVE_TOP_SET=$'["\047\\\\\140$()<>=#;&|\n]'
# Inside double quotes: the closing quote, a backslash, a backtick and a `$`.
_GAIA_VA_LIVE_DOUBLE_QUOTE_SET=$'["\\\\\140$]'
# The first characters an opener can begin with.
_GAIA_VA_LIVE_OPENER_SET=$'[\140$<>=]'
_GAIA_VA_LIVE_CASE_REGEX='(^|[^A-Za-z0-9_])case([^A-Za-z0-9_]|$)'
_GAIA_VA_LIVE_OWNER_REGEX='^[[:space:]]*(cat|tee)([[:space:]]+-[A-Za-z]+)*[[:space:]]*$'
_GAIA_VA_BLANK_LINE_REGEX='^[[:space:]]*$'

_gaia_va_live_work=0
_gaia_va_masked=""

# _gaia_va_mask_openers <span>: set _gaia_va_masked to <span> with every
# opener's first character overwritten. Charges the shared budget and returns
# 1 when it runs out.
_gaia_va_mask_openers() {
  local rest="$1" prefix prefix_length character next_character
  _gaia_va_masked=""
  while [ -n "$rest" ]; do
    _gaia_va_live_work=$(( _gaia_va_live_work + ${#rest} ))
    [ "$_gaia_va_live_work" -le "$_GAIA_VA_MAXIMUM_WORK" ] || return 1
    # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
    prefix="${rest%%$_GAIA_VA_LIVE_OPENER_SET*}"
    prefix_length=${#prefix}
    character="${rest:$prefix_length:1}"
    if [ -z "$character" ]; then _gaia_va_masked+="$rest"; return 0; fi
    next_character="${rest:$(( prefix_length + 1 )):1}"
    _gaia_va_masked+="$prefix"
    # shellcheck disable=SC2016 # the literal openers are the patterns
    case "$character$next_character" in
      '`'*|'$('|'<('|'>(') _gaia_va_masked+=x ;;
      *) _gaia_va_masked+="$character" ;;
    esac
    rest="${rest:$(( prefix_length + 1 ))}"
  done
  return 0
}

# What bash 3.2's matcher stops on inside `$( )`: both quotes, a backtick, a
# backslash and both parentheses.
_GAIA_VA_B32_SET=$'["\047\140\\\\()]'

# _gaia_va_b32_body_safe <region> <after>: <region> runs from just past a
# `$(` through the end of a heredoc body inside it. 0 when bash 3.2 would
# read all of it as part of that substitution, 1 when it may close the
# substitution first. bash 3.2 finds that `)` with a paren-and-quote matcher
# that knows nothing of heredocs or comments, so an unmatched `)` anywhere in
# the region, counted outside quotes, ends the substitution there and
# everything after it runs as live text. A quote the region leaves open is safe only when
# nothing in <after> can close it: the matcher then reaches the end of the
# text, which is a syntax error, so nothing runs. A double-quoted or
# backticked span that nests anything, and a dollar-quoted span, are not
# modelled. Charges the shared
# budget.
_gaia_va_b32_body_safe() {
  local rest="$1" after="$2" prefix prefix_length character span depth=0
  while [ -n "$rest" ]; do
    _gaia_va_live_work=$(( _gaia_va_live_work + ${#rest} ))
    [ "$_gaia_va_live_work" -le "$_GAIA_VA_MAXIMUM_WORK" ] || return 1
    # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
    prefix="${rest%%$_GAIA_VA_B32_SET*}"
    prefix_length=${#prefix}
    character="${rest:$prefix_length:1}"
    [ -n "$character" ] || break
    rest="${rest:$(( prefix_length + 1 ))}"
    case "$character" in
      '(') depth=$(( depth + 1 )) ;;
      ')')
        depth=$(( depth - 1 ))
        [ "$depth" -ge 0 ] || return 1
        ;;
      "$_GAIA_VA_BACKSLASH") rest="${rest:1}" ;;
      *)
        case "$rest" in
          *"$character"*) ;;
          *)
            case "$after" in *"$character"*) return 1 ;; esac
            return 0
            ;;
        esac
        # A `$'` span honours backslash escapes, so its end is not the next
        # apostrophe. An escaped `$` was consumed above and never reaches
        # here.
        case "$character$prefix" in "'"*'$') return 1 ;; esac
        span="${rest%%"$character"*}"
        if [ "$character" != "'" ]; then
          case "$span" in *'$'*|*'`'*|*"$_GAIA_VA_BACKSLASH"*) return 1 ;; esac
        fi
        rest="${rest:$(( ${#span} + 1 ))}"
        ;;
    esac
  done
  [ "$depth" -eq 0 ]
}
