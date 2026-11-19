# shellcheck shell=bash
#
# Rate-limit producer and display source for the GAIA statusline. Sourced by
# gaia-statusline.sh as "$GAIA_DIRECTORY/statusline/rate-limits-reading.sh"; defines
# one function and runs nothing at source time.
#
# Why it exists: the statusline is the only place the account's rate-limit
# windows arrive, so every render hands what it saw to the shared writer
# (scripts/rate-limits-lib.sh), which merges it into the one shared file, and
# displays from the merged result instead of its own possibly stale payload.
# The file shape, the merge rule and the bands live in that library; this file
# only turns the payload's two windows into the writer's input and the
# writer's display records into the four values the left side draws.
#
# One writer call per render and no second read of the file: the writer prints
# the merged display records itself, including the stored windows when it
# refuses a reading (return code 2), so a render whose payload carries no
# usable window still calls it and displays from those records.
#
# Silent by design, like the rest of the statusline: a failure never prints and
# never stops the render. When the library cannot be sourced nothing is set
# for display, so no usage segment renders rather than a second copy of the
# bands being consulted.

# gaia_statusline_rate_limits <main-root> <now> <five_hour_percentage> <five_hour_resets_at> <seven_day_percentage> <seven_day_resets_at>
# Sets _GAIA_RATE_LIMITS_FIVE_HOUR_PERCENTAGE, _GAIA_RATE_LIMITS_FIVE_HOUR_RESETS_AT,
# _GAIA_RATE_LIMITS_SEVEN_DAY_PERCENTAGE and _GAIA_RATE_LIMITS_SEVEN_DAY_RESETS_AT:
# each percentage is a whole number, `reset` or empty. Only the 5-hour and 7-day
# windows are ever drawn. Always returns 0.
gaia_statusline_rate_limits() {
  local root="${1:-}" now="${2:-}" five_hour_percentage="${3:-}" five_hour_resets_at="${4:-}"
  local seven_day_percentage="${5:-}" seven_day_resets_at="${6:-}"
  local windows="" input records="" name percentage resets_at state
  _GAIA_RATE_LIMITS_FIVE_HOUR_PERCENTAGE=""
  _GAIA_RATE_LIMITS_FIVE_HOUR_RESETS_AT=""
  _GAIA_RATE_LIMITS_SEVEN_DAY_PERCENTAGE=""
  _GAIA_RATE_LIMITS_SEVEN_DAY_RESETS_AT=""
  command -v gaia_rate_limits_write >/dev/null 2>&1 || return 0

  # A window with no reset time is shown from the payload and never written.
  if [ -n "$five_hour_percentage" ] && [ -n "$five_hour_resets_at" ]; then
    windows="\"five_hour\":{\"used_percentage\":${five_hour_percentage},\"resets_at\":${five_hour_resets_at}}"
  fi
  if [ -n "$seven_day_percentage" ] && [ -n "$seven_day_resets_at" ]; then
    windows="${windows:+$windows,}\"seven_day\":{\"used_percentage\":${seven_day_percentage},\"resets_at\":${seven_day_resets_at}}"
  fi
  input="{\"producer\":\"statusline\",\"windows\":{${windows}}}"

  # The writer's stdout is the merged display records on every return code; a
  # refusal's stderr is discarded. Return codes never matter here.
  records=$(gaia_rate_limits_write "$root" "$now" "$input" 2>/dev/null) || true

  while IFS=$'\t' read -r name percentage resets_at state; do
    [ -n "$name" ] || continue
    [ "$state" = "reset" ] && percentage="reset"
    case "$name" in
      five_hour)
        _GAIA_RATE_LIMITS_FIVE_HOUR_PERCENTAGE="$percentage"
        _GAIA_RATE_LIMITS_FIVE_HOUR_RESETS_AT="$resets_at"
        ;;
      seven_day)
        _GAIA_RATE_LIMITS_SEVEN_DAY_PERCENTAGE="$percentage"
        _GAIA_RATE_LIMITS_SEVEN_DAY_RESETS_AT="$resets_at"
        ;;
    esac
  done <<<"$records"

  # A window with no record falls back to the payload's own figure.
  if [ -z "$_GAIA_RATE_LIMITS_FIVE_HOUR_PERCENTAGE" ]; then
    _GAIA_RATE_LIMITS_FIVE_HOUR_PERCENTAGE="$five_hour_percentage"
    _GAIA_RATE_LIMITS_FIVE_HOUR_RESETS_AT="$five_hour_resets_at"
  fi
  if [ -z "$_GAIA_RATE_LIMITS_SEVEN_DAY_PERCENTAGE" ]; then
    _GAIA_RATE_LIMITS_SEVEN_DAY_PERCENTAGE="$seven_day_percentage"
    _GAIA_RATE_LIMITS_SEVEN_DAY_RESETS_AT="$seven_day_resets_at"
  fi
  return 0
}
