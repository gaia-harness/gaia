#!/usr/bin/env bash
# The data-proof walk behind the shared verb-arming decision: the heredoc
# view, gaia_verb_arm_view.
# Sourced only by verb-arming-walk.sh, whose header states the view's
# contract; defines functions and constants and does no other work at source
# time.

# shellcheck disable=SC2154  # constants and helpers come from verb-arming-walk.sh

gaia_verb_arm_view() {
  local text="$1"
  GAIA_VERB_ARM_VIEW="$text"
  [ "${#text}" -le "${GAIA_VERB_ARM_MAXIMUM_CHARACTERS:-16384}" ] || return 0
  # No heredoc operator anywhere means no body can be proven data, and this is
  # the shape most raw-matching traffic takes, so it never pays for the walk.
  case "$text" in
    *'<<'*) ;;
    *) return 0 ;;
  esac

  local newline=$'\n'
  local remaining_text view_text opener_line quote_character character prefix prefix_length chunk blanks ok word_start work line_start
  local heredoc_count strip_tabs delimiter delimiter_unreadable delimiter_quoted data first delimiter_offset body delimiter_line body_index heredoc_prefix
  local heredoc_delimiters heredoc_strip_tabs heredoc_quoted
  heredoc_delimiters=()
  heredoc_strip_tabs=()
  heredoc_quoted=()

  _gaia_va_locale_bytes
  remaining_text="$text"
  view_text=""
  quote_character=""
  ok=1
  word_start=1
  work=0
  line_start=0
  heredoc_count=0
  heredoc_prefix=""

  while [ -n "$remaining_text" ]; do
    # Charge this step what it is about to cost, and abandon suppression on
    # running out, exactly as the walk does on anything else it cannot decide
    # cheaply.
    work=$(( work + ${#remaining_text} ))
    if [ "$work" -gt "$_GAIA_VA_MAXIMUM_WORK" ]; then ok=0; break; fi

    if [ -n "$quote_character" ]; then
      # Inside a quoted span, jump to what can end it. A single-quoted span and
      # a backtick span end only at their own delimiter; a double-quoted span
      # also has to honour the backslash, which escapes the character after it
      # there.
      if [ "$quote_character" = '"' ]; then
        # The set is a bracket expression, so it has to reach the matcher
        # UNQUOTED; quoting it would compare the brackets themselves.
        # shellcheck disable=SC2295
        prefix="${remaining_text%%$_GAIA_VA_DOUBLE_QUOTE_SET*}"
      else
        prefix="${remaining_text%%"$quote_character"*}"
      fi
      prefix_length=${#prefix}
      character="${remaining_text:$prefix_length:1}"
      # An empty character here means the strip found nothing, so the span runs
      # to the end of the text without closing.
      if [ -z "$character" ]; then ok=0; break; fi
      view_text+="$prefix$character"
      remaining_text="${remaining_text:$(( prefix_length + 1 ))}"
      if [ "$character" = "$_GAIA_VA_BACKSLASH" ]; then
        [ -n "$remaining_text" ] || { ok=0; break; }
        view_text+="${remaining_text:0:1}"
        remaining_text="${remaining_text:1}"
      else
        quote_character=""
      fi
      continue
    fi

    # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
    prefix="${remaining_text%%$_GAIA_VA_TOP_SET*}"
    # Every expansion of the remaining text costs a pass over the whole of it,
    # so the strip's length is taken once and reused. Reading the character at
    # that offset also answers whether the strip found anything: past the end
    # of the text the slice is empty, which no real match can be.
    prefix_length=${#prefix}
    character="${remaining_text:$prefix_length:1}"
    if [ -z "$character" ]; then
      view_text+="$prefix"
      remaining_text=""
      break
    fi
    view_text+="$prefix"
    remaining_text="${remaining_text:$prefix_length}"
    case "$prefix" in
      '') ;;
      *$_GAIA_VA_WORD_SET) word_start=1 ;;
      *) word_start=0 ;;
    esac

    case "$character" in
      "'"|'"'|'`')
        quote_character="$character"
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        word_start=0
        ;;
      "$_GAIA_VA_BACKSLASH")
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        if [ -z "$remaining_text" ]; then ok=0; break; fi
        character="${remaining_text:0:1}"
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        # A backslash-newline is a line CONTINUATION: the shell removes both
        # and the logical line runs on, so the newline that ends an opener line
        # is somewhere further down. Locating a body under that would mask
        # command text, so give up on the whole input instead.
        if [ "$character" = "$newline" ] && [ "$heredoc_count" -gt 0 ]; then ok=0; break; fi
        word_start=0
        ;;
      '$')
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        case "$remaining_text" in "'"*) ok=0; break ;; esac
        word_start=0
        ;;
      '#')
        if [ "$word_start" = 1 ]; then
          case "$remaining_text" in
            *"$newline"*) prefix="${remaining_text%%"$newline"*}" ;;
            *) prefix="$remaining_text" ;;
          esac
          view_text+="$prefix"
          remaining_text="${remaining_text:${#prefix}}"
        else
          view_text+="$character"
          remaining_text="${remaining_text:1}"
          word_start=0
        fi
        ;;
      '<')
        case "$remaining_text" in
          '<<<'*)
            # A herestring, not a heredoc: its word is on this line and no
            # following line is a body.
            view_text+='<<<'
            remaining_text="${remaining_text:3}"
            word_start=0
            ;;
          '<<'*)
            chunk='<<'
            remaining_text="${remaining_text:2}"
            strip_tabs=0
            case "$remaining_text" in '-'*) chunk="$chunk-"; remaining_text="${remaining_text:1}"; strip_tabs=1 ;; esac
            blanks=""
            # shellcheck disable=SC2295 # bracket expressions, matched as patterns
            case "$remaining_text" in
              $_GAIA_VA_BLANK_SET*) blanks="${remaining_text%%$_GAIA_VA_NONBLANK_SET*}" ;;
            esac
            if [ -n "$blanks" ]; then chunk="$chunk$blanks"; remaining_text="${remaining_text:${#blanks}}"; fi
            delimiter=""
            delimiter_unreadable=0
            delimiter_quoted=1
            case "$remaining_text" in
              "'"*)
                remaining_text="${remaining_text:1}"
                case "$remaining_text" in
                  *"'"*) delimiter="${remaining_text%%\'*}"; remaining_text="${remaining_text:$(( ${#delimiter} + 1 ))}"; chunk="$chunk'$delimiter'" ;;
                  *) delimiter_unreadable=1 ;;
                esac
                ;;
              '"'*)
                remaining_text="${remaining_text:1}"
                case "$remaining_text" in
                  *'"'*) delimiter="${remaining_text%%\"*}"; remaining_text="${remaining_text:$(( ${#delimiter} + 1 ))}"; chunk="$chunk\"$delimiter\"" ;;
                  *) delimiter_unreadable=1 ;;
                esac
                ;;
              "$_GAIA_VA_BACKSLASH"*)
                remaining_text="${remaining_text:1}"
                delimiter="${remaining_text%%[!A-Za-z0-9_.-]*}"
                if [ -n "$delimiter" ]; then remaining_text="${remaining_text:${#delimiter}}"; chunk="$chunk$_GAIA_VA_BACKSLASH$delimiter"; else delimiter_unreadable=1; fi
                ;;
              *)
                delimiter_quoted=0
                delimiter="${remaining_text%%[!A-Za-z0-9_.-]*}"
                if [ -n "$delimiter" ]; then remaining_text="${remaining_text:${#delimiter}}"; chunk="$chunk$delimiter"; else delimiter_unreadable=1; fi
                ;;
            esac
            if [ "$delimiter_unreadable" = 1 ]; then ok=0; break; fi
            # Condition 4: the delimiter has to be the whole word. Anything
            # abutting it is a spelling this walk cannot read exactly, and
            # reading it wrong puts the body's end in the wrong place.
            case "$remaining_text" in
              ''|' '*|"$_GAIA_VA_TAB"*|"$newline"*|';'*|'&'*|'|'*|'<'*|'>'*|')'*) ;;
              *) ok=0; break ;;
            esac
            # Condition 6's evidence, captured here because this is the only
            # point that knows where the operator sits: `view_text` still holds the
            # line up to it and nothing of it is masked yet. Only the first
            # operator on a line is recorded, which is the only one condition 6
            # is ever asked about.
            if [ "$heredoc_count" -eq 0 ]; then heredoc_prefix="${view_text:$line_start}"; fi
            view_text+="$chunk"
            heredoc_delimiters[heredoc_count]="$delimiter"
            heredoc_strip_tabs[heredoc_count]="$strip_tabs"
            heredoc_quoted[heredoc_count]="$delimiter_quoted"
            heredoc_count=$(( heredoc_count + 1 ))
            word_start=0
            ;;
          *)
            view_text+='<'
            remaining_text="${remaining_text:1}"
            word_start=0
            ;;
        esac
        ;;
      "$newline")
        if [ "$heredoc_count" -eq 0 ]; then
          view_text+="$newline"
          remaining_text="${remaining_text:1}"
          line_start=${#view_text}
          word_start=1
          continue
        fi
        # The opener line is read back out of the view rather than accumulated
        # alongside it: the accumulation costs an append per jump on every line
        # in the text, and only a line that turns out to carry an opener is ever
        # read. Nothing ahead of this point in the line is masked, so the slice
        # is the line's own bytes.
        opener_line="${view_text:$line_start}"
        # More than one heredoc on a line and the redirection that decides
        # where each body goes stops being readable from one opener, so none of
        # them is proven; their bodies are still skipped, just not masked.
        data=0
        if [ "$heredoc_count" -eq 1 ] && _gaia_va_opener_is_data "$opener_line" "$heredoc_prefix"; then data=1; fi
        remaining_text="${remaining_text:1}"
        first=1
        body_index=0
        while [ "$body_index" -lt "$heredoc_count" ]; do
          _gaia_va_find_delimiter "$remaining_text" "${heredoc_delimiters[$body_index]}" "${heredoc_strip_tabs[$body_index]}" || { ok=0; break; }
          delimiter_offset="$_gaia_va_delimiter_offset"
          # Condition 7, decided here because only now is the body's extent
          # known. Only the first heredoc can carry the proof, so only it is
          # asked. The needles are the command-substitution openers of
          # `separator_regex` in verb-arming.sh; an opener added there and missed here
          # is masked as data, which fails open.
          if [ "$first" = 1 ] && [ "$data" = 1 ] && [ "${heredoc_quoted[$body_index]}" = 0 ]; then
            # shellcheck disable=SC2016 # the literal opener is the needle
            case "${remaining_text:0:$delimiter_offset}" in
              *'$('*|*'`'*) data=0 ;;
            esac
          fi
          if [ "$first" = 1 ] && [ "$data" = 1 ] && [ "$delimiter_offset" -gt 0 ]; then
            view_text+=x
          else
            view_text+="$newline"
          fi
          first=0
          if [ "$delimiter_offset" -gt 0 ]; then
            body="${remaining_text:0:$delimiter_offset}"
            remaining_text="${remaining_text:$delimiter_offset}"
            if [ "$data" = 1 ]; then
              _gaia_va_locale_characters
              _gaia_va_make_run "$(( ${#body} - 1 ))"
              _gaia_va_locale_bytes
              view_text+="$_gaia_va_run$newline"
            else
              view_text+="$body"
            fi
          fi
          case "$remaining_text" in
            *"$newline"*) delimiter_line="${remaining_text%%"$newline"*}" ;;
            *) delimiter_line="$remaining_text" ;;
          esac
          view_text+="$delimiter_line"
          remaining_text="${remaining_text:${#delimiter_line}}"
          body_index=$(( body_index + 1 ))
          if [ "$body_index" -lt "$heredoc_count" ]; then
            case "$remaining_text" in
              "$newline"*) remaining_text="${remaining_text:1}" ;;
              *) ok=0; break ;;
            esac
          fi
        done
        [ "$ok" = 1 ] || break
        heredoc_count=0
        heredoc_delimiters=()
        heredoc_strip_tabs=()
        heredoc_quoted=()
        line_start=${#view_text}
        word_start=1
        ;;
    esac
  done

  # A heredoc still pending at the end of the text has no body and no
  # delimiter line; an open span has no end. Both are the walk failing to
  # decide, which suppresses nothing.
  if [ "$ok" = 1 ] && [ -z "$quote_character" ] && [ "$heredoc_count" -eq 0 ]; then
    # shellcheck disable=SC2034 # the view is this function's whole product; every reader is a consumer hook
    GAIA_VERB_ARM_VIEW="$view_text"
  fi
  _gaia_va_locale_characters
  return 0
}
