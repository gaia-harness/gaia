#!/usr/bin/env bats

# Pins the /gaia-codify playbook's team-decline contract mechanically: a
# decline and the unclassified suppression are working-tree writes that follow
# the run's isolation step, the publish step carries them and lists lapsed
# files only on a run that already publishes, the fetch step reports the two
# decline stderr codes, the team-declined section exists apart from the
# nudge, and no sentence still calls a decline per-machine. Each guard has a
# real-file pass case and a mutation case on a scratch copy.
# .gaia/tests/statusline/ is already armed by codify.md edits in
# .github/workflows/audit-ci-tests.yml.

setup() {
  CODIFY_MARKDOWN=$(cd "$BATS_TEST_DIRNAME/../../../.claude/skills/gaia/references" && pwd)/codify.md
}

# line_of <file> <extended-regex>
#   Prints the 1-indexed number of the first line matching the pattern, or nothing.
line_of() {
  grep -nE -- "$2" "$1" | head -1 | cut -d: -f1
}

# insert_after <file> <line_number> <text_file>
insert_after() {
  local file="$1" line_number="$2" text_file="$3"
  awk -v line_number="$line_number" -v text_file="$text_file" '
    { print }
    NR==line_number {
      while ((getline inserted_line < text_file) > 0) print inserted_line
    }
  ' "$file" > "${file}.ins" && mv "${file}.ins" "$file"
}

# check_isolation_covers_writes <file> (a)
check_isolation_covers_writes() {
  local file="$1" isolate_line
  isolate_line=$(line_of "$file" '^\*\*Isolate before the first working-tree write\*\*')
  [ -n "$isolate_line" ] || { echo "missing the isolation instruction"; return 1; }
  local text
  text=$(sed -n "${isolate_line}p" "$file")
  printf '%s' "$text" | grep -qF "decline file" || { echo "isolation does not name the decline file"; return 1; }
  printf '%s' "$text" | grep -qF "unclassified suppression" || { echo "isolation does not name the suppression file"; return 1; }
  printf '%s' "$text" | grep -qF "working-tree write" || { echo "isolation does not call them working-tree writes"; return 1; }
  grep -qF "declines, defers) never isolates" "$file" && { echo "the old never-isolates sentence is back"; return 1; }
  return 0
}

# check_decline_after_isolation <file> (b)
check_decline_after_isolation() {
  local file="$1" isolate_line record_line
  isolate_line=$(line_of "$file" '^\*\*Isolate before the first working-tree write\*\*')
  record_line=$(line_of "$file" 'codify-ledger record --finding-class')
  [ -n "$isolate_line" ] || { echo "missing the isolation instruction"; return 1; }
  [ -n "$record_line" ] || { echo "missing the codify-ledger record call"; return 1; }
  [ "$record_line" -gt "$isolate_line" ] || { echo "the record call precedes the isolation instruction"; return 1; }
  return 0
}

# check_publish_precondition <file> (c)
check_publish_precondition() {
  local file="$1" precondition_line text
  precondition_line=$(line_of "$file" '^\*\*Precondition\.\*\*')
  [ -n "$precondition_line" ] || { echo "missing the publish precondition"; return 1; }
  text=$(sed -n "${precondition_line}p" "$file")
  printf '%s' "$text" | grep -qF "recorded any decline" || { echo "precondition omits a decline"; return 1; }
  printf '%s' "$text" | grep -qF "recorded the unclassified suppression" || { echo "precondition omits the suppression"; return 1; }
  return 0
}

# check_lapsed_in_publish <file> (d)
check_lapsed_in_publish() {
  local file="$1" lapsed_count lapsed_line precondition_line cost_line
  lapsed_count=$(grep -cF "codify-ledger lapsed" "$file")
  [ "$lapsed_count" -eq 1 ] || { echo "codify-ledger lapsed appears $lapsed_count times, expected 1"; return 1; }
  lapsed_line=$(line_of "$file" 'codify-ledger lapsed')
  precondition_line=$(line_of "$file" '^\*\*Precondition\.\*\*')
  cost_line=$(line_of "$file" '^## Cost record')
  [ -n "$precondition_line" ] && [ -n "$cost_line" ] || { echo "missing the precondition or cost heading"; return 1; }
  [ "$lapsed_line" -gt "$precondition_line" ] && [ "$lapsed_line" -lt "$cost_line" ] \
    || { echo "codify-ledger lapsed is outside the publish section after its precondition"; return 1; }
  grep -qF "never opens a pull request just to delete lapsed files" "$file" \
    || { echo "missing the no-pull-request-for-lapsed-files statement"; return 1; }
  return 0
}

# check_fetch_reports <file> (e)
check_fetch_reports() {
  local file="$1" fetch_line judge_line section
  fetch_line=$(line_of "$file" '^## Fetch the live candidate list')
  judge_line=$(line_of "$file" '^## Judge-the-form logic')
  [ -n "$fetch_line" ] && [ -n "$judge_line" ] || { echo "missing the Fetch or Judge heading"; return 1; }
  section=$(sed -n "${fetch_line},${judge_line}p" "$file")
  printf '%s' "$section" | grep -qF "skipped_decline_file" || { echo "fetch omits skipped_decline_file"; return 1; }
  printf '%s' "$section" | grep -qF "malformed_decline_ledger" || { echo "fetch omits malformed_decline_ledger"; return 1; }
  return 0
}

# check_team_declined_section <file> (f)
check_team_declined_section() {
  local file="$1" plan_line team_line next_line
  plan_line=$(line_of "$file" '^### Present the plan, then ask once')
  team_line=$(line_of "$file" '^#### Declined by the team')
  next_line=$(line_of "$file" '^## Per-form action handling')
  [ -n "$team_line" ] || { echo "missing the team-declined heading"; return 1; }
  [ -n "$plan_line" ] && [ -n "$next_line" ] || { echo "missing the plan or per-form heading"; return 1; }
  [ "$team_line" -gt "$plan_line" ] && [ "$team_line" -lt "$next_line" ] \
    || { echo "the team-declined section is not under the plan presentation"; return 1; }
  sed -n "${team_line},${next_line}p" "$file" | grep -qF "never reach the statusline nudge" \
    || { echo "the team-declined section does not keep rows out of the nudge"; return 1; }
  return 0
}

# check_no_per_machine_decline <file> (g)
check_no_per_machine_decline() {
  local file="$1"
  grep -qE 'gitignored|never shared|ledger prune' "$file" && { echo "a per-machine or prune phrase is present"; return 1; }
  grep -E 'machine-local' "$file" | grep -qi 'decline' && { echo "a line calls a decline machine-local"; return 1; }
  return 0
}

# check_unclassified_write <file> (h)
check_unclassified_write() {
  local file="$1" section_start section_end record_line isolate_line condition_line
  section_start=$(line_of "$file" '^## Unclassified recurrence signal')
  section_end=$(line_of "$file" '^## Record the review \(end of run\)')
  [ -n "$section_start" ] && [ -n "$section_end" ] || { echo "missing the unclassified or record heading"; return 1; }
  record_line=$(sed -n "${section_start},${section_end}p" "$file" | grep -nF "codify-ledger record" | head -1 | cut -d: -f1)
  [ -n "$record_line" ] || { echo "the unclassified section has no record call"; return 1; }
  isolate_line=$(sed -n "${section_start},${section_end}p" "$file" | grep -nF "Isolate before the write" | head -1 | cut -d: -f1)
  [ -n "$isolate_line" ] || { echo "the unclassified section has no isolation instruction"; return 1; }
  [ "$isolate_line" -lt "$record_line" ] || { echo "the isolation instruction follows the record call"; return 1; }
  condition_line=$(sed -n "${section_start},${section_end}p" "$file" | grep -nF 'only when `unclassified` was non-null' | head -1 | cut -d: -f1)
  [ -n "$condition_line" ] || { echo "the write is not conditioned on unclassified being non-null"; return 1; }
  return 0
}

# check_zero_candidate_question <file> (i)
check_zero_candidate_question() {
  local file="$1" line_number text
  line_number=$(line_of "$file" 'candidate_count.*is .0.*unclassified.* is non-null')
  [ -n "$line_number" ] || { echo "missing the zero-candidate unclassified branch"; return 1; }
  text=$(sed -n "${line_number}p" "$file")
  printf '%s' "$text" | grep -qF "AskUserQuestion" || { echo "the branch does not ask with AskUserQuestion"; return 1; }
  printf '%s' "$text" | grep -qF "before writing anything" || { echo "the question is not before the write"; return 1; }
  return 0
}

# check_team_override_publishes <file> (j)
check_team_override_publishes() {
  local file="$1" line_number text
  line_number=$(line_of "$file" 'candidate_count.*is .0.*team_declined.* is non-empty')
  [ -n "$line_number" ] || { echo "missing the team-declined override branch"; return 1; }
  text=$(sed -n "${line_number}p" "$file")
  printf '%s' "$text" | grep -qF "## Publish the run's changes (end of run)" \
    || { echo "the override does not route an approved row to the publish section"; return 1; }
  return 0
}

# check_decline_exit_codes <file> (k)
check_decline_exit_codes() {
  local file="$1" decline_line defer_line text
  decline_line=$(line_of "$file" '^### decline')
  defer_line=$(line_of "$file" '^### defer')
  [ -n "$decline_line" ] && [ -n "$defer_line" ] || { echo "missing the decline or defer heading"; return 1; }
  text=$(sed -n "${decline_line},${defer_line}p" "$file" | grep -F "Exit codes:")
  [ -n "$text" ] || { echo "missing the decline exit-code list"; return 1; }
  printf '%s' "$text" | grep -qF '`1` bad arguments' || { echo "exit 1 is not bad arguments"; return 1; }
  printf '%s' "$text" | grep -qF 'never exits `2`' || { echo "the list does not say it never exits 2"; return 1; }
  printf '%s' "$text" | grep -qF '`2` bad arguments' && { echo "exit 2 is named for bad arguments"; return 1; }
  return 0
}

# --- real file passes ---

@test "isolation names declines and the suppression as working-tree writes" {
  run check_isolation_covers_writes "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "the decline record call follows the isolation instruction" {
  run check_decline_after_isolation "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "the publish precondition counts a decline and the suppression" {
  run check_publish_precondition "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "lapsed-file removal lives only in the publish section" {
  run check_lapsed_in_publish "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "the fetch section names both decline stderr codes" {
  run check_fetch_reports "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "the team-declined section sits under the plan and stays out of the nudge" {
  run check_team_declined_section "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "no sentence calls a decline per-machine and the prune verb is gone" {
  run check_no_per_machine_decline "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "the unclassified write is conditioned and follows an isolation step" {
  run check_unclassified_write "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "the zero-candidate branch asks before recording the suppression" {
  run check_zero_candidate_question "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "the team-declined override routes an approved row to publish" {
  run check_team_override_publishes "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "the decline exit-code list says 1 for bad arguments and never 2" {
  run check_decline_exit_codes "$CODIFY_MARKDOWN"
  [ "$status" -eq 0 ]
}

# --- mutation cases ---

@test "refuses when the old never-isolates sentence is restored" {
  local copy="$BATS_TEST_TMPDIR/restore-never-isolates.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak -e 's/dispositions write/approvals write/' -e 's/(only scaffolds and defers)/(scaffolds, declines, defers)/' "$copy"
  run check_isolation_covers_writes "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the decline handler moves above the isolation paragraph" {
  local copy="$BATS_TEST_TMPDIR/decline-above-isolation.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  local decline_line defer_line per_form_line block="$BATS_TEST_TMPDIR/decline-block.txt"
  decline_line=$(line_of "$copy" '^### decline')
  defer_line=$(line_of "$copy" '^### defer')
  per_form_line=$(line_of "$copy" '^## Per-form action handling')
  sed -n "${decline_line},$((defer_line - 1))p" "$copy" > "$block"
  sed -i.bak "${decline_line},$((defer_line - 1))d" "$copy"
  insert_after "$copy" "$per_form_line" "$block"
  run check_decline_after_isolation "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the publish precondition drops the decline clause" {
  local copy="$BATS_TEST_TMPDIR/precondition-no-decline.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak 's/recorded any decline/did nothing else/' "$copy"
  run check_publish_precondition "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the publish precondition drops the suppression clause" {
  local copy="$BATS_TEST_TMPDIR/precondition-no-suppression.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak 's/recorded the unclassified suppression/did nothing more/' "$copy"
  run check_publish_precondition "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the lapsed instruction moves into the decline handler" {
  local copy="$BATS_TEST_TMPDIR/lapsed-in-decline.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  local lapsed_line decline_line block="$BATS_TEST_TMPDIR/lapsed-line.txt"
  lapsed_line=$(line_of "$copy" 'codify-ledger lapsed')
  sed -n "${lapsed_line}p" "$copy" > "$block"
  sed -i.bak "${lapsed_line}d" "$copy"
  decline_line=$(line_of "$copy" '^### decline')
  insert_after "$copy" "$decline_line" "$block"
  run check_lapsed_in_publish "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the no-pull-request-for-lapsed-files statement is dropped" {
  local copy="$BATS_TEST_TMPDIR/lapsed-no-statement.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak 's/never opens a pull request just to delete lapsed files/opens a pull request/' "$copy"
  run check_lapsed_in_publish "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the fetch section drops skipped_decline_file" {
  local copy="$BATS_TEST_TMPDIR/fetch-no-skipped.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak 's/skipped_decline_file/gone_code/g' "$copy"
  run check_fetch_reports "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the fetch section drops malformed_decline_ledger" {
  local copy="$BATS_TEST_TMPDIR/fetch-no-malformed.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak 's/malformed_decline_ledger/gone_code/g' "$copy"
  run check_fetch_reports "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the team-declined heading is deleted" {
  local copy="$BATS_TEST_TMPDIR/no-team-heading.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak '/^#### Declined by the team/d' "$copy"
  run check_team_declined_section "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the team-declined section no longer keeps rows out of the nudge" {
  local copy="$BATS_TEST_TMPDIR/team-nudge.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak 's/never reach the statusline nudge/reach the statusline/' "$copy"
  run check_team_declined_section "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the old machine-local decline paragraph is re-inserted" {
  local copy="$BATS_TEST_TMPDIR/old-decline-paragraph.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  printf '\nState that the decline is machine-local only (the ledger is gitignored) and never shared.\n' >> "$copy"
  run check_no_per_machine_decline "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the prune verb reappears" {
  local copy="$BATS_TEST_TMPDIR/prune-back.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  printf '\nlet .gaia/cli/gaia codify-ledger prune drop the entry\n' >> "$copy"
  run check_no_per_machine_decline "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the unclassified section loses its isolation instruction" {
  local copy="$BATS_TEST_TMPDIR/unclassified-no-isolation.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak '/^- Isolate before the write\./d' "$copy"
  run check_unclassified_write "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the unclassified write loses its non-null condition" {
  local copy="$BATS_TEST_TMPDIR/unclassified-no-condition.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak '/^- Write the suppression only when/d' "$copy"
  run check_unclassified_write "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the zero-candidate branch no longer asks" {
  local copy="$BATS_TEST_TMPDIR/zero-no-question.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  local line_number
  line_number=$(line_of "$copy" 'candidate_count.*is .0.*unclassified.* is non-null')
  sed -i.bak "${line_number}s/\`AskUserQuestion\`/a note/" "$copy"
  run check_zero_candidate_question "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the team-declined override routes to record-and-stop" {
  local copy="$BATS_TEST_TMPDIR/override-stops.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak "/candidate_count.*team_declined/s|## Publish the run's changes (end of run)|the record-and-stop branch|" "$copy"
  run check_team_override_publishes "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the decline exit list names 2 for bad arguments" {
  local copy="$BATS_TEST_TMPDIR/exit-two.md"
  cp "$CODIFY_MARKDOWN" "$copy"
  sed -i.bak 's/`1` bad arguments/`2` bad arguments/' "$copy"
  run check_decline_exit_codes "$copy"
  [ "$status" -ne 0 ]
}
