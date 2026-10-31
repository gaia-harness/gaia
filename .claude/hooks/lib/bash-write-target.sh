#!/usr/bin/env bash
# Sourced library: find the file a shell command line writes.
#
# gaia_bash_command_writes_target walks the command's tokens and, for each
# recognised write shape, hands the named target to a caller-supplied predicate.
# The shapes: an output redirect (> or >>, spaced or glued to the target), every
# token after tee or sponge, sed carrying -i (with or without a macOS '' backup
# suffix), and the last non-flag, non-redirect token after cp or mv (the
# destination). A quoted run is rejoined so a path with a space reaches the
# predicate whole.
#
# It is best-effort and biased toward allowing on ambiguity: Bash vectors are
# unbounded, so a shape it does not recognise passes. Two PreToolUse guards
# source it, the manifest write guard and the settings write guard, so a shape
# added here reaches both.
#
# It is detection only. Each guard keeps its own path rule (the predicate) and
# any exemption, because the two differ: one denies and honours an exemption
# marker, the other asks and honours none. Nothing here reads jq, prints, or
# exits.
#
# Sourced only; does no work at source time. Bash 3.2 compatible.

[ -n "${GAIA_BASH_WRITE_TARGET_SH:-}" ] && return 0
GAIA_BASH_WRITE_TARGET_SH=1

# Print the token with one matching pair of surrounding quotes removed.
gaia_write_target_strip_quotes() {
  local text="$1"
  case "$text" in
    \"*\") text=${text#\"}; text=${text%\"} ;;
    \'*\') text=${text#\'}; text=${text%\'} ;;
  esac
  printf '%s' "$text"
}

# Rejoin tokens a quoted run split on whitespace, so a quoted path with a space
# reaches the predicate whole. Result lands in GAIA_WRITE_TARGET_JOINED. An
# unterminated quote joins to the end of the line.
gaia_write_target_join_quoted() {
  local current="" quote="" word position character
  GAIA_WRITE_TARGET_JOINED=()
  for word in "$@"; do
    if [ -n "$quote" ]; then
      current="$current $word"
    else
      current="$word"
    fi
    position=0
    while [ "$position" -lt "${#word}" ]; do
      character="${word:$position:1}"
      if [ -z "$quote" ]; then
        case "$character" in
          \" | \') quote="$character" ;;
        esac
      elif [ "$character" = "$quote" ]; then
        quote=""
      fi
      position=$((position + 1))
    done
    if [ -z "$quote" ]; then
      GAIA_WRITE_TARGET_JOINED+=("$current")
      current=""
    fi
  done
  if [ -n "$current" ]; then
    GAIA_WRITE_TARGET_JOINED+=("$current")
  fi
}

# Return 0 when a recognised write shape in the command line names a target the
# predicate function accepts (called with the raw token); return 1 otherwise.
gaia_bash_command_writes_target() {
  local command_line="$1" predicate="$2"
  local tokens=() line line_tokens token_count i j token next target
  local following_token destination has_i found

  # Tokenize every line, not just the first: a write vector on line 2+ of a
  # multi-line command (heredoc body, &&-joined block, newline-separated
  # statements) must still be inspected.
  while IFS= read -r line || [ -n "$line" ]; do
    read -r -a line_tokens <<<"$line"
    gaia_write_target_join_quoted ${line_tokens[@]+"${line_tokens[@]}"}
    tokens+=(${GAIA_WRITE_TARGET_JOINED[@]+"${GAIA_WRITE_TARGET_JOINED[@]}"} ';')
  done <<<"$command_line"
  token_count=${#tokens[@]}

  i=0
  while [ "$i" -lt "$token_count" ]; do
    token="${tokens[$i]}"

    case "$token" in
      '>' | '>>')
        next="${tokens[$((i + 1))]:-}"
        "$predicate" "$next" && return 0
        ;;
      '>'*)
        # No space after > or >>: operator and target land in one token.
        target="${token#>>}"
        target="${target#>}"
        "$predicate" "$target" && return 0
        ;;
      tee | sponge)
        j=$((i + 1))
        while [ "$j" -lt "$token_count" ]; do
          following_token="${tokens[$j]}"
          case "$following_token" in
            ';' | '&&' | '||' | '|') break ;;
          esac
          "$predicate" "$following_token" && return 0
          j=$((j + 1))
        done
        ;;
      sed)
        has_i=0
        found=0
        j=$((i + 1))
        while [ "$j" -lt "$token_count" ]; do
          following_token="${tokens[$j]}"
          case "$following_token" in
            ';' | '&&' | '||' | '|') break ;;
          esac
          [[ "$following_token" == "-i" || "$following_token" == -i* ]] && has_i=1
          "$predicate" "$following_token" && found=1
          j=$((j + 1))
        done
        [ "$has_i" -eq 1 ] && [ "$found" -eq 1 ] && return 0
        ;;
      cp | mv)
        destination=""
        j=$((i + 1))
        while [ "$j" -lt "$token_count" ]; do
          following_token="${tokens[$j]}"
          case "$following_token" in
            ';' | '&&' | '||' | '|') break ;;
          esac
          case "$following_token" in
            -*) ;;
            # A redirect is no operand; a bare operator also owns the next token.
            [0-9]*[\<\>]* | [\<\>]* | '&>'*)
              case "$following_token" in
                *[\<\>] | '&>>') j=$((j + 1)) ;;
              esac
              ;;
            *) destination="$following_token" ;;
          esac
          j=$((j + 1))
        done
        "$predicate" "$destination" && return 0
        ;;
    esac

    i=$((i + 1))
  done

  return 1
}
