# shellcheck shell=bash
#
# Default left side of the GAIA statusline; gaia-statusline.sh's left-side
# resolution decides when it renders. Sourced by gaia-statusline.sh as
# "$GAIA_DIRECTORY/statusline/gaia-statusline-left.sh"; defines functions and constants and runs
# nothing else at source time.
#
# Shape: project | branch | model (effort) | context bar | 5-hour usage | 7-day
# usage. The project is the MAIN checkout's folder name, so a linked worktree
# shows the main project; the branch carries a tree marker inside a linked
# worktree. A usage window renders only when Claude Code sends it, so no plan
# logic lives here.
#
# The bar is colored from the shared threshold lib's bands (green below yellow,
# yellow from yellow, red from red, fire and skull markers above), the same
# bands the audit-loop checkpoint reads, so the bar and the checkpoint cannot
# disagree. Those bands are token counts for a context window, so they do not
# apply to the usage windows, which carry their own percentage bands. Hot path:
# bash arithmetic and builtins only, plus the one git call for the branch, one
# date call per usage window at or past its countdown band, and, when a checkpoint
# override file exists, one jq call.

# The countdown shows once the reset time decides what happens next: from yellow
# for the 5-hour window, whose reset is near enough to plan around, and from red
# for the 7-day window, whose reset at yellow can still be days off.
GAIA_USAGE_YELLOW_PERCENTAGE=75
GAIA_USAGE_RED_PERCENTAGE=90

# gaia_statusline_usage_segment <icon> <rounded_percentage> <resets_at_epoch_seconds> <countdown_from_percentage>
# Sets _GAIA_STATUSLINE_USAGE_SEGMENT rather than printing, so the hot path forks
# no subshell for it.
gaia_statusline_usage_segment() {
  local icon="${1:-}" percentage="${2:-}" resets_at="${3:-}" countdown_from="${4:-$GAIA_USAGE_RED_PERCENTAGE}"
  local color=$'\033[01;32m' reset=$'\033[00m' countdown="" now seconds_left minutes_left days hours minutes
  _GAIA_STATUSLINE_USAGE_SEGMENT=""
  [ -n "$percentage" ] || return 0
  if [ "$percentage" -ge "$GAIA_USAGE_RED_PERCENTAGE" ]; then
    color=$'\033[01;31m'
  elif [ "$percentage" -ge "$GAIA_USAGE_YELLOW_PERCENTAGE" ]; then
    color=$'\033[01;33m'
  fi
  if [ "$percentage" -ge "$countdown_from" ]; then
    now=$(date +%s 2>/dev/null) || now=""
    if [ -n "$resets_at" ] && [ -n "$now" ]; then
      seconds_left=$((resets_at - now))
      if [ "$seconds_left" -gt 0 ]; then
        # Rounded up so the final minute reads 1m rather than 0m.
        minutes_left=$(((seconds_left + 59) / 60))
        days=$((minutes_left / 1440))
        hours=$((minutes_left % 1440 / 60))
        minutes=$((minutes_left % 60))
        if [ "$days" -gt 0 ]; then
          countdown=" (${days}d${hours}h)"
        elif [ "$hours" -gt 0 ]; then
          countdown=" (${hours}h${minutes}m)"
        else
          countdown=" (${minutes}m)"
        fi
      fi
    fi
  fi
  _GAIA_STATUSLINE_USAGE_SEGMENT="${icon} ${color}${percentage}%${reset}${countdown}"
}

# gaia_statusline_left <state-root> <session-directory> <is-worktree> <model> <effort> <used_percentage> <window_size> <used_tokens> <five_hour_percentage> <five_hour_resets_at> <seven_day_percentage> <seven_day_resets_at>
# Sets _GAIA_STATUSLINE_LEFT to the rendered string (ANSI escapes included); returns 1
# and leaves it empty when there is nothing to show. The usage percentages arrive
# as whole numbers, already validated by the entrypoint's jq call.
gaia_statusline_left() {
  local root="${1:-}" session_directory="${2:-}" is_worktree="${3:-}" model="${4:-}" effort="${5:-}"
  local used_percentage="${6:-}" window="${7:-}" tokens="${8:-}"
  local five_hour_percentage="${9:-}" five_hour_resets_at="${10:-}" seven_day_percentage="${11:-}" seven_day_resets_at="${12:-}"
  local escape_character=$'\033' reset=$'\033[00m' rendered="" separator=" │ " project branch effort_capitalized
  local integer_part fraction_part used_percentage_rounded filled i bar="" color marker="" checkpoint_override ask_tokens ask_window_percent line bands
  local yellow red fire skull
  _GAIA_STATUSLINE_LEFT=""

  project="${root##*/}"
  [ -n "$project" ] && rendered="${escape_character}[01;34m${project}${reset}"

  if [ -n "$session_directory" ]; then
    branch=$(git -C "$session_directory" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
    if [ -n "$branch" ]; then
      [ "$is_worktree" = "true" ] && branch="🌳 ${branch}"
      rendered="${rendered:+$rendered$separator}${escape_character}[01;32m${branch}${reset}"
    fi
  fi

  model="${model#Claude }"
  if [ -n "$effort" ]; then
    case "$effort" in
      xhigh) effort_capitalized="XHigh" ;;
      low) effort_capitalized="Low" ;;
      medium) effort_capitalized="Medium" ;;
      high) effort_capitalized="High" ;;
      max) effort_capitalized="Max" ;;
      *) effort_capitalized="$effort" ;;
    esac
    model="${model:+$model }(${effort_capitalized})"
  fi
  [ -n "$model" ] && rendered="${rendered:+$rendered$separator}${escape_character}[01;36m${model}${reset}"

  # The bar needs the percentage for fill and the percentage-derived token
  # count plus the window for color; without all three there is no honest bar.
  if [ -n "$used_percentage" ] && [ -n "$window" ] && [ -n "$tokens" ] && command -v gaia_context_bands >/dev/null 2>&1; then
    integer_part="${used_percentage%%.*}"
    fraction_part=""
    case "$used_percentage" in *.*) fraction_part="${used_percentage#*.}" ;; esac
    used_percentage_rounded=$((10#${integer_part:-0}))
    case "$fraction_part" in [5-9]*) used_percentage_rounded=$((used_percentage_rounded + 1)) ;; esac
    # round(used_percentage / 10) from the integer part alone: exact, no float math.
    filled=$(((10#${integer_part:-0} + 5) / 10))
    [ "$filled" -gt 10 ] && filled=10
    i=0
    while [ "$i" -lt 10 ]; do
      if [ "$i" -lt "$filled" ]; then bar="${bar}▓"; else bar="${bar}░"; fi
      i=$((i + 1))
    done
    color="${escape_character}[01;32m"
    if checkpoint_override=$(gaia_context_override "$root") && read -r ask_tokens ask_window_percent <<<"$checkpoint_override" &&
      line=$(gaia_context_line "$window" "$ask_tokens" "$ask_window_percent") &&
      bands=$(gaia_context_bands "$window" "$line") && read -r yellow red fire skull <<<"$bands"; then
      if [ "$tokens" -ge "$skull" ]; then
        color="${escape_character}[01;31m"
        marker=" 💀"
      elif [ "$tokens" -ge "$fire" ]; then
        color="${escape_character}[01;31m"
        marker=" 🔥"
      elif [ "$tokens" -ge "$red" ]; then
        color="${escape_character}[01;31m"
      elif [ "$tokens" -ge "$yellow" ]; then
        color="${escape_character}[01;33m"
      fi
    fi
    rendered="${rendered:+$rendered$separator}${color}${bar}${reset} ${used_percentage_rounded}%${marker}"
  fi

  gaia_statusline_usage_segment "🕔" "$five_hour_percentage" "$five_hour_resets_at" "$GAIA_USAGE_YELLOW_PERCENTAGE"
  [ -n "$_GAIA_STATUSLINE_USAGE_SEGMENT" ] && rendered="${rendered:+$rendered$separator}${_GAIA_STATUSLINE_USAGE_SEGMENT}"
  gaia_statusline_usage_segment "📅" "$seven_day_percentage" "$seven_day_resets_at" "$GAIA_USAGE_RED_PERCENTAGE"
  [ -n "$_GAIA_STATUSLINE_USAGE_SEGMENT" ] && rendered="${rendered:+$rendered$separator}${_GAIA_STATUSLINE_USAGE_SEGMENT}"

  [ -n "$rendered" ] || return 1
  _GAIA_STATUSLINE_LEFT="$rendered"
}
