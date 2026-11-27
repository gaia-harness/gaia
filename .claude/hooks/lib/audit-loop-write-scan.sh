#!/usr/bin/env bash
# shellcheck shell=bash
#
# The shell reading block-audit-loop-write.sh and its class libraries share:
# the physical path resolution of the edit-tool arm, the quote-aware command
# reading, the write-spelling predicates, and the walker that decides whether a
# simple command executes a guarded script. Sourced by that guard before its
# class libraries; rate-limits-guard.sh calls these functions, and the walker
# here calls hook-only-scripts-guard.sh's guarded_script_kind by name. It is
# not a hook and carries no registration.
#
# Bash 3.2 compatible.

# physical_path <path> <base-dir>: print the physically resolved absolute path.
# Walks the segments; while each prefix exists as a directory it is entered with
# `pwd -P` (symlinks and `..` resolved by the filesystem), and once a segment is
# missing the rest is joined lexically with `..` collapsed.
physical_path() {
  local input_path="$1" base="$2" current_path path_component lexical=0 rest hops=0 target
  case "$input_path" in
    /*) ;;
    *) input_path="$base/$input_path" ;;
  esac
  current_path=/
  rest="${input_path#/}"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*)
        path_component="${rest%%/*}"
        rest="${rest#*/}"
        ;;
      *)
        path_component="$rest"
        rest=''
        ;;
    esac
    case "$path_component" in
      '' | .) continue ;;
      ..)
        if [ "$lexical" -eq 1 ]; then
          current_path="${current_path%/*}"
          [ -n "$current_path" ] || current_path=/
        else
          current_path=$( (cd "${current_path%/}/.." 2>/dev/null && pwd -P) ) || current_path=/
        fi
        continue
        ;;
    esac
    if [ "$lexical" -eq 0 ] && [ -d "${current_path%/}/$path_component" ]; then
      current_path=$( (cd "${current_path%/}/$path_component" 2>/dev/null && pwd -P) ) || { lexical=1; current_path="${current_path%/}/$path_component"; }
    else
      # A final component that is itself a symlink (a file link into the
      # directory): follow it, a bounded number of hops.
      if [ "$lexical" -eq 0 ] && [ -z "$rest" ] && [ -L "${current_path%/}/$path_component" ] && [ "$hops" -lt 8 ]; then
        hops=$((hops + 1))
        target=$(readlink "${current_path%/}/$path_component" 2>/dev/null) || target=''
        if [ -n "$target" ]; then
          physical_path "$target" "$current_path"
          return 0
        fi
      fi
      lexical=1
      current_path="${current_path%/}/$path_component"
    fi
  done
  printf '%s' "$current_path"
}

# has_write_verb <text>: rc 0 when the text carries a write, move or delete
# verb.
has_write_verb() {
  local verbs_re sedi_re interpreter_re
  verbs_re='(^|[[:space:];&|(`/])(rm|mv|cp|tee|ln|install|dd|touch|truncate|chmod|rsync|unlink|shred)([[:space:]]|$)'
  sedi_re='(^|[[:space:];&|(`/])(sed|perl)[[:space:]]+(-[a-zA-Z]*i|--in-place)'
  interpreter_re='(^|[[:space:];&|(`/])(python[0-9.]*|node|perl|ruby)[[:space:]]+-[a-zA-Z]*[ce]'
  [[ "$1" =~ $verbs_re ]] && return 0
  [[ "$1" =~ $sedi_re ]] && return 0
  [[ "$1" =~ $interpreter_re ]] && return 0
  return 1
}

# has_write_spelling <command>: rc 0 when the command carries a write, move or
# delete spelling anywhere, quoted text included. The fallback reading.
has_write_spelling() {
  local scrub

  # Drop redirects that cannot write a guarded path: descriptor duplication
  # (2>&1, >&2) and a redirect to /dev/null.
  scrub=$(sed -E 's/[0-9]*>&[0-9-]+//g; s/[0-9&]*>>?[[:space:]]*\/dev\/null//g' <<<"$1")

  # A redirect to anything else.
  case "$scrub" in
    *'>'*) return 0 ;;
  esac
  has_write_verb "$scrub"
}

# shell_scan <text>: read the text the way the shell groups it, as far as this
# guard needs. Sets
#   SCAN_WORDS    the words, quotes removed: single and double quotes group, a
#                 backslash outside single quotes escapes the next character,
#                 unquoted blanks, newlines and ; & | ( ) ` end a word, and a
#                 redirect target is not a word
#   SCAN_TARGETS  each `>`, `>>`, `>|` or `>&` redirect target, one per line;
#                 a descriptor duplication (2>&1, >&-) and a process
#                 substitution `>(` have none
#   SCAN_BARE     the text outside quotes and comments, each quoted span as
#                 one Q
#   SCAN_SOUND    0 when the text ends inside a quote, holds a heredoc, has a
#                 command substitution or backtick inside double quotes, or
#                 has a redirect target holding `$`, a backtick or a glob
# An unquoted `#` that starts a word opens a comment to the end of the line.
# A heredoc body is unquoted prose whose apostrophes this reading would take
# for quotes, and a quoted substitution runs commands this reading takes for
# text, so on SCAN_SOUND=0 the caller falls back to the whole-text reading.
shell_scan() {
  local scanned_text="$1" text_length=${#1} i=0 character open_quote='' word='' inword=0 want=0
  SCAN_WORDS=()
  SCAN_TARGETS=''
  SCAN_BARE=''
  SCAN_SOUND=1
  while [ "$i" -le "$text_length" ]; do
    character="${scanned_text:i:1}"
    if [ -n "$open_quote" ] && [ "$i" -lt "$text_length" ]; then
      if [ "$character" = "$open_quote" ]; then
        open_quote=''
      elif [ "$open_quote" = '"' ] && [ "$character" = "\\" ]; then
        i=$((i + 1))
        word="$word${scanned_text:i:1}"
      else
        if [ "$open_quote" = '"' ]; then
          case "$character" in
            '`') SCAN_SOUND=0 ;;
            '$') [ "${scanned_text:i+1:1}" != '(' ] || SCAN_SOUND=0 ;;
          esac
        fi
        word="$word$character"
      fi
      i=$((i + 1))
      continue
    fi
    case "$character" in
      "'" | '"')
        open_quote="$character"
        inword=1
        SCAN_BARE="${SCAN_BARE}Q"
        ;;
      "\\")
        i=$((i + 1))
        word="$word${scanned_text:i:1}"
        inword=1
        SCAN_BARE="$SCAN_BARE$character${scanned_text:i:1}"
        ;;
      '' | ' ' | $'\t' | $'\n' | ';' | '&' | '|' | '(' | ')' | '`' | '>')
        # The end of the text, or a character that ends the word in hand.
        if [ "$inword" -eq 1 ]; then
          if [ "$want" -eq 1 ]; then
            SCAN_TARGETS="$SCAN_TARGETS$word"$'\n'
            want=0
            # A target built from a variable, a substitution or a glob can
            # land on a path the command names elsewhere.
            case "$word" in
              *'$'* | *'*'* | *'?'* | *'['* | *'`'*) SCAN_SOUND=0 ;;
            esac
          elif [ "$character" = '>' ] && [[ "$word" =~ ^[0-9]+$ ]]; then
            : # the descriptor number of a redirect such as 2>, not a word
          else
            SCAN_WORDS[${#SCAN_WORDS[@]}]="$word"
          fi
        fi
        word=''
        inword=0
        SCAN_BARE="$SCAN_BARE$character"
        if [ "$character" = '>' ]; then
          case "${scanned_text:i+1:1}" in
            '>' | '|')
              i=$((i + 1))
              SCAN_BARE="$SCAN_BARE${scanned_text:i:1}"
              ;;
          esac
          if [ "${scanned_text:i+1:1}" = '&' ]; then
            i=$((i + 1))
            SCAN_BARE="$SCAN_BARE&"
            case "${scanned_text:i+1:1}" in
              [0-9-]) ;;
              *) want=1 ;;
            esac
          elif [ "${scanned_text:i+1:1}" != '(' ]; then
            want=1
          fi
        fi
        ;;
      '#')
        if [ "$inword" -eq 1 ]; then
          word="$word$character"
          SCAN_BARE="$SCAN_BARE$character"
        else
          # A comment runs to the end of the line; its apostrophes are not
          # quotes. The newline itself is read next, as a separator.
          while [ "$((i + 1))" -lt "$text_length" ] && [ "${scanned_text:i+1:1}" != $'\n' ]; do
            i=$((i + 1))
          done
        fi
        ;;
      '<')
        # `<<<` is a here-string; a bare `<<` opens a heredoc.
        if [ "${scanned_text:i+1:2}" = '<<' ]; then
          i=$((i + 2))
          word="$word<<"
          SCAN_BARE="$SCAN_BARE<<"
        elif [ "${scanned_text:i+1:1}" = '<' ]; then
          SCAN_SOUND=0
        fi
        word="$word$character"
        inword=1
        SCAN_BARE="$SCAN_BARE$character"
        ;;
      *)
        word="$word$character"
        inword=1
        SCAN_BARE="$SCAN_BARE$character"
        ;;
    esac
    i=$((i + 1))
  done
  [ -z "$open_quote" ] || SCAN_SOUND=0
  return 0
}

# writes_named <command> <names-regex>: rc 0 when the command writes, moves or
# deletes what the regex names: a redirect whose target names it, or a write
# verb outside quotes in a command that names it anywhere. On an unsound
# reading (see shell_scan), any redirect or verb anywhere counts.
writes_named() {
  local target
  [ "$SCAN_SOUND" -eq 1 ] || {
    has_write_spelling "$1"
    return
  }
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    [[ "$target" =~ $2 ]] && return 0
  done <<<"$SCAN_TARGETS"
  has_write_verb "$SCAN_BARE"
}

# words_run_guarded_script [matcher]: rc 0 when the simple command held in the
# `words` array executes a script the matcher accepts (command word, or script
# argument of a shell or `source`/`.`/`exec`). The matcher is called as
# `<matcher> <script-word> <next-word>`; the default, guarded_script_kind,
# accepts a recorder or a reaper script.
words_run_guarded_script() {
  local matcher="${1:-guarded_script_kind}" count=${#words[@]} word_index=0 word base syntax_check

  # Skip the leading words the case below lists, none of which is the command.
  while [ "$word_index" -lt "$count" ]; do
    case "${words[$word_index]}" in
      [A-Za-z_]*=* | '!' | exec | '{' | if | while | until | then | do | else | elif) word_index=$((word_index + 1)) ;;
      time)
        word_index=$((word_index + 1))
        while [ "$word_index" -lt "$count" ] && [[ ${words[$word_index]} == -* ]]; do
          word_index=$((word_index + 1))
        done
        ;;
      *) break ;;
    esac
  done
  [ "$word_index" -lt "$count" ] || return 1

  word="${words[$word_index]}"
  "$matcher" "$word" "${words[$((word_index + 1))]-}" && return 0
  base="${word##*/}"
  case "$base" in
    bash | sh | zsh | dash | ksh | source | .)
      syntax_check=0
      word_index=$((word_index + 1))
      while [ "$word_index" -lt "$count" ]; do
        word="${words[$word_index]}"
        case "$word" in
          -n) syntax_check=1 ;;
          -o | +o) word_index=$((word_index + 1)) ;;
          -* | +*) ;;
          *)
            if "$matcher" "$word" "${words[$((word_index + 1))]-}" && [ "$syntax_check" -eq 0 ]; then
              return 0
            fi
            break
            ;;
        esac
        word_index=$((word_index + 1))
      done
      ;;
  esac
  return 1
}

# runs_guarded_script <command> [matcher]: rc 0 when a simple command in the
# line executes a script the matcher accepts (default guarded_script_kind: a
# recorder or a reaper script, with SCRIPT_KIND naming which; the context
# writer matchers get the same heredoc data view). Each
# segment is read twice, as the shell groups its quotes (a
# quoted path with a space stays one word) and as blank-separated words with
# their quotes stripped (a quote the segment split cut in half), and either
# reading executing a recorder counts.
runs_guarded_script() {
  local command_line="$1" matcher="${2:-guarded_script_kind}" segments segment words word_index count word
  if [ "$matcher" = guarded_script_kind ] || [ "$matcher" = context_writer_execute_matcher ] || [ "$matcher" = context_writer_source_matcher ]; then
    case "$matcher" in
      guarded_script_kind)
        case "$command_line" in
          *audit-loop-grant.sh* | *audit-loop-ask-grant.sh* | *state-reaper*) ;;
          *) return 1 ;;
        esac
        ;;
      *)
        case "$command_line" in
          *gaia-statusline.sh* | *context-reading.sh* | *context-checkpoint-lib.sh* | *context-any-age-lib.sh* | *gaia-next-handoff-lib.sh*) ;;
          *) return 1 ;;
        esac
        ;;
    esac
    # A heredoc body the walker proves is data (a `cat` or `tee` into a file)
    # is text, not commands; its lines would otherwise each read as a segment.
    # A missing walker or an abstention leaves the body judged.
    case "$command_line" in
      *'<<'*)
        if ! type gaia_verb_arm_view >/dev/null 2>&1; then
          # shellcheck source=verb-arming-walk.sh
          [ -f "${BASH_SOURCE[0]%/*}/verb-arming-walk.sh" ] && . "${BASH_SOURCE[0]%/*}/verb-arming-walk.sh" 2>/dev/null
        fi
        if type gaia_verb_arm_view >/dev/null 2>&1 && gaia_verb_arm_view "$command_line"; then
          command_line="$GAIA_VERB_ARM_VIEW"
        fi
        ;;
    esac
  fi
  segments="${command_line//\$\(/$'\n'}"
  segments=$(printf '%s' "$segments" | tr ';&|`()' '\n')
  while IFS= read -r segment; do
    words=()
    read -r -a words <<<"$segment" || true
    count=${#words[@]}
    [ "$count" -gt 0 ] || continue
    word_index=0
    while [ "$word_index" -lt "$count" ]; do
      word="${words[$word_index]//\"/}"
      word="${word//\'/}"
      words[word_index]="$word"
      word_index=$((word_index + 1))
    done
    words_run_guarded_script "$matcher" && return 0

    shell_scan "$segment"
    words=()
    count=${#SCAN_WORDS[@]}
    word_index=0
    while [ "$word_index" -lt "$count" ]; do
      words[word_index]="${SCAN_WORDS[$word_index]}"
      word_index=$((word_index + 1))
    done
    [ "$count" -gt 0 ] || continue
    words_run_guarded_script "$matcher" && return 0
  done <<<"$segments"
  return 1
}
