#!/usr/bin/env bats
#
# Acceptance suite for the review record's hand-over: who receives each saved
# finding, how a member's answer is counted, how a fix round reaches the record,
# and how the loop's ending is read. Stand-in sidecars and dispositions stand for
# the members and the fixer; no review is run.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RECORD_SCRIPT="$REPO_ROOT/.gaia/scripts/audit-code-review-record.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/handover
  write_roster
  alf_set_line tool.sh 1 changed
  alf_set_line notes.txt 1 changed
  alf_commit change
  RUN="$ALF_ROOT/.gaia/local/runs/feat/handover"
  mkdir -p "$RUN"
  RECORD="$RUN/code-review.json"
  SHELL_MEMBER=code-audit-shell
  FRONTEND_MEMBER=code-audit-frontend
}

write_roster() {
  cat >"$ALF_ROOT/.gaia/audit-ci.yml" <<'EOF'
auditors:
  - name: code-audit-frontend
    globs:
      - "apps/**"
    default: true
  - name: code-audit-shell
    globs:
      - "*.sh"
EOF
}

record() {
  bash "$RECORD_SCRIPT" "$@"
}

# save_findings <file>...: record a ran outcome holding one finding per file.
save_findings() {
  local file_path findings='[]'
  for file_path in "$@"; do
    findings="$(printf '%s' "$findings" | jq -c --arg file "$file_path" \
      '. + [{file: $file, line: 3, summary: "summary", failure_scenario: "scenario"}]')"
  done
  printf '%s' "$findings" >"$BATS_TEST_TMPDIR/saved.json"
  record outcome --run-folder "$RUN" --pr 7 --outcome ran --findings "$BATS_TEST_TMPDIR/saved.json"
}

# assign_by_hand <jq-object>: {"cr-1": ["member", handed_only]}; the stand-in for assign.
assign_by_hand() {
  jq --argjson plan "$1" '.findings |= map(.member = $plan[.id][0] | .handed_only = $plan[.id][1])' "$RECORD" >"$RECORD.new"
  mv "$RECORD.new" "$RECORD"
}

finding_field() {
  jq -r --arg id "$1" ".findings[] | select(.id == \$id) | $2" "$RECORD"
}

# sidecar <member> <minutes> <entries-json> [drops-json]: the member's sidecar.
sidecar() {
  local file_path="$ALF_ROOT/.gaia/local/audit/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.$ALF_SLUG.$1.findings.json"
  jq -n -c --arg member "$1" --argjson entries "$3" --argjson drops "${4:-null}" \
    '{schema: 1, member: $member,
      findings: ($entries | map({finding_class: "holistic/x", severity: "major", path: "tool.sh", line: 3} + .))}
     + (if $drops == null then {} else {review_drops: $drops} end)' >"$file_path"
  touch -t "$(alf_time "$2")" "$file_path"
}

# delivered <member> <minutes>: deliver, then stamp the handed file so a later
# sidecar is newer than it.
delivered() {
  record delivery --run-folder "$RUN" --member "$1" >/dev/null
  touch -t "$(alf_time "$2")" "$RUN/code-review-handed-$1.json"
}

reconcile() {
  record reconcile --root "$ALF_ROOT" --run-folder "$RUN" "$@"
}

sum_holds() {
  jq -e '(.findings | length) == ([.findings[] | select(.state == "kept")] | length)
    + ([.findings[] | select(.state == "dropped")] | length)
    + ([.findings[] | select(.state == "unaccounted")] | length)' "$RECORD" >/dev/null
}

# assign

@test "assign: every id has one recipient; unowned and unchanged files go to the default member" {
  save_findings tool.sh notes.txt apps/web/other.txt unchanged.sh
  run record assign --root "$ALF_ROOT" --run-folder "$RUN"
  [ "$status" -eq 0 ]
  [ "$(finding_field cr-1 .member)" = "$SHELL_MEMBER" ]
  [ "$(finding_field cr-2 .member)" = "$FRONTEND_MEMBER" ]
  [ "$(finding_field cr-3 .member)" = "$FRONTEND_MEMBER" ]
  [ "$(finding_field cr-4 .member)" = "$FRONTEND_MEMBER" ]
  [ "$(jq '[.findings[] | select(.member == null)] | length' "$RECORD")" -eq 0 ]
}

@test "assign: a changed file with a non-ASCII name still counts as changed" {
  alf_set_line "é.sh" 1 changed
  alf_commit accent
  save_findings "é.sh"
  run record assign --root "$ALF_ROOT" --run-folder "$RUN"
  [ "$status" -eq 0 ]
  [ "$(finding_field cr-1 .member)" = "$SHELL_MEMBER" ]
}

@test "assign: a recipient the dispatch does not name is handed-only, one the dispatch names is not" {
  save_findings tool.sh notes.txt
  run record assign --root "$ALF_ROOT" --run-folder "$RUN"
  [ "$status" -eq 0 ]
  grep -Fxq "$SHELL_MEMBER"$'\t'false <<<"$output"
  grep -Fxq "$FRONTEND_MEMBER"$'\t'true <<<"$output"
}

@test "assign: a repeat exits 0, prints the same lines and changes nothing" {
  save_findings tool.sh notes.txt
  record assign --root "$ALF_ROOT" --run-folder "$RUN" >/dev/null
  # A stored recipient the roster would never produce shows a repeat reassigns nothing.
  jq '.findings[0].member = "stored-elsewhere"' "$RECORD" >"$RECORD.new"
  mv "$RECORD.new" "$RECORD"
  cp "$RECORD" "$BATS_TEST_TMPDIR/before.json"
  run record assign --root "$ALF_ROOT" --run-folder "$RUN"
  [ "$status" -eq 0 ]
  grep -q '^stored-elsewhere'$'\t' <<<"$output"
  cmp -s "$RECORD" "$BATS_TEST_TMPDIR/before.json"
}

# reconcile

@test "reconcile: an id in neither list is unaccounted and names its member once, then not again" {
  save_findings tool.sh tool.sh notes.txt
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false],\"cr-2\":[\"$SHELL_MEMBER\",false],\"cr-3\":[\"$FRONTEND_MEMBER\",true]}"
  delivered "$SHELL_MEMBER" 10
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1"]}]'
  run reconcile --member "$SHELL_MEMBER" --member "$FRONTEND_MEMBER"
  [ "$status" -eq 0 ]
  grep -Fxq "$SHELL_MEMBER" <<<"$output"
  grep -Fxq "$FRONTEND_MEMBER" <<<"$output"
  [ "$(finding_field cr-1 .state)" = kept ]
  [ "$(finding_field cr-2 .state)" = unaccounted ]
  [ "$(jq -r .handover "$RECORD")" = open ]
  sum_holds
  run reconcile --member "$SHELL_MEMBER" --member "$FRONTEND_MEMBER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r .handover "$RECORD")" = closed ]
  [ "$(finding_field cr-2 .state)" = unaccounted ]
  sum_holds
}

@test "reconcile: a claim by a member the id was not assigned to is unaccounted" {
  save_findings tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false]}"
  delivered "$SHELL_MEMBER" 10
  sidecar "$FRONTEND_MEMBER" 20 '[{"review_ids":["cr-1"]}]'
  run reconcile --member "$SHELL_MEMBER" --member "$FRONTEND_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(finding_field cr-1 .state)" = unaccounted ]
}

@test "reconcile: a sidecar from before the delivery counts for nothing" {
  save_findings tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false]}"
  sidecar "$SHELL_MEMBER" 5 '[{"review_ids":["cr-1"]}]'
  delivered "$SHELL_MEMBER" 10
  run reconcile --member "$SHELL_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(finding_field cr-1 .state)" = unaccounted ]
}

@test "reconcile: a later sidecar overwrite changes neither kept nor dropped" {
  save_findings tool.sh tool.sh notes.txt
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false],\"cr-2\":[\"$SHELL_MEMBER\",false],\"cr-3\":[\"$SHELL_MEMBER\",false]}"
  delivered "$SHELL_MEMBER" 10
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1"]}]' '[{"id":"cr-2","reason":"guard at tool.sh:2"}]'
  reconcile --member "$SHELL_MEMBER" >/dev/null
  [ "$(finding_field cr-1 .state)" = kept ]
  [ "$(finding_field cr-2 .state)" = dropped ]
  [ "$(finding_field cr-2 .drop_reason)" = "guard at tool.sh:2" ]
  sidecar "$SHELL_MEMBER" 30 '[{"review_ids":["cr-2","cr-3"]}]' '[{"id":"cr-1","reason":"changed my mind"}]'
  reconcile --member "$SHELL_MEMBER" >/dev/null
  [ "$(finding_field cr-1 .state)" = kept ]
  [ "$(finding_field cr-2 .state)" = dropped ]
  [ "$(finding_field cr-3 .state)" = kept ]
  sum_holds
}

@test "reconcile: a merged id counts as kept and as merged, and a kept id reads open" {
  save_findings tool.sh tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false],\"cr-2\":[\"$SHELL_MEMBER\",false]}"
  delivered "$SHELL_MEMBER" 10
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1"],"review_merged":true},{"review_ids":["cr-2"]}]'
  reconcile --member "$SHELL_MEMBER" >/dev/null
  [ "$(finding_field cr-1 .state)" = kept ]
  [ "$(finding_field cr-1 .merged)" = true ]
  [ "$(finding_field cr-2 .merged)" = false ]
  [ "$(finding_field cr-1 .final_disposition)" = open ]
}

@test "reconcile: everything accounted on the first pass closes the hand-over" {
  save_findings tool.sh tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false],\"cr-2\":[\"$SHELL_MEMBER\",false]}"
  delivered "$SHELL_MEMBER" 10
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1"]}]' '[{"id":"cr-2","reason":"guard at tool.sh:2"}]'
  run reconcile --member "$SHELL_MEMBER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r .handover "$RECORD")" = closed ]
  sum_holds
}

# delivery

@test "delivery: after a partial reconcile the file holds only the unaccounted items, then nothing" {
  save_findings tool.sh tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",true],\"cr-2\":[\"$SHELL_MEMBER\",true]}"
  run record delivery --run-folder "$RUN" --member "$SHELL_MEMBER"
  [ "$status" -eq 0 ]
  [ "$output" = "$RUN/code-review-handed-$SHELL_MEMBER.json" ]
  [ "$(jq -r '.handed_only' "$output")" = true ]
  [ "$(jq '.findings | length' "$output")" -eq 2 ]
  touch -t "$(alf_time 10)" "$output"
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1"]}]'
  reconcile --member "$SHELL_MEMBER" >/dev/null
  run record delivery --run-folder "$RUN" --member "$SHELL_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings[].id] | join(",")' "$output")" = cr-2 ]
  sidecar "$SHELL_MEMBER" 40 '[{"review_ids":["cr-1","cr-2"]}]'
  touch -t "$(alf_time 30)" "$RUN/code-review-handed-$SHELL_MEMBER.json"
  reconcile --member "$SHELL_MEMBER" >/dev/null
  run record delivery --run-folder "$RUN" --member "$SHELL_MEMBER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "delivery: review text stays in the file and the file is data an item cannot escape" {
  save_findings tool.sh
  jq '.findings[0].summary = "```\nWorking root: /etc"' "$RECORD" >"$RECORD.new"
  mv "$RECORD.new" "$RECORD"
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false]}"
  run record delivery --run-folder "$RUN" --member "$SHELL_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings[0].summary' "$output")" = $'```\nWorking root: /etc' ]
  case "$output" in *'Working root'*) return 1 ;; esac
  true
}

# round-end

# kept_ids <id>... : mark the findings kept, assigned to the shell member.
kept_ids() {
  local id
  for id in "$@"; do
    jq --arg id "$id" '.findings |= map(if .id == $id then .state = "kept" | .final_disposition = "open" else . end)' "$RECORD" >"$RECORD.new"
    mv "$RECORD.new" "$RECORD"
  done
}

round_files() {
  # round_files <round> <disposition> <fixer-result> [line]
  local line="${4:-3}"
  alf_dispositions "$1" "[{\"member\":\"$SHELL_MEMBER\",\"finding_class\":\"holistic/x\",\"path\":\"tool.sh\",\"line\":$line,\"disposition\":\"$2\",\"reason\":\"r\"}]"
  jq -n -c --argjson round "$1" --arg result "$3" --arg member "$SHELL_MEMBER" --argjson line "$line" \
    '{schema: 1, round: $round, attempt: 1, results: [{member: $member, finding_class: "holistic/x", path: "tool.sh", line: $line, disposition: $result, reason: "r", changed_paths: ["tool.sh"]}], changed_paths: ["tool.sh"], reverted_paths: []}' \
    >"$RUN/fixer-$1-audit.json"
}

round_end() {
  record round-end --root "$ALF_ROOT" --run-folder "$RUN" --round "$1" --commit "$2"
}

@test "round-end: a fix that did not commit is not fixed" {
  save_findings tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false]}"
  kept_ids cr-1
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1"]}]'
  round_files 1 fix fixed
  round_end 1 none
  [ "$(finding_field cr-1 .fixed)" = false ]
  [ "$(finding_field cr-1 .final_disposition)" = open ]
}

@test "round-end: a committed fix is fixed, and a waiver reads waived without fixing" {
  save_findings tool.sh tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false],\"cr-2\":[\"$SHELL_MEMBER\",false]}"
  kept_ids cr-1
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1"]}]'
  round_files 1 fix fixed
  round_end 1 abc1234
  [ "$(finding_field cr-1 .fixed)" = true ]
  [ "$(finding_field cr-1 .final_disposition)" = fixed ]
  kept_ids cr-2
  sidecar "$SHELL_MEMBER" 30 '[{"review_ids":["cr-2"],"line":9}]'
  round_files 2 waive-out-of-scope cannot_fix 9
  round_end 2 abc1234
  [ "$(finding_field cr-2 .fixed)" = false ]
  [ "$(finding_field cr-2 .final_disposition)" = waived ]
}

@test "round-end: a fix whose line moved on a later round, or whose sidecar was overwritten, still reads fixed" {
  save_findings tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false]}"
  kept_ids cr-1
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1"]}]'
  round_files 1 fix fixed
  round_end 1 abc1234
  sidecar "$SHELL_MEMBER" 30 '[{"review_ids":["cr-1"],"line":40}]'
  round_files 2 file cannot_fix 40
  round_end 2 none
  [ "$(finding_field cr-1 .fixed)" = true ]
  sidecar "$SHELL_MEMBER" 40 '[]'
  round_end 3 none
  [ "$(finding_field cr-1 .fixed)" = true ]
}

@test "round-end: two ids merged onto one identity key stay two" {
  save_findings tool.sh tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false],\"cr-2\":[\"$SHELL_MEMBER\",false]}"
  kept_ids cr-1 cr-2
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1","cr-2"],"review_merged":true}]'
  round_files 1 fix fixed
  round_end 1 abc1234
  [ "$(jq '[.findings[] | select(.fixed == true)] | length' "$RECORD")" -eq 2 ]
}

@test "round-end: a handed-only member's fixed id reads owed and another member's does not" {
  save_findings tool.sh tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",true],\"cr-2\":[\"$SHELL_MEMBER\",false]}"
  kept_ids cr-1
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1"]}]'
  round_files 1 fix fixed
  round_end 1 abc1234
  [ "$(finding_field cr-1 .recheck)" = owed ]
  [ "$(finding_field cr-2 .recheck)" = null ]
  jq '.findings |= map(if .id == "cr-1" then .handed_only = false else . end) | .findings |= map(if .id == "cr-2" then .state = "kept" else . end)' "$RECORD" >"$RECORD.new"
  mv "$RECORD.new" "$RECORD"
  sidecar "$SHELL_MEMBER" 30 '[{"review_ids":["cr-2"]}]'
  round_files 2 fix fixed
  round_end 2 abc1234
  [ "$(finding_field cr-2 .recheck)" = null ]
}

@test "round-end: rounds and members dispatched come from the loop history" {
  save_findings tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",false]}"
  alf_add_round "[\"$SHELL_MEMBER\"]"
  alf_set_line tool.sh 2 again
  alf_commit again
  alf_add_round "[\"$SHELL_MEMBER\",\"$FRONTEND_MEMBER\"]"
  round_end 1 none
  [ "$(jq .rounds "$RECORD")" -eq 2 ]
  [ "$(jq .members_dispatched "$RECORD")" -eq 2 ]
}

@test "round-end: a malformed commit is a usage error" {
  save_findings tool.sh
  run round_end 1 "not a sha"
  [ "$status" -eq 2 ]
}

# rechecks and recheck-close

recheck_setup() {
  save_findings tool.sh tool.sh
  assign_by_hand "{\"cr-1\":[\"$SHELL_MEMBER\",true],\"cr-2\":[\"$SHELL_MEMBER\",true]}"
  kept_ids cr-1 cr-2
  sidecar "$SHELL_MEMBER" 20 '[{"review_ids":["cr-1","cr-2"],"review_merged":true}]'
  round_files 1 fix fixed
  round_end 1 abc1234
  touch -t "$(alf_time 25)" "$RUN/dispositions-1.json"
}

@test "rechecks: one line per member holding owed ids, ids only; nothing owed prints nothing" {
  save_findings tool.sh
  run record rechecks --run-folder "$RUN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  recheck_setup
  run record rechecks --run-folder "$RUN"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${output%%$'\t'*}" = "$SHELL_MEMBER" ]
  [[ "${output#*$'\t'}" =~ ^cr-[0-9]+(,cr-[0-9]+)*$ ]]
}

@test "recheck-close: a re-reported id clears and an absent one reads done" {
  recheck_setup
  sidecar "$SHELL_MEMBER" 30 '[{"review_ids":["cr-1"]}]'
  run record recheck-close --root "$ALF_ROOT" --run-folder "$RUN" --member "$SHELL_MEMBER" --round 1
  [ "$status" -eq 0 ]
  [ "$(finding_field cr-1 .recheck)" = null ]
  [ "$(finding_field cr-2 .recheck)" = "done" ]
  [ "$(finding_field cr-1 .fixed)" = true ]
  [ "$(finding_field cr-1 .state)" = kept ]
}

@test "recheck-close: a member that left no new sidecar keeps its ids owed" {
  recheck_setup
  run record recheck-close --root "$ALF_ROOT" --run-folder "$RUN" --member "$SHELL_MEMBER" --round 1
  [ "$status" -eq 0 ]
  [ "$(finding_field cr-1 .recheck)" = owed ]
  [ "$(finding_field cr-2 .recheck)" = owed ]
}

# convergence

convergence_of() {
  record convergence --root "$ALF_ROOT" --run-folder "$RUN" --stop-reason "$1"
  jq -r .convergence "$RECORD"
}

grant_answered() {
  alf_seed_state '{}'
  alf_add_round "[\"$SHELL_MEMBER\"]"
  alf_add_checkpoint 1 test
  alf_add_answer 1 grant 3
}

accepted_residual() {
  jq -n -c '{member: "code-audit-frontend", finding_class: "c/imp", path: "f.txt", line: 3, failure_mode: "wrong"}' >"$BATS_TEST_TMPDIR/residual.json"
  bash "$REPO_ROOT/.gaia/scripts/audit-dispositions-check.sh" record-residual --root "$ALF_ROOT" --run-folder "$RUN" --finding "$BATS_TEST_TMPDIR/residual.json"
}

@test "convergence: any stop other than clean is stopped" {
  save_findings tool.sh
  [ "$(convergence_of window-end)" = stopped ]
  [ "$(convergence_of needs-human)" = stopped ]
}

@test "convergence: clean with no grant and no residual is clean" {
  save_findings tool.sh
  [ "$(convergence_of clean)" = clean ]
}

@test "convergence: clean after a grant" {
  save_findings tool.sh
  grant_answered
  [ "$(convergence_of clean)" = "clean after a grant" ]
}

@test "convergence: residuals win over a grant, and the last write holds" {
  save_findings tool.sh
  grant_answered
  accepted_residual
  [ "$(convergence_of clean)" = "accepted with residuals" ]
  [ "$(convergence_of window-end)" = stopped ]
}

# The unit's and the round procedure's text. An agent's steps cannot be run from a
# suite, so these assert the executed prose; the behavior is proven in the flow tests.

unit_definition() {
  printf '%s/.claude/agents/audit-loop-unit.md' "$REPO_ROOT"
}

round_procedure() {
  printf '%s/wiki/concepts/Audit Round Procedure.md' "$REPO_ROOT"
}

# unit_section <heading>: one `##` or `###` section of the unit, heading excluded.
unit_section() {
  awk -v heading="$1" '$0 == heading { inside = 1; next } inside && /^##+ / { exit } inside' "$(unit_definition)"
}

# has <text> <fixed-string>: fails naming what is missing.
has() {
  grep -qF -- "$2" <<<"$1" || { printf 'missing: %s\n' "$2" >&2; return 1; }
}

# line_of <file> <fixed-string>: the first matching line number, or a failure.
line_of() {
  local found
  found="$(grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1)"
  [ -n "$found" ] || { printf 'missing: %s\n' "$2" >&2; return 1; }
  printf '%s\n' "$found"
}

# heading_line <heading>: the unit's heading line, whole-line so a mention in prose
# never answers for it.
heading_line() {
  local found
  found="$(grep -nxF -- "$1" "$(unit_definition)" | cut -d: -f1)"
  [ -n "$found" ] || { printf 'missing heading: %s\n' "$1" >&2; return 1; }
  printf '%s\n' "$found"
}

@test "unit text: decide before dispatch, a background run, reconcile before dispositions, updates before each publish, a stop on a moved tree" {
  local section per_round
  section="$(unit_section '## Code review')"
  [ "$(heading_line '## Deny classes')" -lt "$(heading_line '## Code review')" ]
  [ "$(heading_line '## Code review')" -lt "$(heading_line '## Routing each member')" ]
  has "$(unit_section '## Routing each member')" "Step 2's dispatch waits for \`## Code review\`"
  has "$section" 'before any reviewer or member of the wave is dispatched'
  has "$section" 'review-record decide --root <root> --run-folder <run> --pr <N> --routes <all-light|mixed>'
  has "$section" 'audit-code-review.sh run --root <root> --pr <N> --run-folder <run> < /dev/null > <scratch>/code-review.log 2>&1` with Bash `run_in_background` as one plain command'
  has "$section" 'Monitor until-loop that exits once the log holds a line starting `code-review exit `'
  has "$section" 'review-record reconcile --root <root> --run-folder <run> --member <m> [--member <m>...]'
  has "$section" 'one `--member` for every member `assign` printed'
  has "$section" 'before writing any disposition'
  grep -qE 'exit 3`: .*Stop `needs-human`, with `stop_detail` naming the review as the cause, before any member starts' <<<"$section"
  per_round="$(unit_section '## Per round')"
  grep -qE 'review-record round-end --root <root> --run-folder <run> --round <r> --commit .*review-record convergence --root <root> --run-folder <run> --stop-reason window-end.*then publish the record' <<<"$per_round"
  grep -qE 'review-record convergence --root <root> --run-folder <run> --stop-reason <the stop_reason>`, then publish the record once more' <<<"$(unit_section '## When to stop')"
  has "$(unit_section '## Closing round')" "\`## Per round\`'s record updates with \`--commit none\`, publish the record"
  has "$(unit_section '### Quick-clear path')" "\`## When to stop\`'s convergence and publication once, with \`clean\`"
}

@test "unit text: the wait re-arms until the budget is spent, and a refused outcome on a live group stops for a human" {
  local section
  section="$(unit_section '## Code review')"
  has "$section" 'audit-code-review.sh wait-ms'
  has "$section" '`timeout_ms` the smaller of 1800000'
  has "$section" 'An expired Monitor with budget left is not a timeout: count what has elapsed and re-arm until the whole budget is spent'
  has "$section" "The whole budget spent with no exit line: run \`outcome\` with \`--outcome 'not run' --reason 'timed out'\`"
  has "$section" 'Exit 4 from either means the script or its process group outlived it: stop `needs-human`, with `stop_detail` naming the review'
}

@test "unit text: a predating branch records its outcome only once the review is owed, never when the root is resolved" {
  local section
  section="$(unit_section '## Code review')"
  grep -qF 'branch predates the review' <<<"$(grep -E '^1\. ' <<<"$section")" && return 1
  has "$(grep -E '^1\. ' <<<"$section")" 'Nothing is recorded here'
  has "$(grep -E '^4\. ' <<<"$section")" "--outcome 'not run' --reason 'branch predates the review'"
  [ "$(grep -cF 'branch predates the review' <<<"$section")" -eq 1 ]
  has "$(grep -E '^3\. ' <<<"$section")" 'go to step 4 before dispatching that member'
}

@test "unit text: every quick fallback runs the review, a handed member overrides its route, and the light-cleared line is qualified" {
  local section per_round
  section="$(unit_section '## Code review')"
  has "$section" 'a `full` line, a non-zero mark, a silent reviewer'
  has "$section" 'This overrides any route step 2 returned for that member: it takes the full route, and no light reviewer is dispatched for it'
  has "$section" 'Dispatch a member off the wave, or one already light-cleared, the same way'
  per_round="$(unit_section '## Per round')"
  has "$per_round" 'never the subject of a fix round, unless it holds handed findings: it is then dispatched full'
  has "$per_round" 'its kept findings follow the ordinary path'
}

@test "unit text: a clean stop waits on rechecks, and the re-check line carries ids only" {
  local section
  section="$(unit_section '## Code review')"
  has "$section" 'review-record rechecks --run-folder <run>'
  has "$section" 'A `clean` stop is not taken while `rechecks` prints anything'
  has "$section" '`Re-check review ids: <ids>` after the prompt'"'"'s fixed fields, carrying the ids and nothing else'
  has "$section" 'review-record recheck-close --root <root> --run-folder <run> --member <m> --round <r-1>'
  has "$(unit_section '## When to stop')" '`## Code review` holds no re-check (`clean`)'
}

@test "unit and round procedure: the handed line and the re-check line follow the member template's fixed fields" {
  local fixed_fields_end handed_line recheck_line template_end
  has "$(unit_section '## Code review')" '`Handed review findings: <path>` after the prompt'"'"'s fixed fields'
  fixed_fields_end="$(line_of "$(round_procedure)" '    How your run ends: a reply with no tool call')"
  handed_line="$(line_of "$(round_procedure)" '    Handed review findings: <path>')"
  recheck_line="$(line_of "$(round_procedure)" '    Re-check review ids: <ids>"')"
  template_end="$(line_of "$(round_procedure)" '**The last two lines are optional and come after the fixed fields.**')"
  [ "$fixed_fields_end" -lt "$handed_line" ]
  [ "$handed_line" -lt "$recheck_line" ]
  [ "$recheck_line" -lt "$template_end" ]
  has "$(awk '/^#### Light routing$/ { inside = 1; next } inside && /^#### / { exit } inside' "$(round_procedure)")" '**Hand-over exception.**'
}
