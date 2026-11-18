#!/usr/bin/env bash
# Sourced by plan-verify.sh: the README and ORCHESTRATOR.md readers, the
# test-stage record reader and the security-writer check. Relies on the
# globals of the caller (plan_directory, readme, orchestrator, spec_path,
# repository_root, script_directory) and its fail().
# shellcheck disable=SC2154 # the globals are assigned by the sourcing script
# Prints `<phase><TAB><stem>` for each backticked task-<name> stem in the tasks
# cell of a README `| Phase <N> |` row.
readme_phase_stems() {
  awk -F'|' '
    { phase = $2; gsub(/^[ \t]+|[ \t]+$/, "", phase) }
    phase ~ /^Phase [0-9]+$/ {
      sub(/^Phase /, "", phase)
      cell = $3
      while (match(cell, /`task-[a-z0-9][a-z0-9-]*`/)) {
        print phase "\t" substr(cell, RSTART + 1, RLENGTH - 2)
        cell = substr(cell, RSTART + RLENGTH)
      }
    }' "$1"
}

# Prints the entry of ORCHESTRATOR.md for phase $2: ENTRY, then its lines.
phase_entry() {
  awk -v phase="$2" '
    { trimmed = $0; sub(/^[ \t]+/, "", trimmed); sub(/[ \t\r]+$/, "", trimmed) }
    trimmed ~ /^```/ { in_fence = !in_fence; if (inside) print; next }
    !in_fence && inside && (trimmed ~ /^\*\*Phase / || trimmed ~ /^## /) { exit }
    !in_fence && !inside && index(trimmed, "**Phase " phase ", ") == 1 { inside = 1; print "ENTRY"; print; next }
    inside { print }' "$1"
}
# Reads <plan dir>/TEST-STAGE and sets test_stage_owed: 1 when its first line
# is status: running or status: ran (the test lines are owed), 0 when it reads
# skipped or the file is absent (none owed). Any other first line is one
# failure naming the file and owes nothing.
read_test_stage() {
  local record="$plan_directory/TEST-STAGE" first_line=''
  test_stage_owed=0
  [ -f "$record" ] || return 0
  IFS= read -r first_line <"$record" || true
  first_line="${first_line%$'\r'}"
  first_line="${first_line%"${first_line##*[![:space:]]}"}"
  case "$first_line" in
    'status: running' | 'status: ran') test_stage_owed=1 ;;
    'status: skipped') ;;
    *)
      test_stage_owed=-1
      fail "TEST-STAGE is malformed: its first line is not status: running, status: ran or status: skipped ($record)"
      ;;
  esac
}

# Under a running or ran test stage, the entry of each phase whose task docs
# carry a Test line with a security kind other than none owes a
# '- Security writer:' line.
security_writer_check() {
  local stems_text task_file task_name task_stem kind phase entry_text line_text reported=' '
  [ "$test_stage_owed" -eq 1 ] || return 0
  [ -f "$readme" ] && [ -f "$orchestrator" ] || return 0
  stems_text=$(readme_phase_stems "$readme")
  for task_file in ${task_files[@]+"${task_files[@]}"}; do
    task_name="$(basename "$task_file")"
    task_stem="${task_name%.md}"
    while IFS= read -r line_text || [ -n "$line_text" ]; do
      [[ "$line_text" =~ ^[[:space:]]*-[[:space:]]+Test\ \([^,\)]*,[^,\)]*,[[:space:]]*([^\)]*)\): ]] || continue
      kind="${BASH_REMATCH[1]}"
      kind="${kind%"${kind##*[![:space:]]}"}"
      [ -n "$kind" ] && [ "$kind" != none ] || continue
      phase=$(awk -F'\t' -v stem="$task_stem" '$2 == stem { print $1; exit }' <<<"$stems_text")
      [ -n "$phase" ] || continue
      case "$reported" in *" $phase "*) continue ;; esac
      reported="$reported$phase "
      entry_text=$(phase_entry "$orchestrator" "$phase")
      grep -qE '^[[:space:]]*- Security writer:' <<<"$entry_text" \
        || fail "ORCHESTRATOR.md: Phase $phase owns a security test line ($task_name) but its entry has no '- Security writer:' line"
    done <"$task_file"
  done
}

# The planner substitutes absolute values for these tokens in every file it
# writes; one left behind sends a cold orchestrator to a literal brace path.
placeholder_check() {
  local generated_file placeholder hit_line
  for generated_file in "$readme" "$orchestrator" "$plan_directory/KICKOFF.md" ${task_files[@]+"${task_files[@]}"}; do
    [ -f "$generated_file" ] || continue
    for placeholder in '{PLAN_DIR}' '{SPEC_PATH}' '{AUDIT_PATH}'; do
      while IFS=: read -r hit_line _; do
        [ -n "$hit_line" ] || continue
        fail "$(basename "$generated_file"):$hit_line holds the unsubstituted placeholder $placeholder"
      done < <(grep -nF -- "$placeholder" "$generated_file" 2>/dev/null)
    done
  done
}

# With no test stage run (TEST-STAGE reads skipped or is absent), no Flow test
# line is owed and none may appear, in a spec-derived or a spec-less plan.
flow_test_refusal() {
  local task_file
  [ "$test_stage_owed" -eq 0 ] || return 0
  for task_file in ${task_files[@]+"${task_files[@]}"}; do
    grep -qE '^[[:space:]]*-[[:space:]]+Flow test \([^)]*\):' "$task_file" || continue
    fail "$(basename "$task_file"): carries a Flow test line but the test stage has not run (TEST-STAGE reads skipped or is absent)"
  done
}
