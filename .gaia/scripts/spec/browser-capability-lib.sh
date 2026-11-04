# shellcheck shell=bash
#
# Sourced by plan-verify.sh, never executed. Parses and validates one browser
# capability line from a task doc. The closed capability list and its cue
# patterns stay in plan-verify.sh (capability_tokens and capability_cues,
# parallel by index, plus the joined capability_allowed_list); these helpers read them as
# globals, along with uat_lib_whitespace_text from uat-lib.sh.
#
# Bash 3.2 compatible; BSD and GNU tools.

# plan-verify.sh assigns the capability globals before it calls these helpers.
# shellcheck disable=SC2154

# Sets capability_name and phrase_text from the text after the line marker's
# colon: split on the first colon followed by a space or the end of the text.
split_capability_text() {
  # The appended space folds "a colon at the end of the text" into ": ".
  local padded="$1 "
  case "$padded" in
    *': '*)
      capability_name="${padded%%: *}"
      phrase_text="${padded#*: }"
      ;;
    *)
      capability_name="$1"
      phrase_text=''
      ;;
  esac
}

trim_text() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

# Status 0 when the phrase occurs in the then-clause with word boundaries.
# Both arrive through ENVIRON: awk -v would process backslash escapes.
phrase_is_word_bounded() {
  local found
  found=$(PHRASE_TEXT="$1" THEN_TEXT="$2" LC_ALL=C awk '
    BEGIN {
      phrase = ENVIRON["PHRASE_TEXT"]; then_text = ENVIRON["THEN_TEXT"]
      width = length(phrase); offset = 0; ok = 0
      while ((hit = index(substr(then_text, offset + 1), phrase)) > 0) {
        position = offset + hit
        before = (position == 1) ? "" : substr(then_text, position - 1, 1)
        after = substr(then_text, position + width, 1)
        if (before !~ /[[:alnum:]]/ && after !~ /[[:alnum:]]/) { ok = 1; break }
        offset = position
      }
      print ok
    }')
  [ "$found" = 1 ]
}

# Prints the failure for one capability line, nothing when it validates.
# Args: uat_id, then-clause, text after the marker.
capability_line_problem() {
  local uat="$1" then_text="$2" text="$3" index cue
  text=$(trim_text "$text")
  split_capability_text "${text#:}"
  capability_name=$(trim_text "$capability_name")
  phrase_text=$(trim_text "$phrase_text")
  index=0
  while [ "$index" -lt "${#capability_tokens[@]}" ]; do
    [ "${capability_tokens[$index]}" = "$capability_name" ] && break
    index=$((index + 1))
  done
  if [ "$index" -ge "${#capability_tokens[@]}" ]; then
    printf "%s names browser capability '%s', which is not in the closed list; allowed: %s" "$uat" "$capability_name" "$capability_allowed_list"
    return
  fi
  case "$phrase_text" in
    \"*\" | \`*\`)
      phrase_text="${phrase_text#?}"
      phrase_text="${phrase_text%?}"
      ;;
  esac
  phrase_text=$(printf '%s' "$phrase_text" | uat_lib_whitespace_text)
  cue="${capability_cues[$index]}"
  if [ -n "$phrase_text" ] &&
    phrase_is_word_bounded "$phrase_text" "$then_text" &&
    printf '%s\n' "$phrase_text" | LC_ALL=C grep -qiE "(^|[^[:alnum:]])($cue)([^[:alnum:]]|\$)"; then
    return
  fi
  printf "%s cites the phrase '%s' for %s; the capability phrase must appear verbatim in its then-clause and contain a cue word of that capability" "$uat" "$phrase_text" "$capability_name"
}
