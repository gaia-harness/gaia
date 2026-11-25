#!/usr/bin/env bash
# The non-git segments classify-git-command.sh approves beside its git ones, so
# `R=<path>; git -C "$R" status; echo "status=$?"` or `git log | grep x | head`
# runs without a prompt. Defines data and functions and does no work at source
# time. Reads the caller's hook_root, GAIA_HOOK_CWD, the assignment patterns
# (from git-command-segments.sh), split_git_words (from main-git-guard-parse.sh)
# and gaia_resolve_common_directory (from main-root-lib.sh).
#
# A segment is approved when it is one of:
#   - a literal assignment (the patterns git-command-segments.sh defines) to a
#     name assignment_name_is_safe accepts;
#   - `echo`, `printf`, `true`, `false` or `pwd`, or `date` printing the time;
#   - a reader below with no option that writes, runs a program or follows a
#     file forever, and every file operand inside this repository;
#   - a command a `Bash(...)` allow rule in this tree's .claude/settings.json
#     already approves, which sets segment_runs_program: it runs code nothing
#     here has read, so the caller treats it as a possible branch change.
#
# Honest limit: a reader's option grammar is a table, not the program's own
# parser. An option missing from a value table makes its value read as a file
# operand, which is checked and so fails toward the prompt.

# shellcheck disable=SC2154,SC2034  # hook_root, GAIA_HOOK_CWD and words are the caller's; it reads segment_runs_program

# Names a shell reads when set, even unexported, beyond what the environment
# check in assignment_name_is_safe already refuses.
GAIA_SHELL_SPECIAL_NAMES='BASH_ENV BASHOPTS CDPATH ENV EXECIGNORE FPATH GLOBIGNORE HISTFILE HOME IFS MAILPATH MANPATH MODULE_PATH NULLCMD PATH POSIXLY_CORRECT PROMPT_COMMAND PS4 READNULLCMD SHELLOPTS TMPDIR TMPPREFIX ZDOTDIR'

# The readers, each as: program, the short options that take a value, the short
# options that refuse, the long options allowed (`name` or `name=` for a joined
# value, `-` for none; any other long option refuses), whether the first operand is text
# rather than a file (a pattern or a filter), and the most file operands it may
# take (empty for any number; `uniq` writes its second operand).
GAIA_READER_PROGRAMS=(
  'cat|||-|no|'
  'cut|bcdf||-|no|'
  'grep|ABCDdefm||color= colour= count extended-regexp fixed-strings ignore-case invert-match line-number no-filename only-matching quiet recursive with-filename word-regexp|yes|'
  'head|cn||bytes= lines=|no|'
  'jq||fL|arg argjson ascii-output color-output compact-output exit-status indent join-output monochrome-output null-input raw-input raw-output slurp sort-keys tab|yes|'
  'ls|||-|no|'
  'sort|ktS|oT|-|no|'
  'tail|cn|fF|bytes= lines=|no|'
  'uniq|fs||-|no|1'
  'wc|||bytes chars lines words|no|'
)

# in_this_repository <directory>: 0 when git run in <directory> discovers the
# repository this hook belongs to, through any of its checkouts.
in_this_repository() {
  local own given
  own=$(gaia_resolve_common_directory "$hook_root" 2>/dev/null) || return 1
  given=$(gaia_resolve_common_directory "$1" 2>/dev/null) || return 1
  [ -n "$own" ] && [ "$own" = "$given" ]
}

# path_is_in_this_repository <path>: 0 when <path>, read against the payload
# cwd, is a directory of this repository or a file in one.
path_is_in_this_repository() {
  local path
  case "$1" in
    '~'*) return 1 ;;
    /*) path="$1" ;;
    *) case "$GAIA_HOOK_CWD" in /*) path="$GAIA_HOOK_CWD/$1" ;; *) return 1 ;; esac ;;
  esac
  [ -d "$path" ] || path=$(dirname "$path")
  in_this_repository "$path"
}

# assignment_name_is_safe <name>: 0 for an uppercase name no shell or git reads
# and that this process's environment does not carry. An assignment to a name
# already exported changes what every later program sees, and zsh's lowercase
# special names (`path`, `cdpath`) alias the uppercase ones.
assignment_name_is_safe() {
  [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
  case "$1" in GIT_* | LD_* | DYLD_* | BASH* | ZSH* | LC_*) return 1 ;; esac
  case " $GAIA_SHELL_SPECIAL_NAMES " in *" $1 "*) return 1 ;; esac
  [ -z "${!1+set}" ]
}

# date_prints_time: 0 when the `date` words only choose a format or zone, the
# forms that cannot set the clock.
date_prints_time() {
  local word
  for word in ${words[@]+"${words[@]:1}"}; do
    case "$word" in
      +* | -u | -R | --utc | --rfc-email | -I | -I[a-z]* | --iso-8601 | --iso-8601=* | --rfc-3339=*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# reader_is_approved <entry>: 0 when the reader `words` holds uses only the
# options its entry allows and every file operand is in this repository. A
# recursive grep with no operand reads the cwd, so the cwd must be in it too.
reader_is_approved() {
  local value_letters refused_letters long_options text_first operand_limit index=1 count word
  local letter position long_name operands_only=0 text_seen=0 operand_count=0 recursive=0
  IFS='|' read -r _ value_letters refused_letters long_options text_first operand_limit <<<"$1"
  count=${#words[@]}
  while [ "$index" -lt "$count" ]; do
    word="${words[$index]}"
    index=$((index + 1))
    if [ "$operands_only" -eq 0 ]; then
      case "$word" in
        --) operands_only=1; continue ;;
        --*)
          long_name="${word#--}"
          case "$long_name" in *=*) long_name="${long_name%%=*}=" ;; esac
          case " $long_options " in *" $long_name "*) ;; *) return 1 ;; esac
          case "$long_name" in
            arg | argjson) index=$((index + 2)) ;;
            indent) index=$((index + 1)) ;;
            recursive) recursive=1 ;;
          esac
          continue ;;
        -?*)
          position=1
          while [ "$position" -lt "${#word}" ]; do
            letter="${word:$position:1}"
            position=$((position + 1))
            case "$refused_letters" in *"$letter"*) return 1 ;; esac
            case "$letter" in r | R) recursive=1 ;; esac
            case "$value_letters" in
              *"$letter"*)
                # The value is the rest of this word, else the next word. A
                # value of -e or -f names the pattern, so no operand is text.
                case "$letter" in e | f) text_seen=1 ;; esac
                if [ "$position" -ge "${#word}" ]; then
                  word="${words[$index]:-}"
                  index=$((index + 1))
                else
                  word="${word:$position}"
                fi
                if [ "$letter" = f ] && [ "$text_first" = yes ]; then
                  path_is_in_this_repository "$word" || return 1
                fi
                break ;;
            esac
          done
          continue ;;
      esac
    fi
    if [ "$text_first" = yes ] && [ "$text_seen" -eq 0 ]; then
      text_seen=1
      continue
    fi
    operand_count=$((operand_count + 1))
    [ -z "$operand_limit" ] || [ "$operand_count" -le "$operand_limit" ] || return 1
    [ "$word" = - ] && continue
    path_is_in_this_repository "$word" || return 1
  done
  [ "$recursive" -eq 0 ] || [ "$operand_count" -gt 0 ] || path_is_in_this_repository .
}

# normalize_repository_path <word>: print <word>, with an absolute path inside a
# checkout of this repository rewritten relative to that checkout's root, the
# spelling the settings rules use. Git prints the root with symlinks resolved
# (macOS /var is /private/var), so the path is resolved the same way first.
normalize_repository_path() {
  local root directory path
  case "$1" in
    /*)
      directory=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || directory=""
      path="$directory/${1##*/}"
      [ -n "$directory" ] && root=$(git -C "$directory" rev-parse --show-toplevel 2>/dev/null) || root=""
      if [ -n "$root" ] && in_this_repository "$root"; then
        case "$path" in "$root"/*) printf '%s' "${path#"$root"/}"; return 0 ;; esac
      fi
      ;;
  esac
  printf '%s' "$1"
}

# matches_allow_rule: 0 when the segment `words` holds is approved by a
# `Bash(...)` rule in this tree's settings file. A rule is `Bash(<words>)`,
# matching exactly, or `Bash(<words>:*)` or `Bash(<words> *)`, matching those
# words and any after them, compared word by word so a quoted word holding
# spaces cannot stand in for several. A rule with any other `*` is skipped.
matches_allow_rule() {
  local rule prefix exact index
  local -a checked rule_words
  checked=(${words[@]+"${words[@]}"})
  checked[0]=$(normalize_repository_path "${checked[0]}")
  [ "${#checked[@]}" -lt 2 ] || checked[1]=$(normalize_repository_path "${checked[1]}")
  while IFS= read -r rule; do
    exact=1
    case "$rule" in
      *:\*) prefix="${rule%:\*}"; exact=0 ;;
      *' *') prefix="${rule% \*}"; exact=0 ;;
      *) prefix="$rule" ;;
    esac
    case "$prefix" in *'*'*) continue ;; esac
    read -r -a rule_words <<<"$prefix"
    [ "${#rule_words[@]}" -gt 0 ] || continue
    [ "${#checked[@]}" -ge "${#rule_words[@]}" ] || continue
    [ "$exact" -eq 0 ] || [ "${#checked[@]}" -eq "${#rule_words[@]}" ] || continue
    index=0
    while [ "$index" -lt "${#rule_words[@]}" ]; do
      [ "${checked[$index]}" = "${rule_words[$index]}" ] || continue 2
      index=$((index + 1))
    done
    return 0
  done < <(jq -r '.permissions.allow[]? | strings | select(startswith("Bash(") and endswith(")")) | .[5:-1]' \
             "$hook_root/.claude/settings.json" 2>/dev/null)
  return 1
}

# non_git_segment_is_approved <segment>: 0 when the segment is one the header
# lists. Sets segment_runs_program to 1 for a settings-rule match, else 0.
non_git_segment_is_approved() {
  local entry name segment="$1"
  segment_runs_program=0
  segment="${segment#"${segment%%[![:space:]]*}"}"
  segment="${segment%"${segment##*[![:space:]]}"}"
  # The whole segment is the assignment, never a prefix to a command.
  if [[ "$segment" =~ $literal_assignment_pattern ]] || [[ "$segment" =~ $double_quoted_assignment_pattern ]] \
     || [[ "$segment" =~ $single_quoted_assignment_pattern ]]; then
    assignment_name_is_safe "${BASH_REMATCH[1]}"
    return
  fi
  split_git_words "$segment"
  [ "${#words[@]}" -gt 0 ] || return 1
  case "${words[0]}" in
    echo | true | false | pwd) return 0 ;;
    # `printf -v` assigns a variable, which can be PATH.
    printf) case "${words[1]:-}" in -v*) return 1 ;; esac; return 0 ;;
    date) date_prints_time; return ;;
  esac
  for entry in ${GAIA_READER_PROGRAMS[@]+"${GAIA_READER_PROGRAMS[@]}"}; do
    name="${entry%%|*}"
    [ "$name" = "${words[0]}" ] || continue
    reader_is_approved "$entry"
    return
  done
  matches_allow_rule || return 1
  segment_runs_program=1
  return 0
}
