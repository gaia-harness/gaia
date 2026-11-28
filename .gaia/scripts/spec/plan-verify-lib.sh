#!/usr/bin/env bash
# Sourced by plan-verify.sh and the archive scripts: the README and ORCHESTRATOR.md readers, the
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

# test_stage_close_owed <plan_folder>: 0 when that folder's TEST-STAGE first
# line reads running or ran, so a gaia-test close is owed on the usage ledger;
# 1 when it reads skipped, is absent or is malformed. Reuses read_test_stage in
# a subshell with a silent fail(), so the archive scripts that source this
# library keep their own globals and report nothing here.
test_stage_close_owed() {
  (
    fail() { :; }
    plan_directory="$1" read_test_stage
    [ "$test_stage_owed" -eq 1 ]
  )
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

# The planner (README.md, task docs) and the renderer (ORCHESTRATOR.md,
# KICKOFF.md) substitute absolute values for these tokens; one left behind
# sends a cold orchestrator to a literal brace path.
placeholder_check() {
  local generated_file placeholder hit_line
  for generated_file in "$readme" "$orchestrator" "$plan_directory/KICKOFF.md" ${task_files[@]+"${task_files[@]}"}; do
    [ -f "$generated_file" ] || continue
    for placeholder in '{PLAN_DIR}' '{SPEC_PATH}' '{AUDIT_PATH}' '{BRANCH_ID}'; do
      while IFS=: read -r hit_line _; do
        [ -n "$hit_line" ] || continue
        fail "$(basename "$generated_file"):$hit_line holds the unsubstituted placeholder $placeholder"
      done < <(grep -nF -- "$placeholder" "$generated_file" 2>/dev/null)
    done
  done
}

# Extensions of the data files a whole-tree check reads row by row, such as an
# allowlist; a file whose name contains "allowlist" counts whatever its
# extension. A heuristic: the data arm of cross_phase_check fires only on
# these, because a later task naming an earlier phase's file beside a source
# file, or beside a plain txt or csv nothing reads, is usually a consumer or
# prose, not a check.
cross_phase_data_extensions=(tsv allowlist)

# Succeeds when file $1 names $2 as a whole path token: not as the tail of a
# longer name (update.ts holds date.ts, vite.config.ts holds config.ts) and,
# for a bare root name like package.json when $3 is strict, not as the tail of
# a longer path (apps/web/package.json).
names_path_token() {
  local file="$1" needle="$2" strict="$3" escaped lead='[^A-Za-z0-9_.@+-]'
  escaped=$(printf '%s' "$needle" | sed 's/[].[*^$+?(){}|\\]/\\&/g')
  [ "$strict" = strict ] && lead='[^A-Za-z0-9_.@+/-]'
  grep -qE -- "(^|$lead)$escaped(\$|[^A-Za-z0-9_@+-]|\.(\$|[^A-Za-z0-9_@+-]))" "$file"
}

# Prints <phase>\t<task doc>\t<line>\t<repo-relative path>\t<kind> for every
# file path a task doc's `## Files to touch` section names, from the README
# phase rows in $1. kind is "lead" for the first path on a line, the file the
# bullet declares, and "mention" for any later path on it (context, an example). A path is a token ending in a file extension, with the repository root or
# RESOLVED_ROOT/ prefix removed; a token outside the repository, or a bare name
# no file at the repository root has, is dropped.
files_to_touch_rows() {
  local stems_text="$1" task_file task_name task_phase phase task line_number path kind last_lead_key=''
  for task_file in ${task_files[@]+"${task_files[@]}"}; do
    task_name="$(basename "$task_file")"
    task_phase=$(awk -F'\t' -v stem="${task_name%.md}" '$2 == stem { print $1 }' <<<"$stems_text")
    [ -n "$task_phase" ] && [ "$(grep -c . <<<"$task_phase")" -eq 1 ] || continue
    while IFS=$'\t' read -r phase task line_number path; do
      [ -n "$path" ] || continue
      case "$path" in
        */*) ;;
        *) [ -e "$repository_root/$path" ] || continue ;;
      esac
      kind=mention
      if [ "$last_lead_key" != "$task:$line_number" ]; then
        kind=lead
        last_lead_key="$task:$line_number"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$phase" "$task" "$line_number" "$path" "$kind"
    done < <(awk -v phase="$task_phase" -v task="$task_name" -v root="$repository_root" '
      /^#+[ \t]+Files to touch/ { inside = 1; next }
      inside && /^#+[ \t]/ { inside = 0 }
      inside {
        text = $0
        while ((position = index(text, root "/")) > 0)
          text = substr(text, 1, position - 1) substr(text, position + length(root) + 1)
        gsub(/RESOLVED_ROOT\//, "", text)
        gsub(/[^A-Za-z0-9_.\/@+-]+/, " ", text)
        count = split(text, tokens, " ")
        for (index_number = 1; index_number <= count; index_number++) {
          token = tokens[index_number]
          sub(/^\.\//, "", token)
          sub(/\.+$/, "", token)
          if (token ~ /^\// || token ~ /\/\// || token !~ /\.[A-Za-z0-9]+$/) continue
          if (!seen[token "\t" NR]++) print phase "\t" task "\t" NR "\t" token
        }
      }' "$task_file")
  done
}

# A phase gate retry re-dispatches only the tasks of its own phase that declare
# a failing file, so a file only a later phase declares that catches an earlier
# phase's change halts the earlier gate with no task to retry. "Catches" is one
# of two arms:
#   suite: the later file is a test file (a flow runner in flow-runners-lib.sh
#     runs it) whose text names the earlier file by repo-relative path, or by
#     basename when no other tracked file shares that basename;
#   data: the later file has a cross_phase_data_extensions extension or
#     "allowlist" in its name, and the later task's Files to touch line naming
#     it also names the earlier file.
# A phase declares only the leading path of a Files to touch line.
# A whole-tree check over any other kind of file is left to the decomposition
# audit's dependency lens.
cross_phase_check() {
  local stems_text declared mentioned tracked_paths='' tracked_read=0 status data_extension
  local later_phase later_task later_line later_path is_test is_data extension
  local strictness earlier_phase earlier_task earlier_path base_name reported=$'\n' key
  [ -f "$readme" ] || return 0
  stems_text=$(readme_phase_stems "$readme")
  [ -n "$stems_text" ] || return 0
  mentioned=$(files_to_touch_rows "$stems_text")
  declared=$(awk -F'\t' '$5 == "lead"' <<<"$mentioned")
  [ -n "$declared" ] || return 0
  while IFS=$'\t' read -r later_phase later_task later_line later_path _; do
    [ -f "$repository_root/$later_path" ] || continue
    awk -F'\t' -v phase="$later_phase" '$1 + 0 < phase + 0 { found = 1 } END { exit !found }' <<<"$declared" || continue
    is_data=0
    extension="${later_path##*.}"
    for data_extension in ${cross_phase_data_extensions[@]+"${cross_phase_data_extensions[@]}"}; do
      [ "$extension" = "$data_extension" ] && is_data=1
    done
    case "${later_path##*/}" in *allowlist*) is_data=1 ;; esac
    is_test=0
    if [ "$is_data" -eq 0 ]; then
      status=0
      flow_runners_for_path "$repository_root" "$later_path" >/dev/null 2>&1 || status=$?
      case "$status" in
        0) is_test=1 ;;
        1) continue ;;
        *)
          fail "cannot tell whether $later_path is a test file for the cross-phase check: the flow runner table is unreadable (is jq installed?)"
          return 0
          ;;
      esac
    fi
    while IFS=$'\t' read -r earlier_phase earlier_task _ earlier_path _; do
      [ "$earlier_path" != "$later_path" ] || continue
      # The earlier phase declares the later file too: its own gate retry can reach it.
      awk -F'\t' -v phase="$earlier_phase" -v path="$later_path" '$1 == phase && $4 == path { found = 1 } END { exit !found }' <<<"$declared" && continue
      key="$earlier_phase"$'\t'"$earlier_path"$'\t'"$later_path"
      case "$reported" in *$'\n'"$key"$'\n'*) continue ;; esac
      if [ "$is_test" -eq 1 ]; then
        strictness=loose
        case "$earlier_path" in */*) ;; *) strictness=strict ;; esac
        if ! names_path_token "$repository_root/$later_path" "$earlier_path" "$strictness"; then
          if [ "$tracked_read" -eq 0 ]; then
            tracked_paths=$(git -C "$repository_root" ls-files -z 2>/dev/null | tr '\0' '\n')
            tracked_read=1
          fi
          # No tracked list means uniqueness is unknown: match by path only.
          [ -n "$tracked_paths" ] || continue
          base_name="${earlier_path##*/}"
          awk -F/ -v base="$base_name" -v self="$earlier_path" \
            '$NF == base && $0 != self { shared = 1 } END { exit shared }' <<<"$tracked_paths" || continue
          names_path_token "$repository_root/$later_path" "$base_name" loose || continue
        fi
      else
        awk -F'\t' -v task="$later_task" -v line="$later_line" -v path="$earlier_path" \
          '$2 == task && $3 == line && $4 == path { found = 1 } END { exit !found }' <<<"$mentioned" || continue
      fi
      reported="$reported$key"$'\n'
      fail "Phase $earlier_phase ($earlier_task) changes $earlier_path, which $later_path checks, but Phase $later_phase ($later_task) declares $later_path and Phase $earlier_phase does not, so Phase $earlier_phase's gate can fail on a file none of its tasks owns: declare $later_path in a Phase $earlier_phase task as well, or reorder the tasks"
    done < <(awk -F'\t' -v phase="$later_phase" '$1 + 0 < phase + 0' <<<"$declared")
  done <<<"$declared"
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
