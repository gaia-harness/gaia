#!/usr/bin/env bash
# Deterministic part of the /gaia-plan verification step (step 4.5): checks a
# generated plan folder before an orchestrator runs it cold. The decomposition
# audit that follows is skipped for trivial plans and when fan-out is
# unavailable, so the checks that must always run live here.
#
# Usage: plan-verify.sh <plan-dir> [--spec <spec-path>]
#
# Always checked: README.md, ORCHESTRATOR.md, KICKOFF.md and at least one
# task-*.md exist; ORCHESTRATOR.md carries the verbatim step sentinels the plan
# needs, each on a line of its own (leading and trailing whitespace allowed,
# nothing else), in the order the template places them. Without --spec the plan
# is spec-less and the three UAT sentinels are not required. The
# yield-handling, worthiness-step, overlap-pass, wiki-promotion, code-audit and
# post-clearance blocks are also checked verbatim: each one's non-blank lines
# (trimmed) must equal the fenced block planner.md holds, with the
# plan-directory and SPEC-path placeholders replaced by this plan's absolute
# values, so a paraphrased or shortened copy cannot ship. Maintainer-only marker
# lines inside a block are compared like any other line, so a plan matches the
# planner.md it was generated from, marked or stripped, and a plan that dropped a
# marked pair its planner.md keeps fails. A plan generated before a block
# existed is not re-verified: only /gaia-plan step 4.5 runs this script.
# README.md, ORCHESTRATOR.md, KICKOFF.md and every task-*.md hold no
# literal {PLAN_DIR}, {SPEC_PATH} or {AUDIT_PATH}; one failure line per hit.
#
# With --spec (a spec-derived plan) additionally: the UAT routing table in
# README.md validates (delegated to uat_lib_validate_routing); the three UAT
# sentinels are required; every story-routed UAT has a story test
# criterion line in some task doc whose text carries the UAT's then-clause.
# A story or non-ui row whose then-clause reads like a route, navigation, URL,
# redirect, session or server-state check prints a non-fatal WARN: line
# (misrouting hint). An e2e row, which only a plan generated before the split
# holds, fails with a line telling the planner to route it real-server (the live
# stack with no page) or browser (only a real browser shows it); the shared
# validator still accepts it.
#
# A browser row must name the capability that needs a real browser, from this
# closed list (matched exactly as spelled, case-sensitive), each with the cue
# words its phrase must carry (case-insensitive, word-bounded):
#   capability: client JavaScript | cues: without a reload|client-side|optimistic(ally)?|live
#   capability: layout or visual position | cues: beside|above|below|position(s|ed)?|viewport|layout
#   capability: focus or keyboard | cues: focus(es|ed|ing)?|keyboard|tab key
#   capability: rendered-DOM accessibility scan | cues: accessibility|axe|screen readers?
#   capability: browser-only navigation | cues: back button|browser history|client navigation
# The line lives in any task-*.md:
#   - Browser capability (<uat_id>): <capability>: <then-clause phrase, verbatim>
# Parse: the text after the marker is trimmed, then split on the first colon
# followed by a space or the end of the text; the left side is the capability,
# the right side the phrase. A bare trailing colon, or no such colon, gives an
# empty phrase. One enclosing pair of double quotes or backticks is stripped
# from the phrase, then whitespace is normalized. The phrase must be a
# case-sensitive substring of the whitespace-normalized then-clause with at
# least one word-bounded occurrence, and must contain a cue word of the
# capability it names. With several lines for one UAT the row passes when any
# one validates; otherwise the first line found is the one reported.
# A browser row whose Given says JavaScript is disabled (javascript or js
# followed by disabled, off, turned off or not enabled; or without or no
# javascript or js) is refused whatever its capability line says, since a
# request client never runs JavaScript and the UAT belongs on real-server. The
# pattern is word-bounded, so a Given that says "no JavaScript errors" is
# refused too: an accepted false positive, resolved by routing.
#
# Every failure is reported on stderr, one line each, in a single run.
#
# Exit codes: 0 pass; 1 one or more failures; 2 usage error.
#
# Bash 3.2 compatible; BSD and GNU tools.
capability_tokens=("client JavaScript" "layout or visual position" "focus or keyboard" "rendered-DOM accessibility scan" "browser-only navigation")
capability_cues=('without a reload|client-side|optimistic(ally)?|live' 'beside|above|below|position(s|ed)?|viewport|layout' 'focus(es|ed|ing)?|keyboard|tab key' 'accessibility|axe|screen readers?' 'back button|browser history|client navigation')
javascript_disabled_pattern='(^|[^[:alnum:]])((javascript|js)[ -](is )?(disabled|off|turned off|not enabled)|without (javascript|js)|no[ -](javascript|js))([^[:alnum:]]|$)'
set -uo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/spec/uat-lib.sh
. "$script_directory/uat-lib.sh"
# shellcheck source=.gaia/scripts/spec/browser-capability-lib.sh
. "$script_directory/browser-capability-lib.sh"

usage() {
  printf 'usage: plan-verify.sh <plan-dir> [--spec <spec-path>]\n' >&2
  exit 2
}

plan_directory=''
spec_path=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --spec)
      [ "$#" -ge 2 ] || usage
      spec_path="$2"
      shift 2
      ;;
    -*) usage ;;
    *)
      [ -z "$plan_directory" ] || usage
      plan_directory="$1"
      shift
      ;;
  esac
done
[ -n "$plan_directory" ] || usage
if [ ! -d "$plan_directory" ]; then
  printf 'plan-verify: plan folder not found: %s\n' "$plan_directory" >&2
  exit 2
fi
if [ -n "$spec_path" ] && [ ! -f "$spec_path" ]; then
  printf 'plan-verify: SPEC not found: %s\n' "$spec_path" >&2
  exit 2
fi

failures=0
fail() {
  printf 'plan-verify: %s\n' "$1" >&2
  failures=$((failures + 1))
}

capability_allowed_list=''
for capability_token in "${capability_tokens[@]}"; do
  capability_allowed_list="${capability_allowed_list:+$capability_allowed_list, }$capability_token"
done

# The capability line scan runs over every task doc; the JavaScript-disabled
# check reads the Given and fires independently of the line.
browser_row_check() {
  local uat="$1" then_text="$2" given_text="$3" marker task_line problem first_problem='' passed=0
  marker="Browser capability ($uat)"
  if [ "${#task_files[@]}" -gt 0 ]; then
    while IFS= read -r task_line; do
      problem=$(capability_line_problem "$uat" "$then_text" "${task_line#*"$marker"}")
      if [ -z "$problem" ]; then
        passed=1
        break
      fi
      [ -n "$first_problem" ] || first_problem="$problem"
    done < <(grep -hF -- "$marker" "${task_files[@]}")
  fi
  if [ "$passed" -eq 0 ]; then
    if [ -n "$first_problem" ]; then
      fail "$first_problem"
    else
      fail "$uat is routed browser but no task doc carries its line: - $marker: <capability>: <then-clause phrase>; a browser row needs a capability from the closed list: $capability_allowed_list"
    fi
  fi
  if printf '%s\n' "$given_text" | grep -qiE "$javascript_disabled_pattern"; then
    fail "$uat is routed browser but its Given says JavaScript is disabled; a JavaScript-disabled UAT routes to real-server"
  fi
}

readme="$plan_directory/README.md"
orchestrator="$plan_directory/ORCHESTRATOR.md"

[ -f "$readme" ] || fail "README.md is missing from $plan_directory"
[ -f "$orchestrator" ] || fail "ORCHESTRATOR.md is missing from $plan_directory"
[ -f "$plan_directory/KICKOFF.md" ] || fail "KICKOFF.md is missing from $plan_directory"
task_files=()
for candidate in "$plan_directory"/task-*.md; do
  [ -f "$candidate" ] && task_files+=("$candidate")
done
[ "${#task_files[@]}" -gt 0 ] || fail "no task-*.md file exists in $plan_directory"

# Required sentinels in the order the template places them.
sentinels=()
if [ -n "$spec_path" ]; then
  sentinels+=('<!-- gaia:orchestrator-step uat-render -->' '<!-- gaia:orchestrator-step uat-gate -->')
fi
sentinels+=('<!-- gaia:orchestrator-step yield-handling -->')
if [ -n "$spec_path" ]; then
  sentinels+=('<!-- gaia:orchestrator-step uat-pre-audit -->')
fi
sentinels+=(
  '<!-- gaia:orchestrator-step worthiness-step -->'
  '<!-- gaia:orchestrator-step overlap-pass -->'
  '<!-- gaia:orchestrator-step wiki-promotion -->'
  '<!-- gaia:orchestrator-step code-audit -->'
  '<!-- gaia:orchestrator-step post-clearance -->'
  '<!-- gaia:orchestrator-step post-merge-close -->'
)
verbatim_sentinels=(
  '<!-- gaia:orchestrator-step yield-handling -->'
  '<!-- gaia:orchestrator-step worthiness-step -->'
  '<!-- gaia:orchestrator-step overlap-pass -->'
  '<!-- gaia:orchestrator-step wiki-promotion -->'
  '<!-- gaia:orchestrator-step code-audit -->'
  '<!-- gaia:orchestrator-step post-clearance -->'
)
planner_template="$script_directory/../../../.claude/skills/gaia/references/plan/planner.md"

if [ -f "$orchestrator" ]; then
  # first_lines[i] is the line number of the first line matching sentinels[i], or 0.
  first_lines=()
  for _ in ${sentinels[@]+"${sentinels[@]}"}; do first_lines+=(0); done
  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      '<!-- gaia:orchestrator-step '*) ;;
      *) continue ;;
    esac
    index=0
    while [ "$index" -lt "${#sentinels[@]}" ]; do
      if [ "$line" = "${sentinels[$index]}" ] && [ "${first_lines[$index]}" -eq 0 ]; then
        first_lines[index]=$line_number
      fi
      index=$((index + 1))
    done
  done <"$orchestrator"

  index=0
  while [ "$index" -lt "${#sentinels[@]}" ]; do
    if [ "${first_lines[$index]}" -eq 0 ]; then
      fail "ORCHESTRATOR.md is missing the sentinel line ${sentinels[$index]}"
    else
      # Out of order: a sentinel the template places later appears above this one.
      later=$((index + 1))
      while [ "$later" -lt "${#sentinels[@]}" ]; do
        if [ "${first_lines[$later]}" -ne 0 ] && [ "${first_lines[$later]}" -lt "${first_lines[$index]}" ]; then
          fail "ORCHESTRATOR.md sentinel ${sentinels[$index]} is out of order: it must come before ${sentinels[$later]}"
          break
        fi
        later=$((later + 1))
      done
    fi
    index=$((index + 1))
  done

  # Verbatim check of each listed block against planner.md's copy.
  case "$plan_directory" in
    /*) absolute_plan_directory="${plan_directory%/}" ;;
    *) absolute_plan_directory="$(cd "$plan_directory" && pwd)" ;;
  esac
  absolute_spec_path=''
  if [ -n "$spec_path" ]; then
    case "$spec_path" in
      /*) absolute_spec_path="$spec_path" ;;
      *) absolute_spec_path="$(cd "$(dirname "$spec_path")" && pwd)/$(basename "$spec_path")" ;;
    esac
  fi
  for verbatim_sentinel in ${verbatim_sentinels[@]+"${verbatim_sentinels[@]}"}; do
    block_found=0
    index=0
    while [ "$index" -lt "${#sentinels[@]}" ]; do
      if [ "${sentinels[$index]}" = "$verbatim_sentinel" ] && [ "${first_lines[$index]}" -ne 0 ]; then
        block_found="${first_lines[$index]}"
      fi
      index=$((index + 1))
    done
    [ "$block_found" -ne 0 ] || continue
    block_name="${verbatim_sentinel#<!-- gaia:orchestrator-step }"
    block_name="${block_name% -->}"
    expected_lines=()
    if [ -f "$planner_template" ]; then
      while IFS= read -r line; do
        line="${line//\{PLAN_DIR\}/$absolute_plan_directory}"
        if [ -n "$absolute_spec_path" ]; then
          line="${line//\{SPEC_PATH\}/$absolute_spec_path}"
        fi
        expected_lines+=("$line")
      done < <(awk -v want="$verbatim_sentinel" '
        { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
        t ~ /^```/ {
          if (in_fence) { if (hit) { printf "%s", buffer; exit } in_fence = 0 }
          else { in_fence = 1; buffer = ""; hit = 0 }
          next
        }
        in_fence { if (t == want) hit = 1; if (t != "") buffer = buffer t "\n" }' "$planner_template")
    fi
    if [ "${#expected_lines[@]}" -eq 0 ]; then
      fail "planner.md holds no fenced $block_name block to check ORCHESTRATOR.md against: $planner_template"
      continue
    fi
    actual_numbers=()
    actual_lines=()
    while IFS=$'\t' read -r actual_number actual_text; do
      actual_numbers+=("$actual_number")
      actual_lines+=("$actual_text")
    done < <(awk -v start="$block_found" -v count="${#expected_lines[@]}" '
      NR >= start {
        t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t)
        if (t == "") next
        print NR "\t" t
        if (++taken == count) exit
      }' "$orchestrator")
    mismatch_line=0
    index=0
    while [ "$index" -lt "${#expected_lines[@]}" ]; do
      if [ "$index" -ge "${#actual_lines[@]}" ]; then
        mismatch_line=$(($(wc -l <"$orchestrator") + 1))
        break
      fi
      if [ "${actual_lines[$index]}" != "${expected_lines[$index]}" ]; then
        mismatch_line="${actual_numbers[$index]}"
        break
      fi
      index=$((index + 1))
    done
    if [ "$mismatch_line" -ne 0 ]; then
      fail "ORCHESTRATOR.md:$mismatch_line: the $block_name block does not match planner.md's copy"
    fi
  done
fi

# The planner substitutes absolute values for these tokens in every file it
# writes; one left behind sends a cold orchestrator to a literal brace path.
for generated_file in "$readme" "$orchestrator" "$plan_directory/KICKOFF.md" ${task_files[@]+"${task_files[@]}"}; do
  [ -f "$generated_file" ] || continue
  for placeholder in '{PLAN_DIR}' '{SPEC_PATH}' '{AUDIT_PATH}'; do
    while IFS=: read -r hit_line _; do
      [ -n "$hit_line" ] || continue
      fail "$(basename "$generated_file"):$hit_line holds the unsubstituted placeholder $placeholder"
    done < <(grep -nF -- "$placeholder" "$generated_file" 2>/dev/null)
  done
done

if [ -n "$spec_path" ] && [ -f "$readme" ]; then
  routing_problems=''
  routing_status=0
  routing_problems=$(uat_lib_validate_routing "$spec_path" "$readme" 2>&1 >/dev/null) || routing_status=$?
  if [ "$routing_status" -ne 0 ]; then
    if [ -z "$routing_problems" ]; then
      routing_problems="uat-routing: the routing table in $readme did not validate"
    fi
    while IFS= read -r problem_line; do
      [ -n "$problem_line" ] || continue
      fail "$problem_line"
    done <<<"$routing_problems"
  fi

  spec_rows=''
  routing_rows=''
  if spec_rows=$(uat_lib_parse_spec "$spec_path" 2>/dev/null) && routing_rows=$(uat_lib_parse_routing "$readme" 2>/dev/null); then
    while IFS=$'\t' read -r uat_id surface _ _ _; do
      [ -n "$uat_id" ] || continue
      then_clause=$(printf '%s\n' "$spec_rows" | awk -F'\t' -v id="$uat_id" '$1 == id { print $4; exit }')
      [ -n "$then_clause" ] || continue
      case "$surface" in
        story)
          marker="Story test criterion ($uat_id)"
          found=0
          for task_file in ${task_files[@]+"${task_files[@]}"}; do
            while IFS= read -r task_line; do
              case "$task_line" in
                *"$marker"*) ;;
                *) continue ;;
              esac
              remainder=$(printf '%s' "${task_line#*"$marker"}" | uat_lib_whitespace_text)
              case "$remainder" in
                *"$then_clause"*)
                  found=1
                  break
                  ;;
              esac
            done <"$task_file"
            [ "$found" -eq 0 ] || break
          done
          if [ "$found" -eq 0 ]; then
            fail "$uat_id is story-routed but no task doc carries its line: - $marker: <then-clause verbatim>"
          fi
          ;;
      esac
      case "$surface" in
        e2e)
          fail "uat-routing: $uat_id uses the e2e surface, which a new plan no longer takes; route it real-server (the live stack with no page) or browser (only a real browser shows it)"
          ;;
        browser)
          browser_row_check "$uat_id" "$then_clause" "$(printf '%s\n' "$spec_rows" | awk -F'\t' -v id="$uat_id" '$1 == id { print $2; exit }')"
          ;;
      esac
      case "$surface" in
        story | non-ui)
          if grep -qiE 'route|navigat|redirect|session|server[ -]?(side )?state|(^|[^a-z])urls?([^a-z]|$)' <<<"$then_clause"; then
            printf 'WARN: %s is routed %s but its then-clause reads like a route, navigation, URL, redirect, session or server-state check; confirm it is not a route or, when only a browser shows it, a browser UAT\n' "$uat_id" "$surface" >&2
          fi
          ;;
      esac
    done <<<"$routing_rows"
  fi
fi

[ "$failures" -eq 0 ] || exit 1
exit 0
