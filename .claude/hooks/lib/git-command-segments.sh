#!/usr/bin/env bash
# The command-structure walker classify-git-command.sh reads. Defines patterns
# and a function and does no work at source time. LC_ALL=C is the caller's:
# byte indexing keeps the walk linear in a long commit message.

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
#
# A filter pipe or a quoted heredoc is dropped from its segment, the heredoc
# body unread; segment_heredocs marks each segment that read one.
filter_pattern='^([[:blank:]]*(head|tail)([[:blank:]]+-(n[[:blank:]]*)?[0-9]+)?|[[:blank:]]*wc[[:blank:]]+-l)[[:blank:]]*'
heredoc_pattern=$'^<<[[:space:]]*([\'"])([A-Za-z_][A-Za-z0-9_]*)([\'"])[[:space:]]*\n'
split_command_segments() {
  local text="$1" length index=0 copy_from=0 character next quote="" segment="" lookahead token span
  local rest after delimiter body heredoc=0 newline=$'\n'
  length=${#text}
  segments=()
  segment_heredocs=()
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
        segment_heredocs+=("$heredoc"); heredoc=0
        segment=""; index=$((index + 1)); copy_from=$index; continue ;;
      '|')
        if [ "$next" != '|' ]; then
          # One filter, then only the end of the text or a list operator.
          rest="${text:$((index + 1))}"
          [[ "$rest" =~ $filter_pattern ]] || return 1
          after="${rest:${#BASH_REMATCH[0]}:2}"
          case "$after" in '' | ';'* | "$newline"* | '&&' | '||') ;; *) return 1 ;; esac
          segment="$segment${text:$copy_from:$((index - copy_from))} "
          index=$((index + 1 + ${#BASH_REMATCH[0]})); copy_from=$index; continue
        fi
        segments+=("$segment${text:$copy_from:$((index - copy_from))}")
        segment_heredocs+=("$heredoc"); heredoc=0
        segment=""; index=$((index + 2)); copy_from=$index; continue ;;
      '&')
        [ "$next" = '&' ] || return 1
        segments+=("$segment${text:$copy_from:$((index - copy_from))}")
        segment_heredocs+=("$heredoc"); heredoc=0
        segment=""; index=$((index + 2)); copy_from=$index; continue ;;
      '<')
        # The header line ends at the delimiter; the body runs to the first
        # line that is exactly the delimiter, or the text falls through.
        rest="${text:$index}"
        [[ "$rest" =~ $heredoc_pattern ]] || return 1
        [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[3]}" ] || return 1
        delimiter="${BASH_REMATCH[2]}"
        rest="${rest:${#BASH_REMATCH[0]}}$newline"
        case "$rest" in
          "$delimiter$newline"*) body="" ;;
          *"$newline$delimiter$newline"*) body="${rest%%"$newline$delimiter$newline"*}$newline" ;;
          *) return 1 ;;
        esac
        segment="$segment${text:$copy_from:$((index - copy_from))} "
        index=$((index + ${#BASH_REMATCH[0]} + ${#body} + ${#delimiter})); copy_from=$index
        heredoc=1; continue ;;
      '>' | '(' | ')' | '*' | '?' | '[' | '#') return 1 ;;
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
  segment_heredocs+=("$heredoc")
  return 0
}
