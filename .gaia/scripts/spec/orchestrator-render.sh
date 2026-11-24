#!/usr/bin/env bash
# Assembles a plan folder's ORCHESTRATOR.md and KICKOFF.md from the orchestrator
# template and the planner's kept parts file, so the planner writes only the
# plan-specific text and never retypes the fixed orchestrator text.
#
# Usage: orchestrator-render.sh <plan-dir> --parts <parts file> --audit <audit path | unset>
#          --branch <branch id> [--spec <spec path>]
#
# <plan-dir> is the absolute path of an existing plan folder. The template is
# <script dir>/../../../.claude/skills/gaia/references/plan/orchestrator-template.md.
# A re-render (the test stage appends a closing phase to the parts file) passes:
#   --parts   <plan-dir>/orchestrator-parts.md
#   --branch  the lowercased SPEC id for a spec-derived plan, else the plan
#             folder's basename
#   --audit   the SPEC folder's AUDIT.md when it exists, else unset
#   --spec    the SPEC folder's SPEC.md, for a spec-derived plan only
#
# Parts file grammar: parts are delimited by H2 lines at column 0 outside every
# fence. Allowed headings, in any order: ## Title, ## Pushes, ## Phase loop,
# ## Phase entries, ## Kickoff goal, ## Kickoff outline. Every part but ## Pushes
# is required and needs a non-blank body. A part's body is the lines after its
# heading up to the next part heading, leading and trailing blank lines trimmed,
# emitted verbatim at its template slot. The ## Title body's first non-blank
# line is the plan title; it also holds `Type: <Conventional Commits type>`
# (matches ^[a-z]+$) and `Slug: <2-4 word slug>` (none of " ` $ \) lines. Each
# phase entry in ## Phase entries opens with `**Phase <N>, <title>` on its own
# line outside every fence; {PHASE_COUNT} is the number of those lines. A part
# body holds none of the eight template tokens and no
# gaia:orchestrator-step sentinel line.
#
# Template grammar (the template's own header owns it): region markers pick the
# ORCHESTRATOR.md and KICKOFF.md text, part slots take a part body, render-if
# runs (spec, audit, pushes) are conditional, and a fenced block whose first
# content line is a gaia:orchestrator-step sentinel is emitted without its fence
# lines. Substitution is literal and runs on template lines only: the four
# values {PLAN_DIR}, {SPEC_PATH}, {AUDIT_PATH}, {BRANCH_ID}, plus {TITLE},
# {BRANCH_TYPE}, {BRANCH_SLUG} and {PHASE_COUNT}. Every other brace or angle
# placeholder passes through.
#
# Both files are rendered to temporary files in <plan-dir> first, then replaced;
# if the second replace fails the first is restored, so a refusal or a failure
# leaves both files as they were.
#
# Refusals (exit 1, one stderr line, outputs untouched), each prefixed
# `orchestrator-render: `:
#   missing part: <heading>             unknown part: <heading>
#   duplicate part: <heading>           text before the first part heading
#   part <heading> holds a gaia:orchestrator-step sentinel
#   part <heading> holds the token <token>
#   missing field: Type|Slug            invalid field: Type|Slug
#   --branch|--audit|--spec|--plan-dir holds a newline
#   template not found: <path>          malformed template: <reason>
#   unsubstituted token <token> in the rendered output
#   cannot write <file>
#
# Exit codes: 0 both written, nothing on stdout; 1 a refusal; 2 usage error (a
# missing or extra argument, a non-absolute or missing <plan-dir>, a missing
# parts file, a missing --spec file).
#
# Bash 3.2 compatible; BSD and GNU tools.
set -uo pipefail
# A quoted `&` in a replacement is literal only without bash 5.2's patsub_replacement.
shopt -u patsub_replacement 2>/dev/null || true

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$script_directory/../../../.claude/skills/gaia/references/plan/orchestrator-template.md"

usage() {
  printf 'usage: orchestrator-render.sh <plan-dir> --parts <parts file> --audit <audit path | unset> --branch <branch id> [--spec <spec path>]\n' >&2
  exit 2
}

# shellcheck source=.gaia/scripts/spec/orchestrator-render-lib.sh
source "$script_directory/orchestrator-render-lib.sh"

plan_directory=''
parts_file=''
audit_value=''
branch_id=''
spec_value=''
have_parts=0 have_audit=0 have_branch=0 have_spec=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --parts) [ "$#" -ge 2 ] && [ "$have_parts" -eq 0 ] || usage; parts_file="$2"; have_parts=1; shift 2 ;;
    --audit) [ "$#" -ge 2 ] && [ "$have_audit" -eq 0 ] || usage; audit_value="$2"; have_audit=1; shift 2 ;;
    --branch) [ "$#" -ge 2 ] && [ "$have_branch" -eq 0 ] || usage; branch_id="$2"; have_branch=1; shift 2 ;;
    --spec) [ "$#" -ge 2 ] && [ "$have_spec" -eq 0 ] || usage; spec_value="$2"; have_spec=1; shift 2 ;;
    -*) usage ;;
    *) [ -z "$plan_directory" ] || usage; plan_directory="$1"; shift ;;
  esac
done
[ -n "$plan_directory" ] && [ "$have_parts" -eq 1 ] && [ "$have_audit" -eq 1 ] && [ "$have_branch" -eq 1 ] || usage
[ -n "$parts_file" ] && [ -n "$audit_value" ] && [ -n "$branch_id" ] || usage
case "$plan_directory" in
  /*) ;;
  *) usage ;;
esac
plan_directory="${plan_directory%/}"
[ -n "$plan_directory" ] || usage
newline=$'\n'
case "$plan_directory" in *"$newline"*) refuse '--plan-dir holds a newline' ;; esac
case "$branch_id" in *"$newline"*) refuse '--branch holds a newline' ;; esac
case "$audit_value" in *"$newline"*) refuse '--audit holds a newline' ;; esac
case "$spec_value" in *"$newline"*) refuse '--spec holds a newline' ;; esac
[ -d "$plan_directory" ] || usage
[ -f "$parts_file" ] || usage
if [ "$have_spec" -eq 1 ]; then
  [ -n "$spec_value" ] && [ -f "$spec_value" ] || usage
  spec_value="$(cd "$(dirname "$spec_value")" && pwd)/$(basename "$spec_value")"
fi

# ---- parts file ----------------------------------------------------------
part_title='' part_pushes='' part_phase_loop='' part_phase_entries='' part_kickoff_goal='' part_kickoff_outline=''
seen_parts='|'
current_part=''
pending_blanks=''
in_fence=0
while IFS= read -r line || [ -n "$line" ]; do
  trim_line "$line"
  if [ "$in_fence" -eq 0 ] && [ "${line#'## '}" != "$line" ]; then
    heading="${line%"${line##*[![:space:]]}"}"
    case "$heading" in
      '## Title') current_part=part_title ;;
      '## Pushes') current_part=part_pushes ;;
      '## Phase loop') current_part=part_phase_loop ;;
      '## Phase entries') current_part=part_phase_entries ;;
      '## Kickoff goal') current_part=part_kickoff_goal ;;
      '## Kickoff outline') current_part=part_kickoff_outline ;;
      *) refuse "unknown part: $heading" ;;
    esac
    case "$seen_parts" in *"|$current_part|"*) refuse "duplicate part: $heading" ;; esac
    seen_parts="$seen_parts$current_part|"
    pending_blanks=''
    continue
  fi
  case "$trimmed" in '```'*) in_fence=$((1 - in_fence)) ;; esac
  if [ -z "$current_part" ]; then
    [ -z "$trimmed" ] || refuse 'text before the first part heading'
    continue
  fi
  if [ -z "$trimmed" ]; then
    [ -z "${!current_part}" ] || pending_blanks="$pending_blanks$line$newline"
    continue
  fi
  body="${!current_part}"
  printf -v "$current_part" '%s' "${body:+$body$newline}$pending_blanks$line"
  pending_blanks=''
done <"$parts_file"

for required in 'Title:part_title' 'Phase loop:part_phase_loop' 'Phase entries:part_phase_entries' 'Kickoff goal:part_kickoff_goal' 'Kickoff outline:part_kickoff_outline'; do
  required_variable="${required#*:}"
  [ -n "${!required_variable}" ] || refuse "missing part: ## ${required%%:*}"
done

check_part '## Title' "$part_title"
check_part '## Pushes' "$part_pushes"
check_part '## Phase loop' "$part_phase_loop"
check_part '## Phase entries' "$part_phase_entries"
check_part '## Kickoff goal' "$part_kickoff_goal"
check_part '## Kickoff outline' "$part_kickoff_outline"

# Title fields.
# shellcheck disable=SC2034 # read by the sourced library
title_text="${part_title%%"$newline"*}"
branch_type='' branch_slug='' have_type=0 have_slug=0
case "$part_title" in
  *"$newline"*)
    while IFS= read -r line || [ -n "$line" ]; do
      trim_line "$line"
      if [[ $trimmed =~ ^Type:[[:space:]]*(.*)$ ]] && [ "$have_type" -eq 0 ]; then
        branch_type="${BASH_REMATCH[1]}"
        have_type=1
      elif [[ $trimmed =~ ^Slug:[[:space:]]*(.*)$ ]] && [ "$have_slug" -eq 0 ]; then
        branch_slug="${BASH_REMATCH[1]}"
        have_slug=1
      fi
    done <<<"${part_title#*"$newline"}"
    ;;
esac
[ "$have_type" -eq 1 ] || refuse 'missing field: Type'
[ "$have_slug" -eq 1 ] || refuse 'missing field: Slug'
[[ $branch_type =~ ^[a-z]+$ ]] || refuse 'invalid field: Type'
[ -n "$branch_slug" ] || refuse 'invalid field: Slug'
backslash=$'\\'
case "$branch_slug" in *'"'* | *'`'* | *'$'* | *"$backslash"*) refuse 'invalid field: Slug' ;; esac

# {PHASE_COUNT}: the phase entry lines outside every fence.
phase_count=0
in_fence=0
while IFS= read -r line || [ -n "$line" ]; do
  trim_line "$line"
  case "$trimmed" in
    '```'*) in_fence=$((1 - in_fence)) ;;
    *) if [ "$in_fence" -eq 0 ] && [[ $trimmed =~ ^\*\*Phase\ [0-9]+,\  ]]; then phase_count=$((phase_count + 1)); fi ;;
  esac
done <<<"$part_phase_entries"

# ---- template ------------------------------------------------------------
[ -f "$template" ] || refuse "template not found: $template"
template_lines=()
while IFS= read -r line || [ -n "$line" ]; do
  template_lines+=("$line")
done <"$template"
template_count="${#template_lines[@]}"

# Region bounds: each marker appears once outside a fence, orchestrator first.
orchestrator_start=-1 kickoff_start=-1
in_fence=0
index=0
while [ "$index" -lt "$template_count" ]; do
  trim_line "${template_lines[$index]}"
  case "$trimmed" in
    '```'*) in_fence=$((1 - in_fence)) ;;
    '<!-- gaia:template orchestrator -->')
      [ "$in_fence" -eq 1 ] || { [ "$orchestrator_start" -lt 0 ] || refuse 'malformed template: the orchestrator region marker appears twice'; orchestrator_start=$index; }
      ;;
    '<!-- gaia:template kickoff -->')
      [ "$in_fence" -eq 1 ] || { [ "$kickoff_start" -lt 0 ] || refuse 'malformed template: the kickoff region marker appears twice'; kickoff_start=$index; }
      ;;
  esac
  index=$((index + 1))
done
[ "$orchestrator_start" -ge 0 ] || refuse 'malformed template: no orchestrator region marker'
[ "$kickoff_start" -gt "$orchestrator_start" ] || refuse 'malformed template: the kickoff region marker is missing or before the orchestrator region marker'

# ---- render, check, replace ----------------------------------------------
orchestrator_output="$plan_directory/ORCHESTRATOR.md"
kickoff_output="$plan_directory/KICKOFF.md"
temp_orchestrator='' temp_kickoff='' backup=''
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { rm -f -- "$temp_orchestrator" "$temp_kickoff" "$backup"; }
trap cleanup EXIT
temp_orchestrator="$(mktemp "$plan_directory/.orchestrator-render.XXXXXX")" || refuse "cannot write $orchestrator_output"
temp_kickoff="$(mktemp "$plan_directory/.orchestrator-render.XXXXXX")" || refuse "cannot write $kickoff_output"

render_region "$((orchestrator_start + 1))" "$kickoff_start" >"$temp_orchestrator" || exit 1
render_region "$((kickoff_start + 1))" "$template_count" >"$temp_kickoff" || exit 1

for token in '{PLAN_DIR}' '{SPEC_PATH}' '{AUDIT_PATH}' '{BRANCH_ID}' '{TITLE}' '{BRANCH_TYPE}' '{BRANCH_SLUG}' '{PHASE_COUNT}'; do
  if grep -qF -- "$token" "$temp_orchestrator" "$temp_kickoff"; then
    refuse "unsubstituted token $token in the rendered output"
  fi
done

if [ -e "$orchestrator_output" ]; then
  backup="$(mktemp "$plan_directory/.orchestrator-render.XXXXXX")" || refuse "cannot write $orchestrator_output"
  cp -p -- "$orchestrator_output" "$backup" || refuse "cannot write $orchestrator_output"
fi
replace_file "$temp_orchestrator" "$orchestrator_output" || refuse "cannot write $orchestrator_output"
if ! replace_file "$temp_kickoff" "$kickoff_output"; then
  if [ -n "$backup" ]; then mv -f -- "$backup" "$orchestrator_output"; else rm -f -- "$orchestrator_output"; fi
  refuse "cannot write $kickoff_output"
fi
exit 0
