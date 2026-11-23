#!/usr/bin/env bash
# The commit- and PR-message heredoc view for the read guard's dump split.
# Sourced by lib/reader-operands.sh; defines functions and does no work at
# source time.
#
#   gaia_message_heredoc_view <text>
#
# ASSIGNS GAIA_MESSAGE_HEREDOC_VIEW: <text> with one heredoc body overwritten,
# newlines kept, when <text> has exactly this shape, and <text> unchanged
# otherwise:
#
#   <prefix>git [-C <dir>|-c <setting>|--<option>]... commit <word>... -m|--message "$(cat <<'D'
#   <prefix>gh pr|issue create|edit|comment <word>... -b|--body|-t|--title "$(cat <<'D'
#   <body lines>
#   D
#   )"<rest of the command>
#
# The message flag may also be glued (`--message="$(cat`), the delimiter may be
# double-quoted, and blanks may sit between `<<` and it. <prefix> is plain
# commands joined by `&&`, `||`, `;`, `|` or newlines: words, quoted or not,
# with no expansion, substitution, escape, redirect, comment or grouping
# anywhere. The text carries no other `<<`.
#
# WHY THE BODY MAY NOT HOLD ' " ` ( ) \ OR $. bash 3.2, macOS /bin/bash, scans a
# substitution's body as shell text before it knows the heredoc is there: a `)`
# ends the substitution early and the lines after it run as commands, and a
# quote, backtick, `(`, `$(` or a trailing backslash pairs differently or fails
# to parse. With none of those characters, bash 3.2, bash 5 and zsh all end the
# body at the delimiter line and close the substitution at `)"`, so the body is
# only ever the message git or gh is handed.
#
# Every other form, a body holding one of those characters included, is
# returned unchanged and stays judged: the direction that fails closed.

_GAIA_MESSAGE_HEREDOC_TAB=$'\t'

gaia_message_heredoc_view() {
  local text="$1"
  GAIA_MESSAGE_HEREDOC_VIEW="$text"
  # The walker's character bound, so the two views abstain on the same inputs.
  [ "${#text}" -le "${GAIA_VERB_ARM_MAXIMUM_CHARACTERS:-16384}" ] || return 0

  # shellcheck disable=SC2016 # the literal opener is the needle
  local opener='"$(cat'
  local newline=$'\n'
  case "$text" in
    *"$opener"[[:blank:]]*'<<'*) ;;
    *) return 0 ;;
  esac
  case "${text#*<<}" in *'<<'*) return 0 ;; esac

  local head after quote delimiter body_start body_and_rest body closing
  head="${text%%"$opener"*}"
  after="${text:$(( ${#head} + ${#opener} ))}"
  after="${after#"${after%%[![:blank:]]*}"}"
  case "$after" in '<<'*) after="${after:2}" ;; *) return 0 ;; esac
  after="${after#"${after%%[![:blank:]]*}"}"
  quote="${after:0:1}"
  case "$quote" in "'"|'"') ;; *) return 0 ;; esac
  after="${after:1}"
  delimiter="${after%%"$quote"*}"
  [ "$delimiter" != "$after" ] || return 0
  [[ "$delimiter" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  after="${after:$(( ${#delimiter} + 1 ))}"
  case "$after" in "$newline"*) ;; *) return 0 ;; esac
  body_and_rest="${after:1}"
  body_start=$(( ${#text} - ${#body_and_rest} ))

  case "$body_and_rest" in
    "$delimiter$newline"*) body="" ;;
    *"$newline$delimiter$newline"*) body="${body_and_rest%%"$newline$delimiter$newline"*}$newline" ;;
    *) return 0 ;;
  esac
  closing="${body_and_rest:$(( ${#body} + ${#delimiter} + 1 ))}"
  case "$closing" in ')"'*) ;; *) return 0 ;; esac
  case "$body" in *[\'\"\`\(\)\\\$]*) return 0 ;; esac

  _gaia_message_heredoc_prefix_is_message_flag "$head" || return 0

  # shellcheck disable=SC2034 # the view is this function's whole product, read by its caller
  GAIA_MESSAGE_HEREDOC_VIEW="${text:0:$body_start}${body//[!$newline]/x}${text:$(( body_start + ${#body} ))}"
  return 0
}

# _gaia_message_heredoc_prefix_is_message_flag <prefix>: succeed when the last
# simple command of <prefix> is a git commit or gh pr/issue create, edit or
# comment whose final word is a message flag, written apart (`-m `) or glued
# (`--message=`) to the substitution that follows.
_gaia_message_heredoc_prefix_is_message_flag() {
  local prefix="$1"
  # A character walk costs O(n) per step on bash 3.2, so a long prefix is
  # refused rather than paid for; a real commit prefix is a line or two.
  [ "${#prefix}" -le 1024 ] || return 1

  local index=0 character quote="" word="" in_word=0 newline=$'\n'
  local words=()
  while [ "$index" -lt "${#prefix}" ]; do
    character="${prefix:$index:1}"
    index=$(( index + 1 ))
    if [ "$quote" = "'" ]; then
      case "$character" in
        "'") quote="" ;;
        *) word+="$character" ;;
      esac
      continue
    fi
    if [ "$quote" = '"' ]; then
      case "$character" in
        '"') quote="" ;;
        '$'|'`'|\\) return 1 ;;
        *) word+="$character" ;;
      esac
      continue
    fi
    case "$character" in
      "'"|'"') quote="$character"; in_word=1 ;;
      ' '|"$_GAIA_MESSAGE_HEREDOC_TAB")
        if [ "$in_word" = 1 ]; then words+=("$word"); word=""; in_word=0; fi
        ;;
      ';'|'&'|'|'|"$newline")
        if [ "$in_word" = 1 ]; then words+=("$word"); word=""; in_word=0; fi
        words=()
        ;;
      '$'|'`'|\\|'#'|'<'|'>'|'('|')'|'{'|'}') return 1 ;;
      *) word+="$character"; in_word=1 ;;
    esac
  done
  [ -z "$quote" ] || return 1
  [ "${#words[@]}" -gt 0 ] || return 1

  local count="${#words[@]}" position=1 flags glued
  case "${words[0]}" in
    git)
      while [ "$position" -lt "$count" ]; do
        case "${words[$position]}" in
          -C|-c) position=$(( position + 2 )) ;;
          --*) position=$(( position + 1 )) ;;
          *) break ;;
        esac
      done
      [ "$position" -lt "$count" ] && [ "${words[$position]}" = commit ] || return 1
      flags=' -m --message '
      glued='--message='
      ;;
    gh)
      while [ "$position" -lt "$count" ]; do
        case "${words[$position]}" in
          -R|--repo) position=$(( position + 2 )) ;;
          --repo=*) position=$(( position + 1 )) ;;
          *) break ;;
        esac
      done
      [ "$position" -lt "$count" ] || return 1
      case "${words[$position]}" in pr|issue) ;; *) return 1 ;; esac
      position=$(( position + 1 ))
      [ "$position" -lt "$count" ] || return 1
      case "${words[$position]}" in create|edit|comment) ;; *) return 1 ;; esac
      flags=' -b --body -t --title '
      glued='--body= --title='
      ;;
    *) return 1 ;;
  esac

  if [ "$in_word" = 1 ]; then
    case " $glued " in *" $word "*) return 0 ;; esac
    return 1
  fi
  [ "$(( count - 1 ))" -gt "$position" ] || return 1
  case "$flags" in *" ${words[$(( count - 1 ))]} "*) return 0 ;; esac
  return 1
}

