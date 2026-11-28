#!/usr/bin/env bash
# Deterministic part of the /gaia-plan verification step (step 4.5): checks a
# generated plan folder before an orchestrator runs it cold. The decomposition
# audit that follows is skipped for trivial plans and when fan-out is
# unavailable, so the checks that must always run live here.
#
# Usage: plan-verify.sh <plan-dir> [--spec <spec-path>]
#
# Always checked: README.md, ORCHESTRATOR.md, KICKOFF.md and at least one
# task-*.md exist; task file names match task-[a-z0-9][a-z0-9-]*.md and none
# ends in -tests; ORCHESTRATOR.md carries the verbatim step sentinels the plan
# needs, each on a line of its own (leading and trailing whitespace allowed,
# nothing else), in the order the template places them (flow-checks only with
# --spec). Every sentinel but post-merge-close is also checked verbatim: each
# block's non-blank lines (trimmed) must equal the fenced block the orchestrator
# template (orchestrator-template.md, the one block source the renderer also
# reads) holds, with the plan-directory and SPEC-path placeholders replaced by
# this plan's absolute values, so a paraphrased or shortened copy cannot ship.
# A missing template fails once and skips the block checks.
# Maintainer-only marker lines inside a block are compared like any other line,
# so a plan matches the template it was generated from, marked or stripped.
# README.md, ORCHESTRATOR.md, KICKOFF.md and every task-*.md hold no literal
# {PLAN_DIR}, {SPEC_PATH}, {AUDIT_PATH} or {BRANCH_ID}; one failure line per hit.
#
# The test stage's record, <plan dir>/TEST-STAGE, decides what the test lines
# owe (its first line reads status: running, ran or skipped; the test stage
# owns the rule). Under running or ran, each phase whose task docs carry a
#     - Test (<behavior id>, <layer>, <security kind>): <file> › <title>
# line with a security kind other than none must hold, in its ORCHESTRATOR.md
# entry, a line starting '- Security writer:', and a spec-derived plan owes the
# Flow test lines below. Under skipped, or with no record, no test line is owed
# and any task doc carrying a Flow test line fails naming the file. A first line that is none of the three fails naming the file and owes
# or refuses nothing.
#
# With --spec (a spec-derived plan) additionally, after the SPEC's flows are
# read (a uats: key or a malformed flow fails the plan with the reader's
# reason):
# - Each README `| Phase <N> |` row names its tasks as backticked task-<name>
#   stems; a task doc's phase is the row naming its stem, and a stem in no row
#   or in two rows fails. The last phase is the highest <N>.
# - Every task doc in the last phase carries exactly one line
#     - Flow test (<flow_id>): <repo-relative test path>
#   and every SPEC flow has exactly one such line (under running or ran). A
#   line naming a flow the SPEC lacks, a line in an earlier phase's task doc, or a path other than the flow's expected path fails. The
#   expected path is a web flow's <web package>/.playwright/flows/<slug>.spec.ts,
#   or a command flow's test_path.
# - ORCHESTRATOR.md's last-phase entry (from the **Phase <N>, line outside every
#   fenced block to the next **Phase or ## line outside one) holds, for each
#   Flow test line, a line that runs it: a command of the flow's runner, as
#   flow-runners-lib.sh resolves it (for a web flow, any built-in runner's),
#   plus the test path's basename unless that runner sets names_path false.
#
# Always, when the README has phase rows: a file only a later phase's task
# declares under `## Files to touch` must not catch a file an earlier phase
# declares (cross_phase_check in plan-verify-lib.sh owns what catches), since
# the earlier phase's gate retry cannot reach it.
#
# Every failure is reported on stderr, one line each, in a single run. Exit
# codes: 0 pass; 1 one or more failures; 2 usage error. Bash 3.2 compatible; BSD and GNU tools.
set -uo pipefail
# Literal substitution: an unquoted replacement under bash 5.2 would treat '&' as
# the matched text. /bin/bash 3.2 has no such option.
shopt -u patsub_replacement 2>/dev/null || true

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"
# shellcheck source=.gaia/scripts/spec/flows-lib.sh
. "$script_directory/flows-lib.sh"
# shellcheck source=.gaia/scripts/spec/flow-runners-lib.sh
. "$script_directory/flow-runners-lib.sh"
# shellcheck source=.gaia/scripts/spec/plan-verify-lib.sh
. "$script_directory/plan-verify-lib.sh"

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

readme="$plan_directory/README.md"
orchestrator="$plan_directory/ORCHESTRATOR.md"

[ -f "$readme" ] || fail "README.md is missing from $plan_directory"
[ -f "$orchestrator" ] || fail "ORCHESTRATOR.md is missing from $plan_directory"
[ -f "$plan_directory/KICKOFF.md" ] || fail "KICKOFF.md is missing from $plan_directory"
task_files=()
for candidate in "$plan_directory"/task-*.md; do
  [ -f "$candidate" ] || continue
  task_files+=("$candidate")
  case "$(basename "$candidate")" in
    *-tests.md) fail "$(basename "$candidate") ends in -tests; a task doc is named for its task, not for a test-author unit" ;;
  esac
  grep -qE '^task-[a-z0-9][a-z0-9-]*\.md$' <<<"$(basename "$candidate")" \
    || fail "$(basename "$candidate") does not match task-[a-z0-9][a-z0-9-]*.md"
done
[ "${#task_files[@]}" -gt 0 ] || fail "no task-*.md file exists in $plan_directory"

# Required sentinels in the order the template places them.
sentinels=(
  '<!-- gaia:orchestrator-step resume-detection -->'
  '<!-- gaia:orchestrator-step yield-handling -->'
  '<!-- gaia:orchestrator-step gate-retry -->'
  '<!-- gaia:orchestrator-step security-writer -->'
  '<!-- gaia:orchestrator-step simplify-pass -->'
)
if [ -n "$spec_path" ]; then
  sentinels+=('<!-- gaia:orchestrator-step flow-checks -->')
fi
sentinels+=(
  '<!-- gaia:orchestrator-step wiki-promotion -->'
  '<!-- gaia:orchestrator-step code-audit -->'
  '<!-- gaia:orchestrator-step post-clearance -->'
  '<!-- gaia:orchestrator-step post-merge-close -->'
)
verbatim_sentinels=(
  '<!-- gaia:orchestrator-step resume-detection -->' '<!-- gaia:orchestrator-step yield-handling -->' '<!-- gaia:orchestrator-step gate-retry -->'
  '<!-- gaia:orchestrator-step security-writer -->'
  '<!-- gaia:orchestrator-step simplify-pass -->'
  '<!-- gaia:orchestrator-step flow-checks -->'
  '<!-- gaia:orchestrator-step wiki-promotion -->'
  '<!-- gaia:orchestrator-step code-audit -->'
  '<!-- gaia:orchestrator-step post-clearance -->'
)
block_template="$script_directory/../../../.claude/skills/gaia/references/plan/orchestrator-template.md"

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

  # Verbatim check of each listed block against the template's copy.
  case "$plan_directory" in
    /*) absolute_plan_directory="${plan_directory%/}" ;;
    *) absolute_plan_directory="$(cd "$plan_directory" && pwd)" ;;
  esac
  absolute_spec_path=''
  if [ -n "$spec_path" ]; then
    absolute_spec_path="$(cd "$(dirname "$spec_path")" && pwd)/$(basename "$spec_path")"
  fi
  verbatim_list=(${verbatim_sentinels[@]+"${verbatim_sentinels[@]}"})
  if [ ! -f "$block_template" ]; then
    fail "the orchestrator template is missing: $block_template"
    verbatim_list=()
  fi
  for verbatim_sentinel in ${verbatim_list[@]+"${verbatim_list[@]}"}; do
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
    if [ -f "$block_template" ]; then
      while IFS= read -r line; do
        line="${line//"{PLAN_DIR}"/$absolute_plan_directory}"
        if [ -n "$absolute_spec_path" ]; then
          line="${line//"{SPEC_PATH}"/$absolute_spec_path}"
        fi
        expected_lines+=("$line")
      done < <(awk -v want="$verbatim_sentinel" '
        { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
        t ~ /^```/ {
          if (in_fence) { if (hit) { printf "%s", buffer; exit } in_fence = 0 }
          else { in_fence = 1; buffer = ""; hit = 0 }
          next
        }
        in_fence { if (t == want) hit = 1; if (t != "") buffer = buffer t "\n" }' "$block_template")
    fi
    if [ "${#expected_lines[@]}" -eq 0 ]; then
      fail "the orchestrator template holds no fenced $block_name block to check ORCHESTRATOR.md against: $block_template"
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
      fail "ORCHESTRATOR.md:$mismatch_line: the $block_name block does not match the template's copy"
    fi
  done
fi

placeholder_check


# shellcheck disable=SC2154  # test_stage_owed comes from read_test_stage in plan-verify-lib.sh
flow_checks() {
  local flow_output flow_status=0 web_directory='' flow_id slug kind target
  local stems_text phase last_phase=0 task_file task_name task_stem task_phase matches
  local line_text path_text expected_path flow_lines='' entry_text
  local line_count line_files line_task line_phase line_flow_id line_kind run_status run_detail
  flow_output=$(flows_lib_parse_spec "$spec_path" 2>&1) || flow_status=$?
  if [ "$flow_status" -ne 0 ]; then
    while IFS= read -r line_text; do
      [ -z "$line_text" ] || fail "$line_text"
    done <<<"$flow_output"
    return 0
  fi
  [ -f "$readme" ] || return 0

  stems_text=$(readme_phase_stems "$readme")
  if [ -z "$stems_text" ]; then
    fail "README.md has no '| Phase <N> |' task-graph row naming backticked task-<name> stems"
    return 0
  fi
  while IFS=$'\t' read -r phase _; do
    [ "$phase" -le "$last_phase" ] || last_phase="$phase"
  done <<<"$stems_text"

  # flow_lines holds <task doc>, <phase>, <flow id>, <path> per Flow test line; '-' marks a task doc with no single README phase (tab-split reads collapse an empty field).
  for task_file in ${task_files[@]+"${task_files[@]}"}; do
    task_name="$(basename "$task_file")"
    task_stem="${task_name%.md}"
    matches=$(awk -F'\t' -v stem="$task_stem" '$2 == stem { print $1 }' <<<"$stems_text")
    task_phase=''
    if [ -z "$matches" ]; then
      fail "$task_name: no README '| Phase <N> |' row names the stem \`$task_stem\`"
    elif [ "$(grep -c . <<<"$matches")" -gt 1 ]; then
      fail "$task_name: more than one README '| Phase <N> |' row names the stem \`$task_stem\`"
    else
      task_phase="$matches"
    fi
    line_count=0
    while IFS= read -r line_text || [ -n "$line_text" ]; do
      [[ "$line_text" =~ ^[[:space:]]*-[[:space:]]+Flow\ test\ \(([^\)]*)\):[[:space:]]*(.*)$ ]] || continue
      path_text="${BASH_REMATCH[2]}"
      path_text="${path_text%"${path_text##*[![:space:]]}"}"
      flow_lines="${flow_lines}${task_name}"$'\t'"${task_phase:--}"$'\t'"${BASH_REMATCH[1]}"$'\t'"$path_text"$'\n'
      line_count=$((line_count + 1))
    done <"$task_file"
    if [ "$test_stage_owed" -eq 1 ] && [ "$task_phase" = "$last_phase" ]; then
      if [ "$line_count" -eq 0 ]; then
        fail "$task_name: the last-phase (Phase $last_phase) task doc has no '- Flow test (<flow_id>): <path>' line"
      elif [ "$line_count" -gt 1 ]; then
        fail "$task_name: carries $line_count Flow test lines; a last-phase task owns exactly one flow"
      fi
    fi
  done

  [ "$test_stage_owed" -eq 1 ] || return 0 # malformed record reported, or no test stage: Flow lines handled by flow_test_refusal

  while IFS=$'\t' read -r flow_id slug _ _ kind target; do
    [ -n "$flow_id" ] || continue
    expected_path="$target"
    if [ "$kind" = web ]; then
      if [ -z "$web_directory" ]; then
        web_directory=$(flows_lib_web_subdirectory "$repository_root" .playwright/flows 2>&1) || {
          fail "$flow_id: cannot place its web flow test: $web_directory"
          continue
        }
      fi
      expected_path="$web_directory/$slug.spec.ts"
    fi
    line_files=$(awk -F'\t' -v id="$flow_id" '$3 == id { print $1 }' <<<"$flow_lines" | paste -sd, - | sed 's/,/, /g')
    line_count=$(awk -F'\t' -v id="$flow_id" '$3 == id' <<<"$flow_lines" | grep -c .)
    if [ "$line_count" -eq 0 ]; then
      fail "$flow_id has no '- Flow test ($flow_id): $expected_path' line in any task doc"
    elif [ "$line_count" -gt 1 ]; then
      fail "$flow_id is named on $line_count Flow test lines ($line_files); one task owns one flow"
    fi
    while IFS=$'\t' read -r line_task _ line_flow_id path_text; do
      [ "$line_flow_id" = "$flow_id" ] || continue
      [ "$path_text" = "$expected_path" ] || fail "$line_task: the Flow test line for $flow_id has path $path_text; the expected path is $expected_path"
    done <<<"$flow_lines"
  done <<<"$flow_output"

  while IFS=$'\t' read -r line_task line_phase line_flow_id _; do
    [ -n "$line_task" ] || continue
    grep -qxF -- "$line_flow_id" <<<"$(cut -f1 <<<"$flow_output")" \
      || fail "$line_task: the Flow test line names $line_flow_id, which the SPEC does not define"
    if [ "$line_phase" != - ] && [ "$line_phase" != "$last_phase" ]; then
      fail "$line_task (Phase $line_phase): the Flow test line for $line_flow_id belongs in a last-phase (Phase $last_phase) task doc"
    fi
  done <<<"$flow_lines"

  [ -f "$orchestrator" ] || return 0
  entry_text=$(phase_entry "$orchestrator" "$last_phase")
  if [ -z "$entry_text" ]; then
    fail "ORCHESTRATOR.md has no **Phase $last_phase, entry for the last phase"
    return 0
  fi
  while IFS=$'\t' read -r line_task line_phase line_flow_id path_text; do
    [ -n "$line_task" ] && [ "$line_phase" = "$last_phase" ] || continue
    line_kind=$(awk -F'\t' -v id="$line_flow_id" '$1 == id { print $5; exit }' <<<"$flow_output")
    [ -n "$line_kind" ] || continue # a flow the SPEC lacks, reported above
    run_status=0
    run_detail=$(flow_runners_line_runs "$repository_root" "$line_kind" "$path_text" "$entry_text" 2>&1) || run_status=$?
    case "$run_status" in
      0) ;;
      1) fail "ORCHESTRATOR.md: the Phase $last_phase entry runs no flow test for $line_flow_id: $run_detail" ;;
      *) fail "$line_flow_id: ${run_detail#flow-runners: }" ;;
    esac
  done <<<"$flow_lines"
}

read_test_stage
flow_test_refusal
if [ -n "$spec_path" ]; then
  flow_checks
fi

security_writer_check
cross_phase_check

[ "$failures" -eq 0 ] || exit 1
exit 0
