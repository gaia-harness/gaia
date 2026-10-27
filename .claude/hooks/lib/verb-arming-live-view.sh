#!/usr/bin/env bash
# The liveness scan's entry point. Its contract heads
# verb-arming-live-helpers.sh.
# Sourced only by verb-arming-walk.sh, whose header states the view's
# contract; defines functions and constants and does no other work at source
# time.

# shellcheck disable=SC2154  # constants and helpers come from verb-arming-walk.sh and verb-arming-live-helpers.sh

gaia_verb_arm_live_view() {
  local text="$1"
  GAIA_VERB_ARM_LIVE="$text"
  [ "${#text}" -le "${GAIA_VERB_ARM_MAXIMUM_CHARACTERS:-16384}" ] || return 0

  local newline=$'\n'
  local remaining_text view_text ok word_start stack_top backtick_depth kind prefix prefix_length character next_character inner command_so_far rest dead
  local chunk strip_tabs blanks delimiter delimiter_unreadable delimiter_quoted heredoc_count heredoc_stack_top heredoc_owned heredoc_end body_index delimiter_offset body delimiter_line
  # The context stack. kind: T top level, S `$( )`, P `<( )` `>( )` `=( )`,
  # B backticks, D double quotes. parenthesis_depths counts bare parentheses, case_seen records the
  # word `case`, command_starts is the offset in `view_text` where the current command began,
  # and substitution_open_offsets, for an S frame, the offset just past its `$(`. Offsets in `view_text`
  # are offsets in <text>: the scan runs on bytes and masks one for one.
  local frame_kinds parenthesis_depths case_seen command_starts substitution_open_offsets heredoc_delimiters heredoc_strip_tabs heredoc_quoted frame_index
  frame_kinds=(T); parenthesis_depths=(0); case_seen=(0); command_starts=(0); substitution_open_offsets=(0)
  heredoc_delimiters=(); heredoc_strip_tabs=(); heredoc_quoted=()

  _gaia_va_locale_bytes
  remaining_text="$text"
  view_text=""
  ok=1
  word_start=1
  stack_top=0
  backtick_depth=0
  heredoc_count=0
  heredoc_stack_top=0
  heredoc_owned=0
  heredoc_end=0
  _gaia_va_live_work=0

  while [ -n "$remaining_text" ]; do
    _gaia_va_live_work=$(( _gaia_va_live_work + ${#remaining_text} ))
    if [ "$_gaia_va_live_work" -gt "$_GAIA_VA_MAXIMUM_WORK" ]; then ok=0; break; fi
    kind="${frame_kinds[$stack_top]}"

    if [ "$kind" = D ]; then
      # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
      prefix="${remaining_text%%$_GAIA_VA_LIVE_DOUBLE_QUOTE_SET*}"
      prefix_length=${#prefix}
      character="${remaining_text:$prefix_length:1}"
      if [ -z "$character" ]; then ok=0; break; fi
      view_text+="$prefix"
      remaining_text="${remaining_text:$prefix_length}"
    else
      # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
      prefix="${remaining_text%%$_GAIA_VA_LIVE_TOP_SET*}"
      prefix_length=${#prefix}
      character="${remaining_text:$prefix_length:1}"
      if [ -z "$character" ]; then view_text+="$remaining_text"; remaining_text=""; break; fi
      view_text+="$prefix"
      remaining_text="${remaining_text:$prefix_length}"
      if [ -n "$prefix" ]; then
        [[ "$prefix" =~ $_GAIA_VA_LIVE_CASE_REGEX ]] && case_seen[stack_top]=1
        case "$prefix" in
          *$_GAIA_VA_WORD_SET) word_start=1 ;;
          *) word_start=0 ;;
        esac
      fi
    fi
    next_character="${remaining_text:1:1}"

    case "$character" in
      '"')
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        if [ "$kind" = D ]; then
          stack_top=$(( stack_top - 1 ))
        else
          stack_top=$(( stack_top + 1 )); frame_kinds[stack_top]=D; parenthesis_depths[stack_top]=0; case_seen[stack_top]=0; command_starts[stack_top]=${#view_text}
        fi
        word_start=0
        ;;
      "'")
        # Only reachable outside double quotes: the double-quote set holds no
        # apostrophe.
        remaining_text="${remaining_text:1}"
        case "$remaining_text" in
          *"'"*) ;;
          *) ok=0; break ;;
        esac
        inner="${remaining_text%%\'*}"
        # bash ends a backquote at its first unescaped backtick, quoted or not.
        if [ "$backtick_depth" -gt 0 ]; then
          case "$inner" in *'`'*) ok=0; break ;; esac
        fi
        _gaia_va_mask_openers "$inner" || { ok=0; break; }
        view_text+="'$_gaia_va_masked'"
        remaining_text="${remaining_text:$(( ${#inner} + 1 ))}"
        word_start=0
        ;;
      "$_GAIA_VA_BACKSLASH")
        view_text+="$character"
        if [ -z "$next_character" ]; then ok=0; break; fi
        # Under backticks, in any context down to the innermost, the shell
        # strips the backslash from `\$`, `` \` `` and `\\` before parsing the
        # inner command, so the escape it seems to make is gone by then.
        if [ "$backtick_depth" -gt 0 ]; then
          case "$next_character" in
            '$'|'`'|"$_GAIA_VA_BACKSLASH") ok=0; break ;;
          esac
        fi
        # A line continuation moves the newline that ends a heredoc opener.
        if [ "$next_character" = "$newline" ] && [ "$heredoc_count" -gt 0 ]; then ok=0; break; fi
        case "$next_character" in
          '$'|'`'|'<'|'>'|'=') view_text+=x ;;
          *) view_text+="$next_character" ;;
        esac
        remaining_text="${remaining_text:2}"
        word_start=0
        ;;
      '`')
        # Under backticks, bash closes the outer backquote here even from
        # inside double quotes or a nested `$( )`, where zsh opens a new one.
        if [ "$backtick_depth" -gt 0 ] && [ "$kind" != B ]; then ok=0; break; fi
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        if [ "$kind" = B ]; then
          stack_top=$(( stack_top - 1 ))
          backtick_depth=$(( backtick_depth - 1 ))
          word_start=0
        else
          stack_top=$(( stack_top + 1 )); frame_kinds[stack_top]=B; parenthesis_depths[stack_top]=0; case_seen[stack_top]=0; command_starts[stack_top]=${#view_text}
          backtick_depth=$(( backtick_depth + 1 ))
          word_start=1
        fi
        ;;
      '$')
        case "$next_character" in
          '(')
            # shellcheck disable=SC2016 # the literal opener, copied through
            view_text+='$('
            remaining_text="${remaining_text:2}"
            stack_top=$(( stack_top + 1 )); frame_kinds[stack_top]=S; parenthesis_depths[stack_top]=0; case_seen[stack_top]=0; command_starts[stack_top]=${#view_text}
            substitution_open_offsets[stack_top]=${#view_text}
            word_start=1
            ;;
          "'")
            # A dollar-quoted word, except inside double quotes, where the
            # apostrophe is ordinary.
            if [ "$kind" != D ]; then ok=0; break; fi
            view_text+='$'
            remaining_text="${remaining_text:1}"
            ;;
          '{')
            rest="${remaining_text:2}"
            case "$rest" in
              *'}'*) ;;
              *) ok=0; break ;;
            esac
            inner="${rest%%\}*}"
            # A plain parameter expansion is skipped whole. Anything that can
            # nest, quote, or run a command inside the braces is not modelled,
            # and that includes bash 5.3's `${ ` and `${|`.
            case "$inner" in
              ''|[[:space:]]*|'|'*|*[\"\'\`\$\(\{\\]*|*"$newline"*) ok=0; break ;;
            esac
            view_text+="\${$inner}"
            remaining_text="${remaining_text:$(( ${#inner} + 3 ))}"
            word_start=0
            ;;
          *)
            view_text+='$'
            remaining_text="${remaining_text:1}"
            word_start=0
            ;;
        esac
        ;;
      '(')
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        parenthesis_depths[stack_top]=$(( ${parenthesis_depths[$stack_top]} + 1 ))
        command_starts[stack_top]=${#view_text}
        word_start=1
        ;;
      ')')
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        if [ "${case_seen[$stack_top]}" = 1 ]; then ok=0; break; fi
        if [ "${parenthesis_depths[$stack_top]}" -gt 0 ]; then
          parenthesis_depths[stack_top]=$(( ${parenthesis_depths[$stack_top]} - 1 ))
          # A subshell's `)` is an operator, so a `#` right after it opens a
          # comment, where after a substitution's `)` it continues the word.
          # Rather than model which `(` this closes, stop.
          case "$remaining_text" in '#'*) ok=0; break ;; esac
        elif [ "$kind" = S ] || [ "$kind" = P ]; then
          stack_top=$(( stack_top - 1 ))
        else
          ok=0; break
        fi
        word_start=0
        ;;
      '<'|'>'|'=')
        if [ "$next_character" = '(' ]; then
          view_text+="$character("
          remaining_text="${remaining_text:2}"
          stack_top=$(( stack_top + 1 )); frame_kinds[stack_top]=P; parenthesis_depths[stack_top]=0; case_seen[stack_top]=0; command_starts[stack_top]=${#view_text}
          word_start=1
        elif [ "$character" = '<' ] && [ "${remaining_text:0:3}" = '<<<' ]; then
          view_text+='<<<'
          remaining_text="${remaining_text:3}"
          word_start=0
        elif [ "$character" = '<' ] && [ "$next_character" = '<' ]; then
          # Inside parentheses `<<` may be an arithmetic shift, and a heredoc
          # in a subshell can feed whatever reads the subshell's output.
          if [ "${parenthesis_depths[$stack_top]}" -gt 0 ]; then ok=0; break; fi
          # The delimiter is read exactly as the data-proof walk reads it.
          command_so_far="${view_text:${command_starts[$stack_top]}}"
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
          case "$remaining_text" in
            ''|' '*|"$_GAIA_VA_TAB"*|"$newline"*|';'*|'&'*|'|'*|'<'*|'>'*|')'*) ;;
            *) ok=0; break ;;
          esac
          if [ "$heredoc_count" -eq 0 ]; then
            heredoc_stack_top=$stack_top
            heredoc_owned=0
            if [ "$kind" = T ] || [ "$kind" = S ]; then
              [[ "$command_so_far" =~ $_GAIA_VA_LIVE_OWNER_REGEX ]] && heredoc_owned=1
            fi
          elif [ "$stack_top" -ne "$heredoc_stack_top" ]; then
            ok=0; break
          fi
          view_text+="$chunk"
          heredoc_delimiters[heredoc_count]="$delimiter"
          heredoc_strip_tabs[heredoc_count]="$strip_tabs"
          heredoc_quoted[heredoc_count]="$delimiter_quoted"
          heredoc_count=$(( heredoc_count + 1 ))
          [ "$heredoc_count" -eq 1 ] && heredoc_end=${#view_text}
          word_start=0
        else
          view_text+="$character"
          remaining_text="${remaining_text:1}"
          word_start=0
        fi
        ;;
      '#')
        if [ "$word_start" = 1 ]; then
          case "$remaining_text" in
            *"$newline"*) prefix="${remaining_text%%"$newline"*}" ;;
            *) prefix="$remaining_text" ;;
          esac
          if [ "$backtick_depth" -gt 0 ]; then
            case "$prefix" in *'`'*) ok=0; break ;; esac
          fi
          view_text+="$prefix"
          remaining_text="${remaining_text:${#prefix}}"
        else
          view_text+="$character"
          remaining_text="${remaining_text:1}"
        fi
        ;;
      ';'|'&'|'|')
        # After `>` or `<` this completes a redirection operator (`>&`, `<&`,
        # `>|`) rather than ending the command, and the word after it is a
        # file, never the command a heredoc belongs to.
        case "$view_text" in
          *'>'|*'<') ;;
          *) command_starts[stack_top]=$(( ${#view_text} + 1 )) ;;
        esac
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        word_start=1
        ;;
      "$newline")
        if [ "$heredoc_count" -eq 0 ]; then
          view_text+="$newline"
          remaining_text="${remaining_text:1}"
          command_starts[stack_top]=${#view_text}
          word_start=1
          continue
        fi
        # The bodies begin here, in the context their operators stood in.
        if [ "$stack_top" -ne "$heredoc_stack_top" ]; then ok=0; break; fi
        dead=0
        if [ "$heredoc_count" -eq 1 ] && [ "$heredoc_owned" = 1 ] && [ "${heredoc_quoted[0]}" = 1 ] \
           && [[ "${view_text:$heredoc_end}" =~ $_GAIA_VA_BLANK_LINE_REGEX ]]; then
          dead=1
        fi
        view_text+="$newline"
        remaining_text="${remaining_text:1}"
        body_index=0
        while [ "$body_index" -lt "$heredoc_count" ]; do
          _gaia_va_find_delimiter "$remaining_text" "${heredoc_delimiters[$body_index]}" "${heredoc_strip_tabs[$body_index]}" || { ok=0; break; }
          delimiter_offset="$_gaia_va_delimiter_offset"
          body="${remaining_text:0:$delimiter_offset}"
          remaining_text="${remaining_text:$delimiter_offset}"
          if [ "$backtick_depth" -gt 0 ]; then
            case "$body" in *'`'*) ok=0; break ;; esac
          fi
          # bash 3.2's matcher starts at each enclosing `$(`, not at the body,
          # so it reads everything from there on: earlier bodies, comments and
          # delimiter lines included.
          if [ "$dead" = 1 ]; then
            frame_index=0
            while [ "$frame_index" -le "$heredoc_stack_top" ]; do
              if [ "${frame_kinds[$frame_index]}" = S ]; then
                _gaia_va_b32_body_safe "${text:${substitution_open_offsets[$frame_index]}:$(( ${#view_text} - ${substitution_open_offsets[$frame_index]} ))}$body" "$remaining_text" || { ok=0; break; }
              fi
              frame_index=$(( frame_index + 1 ))
            done
            [ "$ok" = 1 ] || break
          fi
          if [ "$dead" = 1 ]; then
            _gaia_va_mask_openers "$body" || { ok=0; break; }
            view_text+="$_gaia_va_masked"
          else
            view_text+="$body"
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
              "$newline"*) view_text+="$newline"; remaining_text="${remaining_text:1}" ;;
              *) ok=0; break ;;
            esac
          fi
        done
        [ "$ok" = 1 ] || break
        heredoc_count=0
        heredoc_delimiters=(); heredoc_strip_tabs=(); heredoc_quoted=()
        command_starts[stack_top]=${#view_text}
        word_start=1
        ;;
    esac
  done

  # Anything still open at the end is the scan failing to decide, which masks
  # nothing.
  if [ "$ok" = 1 ] && [ "$stack_top" -eq 0 ] && [ "$heredoc_count" -eq 0 ]; then
    # shellcheck disable=SC2034 # read by lib/verb-arming.sh
    GAIA_VERB_ARM_LIVE="$view_text"
  fi
  _gaia_va_locale_characters
  return 0
}
