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
# worktree. A usage window renders from the writer's display records
# (see rate-limits-reading.sh), so no plan logic lives here;
# a window absent from those records and from the payload is not drawn.
#
# The bar is colored from the shared threshold lib's bands (green below yellow,
# yellow from yellow, red from red, fire and skull markers above), the same
# bands the audit-loop checkpoint reads, so the bar and the checkpoint cannot
# disagree. Those bands are token counts for a context window, so they do not
# apply to the usage windows, whose percentage bands come from the rate-limit
# library (scripts/rate-limits-lib.sh). Hot path:
# bash arithmetic and builtins only, plus the one git call for the branch, and, when a checkpoint
# override file exists, one jq call.

# gaia_statusline_usage_segment <icon> <percentage|reset> <resets_at_epoch_seconds> <countdown_from_percentage> <now>
# Sets _GAIA_STATUSLINE_USAGE_SEGMENT rather than printing, so the hot path forks
# no subshell for it. The bands come from the rate-limit library; with them
# unset nothing renders. The countdown shows once the reset time decides what
# happens next: from the warning band for the 5-hour window, whose reset is near
# enough to plan around, and from the critical band for the 7-day window, whose
# reset at the warning band can still be days off. `reset` means the window's
# reset time has passed: no percentage and no countdown.
gaia_statusline_usage_segment() {
  local icon="${1:-}" percentage="${2:-}" resets_at="${3:-}" countdown_from="${4:-}" now="${5:-}"
  local color=$'\033[01;32m' reset=$'\033[00m' countdown="" seconds_left minutes_left days hours minutes
  _GAIA_STATUSLINE_USAGE_SEGMENT=""
  [ -n "$percentage" ] || return 0
  [ -n "${GAIA_RATE_LIMIT_WARNING_PERCENTAGE:-}" ] && [ -n "${GAIA_RATE_LIMIT_CRITICAL_PERCENTAGE:-}" ] || return 0
  if [ "$percentage" = "reset" ]; then
    _GAIA_STATUSLINE_USAGE_SEGMENT="${icon} ${color}reset${reset}"
    return 0
  fi
  if [ "$percentage" -ge "$GAIA_RATE_LIMIT_CRITICAL_PERCENTAGE" ]; then
    color=$'\033[01;31m'
  elif [ "$percentage" -ge "$GAIA_RATE_LIMIT_WARNING_PERCENTAGE" ]; then
    color=$'\033[01;33m'
  fi
  if [ "$percentage" -ge "$countdown_from" ]; then
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

# gaia_statusline_left <state-root> <session-directory> <is-worktree> <model> <effort> <used_percentage> <window_size> <used_tokens> <five_hour_percentage> <five_hour_resets_at> <seven_day_percentage> <seven_day_resets_at> <now>
# Sets _GAIA_STATUSLINE_LEFT to the rendered string (ANSI escapes included); returns 1
# and leaves it empty when there is nothing to show. The usage percentages arrive
# as whole numbers or `reset`, from the writer's display records.
gaia_statusline_left() {
  local root="${1:-}" session_directory="${2:-}" is_worktree="${3:-}" model="${4:-}" effort="${5:-}"
  local used_percentage="${6:-}" window="${7:-}" tokens="${8:-}"
  local five_hour_percentage="${9:-}" five_hour_resets_at="${10:-}" seven_day_percentage="${11:-}" seven_day_resets_at="${12:-}" now="${13:-}"
  local escape_character=$'\033' reset=$'\033[00m' rendered="" separator=" │ " project branch effort_capitalized
  local integer_part fraction_part used_percentage_rounded filled i bar="" color marker="" override_marker="" override_status ask_tokens line bands
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
    # One parse serves both the line and the marker; a zero line (checkpoint
    # off) has no bands, so the bar stays green.
    override_status="" ask_tokens=""
    if command -v gaia_context_override_state >/dev/null 2>&1; then
      read -r override_status ask_tokens _ <<<"$(gaia_context_override_state "$root")"
    fi
    case "$override_status" in
      clamped-low | clamped-high | invalid) override_marker=" ${escape_character}[01;33m⚠ override${reset}" ;;
    esac
    if [ -n "$ask_tokens" ] &&
      line=$(gaia_context_line "$window" "$ask_tokens" "$GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT") &&
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
    rendered="${rendered:+$rendered$separator}${color}${bar}${reset} ${used_percentage_rounded}%${marker}${override_marker}"
  fi

  gaia_statusline_usage_segment "🕔" "$five_hour_percentage" "$five_hour_resets_at" "${GAIA_RATE_LIMIT_WARNING_PERCENTAGE:-}" "$now"
  [ -n "$_GAIA_STATUSLINE_USAGE_SEGMENT" ] && rendered="${rendered:+$rendered$separator}${_GAIA_STATUSLINE_USAGE_SEGMENT}"
  gaia_statusline_usage_segment "📅" "$seven_day_percentage" "$seven_day_resets_at" "${GAIA_RATE_LIMIT_CRITICAL_PERCENTAGE:-}" "$now"
  [ -n "$_GAIA_STATUSLINE_USAGE_SEGMENT" ] && rendered="${rendered:+$rendered$separator}${_GAIA_STATUSLINE_USAGE_SEGMENT}"

  [ -n "$rendered" ] || return 1
  _GAIA_STATUSLINE_LEFT="$rendered"
}
