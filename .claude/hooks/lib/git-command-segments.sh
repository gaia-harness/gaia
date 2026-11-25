#!/usr/bin/env bash
# The command-structure walker classify-git-command.sh reads. Defines patterns
# and functions and does no work at source time. LC_ALL=C is the caller's:
# byte indexing keeps the walk linear in a long commit message.

# split_command_segments <text>: put each simple command of <text> in the array
# `segments`, or return 1 when the text carries anything but simple commands
# joined by a list operator or a pipe. A character walk rather than a pattern,
# because a separator or an expansion inside single quotes is text and outside
# them is shell, and a commit subject routinely carries `;`, `(` or `&` in
# quotes. Each pipe stage is its own segment; the caller vouches for every one.
#
# Inside double quotes `$` and a backtick still expand, so `$` is read there
# too and a backtick falls through. A backslash falls through wherever the shell reads it, because the word
# parser and the shell disagree on what it escapes inside double quotes. A
# brace list (`{a,b}`, `{1..3}`) expands to several words the parser reads as
# one, so an unquoted `{` whose span to the next `}` holds `,` or `..` falls
# through; `@{u}` and `HEAD^{tree}` hold neither and do not expand.
#
# The only expansions read are `$?`, kept as written since it expands to a
# number, and a reference to a variable whose latest assignment, in an earlier
# segment, is a literal outside a pipe and before any `&&`, `||` or pipe
# (expand_parameter_reference below). A quoted heredoc is dropped from its
# segment, the body unread; segment_heredocs marks
# each segment that read one.
# `assignment_names` and `assignment_values` hold the literal assignments read
# so far, and the caller judges whether each assignment segment may run.
heredoc_pattern=$'^<<[[:space:]]*([\'"])([A-Za-z_][A-Za-z0-9_]*)([\'"])[[:space:]]*\n'
literal_assignment_pattern='^([A-Za-z_][A-Za-z0-9_]*)=([A-Za-z0-9_./:@%+,-]+)$'
double_quoted_assignment_pattern='^([A-Za-z_][A-Za-z0-9_]*)="([A-Za-z0-9_./:@%+,-]+)"$'
single_quoted_assignment_pattern="^([A-Za-z_][A-Za-z0-9_]*)='([A-Za-z0-9_./:@%+,-]+)'$"

# finish_segment <text> <operator>: append one segment, record it when it is a
# literal assignment that always runs, then note the operator that ends it. An
# assignment counts only while every operator before it is `;` or a newline:
# after `&&` or `||` it may not run, and in a pipe stage it runs in a subshell,
# so a later reference would expand to something this walk never read. Such an
# assignment is recorded with an empty value, which no literal pattern matches,
# so the name stays unreadable even after an earlier always-run assignment of
# it. Reads and sets the caller's locals by bash's dynamic scope.
finish_segment() {
  local text="$1" trimmed
  segments+=("$text")
  segment_heredocs+=("$heredoc"); heredoc=0
  trimmed="${text#"${text%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  if [[ "$trimmed" =~ $literal_assignment_pattern ]] \
       || [[ "$trimmed" =~ $double_quoted_assignment_pattern ]] \
       || [[ "$trimmed" =~ $single_quoted_assignment_pattern ]]; then
    assignment_names+=("${BASH_REMATCH[1]}")
    if [ "$unconditional" -eq 1 ] && [ "$2" != '|' ]; then
      assignment_values+=("${BASH_REMATCH[2]}")
    else
      assignment_values+=("")
    fi
  fi
  case "$2" in ';') ;; *) unconditional=0 ;; esac
}

# expand_parameter_reference <text> <index>: read the `$` reference at <index>.
# Sets parameter_value to the text it stands for and parameter_length to how
# much of <text> it spans, or returns 1 for any reference this walk cannot
# read. The latest assignment of a name wins, as it does in the shell. The Bash
# tool may run zsh, where a bare `$NAME` followed by `[` subscripts and by `:`
# applies a modifier (`$R:h` is its directory), so a bare reference followed
# by either falls through; `${NAME}` ends at its brace in both shells.
expand_parameter_reference() {
  local rest="${1:$2:80}" name position following
  case "$rest" in
    '$?'*) parameter_value='$?'; parameter_length=2; return 0 ;;
  esac
  if [[ "$rest" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then
    name="${BASH_REMATCH[1]}"; parameter_length=${#BASH_REMATCH[0]}
  elif [[ "$rest" =~ ^\$([A-Za-z_][A-Za-z0-9_]*) ]]; then
    name="${BASH_REMATCH[1]}"; parameter_length=${#BASH_REMATCH[0]}
    following="${rest:$parameter_length:1}"
    case "$following" in '[' | ':') return 1 ;; esac
  else
    return 1
  fi
  position=${#assignment_names[@]}
  while [ "$position" -gt 0 ]; do
    position=$((position - 1))
    if [ "${assignment_names[$position]}" = "$name" ]; then
      parameter_value="${assignment_values[$position]}"
      [ -n "$parameter_value" ]
      return
    fi
  done
  return 1
}

split_command_segments() {
  local text="$1" length index=0 copy_from=0 character next quote="" segment="" lookahead token span
  local rest delimiter body heredoc=0 unconditional=1 newline=$'\n' parameter_value parameter_length
  length=${#text}
  segments=()
  segment_heredocs=()
  assignment_names=()
  assignment_values=()
  while [ "$index" -lt "$length" ]; do
    character="${text:$index:1}"
    if [ "$quote" = "'" ]; then
      [ "$character" = "'" ] && quote=""
      index=$((index + 1)); continue
    fi
    case "$character" in
      '`' | \\) return 1 ;;
      '$')
        expand_parameter_reference "$text" "$index" || return 1
        segment="$segment${text:$copy_from:$((index - copy_from))}$parameter_value"
        index=$((index + parameter_length)); copy_from=$index; continue ;;
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
              "$token" | "$token"[[:space:]\;\|]* | "$token&&"*)
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
        finish_segment "$segment${text:$copy_from:$((index - copy_from))}" ';'
        segment=""; index=$((index + 1)); copy_from=$index; continue ;;
      '|')
        if [ "$next" = '|' ]; then
          finish_segment "$segment${text:$copy_from:$((index - copy_from))}" '||'
          index=$((index + 2))
        else
          finish_segment "$segment${text:$copy_from:$((index - copy_from))}" '|'
          index=$((index + 1))
        fi
        segment=""; copy_from=$index; continue ;;
      '&')
        [ "$next" = '&' ] || return 1
        finish_segment "$segment${text:$copy_from:$((index - copy_from))}" '&&'
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
  finish_segment "$segment${text:$copy_from:$((index - copy_from))}" ';'
  return 0
}
