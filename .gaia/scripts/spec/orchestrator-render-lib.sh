#!/usr/bin/env bash
# shellcheck disable=SC2154 # the sourcing script owns the globals
# Sourced by orchestrator-render.sh: its refusal and trim helpers, the part-body
# check, the literal token substitution, the region renderer and the file
# replace. Relies on the globals of the caller (plan_directory, spec_value,
# audit_value, branch_id, title_text, branch_type, branch_slug, phase_count,
# have_spec, the part_* bodies, template_lines) and on its
# `shopt -u patsub_replacement`, so a replacement value lands literally.

refuse() {
  printf 'orchestrator-render: %s\n' "$1" >&2
  exit 1
}

# trim_line <text>: sets trimmed to the text without leading and trailing whitespace.
trim_line() {
  trimmed="${1#"${1%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
}

# check_part <heading> <body>: refuses a sentinel line or a template token in a part body.
check_part() {
  local part_line token
  while IFS= read -r part_line || [ -n "$part_line" ]; do
    trim_line "$part_line"
    case "$trimmed" in '<!-- gaia:orchestrator-step '*) refuse "part $1 holds a gaia:orchestrator-step sentinel" ;; esac
  done <<<"$2"
  for token in '{PLAN_DIR}' '{SPEC_PATH}' '{AUDIT_PATH}' '{BRANCH_ID}' '{TITLE}' '{BRANCH_TYPE}' '{BRANCH_SLUG}' '{PHASE_COUNT}'; do
    case "$2" in *"$token"*) refuse "part $1 holds the token $token" ;; esac
  done
}

# substitute_line <text>: sets substituted to the text with each token replaced
# by its value, literally (pattern quoted, replacement unquoted).
substitute_line() {
  substituted="$1"
  case "$substituted" in *'{'*) ;; *) return 0 ;; esac
  substituted="${substituted//"{PLAN_DIR}"/$plan_directory}"
  [ "$have_spec" -eq 0 ] || substituted="${substituted//"{SPEC_PATH}"/$spec_value}"
  [ "$audit_value" = unset ] || substituted="${substituted//"{AUDIT_PATH}"/$audit_value}"
  substituted="${substituted//"{BRANCH_ID}"/$branch_id}"
  substituted="${substituted//"{TITLE}"/$title_text}"
  substituted="${substituted//"{BRANCH_TYPE}"/$branch_type}"
  substituted="${substituted//"{BRANCH_SLUG}"/$branch_slug}"
  substituted="${substituted//"{PHASE_COUNT}"/$phase_count}"
}

# render_region <first line index> <end index (exclusive)>: writes the region to stdout.
render_region() {
  local index="$1" end="$2" in_fence=0 fixed_fence=0 lookahead conditional='' emit=1 slot_text
  while [ "$index" -lt "$end" ]; do
    local raw="${template_lines[$index]}"
    trim_line "$raw"
    local line_kind="$trimmed"
    index=$((index + 1))
    if [ "$in_fence" -eq 1 ]; then
      case "$line_kind" in
        '```'*)
          in_fence=0
          if [ "$fixed_fence" -eq 1 ]; then fixed_fence=0; continue; fi
          ;;
      esac
    else
      case "$line_kind" in
        '```'*)
          in_fence=1
          lookahead="$index"
          while [ "$lookahead" -lt "$end" ]; do
            trim_line "${template_lines[$lookahead]}"
            [ -z "$trimmed" ] || break
            lookahead=$((lookahead + 1))
          done
          if [ "$lookahead" -lt "$end" ]; then
            case "$trimmed" in '<!-- gaia:orchestrator-step '*) fixed_fence=1 ;; esac
          fi
          if [ "$fixed_fence" -eq 1 ]; then continue; fi
          ;;
        '<!-- gaia:render-if '*' -->')
          [ -z "$conditional" ] || refuse 'malformed template: render-if blocks nest'
          conditional="${line_kind#'<!-- gaia:render-if '}"
          conditional="${conditional%' -->'}"
          case "$conditional" in
            spec) [ "$have_spec" -eq 1 ] && emit=1 || emit=0 ;;
            audit) [ "$audit_value" != unset ] && emit=1 || emit=0 ;;
            pushes) [ -n "$part_pushes" ] && emit=1 || emit=0 ;;
            *) refuse "malformed template: unknown render-if $conditional" ;;
          esac
          continue
          ;;
        '<!-- gaia:render-end -->')
          [ -n "$conditional" ] || refuse 'malformed template: render-end without render-if'
          conditional=''
          emit=1
          continue
          ;;
        '<!-- gaia:part '*' -->')
          slot_text="${line_kind#'<!-- gaia:part '}"
          slot_text="${slot_text%' -->'}"
          case "$slot_text" in
            pushes) slot_text="$part_pushes" ;;
            phase-loop) slot_text="$part_phase_loop" ;;
            phase-entries) slot_text="$part_phase_entries" ;;
            kickoff-goal) slot_text="$part_kickoff_goal" ;;
            kickoff-outline) slot_text="$part_kickoff_outline" ;;
            *) refuse "malformed template: unknown part slot $slot_text" ;;
          esac
          if [ "$emit" -eq 1 ] && [ -n "$slot_text" ]; then printf '%s\n' "$slot_text"; fi
          continue
          ;;
      esac
    fi
    [ "$emit" -eq 1 ] || continue
    substitute_line "$raw"
    printf '%s\n' "$substituted"
  done
  [ -z "$conditional" ] || refuse 'malformed template: a render-if block is not closed'
}

# replace_file <temporary file> <target>: moves a rendered file into place.
replace_file() {
  [ ! -d "$2" ] || return 1
  chmod 644 "$1" && mv -f -- "$1" "$2"
}
