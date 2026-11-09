#!/usr/bin/env bats
#
# Flow proof that a kept review finding reaches the fix and re-check path. No agent
# runs: this suite plays the agents' file writes (the stand-in `claude`, the
# members' sidecars through the real writer, the orchestrator's dispositions, the
# fixer's results and commit) and calls the real review script, record script,
# findings writer, dispositions check, digest and clearance writer, so what it
# proves is the seam between them. Real member behavior is proven only by the gate
# run.
#
# The stand-in `claude` logs each call to a count file and writes a canned result.
# Times are pinned with `touch -t` (alf_time) so a sidecar is newer than a handed
# file by a whole minute; the suite never sleeps.
#
# Run: pnpm test:shell .gaia/tests/hooks/audit-code-review.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # GAIA_REVIEW_SCRIPTS points the suite at a scratch copy of the scripts tree (its
  # .gaia/scripts, with .claude/hooks/lib two levels up), which is how a mutant is run.
  SCRIPTS="${GAIA_REVIEW_SCRIPTS:-$REPO_ROOT/.gaia/scripts}"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/review-flow
  SHELL_MEMBER=code-audit-shell
  FRONTEND_MEMBER=code-audit-frontend
  write_roster
  alf_set_line tool.sh 1 changed
  alf_set_line other.sh 1 changed
  alf_set_line notes.txt 1 changed
  alf_commit change
  RUN="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  RECORD="$RUN/code-review.json"
  mkdir -p "$RUN"
  STAND_IN="$BATS_TEST_TMPDIR/stand-in"
  export STAND_IN
  mkdir -p "$STAND_IN/bin" "$STAND_IN/log"
  write_stand_in_claude
  write_stand_in_gh
  PATH="$STAND_IN/bin:$PATH"
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

# The stand-in prints $STAND_IN/result as the child's JSON result and counts calls.
write_stand_in_claude() {
  cat >"$STAND_IN/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1-}" = --version ]; then printf '2.1.319 (Claude Code)\n'; exit 0; fi
printf 'call\n' >>"$STAND_IN/calls"
cat "$STAND_IN/result"
EOF
  chmod +x "$STAND_IN/bin/claude"
  printf '```json\n[]\n```' | jq -Rs '{subtype: "success", is_error: false, local_command: "code_review", total_cost_usd: 0.5, result: .}' >"$STAND_IN/result"
}

write_stand_in_gh() {
  printf '#!/usr/bin/env bash\ncase "$*" in *isCrossRepository*) printf "false\\n"; exit 0 ;; esac\nexit 1\n' >"$STAND_IN/bin/gh"
  chmod +x "$STAND_IN/bin/gh"
}

claude_calls() {
  if [ -f "$STAND_IN/calls" ]; then wc -l <"$STAND_IN/calls" | tr -d ' '; else printf '0\n'; fi
}

# canned_findings <file:line>...: the child's result holds one finding per argument.
canned_findings() {
  local spec items='[]'
  for spec in "$@"; do
    items="$(printf '%s' "$items" | jq -c --arg file "${spec%%:*}" --argjson line "${spec##*:}" \
      '. + [{file: $file, line: $line, summary: "review summary \($file)", failure_scenario: "review scenario \($file)"}]')"
  done
  printf '```json\n%s\n```' "$items" | jq -Rs '{subtype: "success", is_error: false, local_command: "code_review", total_cost_usd: 0.5, result: .}' >"$STAND_IN/result"
}

record() {
  bash "$SCRIPTS/audit-code-review-record.sh" "$@"
}

review_run() {
  run bash "$SCRIPTS/audit-code-review.sh" run --root "$ALF_ROOT" --pr 7 --run-folder "$RUN" </dev/null
}

finding_field() {
  jq -r --arg id "$1" ".findings[] | select(.id == \$id) | $2" "$RECORD"
}

# deliver_to <member> <minutes>: deliver, then stamp the handed file at that time.
deliver_to() {
  local handed
  handed="$(record delivery --run-folder "$RUN" --member "$1")" || return 1
  [ -n "$handed" ] || return 1
  touch -t "$(alf_time "$2")" "$handed"
}

# member_report <member> <minutes> <entries-json> [drops-json]: the member's sidecar,
# written through the real writer; each entry takes the base fields below.
member_report() {
  local findings_file="$BATS_TEST_TMPDIR/report-$1.json" drops_file="$BATS_TEST_TMPDIR/drops-$1.json" sidecar
  jq -n -c --argjson entries "$3" '$entries | map({finding_class: "holistic/x", severity: "major", line: 1,
    title: "member title", failure_mode: "member failure", verified_by: "member checked", suggested_fix: "member fix"} + .)' >"$findings_file"
  if [ -n "${4:-}" ]; then
    printf '%s' "$4" >"$drops_file"
    bash "$SCRIPTS/audit-write-findings.sh" --root "$ALF_ROOT" --member "$1" --base "$(alf_git rev-parse main)" \
      --findings "$findings_file" --review-drops "$drops_file" >/dev/null || return 1
  else
    bash "$SCRIPTS/audit-write-findings.sh" --root "$ALF_ROOT" --member "$1" --base "$(alf_git rev-parse main)" \
      --findings "$findings_file" >/dev/null || return 1
  fi
  for sidecar in "$ALF_ROOT/.gaia/local/audit/"*."$ALF_SLUG.$1.findings.json"; do touch -t "$(alf_time "$2")" "$sidecar"; done
}

# --- the flow, played ---------------------------------------------------------------

# ran_review: three findings, a round recorded on HEAD, the review run and assigned.
# cr-1 and cr-2 go to the shell member, cr-3 (a file no member owns) to the frontend
# default member, which the dispatch does not name.
ran_review() {
  canned_findings tool.sh:1 other.sh:1 notes.txt:1
  review_run
  [ "$status" -eq 0 ] || return 1
  alf_add_round "[\"$SHELL_MEMBER\"]"
  alf_stamp 1 5
  record assign --root "$ALF_ROOT" --run-folder "$RUN" >/dev/null
}

# answered: the shell member keeps cr-1 and drops cr-2, the frontend keeps cr-3.
answered() {
  deliver_to "$SHELL_MEMBER" 10 || return 1
  deliver_to "$FRONTEND_MEMBER" 10 || return 1
  member_report "$SHELL_MEMBER" 20 '[{"path":"tool.sh","review_ids":["cr-1"]}]' '[{"id":"cr-2","reason":"guarded at other.sh:1"}]' || return 1
  member_report "$FRONTEND_MEMBER" 20 '[{"path":"notes.txt","review_ids":["cr-3"]}]' || return 1
  record reconcile --root "$ALF_ROOT" --run-folder "$RUN" --member "$SHELL_MEMBER" --member "$FRONTEND_MEMBER" >/dev/null
}

check_round() {
  run bash "$SCRIPTS/audit-dispositions-check.sh" check --root "$ALF_ROOT" --run-folder "$RUN" --round "$1"
}

# fix_entry <member> <path>: the orchestrator's fix disposition for a kept finding.
fix_entry() {
  jq -n -c --arg member "$1" --arg path "$2" \
    '{member: $member, finding_class: "holistic/x", path: $path, line: 1, disposition: "fix", reason: "kept review finding"}'
}

write_dispositions() {
  jq -n -c --argjson entries "$1" '{schema: 1, round: 1, entries: $entries, enforcement_paths_allowed: []}' >"$RUN/dispositions-1.json"
}

# fix_and_commit <path>...: the fixer's result file and commit for round 1; sets ALF_COMMIT.
fix_and_commit() {
  local path results='[]'
  for path in "$@"; do
    results="$(printf '%s' "$results" | jq -c --arg path "$path" '. + [{member: "", finding_class: "holistic/x", path: $path, line: 1, disposition: "fixed"}]')"
    alf_set_line "$path" 1 "repaired"
  done
  results="$(printf '%s' "$results" | jq -c --arg shell "$SHELL_MEMBER" --arg frontend "$FRONTEND_MEMBER" \
    'map(.member = (if .path == "notes.txt" then $frontend else $shell end))')"
  jq -n -c --argjson results "$results" '{schema: 1, round: 1, attempt: 1, results: $results}' >"$RUN/fixer-1-audit.json"
  alf_commit "fix(audit): address audit round 1 findings"
}

@test "review: every finding in the result has exactly one recipient" {
  canned_findings tool.sh:1 other.sh:1 notes.txt:1
  review_run
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$RECORD")" = ran ]
  alf_add_round "[\"$SHELL_MEMBER\"]"
  run record assign --root "$ALF_ROOT" --run-folder "$RUN"
  [ "$status" -eq 0 ]
  [ "$(jq '.findings | length' "$RECORD")" -eq 3 ]
  [ "$(jq '[.findings[] | select((.member | type) == "string" and (.handed_only | type) == "boolean")] | length' "$RECORD")" -eq 3 ]
  [ "$(finding_field cr-1 .member)" = "$SHELL_MEMBER" ]
  [ "$(finding_field cr-2 .member)" = "$SHELL_MEMBER" ]
  [ "$(finding_field cr-3 .member)" = "$FRONTEND_MEMBER" ]
}

@test "review: assign refuses a roster with no default member and an unreadable record, assigning nothing" {
  canned_findings tool.sh:1 notes.txt:1
  review_run
  alf_add_round "[\"$SHELL_MEMBER\"]"
  cp "$RECORD" "$BATS_TEST_TMPDIR/record-before.json"
  sed -i.bak '/default: true/d' "$ALF_ROOT/.gaia/audit-ci.yml"
  run --separate-stderr record assign --root "$ALF_ROOT" --run-folder "$RUN"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF 'the roster names no default member' <<<"$stderr"
  cmp -s "$RECORD" "$BATS_TEST_TMPDIR/record-before.json"
  [ "$(jq '[.findings[] | select(.member != null)] | length' "$RECORD")" -eq 0 ]
  write_roster
  printf 'not json {\n' >"$RECORD"
  run record assign --root "$ALF_ROOT" --run-folder "$RUN"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [ "$(cat "$RECORD")" = 'not json {' ]
}

@test "reconcile: a kept id keeps its mark and added equals kept plus dropped plus unaccounted" {
  ran_review
  answered
  [ "$(finding_field cr-1 .state)" = kept ]
  [ "$(finding_field cr-2 .state)" = dropped ]
  [ "$(finding_field cr-3 .state)" = kept ]
  jq -e '(.findings | length) == ([.findings[] | select(.state == "kept")] | length)
    + ([.findings[] | select(.state == "dropped")] | length)
    + ([.findings[] | select(.state == "unaccounted")] | length)' "$RECORD" >/dev/null
}

@test "dispositions check: a kept finding with no disposition refuses the round, and fix passes it with the member's own words" {
  ran_review
  answered
  write_dispositions '[]'
  check_round 1
  [ "$status" -eq 1 ]
  grep -qF 'violation: undisposed' <<<"$output"
  grep -qF '"path":"tool.sh"' <<<"$output"
  write_dispositions "[$(fix_entry "$SHELL_MEMBER" tool.sh), $(fix_entry "$FRONTEND_MEMBER" notes.txt)]"
  check_round 1
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  # The evaluator lists the kept finding by its identity key, and the sidecar the
  # unit briefs the fixer from holds the member's words and none of the review's.
  run bash "$SCRIPTS/audit-loop-eval.sh" findings --root "$ALF_ROOT" --round 1
  [ "$status" -eq 0 ]
  grep -qF '"path":"tool.sh"' <<<"$output"
  local sidecar_text
  sidecar_text="$(cat "$ALF_ROOT/.gaia/local/audit/"*".$ALF_SLUG.$SHELL_MEMBER.findings.json")"
  grep -qF 'member title' <<<"$sidecar_text"
  grep -qF 'member failure' <<<"$sidecar_text"
  grep -qF 'member fix' <<<"$sidecar_text"
  grep -qF 'review summary' <<<"$sidecar_text" && return 1
  grep -qF 'review scenario' <<<"$sidecar_text" && return 1
  true
}

@test "a fix to a kept finding's file rotates the member's digest and the earned marker does not carry over" {
  ran_review
  answered
  local before after
  before="$(bash "$SCRIPTS/audit-member-digest.sh" --root "$ALF_ROOT" --member "$SHELL_MEMBER")"
  run bash "$SCRIPTS/audit-write-clearance.sh" --root "$ALF_ROOT" --member "$SHELL_MEMBER" --provenance earned --scope-digest "$before"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ -f "$ALF_ROOT/.gaia/local/audit/$before.$SHELL_MEMBER.ok" ]
  fix_and_commit tool.sh
  after="$(bash "$SCRIPTS/audit-member-digest.sh" --root "$ALF_ROOT" --member "$SHELL_MEMBER")"
  [ "$before" != "$after" ]
  [ ! -f "$ALF_ROOT/.gaia/local/audit/$after.$SHELL_MEMBER.ok" ]
}

@test "round-end after a committed fix counts it fixed, and the record ends complete" {
  ran_review
  answered
  write_dispositions "[$(fix_entry "$SHELL_MEMBER" tool.sh), $(fix_entry "$FRONTEND_MEMBER" notes.txt)]"
  fix_and_commit tool.sh notes.txt
  record round-end --root "$ALF_ROOT" --run-folder "$RUN" --round 1 --commit "$ALF_COMMIT"
  record convergence --root "$ALF_ROOT" --run-folder "$RUN" --stop-reason window-end
  [ "$(finding_field cr-1 .fixed)" = true ]
  [ "$(finding_field cr-1 .final_disposition)" = fixed ]
  [ "$(finding_field cr-2 .fixed)" = false ]
  jq -e '.outcome == "ran" and .handover == "closed" and (.rounds | type) == "number" and (.members_dispatched | type) == "number"
    and .convergence == "stopped" and (.cost | type) == "number" and (.attempts | length) == 1
    and ([.findings[] | select(.state == null or .member == null or .id == null)] | length) == 0' "$RECORD" >/dev/null
}

@test "publish-values through the record writer renders the counts the subcommands wrote" {
  ran_review
  answered
  write_dispositions "[$(fix_entry "$SHELL_MEMBER" tool.sh), $(fix_entry "$FRONTEND_MEMBER" notes.txt)]"
  fix_and_commit tool.sh notes.txt
  record round-end --root "$ALF_ROOT" --run-folder "$RUN" --round 1 --commit "$ALF_COMMIT"
  local values="$BATS_TEST_TMPDIR/values.json" body_in="$BATS_TEST_TMPDIR/body-in.md" body_out="$BATS_TEST_TMPDIR/body-out.md"
  record publish-values --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --rounds 1 >"$BATS_TEST_TMPDIR/review.json"
  jq -c --slurpfile review "$BATS_TEST_TMPDIR/review.json" '. + {review: $review[0]}' \
    <<<'{"total":1,"members":{"code-audit-shell":1},"grants":0}' >"$values"
  printf 'body\n' >"$body_in"
  run bash "$SCRIPTS/audit-loop-record.sh" --pr 7 --values-json "$values" --body-in "$body_in" --body-out "$body_out"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -qF 'code review: ran; added 3, kept 2, dropped 1, unaccounted 0, merged 0, fixed 2;' "$body_out"
}

@test "decide: one stand-in call across later waves and a resume" {
  canned_findings tool.sh:1
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = run ]
  review_run
  [ "$(claude_calls)" -eq 1 ]
  alf_add_round "[\"$SHELL_MEMBER\"]"
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = deliver ]
  record assign --root "$ALF_ROOT" --run-folder "$RUN" >/dev/null
  deliver_to "$SHELL_MEMBER" 10
  member_report "$SHELL_MEMBER" 20 '[{"path":"tool.sh","review_ids":["cr-1"]}]'
  record reconcile --root "$ALF_ROOT" --run-folder "$RUN" --member "$SHELL_MEMBER" >/dev/null
  alf_add_round "[\"$SHELL_MEMBER\"]"
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = none ]
  # A second run on the ended record is the only call that could spawn again.
  review_run
  [ "$status" -eq 0 ]
  [ "$(claude_calls)" -eq 1 ]
  [ "$(jq -r .outcome "$RECORD")" = ran ]
  [ "$(jq '.attempts | length' "$RECORD")" -eq 1 ]
  [ "$(finding_field cr-1 .state)" = kept ]
}

@test "decide: no call on an all-quick wave, one call when the branch later needs a full wave" {
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes all-light
  [ "$output" = quick-first ]
  [ "$(claude_calls)" -eq 0 ]
  record outcome --run-folder "$RUN" --pr 7 --outcome 'not needed' --reason 'quick review cleared'
  [ "$(jq -r .outcome "$RECORD")" = 'not needed' ]
  alf_add_round '[]'
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = run ]
  [ "$(claude_calls)" -eq 0 ]
  canned_findings tool.sh:1
  review_run
  [ "$status" -eq 0 ]
  [ "$(claude_calls)" -eq 1 ]
  [ "$(jq -r .outcome "$RECORD")" = ran ]
  [ "$(finding_field cr-1 .file)" = tool.sh ]
}

@test "a member that accounts for nothing is named once, then reads unaccounted; redelivery holds only those" {
  ran_review
  deliver_to "$SHELL_MEMBER" 10
  deliver_to "$FRONTEND_MEMBER" 10
  member_report "$SHELL_MEMBER" 20 '[{"path":"tool.sh","review_ids":["cr-1"]}]'
  member_report "$FRONTEND_MEMBER" 20 '[]'
  run record reconcile --root "$ALF_ROOT" --run-folder "$RUN" --member "$SHELL_MEMBER" --member "$FRONTEND_MEMBER"
  [ "$status" -eq 0 ]
  grep -qxF "$SHELL_MEMBER" <<<"$output"
  grep -qxF "$FRONTEND_MEMBER" <<<"$output"
  run record delivery --run-folder "$RUN" --member "$SHELL_MEMBER"
  [ "$(jq -r '[.findings[].id] | join(",")' "$output")" = cr-2 ]
  deliver_to "$SHELL_MEMBER" 25
  member_report "$SHELL_MEMBER" 30 '[{"path":"tool.sh","review_ids":["cr-1"]}]' '[{"id":"cr-2","reason":"guarded"}]'
  member_report "$FRONTEND_MEMBER" 30 '[]'
  deliver_to "$FRONTEND_MEMBER" 25
  run record reconcile --root "$ALF_ROOT" --run-folder "$RUN" --member "$SHELL_MEMBER" --member "$FRONTEND_MEMBER"
  [ -z "$output" ]
  [ "$(finding_field cr-3 .state)" = unaccounted ]
  [ "$(jq -r .handover "$RECORD")" = closed ]
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = none ]
  rm -f "$RUN/code-review-handed-$FRONTEND_MEMBER.json"
  run record delivery --run-folder "$RUN" --member "$FRONTEND_MEMBER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$RUN/code-review-handed-$FRONTEND_MEMBER.json" ]
}

@test "a lost unit: assign twice gives the same recipients and set, and a forced close leaves the sum whole" {
  canned_findings tool.sh:1 notes.txt:1
  review_run
  alf_add_round "[\"$SHELL_MEMBER\"]"
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = deliver ]
  run record assign --root "$ALF_ROOT" --run-folder "$RUN"
  local first="$output"
  record delivery --run-folder "$RUN" --member "$SHELL_MEMBER" >/dev/null
  cp "$RUN/code-review-handed-$SHELL_MEMBER.json" "$BATS_TEST_TMPDIR/handed-first.json"
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = deliver ]
  run record assign --root "$ALF_ROOT" --run-folder "$RUN"
  [ "$output" = "$first" ]
  record delivery --run-folder "$RUN" --member "$SHELL_MEMBER" >/dev/null
  cmp -s "$RUN/code-review-handed-$SHELL_MEMBER.json" "$BATS_TEST_TMPDIR/handed-first.json"
  # A recipient already saved is never re-derived: move one and assign again.
  jq '.findings |= map(if .id == "cr-1" then .member = "saved-elsewhere" else . end)' "$RECORD" >"$RECORD.new" && mv "$RECORD.new" "$RECORD"
  record assign --root "$ALF_ROOT" --run-folder "$RUN" >/dev/null
  [ "$(finding_field cr-1 .member)" = saved-elsewhere ]
  alf_state_edit '.history.units = [{unit: 1, start_round: 1, k: 1, through_round: 1, after_checkpoint: 1, admitted_on: "accept"}]'
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = none ]
  [ "$(jq -r .handover "$RECORD")" = closed ]
  jq -e '(.findings | length) == ([.findings[] | select(.state == "unaccounted")] | length)' "$RECORD" >/dev/null
}

@test "a handed-only member's fix is owed a re-check that names ids only; a quiet sidecar closes it, a re-report keeps the ordinary path" {
  ran_review
  [ "$(finding_field cr-3 .handed_only)" = true ]
  answered
  write_dispositions "[$(fix_entry "$FRONTEND_MEMBER" notes.txt)]"
  fix_and_commit notes.txt
  record round-end --root "$ALF_ROOT" --run-folder "$RUN" --round 1 --commit "$ALF_COMMIT"
  [ "$(finding_field cr-3 .recheck)" = owed ]
  [ "$(finding_field cr-1 .recheck)" = null ]
  run record rechecks --run-folder "$RUN"
  [ "$output" = "$FRONTEND_MEMBER"$'\t'cr-3 ]
  touch -t "$(alf_time 35)" "$RUN/dispositions-1.json"
  local before_state
  before_state="$(jq -c '[.findings[] | [.id, .state, .fixed]]' "$RECORD")"
  member_report "$FRONTEND_MEMBER" 40 '[{"path":"notes.txt","review_ids":["cr-3"]}]'
  record recheck-close --root "$ALF_ROOT" --run-folder "$RUN" --member "$FRONTEND_MEMBER" --round 1
  [ "$(finding_field cr-3 .recheck)" = null ]
  [ "$(finding_field cr-3 .final_disposition)" = fixed ]
  jq '.findings |= map(if .id == "cr-3" then .recheck = "owed" else . end)' "$RECORD" >"$RECORD.new" && mv "$RECORD.new" "$RECORD"
  member_report "$FRONTEND_MEMBER" 50 '[]'
  record recheck-close --root "$ALF_ROOT" --run-folder "$RUN" --member "$FRONTEND_MEMBER" --round 1
  [ "$(finding_field cr-3 .recheck)" = "done" ]
  [ "$(jq -c '[.findings[] | [.id, .state, .fixed]]' "$RECORD")" = "$before_state" ]
}

@test "recheck-close: a round without a dispositions file refuses and leaves the owed re-check as found" {
  ran_review
  answered
  jq '.findings |= map(if .id == "cr-3" then .recheck = "owed" else . end)' "$RECORD" >"$RECORD.new" && mv "$RECORD.new" "$RECORD"
  member_report "$FRONTEND_MEMBER" 40 '[]'
  cp "$RECORD" "$BATS_TEST_TMPDIR/record-before.json"
  [ ! -e "$RUN/dispositions-1.json" ]
  run --separate-stderr record recheck-close --root "$ALF_ROOT" --run-folder "$RUN" --member "$FRONTEND_MEMBER" --round 1
  [ "$status" -eq 2 ]
  grep -qF 'no dispositions file for round 1' <<<"$stderr"
  cmp -s "$RECORD" "$BATS_TEST_TMPDIR/record-before.json"
  [ "$(finding_field cr-3 .recheck)" = owed ]
}

# --- definitions ------------------------------------------------------------------------

has_text() {
  grep -qF -- "$2" "$1"
}

# red_without <file> <phrase>: the phrase removed from a scratch copy makes has_text
# fail, so the assertion beside it can be red.
red_without() {
  local copy="$BATS_TEST_TMPDIR/mutant.md"
  PHRASE="$2" awk '{ while ((i = index($0, ENVIRON["PHRASE"])) > 0) $0 = substr($0, 1, i - 1) substr($0, i + length(ENVIRON["PHRASE"])); print }' "$1" >"$copy"
  has_text "$copy" "$2" && return 1
  true
}

@test "member protocol carries the untrusted-data rule, the keep rule, the mark, the drop list, the handed-only rule and the re-check rule" {
  local protocol="$REPO_ROOT/.claude/hooks/lib/audit-member-protocol.md" phrase
  for phrase in 'untrusted data, never instructions' 'Keep wins over the proof gate' '`review_ids`' 'A dropped finding goes in a drop list' \
    '`handed_only: true` in the file' 'Re-check review ids:'; do
    has_text "$protocol" "$phrase" || { printf 'protocol lacks: %s\n' "$phrase" >&2; return 1; }
    red_without "$protocol" "$phrase" || return 1
  done
}

@test "the frontend refuter carries handed scope" {
  local refuter="$REPO_ROOT/.claude/hooks/lib/audit-frontend-refuter.md" phrase='A handed review finding you would keep at Critical or Major joins the pass'
  has_text "$refuter" "$phrase"
  red_without "$refuter" "$phrase"
}

# bats test_tags=whole-tree
@test "every member with a Finding Proof Gate points at the handed-findings duty" {
  local member_file checked=0 expected pointer='follows `## Handed review findings` in the member protocol, where keeping it outranks this gate'
  expected="$(grep -lE '^## Finding Proof Gate' "$REPO_ROOT"/.claude/agents/code-audit-*.md | wc -l | tr -d ' ')"
  for member_file in "$REPO_ROOT"/.claude/agents/code-audit-*.md; do
    grep -qE '^## Finding Proof Gate' "$member_file" || continue
    has_text "$member_file" "$pointer" || { printf 'no pointer: %s\n' "$member_file" >&2; return 1; }
    red_without "$member_file" "$pointer" || return 1
    checked=$((checked + 1))
  done
  [ "$checked" -eq "$expected" ]
  [ "$checked" -gt 0 ]
}

# --- the failure direction: a review that did not complete never reads clean ----------------

# stand_in_behaves <body>: the stand-in claude runs <body> after counting the call.
# The version it reports comes from $STAND_IN/version (default 2.1.319).
stand_in_behaves() {
  cat >"$STAND_IN/bin/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1-}" = --version ]; then printf '%s (Claude Code)\n' "$(cat "$STAND_IN/version" 2>/dev/null || printf 2.1.319)"; exit 0; fi
printf 'call\n' >>"$STAND_IN/calls"
. "$STAND_IN/behavior"
STUB
  chmod +x "$STAND_IN/bin/claude"
  printf '%s\n' "$1" >"$STAND_IN/behavior"
}

# stand_in_result <jq args...>: the child prints that object and exits 0.
stand_in_result() {
  jq -n -c "$@" >"$STAND_IN/result"
  stand_in_behaves 'cat "$STAND_IN/result"'
}

FENCED_EMPTY=$'```json\n[]\n```'

state_rounds() {
  if [ -f "$ALF_STATE" ]; then jq '.history.rounds | length' "$ALF_STATE"; else printf '0\n'; fi
}

# published_clause: the code review clause of the real `## Audit rounds` line,
# rendered by audit-loop-record.sh from the record writer's own publish-values.
published_clause() {
  local values="$BATS_TEST_TMPDIR/clause-values.json" body_in="$BATS_TEST_TMPDIR/clause-in.md" body_out="$BATS_TEST_TMPDIR/clause-out.md" review_json
  review_json="$(record publish-values --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --rounds 1)" || return 1
  [ -n "$review_json" ] || return 1
  jq -c --argjson review "$review_json" '. + {review: $review}' <<<'{"total":1,"members":{"code-audit-shell":1},"grants":0}' >"$values"
  printf 'body\n' >"$body_in"
  bash "$SCRIPTS/audit-loop-record.sh" --pr 7 --values-json "$values" --body-in "$body_in" --body-out "$body_out" >/dev/null || return 1
  sed -n 's/^.*human grants: [0-9]*; code review: //p' "$body_out"
}

# published_clause_through_eval: the same clause, with the values taken from the
# evaluator's own record-values, so the rounds in the branch's history reach
# the record writer's publish-values as they do in the unit.
published_clause_through_eval() {
  local values="$BATS_TEST_TMPDIR/eval-values.json" body_in="$BATS_TEST_TMPDIR/eval-in.md" body_out="$BATS_TEST_TMPDIR/eval-out.md"
  bash "$SCRIPTS/audit-loop-eval.sh" record-values --root "$ALF_ROOT" >"$values" || return 1
  jq -e 'has("review")' "$values" >/dev/null || return 1
  printf 'body\n' >"$body_in"
  bash "$SCRIPTS/audit-loop-record.sh" --pr 7 --values-json "$values" --body-in "$body_in" --body-out "$body_out" >/dev/null || return 1
  sed -n 's/^.*human grants: [0-9]*; code review: //p' "$body_out"
}

# --- the real merge gate and the audit-loop bound, with the record present and absent ---

# The sourced merge-gate fixture reads the names assigned here.
# shellcheck disable=SC2034
prepare_gate() {
  [ -z "${GATE_READY-}" ] || return 0
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/hooks/helpers/merge-gate-fixture.sh"
  REPO="$ALF_ROOT"
  MGF_REPO_ROOT="$REPO_ROOT"
  MGF_LIBRARY_DIRECTORY="$REPO_ROOT/.claude/hooks/lib"
  MGF_HOOK="${GATE_HOOK:-$REPO_ROOT/.claude/hooks/pr-merge-audit-check.sh}"
  BOUND_HOOK="${BOUND_HOOK_UNDER_TEST:-$REPO_ROOT/.claude/hooks/audit-loop-bound.sh}"
  CATCHUP_ORIGIN="$ALF_ORIGIN"
  CATCHUP_BASE_BRANCH=main
  unset GITHUB_REPOSITORY GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS GAIA_AUDIT_LOOP_DEADLINE_SECONDS
  local library_file
  mkdir -p "$ALF_ROOT/.gaia/scripts" "$ALF_ROOT/.claude/hooks/lib"
  cp "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" "$REPO_ROOT/.gaia/scripts/resolve-audit-members.sh" "$ALF_ROOT/.gaia/scripts/"
  for library_file in audit-scope.sh audit-machinery.sh audit-clearance.sh audit-digest.sh audit-base-provenance.sh audit-branch-patch.sh; do
    cp "$MGF_LIBRARY_DIRECTORY/$library_file" "$ALF_ROOT/.claude/hooks/lib/$library_file"
  done
  mgf_install_gh_stub
  mgf_record 7 false "feat: review flow" tool.sh other.sh notes.txt
  GATE_READY=1
}

# capture_gates: GATE_RESULT holds the merge gate's and the bound hook's decisions.
# The bound hook writes the branch's round state, which is put back after it runs.
capture_gates() {
  local payload state_directory="${ALF_STATE%/*}" state_backup="$BATS_TEST_TMPDIR/loop-state-backup"
  mgf_run_merge 'gh pr merge 7 --squash'
  GATE_RESULT="merge $status: $output"
  payload="$(jq -n -c --arg root "$ALF_ROOT" '{session_id: "gate", hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
    tool_input: {subagent_type: "code-audit-frontend", prompt: ("Audit the change. Working root: " + $root + ", base main")}}')"
  rm -rf "$state_backup"
  if [ -d "$state_directory" ]; then cp -R "$state_directory" "$state_backup"; fi
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$ALF_ROOT" "$payload" "$BOUND_HOOK"
  GATE_RESULT="$GATE_RESULT"$'\n'"bound $status: $output"
  rm -rf "$state_directory"
  if [ -d "$state_backup" ]; then cp -R "$state_backup" "$state_directory"; fi
}

# gates_ignore_record: both hooks decide the same with the review record present
# and set aside, on the same repository, and the merge decision is a real deny
# text, not silence, so a gate that began to read the record would change it.
gates_ignore_record() {
  local with_record without_record
  prepare_gate
  capture_gates
  with_record="$GATE_RESULT"
  if [ -f "$RECORD" ]; then mv "$RECORD" "$RECORD.aside"; fi
  capture_gates
  without_record="$GATE_RESULT"
  if [ -f "$RECORD.aside" ]; then mv "$RECORD.aside" "$RECORD"; fi
  [ "$with_record" = "$without_record" ] || { printf 'with record:\n%s\nwithout:\n%s\n' "$with_record" "$without_record" >&2; return 1; }
  grep -qF 'permissionDecision' <<<"$with_record"
}

# expect_unrun <outcome> <claude-calls> <attempts> <reason> <cost-text>: the failure
# direction end to end: the stand-in was called that many times, the record holds
# the literal outcome and reason and the attempts, the rendered clause carries no
# finding count, the review opened no round, and the gates decide as they do with
# no record.
expect_unrun() {
  local clause
  [ "$(claude_calls)" -eq "$2" ] || { printf 'calls %s, wanted %s\n' "$(claude_calls)" "$2" >&2; return 1; }
  [ "$(jq -r .outcome "$RECORD")" = "$1" ]
  [ "$(jq -r .reason "$RECORD")" = "$4" ] || { printf 'reason %s, wanted %s\n' "$(jq -r .reason "$RECORD")" "$4" >&2; return 1; }
  [ "$(jq '.attempts | length' "$RECORD")" -eq "$3" ]
  [ "$(jq '.findings | length' "$RECORD")" -eq 0 ]
  clause="$(published_clause)"
  [ "$clause" = "$1: $4; $5." ] || { printf 'clause: %s\n' "$clause" >&2; return 1; }
  grep -qE 'added|kept|dropped|unaccounted|merged|fixed|denials' <<<"$clause" && return 1
  [ "$(state_rounds)" -eq "$ROUNDS_BEFORE" ]
  gates_ignore_record
}

expect_not_run() {
  expect_unrun 'not run' "$@"
}

# failing_review: note the round count, then run the real script to a recorded outcome.
failing_review() {
  ROUNDS_BEFORE="$(state_rounds)"
  review_run
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  [ "${lines[$((${#lines[@]} - 1))]}" = 'code-review exit 0' ]
}

@test "failure: a child that exits non-zero is retried once and published as not run" {
  stand_in_behaves 'exit 3'
  failing_review
  expect_not_run 2 2 'nonzero exit' 'estimated cost unknown'
}

@test "failure: a child that cannot launch is published as not run after one call, never retried" {
  local launch_status
  for launch_status in 126 127; do
    rm -f "$RECORD" "$STAND_IN/calls"
    stand_in_behaves "exit $launch_status"
    failing_review
    [ "$(jq -r '.attempts[0].exit' "$RECORD")" -eq "$launch_status" ]
    grep -qF 'ignores user settings' <<<"$output" || { printf 'no settings hint for %s\n' "$launch_status" >&2; return 1; }
    expect_not_run 1 1 'launch failed' 'estimated cost unknown'
  done
}

@test "failure: a process group that outlives the deadline stops the unit with exit 1 and records no outcome" {
  # The scratch copy never sends KILL and gives up on the group after one second,
  # standing in for a group that survives every signal. The child exits normally and
  # leaves a descendant that ignores TERM.
  scratch_scripts audit-code-review-child.sh 's/^kill "KILL", -\$group;$/# no kill/;s/\[ "\$tick" -lt 40 \]/[ "$tick" -lt 2 ]/'
  sed -i.bak 's/^REVIEW_TIMEOUT_SECONDS=.*/REVIEW_TIMEOUT_SECONDS=1/;s/^SUPERVISOR_GRACE_SECONDS=.*/SUPERVISOR_GRACE_SECONDS=1/' "$SCRATCH_SCRIPTS/audit-code-review.sh"
  stand_in_behaves '(trap "" TERM; exec sleep 300) >/dev/null 2>&1 &'
  ROUNDS_BEFORE="$(state_rounds)"
  run bash "$SCRATCH_SCRIPTS/audit-code-review.sh" run --root "$ALF_ROOT" --pr 7 --run-folder "$RUN" </dev/null
  kill -KILL -- "-$(cat "$RUN/code-review-attempt-1/pgid")" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [ "${lines[$((${#lines[@]} - 1))]}" = 'code-review exit 1' ]
  grep -qF 'outlived the deadline; recording nothing while it lives' <<<"$output"
  [ "$(claude_calls)" -eq 1 ]
  [ "$(jq -r .outcome "$RECORD")" = pending ]
  [ "$(jq -r '.attempts[0].closed_at' "$RECORD")" = null ]
}

@test "failure: an error result is retried once and published as not run" {
  stand_in_result '{subtype: "success", is_error: true, local_command: "code_review", total_cost_usd: 0.5, result: "boom"}'
  failing_review
  expect_not_run 2 2 'error result' 'estimated cost $1.00 for the review session only'
}

@test "failure: a project skill that answers with an empty fence is not the built-in" {
  stand_in_result --arg result "$FENCED_EMPTY" '{subtype: "success", is_error: false, total_cost_usd: 0.5, result: $result}'
  failing_review
  expect_not_run 2 2 'not the built-in' 'estimated cost $1.00 for the review session only'
}

@test "failure: the built-in answering free prose is an unusable result" {
  stand_in_result '{subtype: "success", is_error: false, local_command: "code_review", total_cost_usd: 0.5, result: "Looks fine to me, nothing to report."}'
  failing_review
  expect_not_run 2 2 'unusable result' 'estimated cost $1.00 for the review session only'
}

# scratch_scripts <script> <sed-expression>: a copy of the scripts tree (real files, never
# links) with one edit applied to <script>; sets SCRATCH_SCRIPTS. Fails when the edit
# changed nothing, so a mutation that no longer matches cannot pass unnoticed.
scratch_scripts() {
  local scratch="$BATS_TEST_TMPDIR/scratch" target
  rm -rf "$scratch"
  mkdir -p "$scratch/.gaia" "$scratch/.claude/hooks"
  cp -R "$SCRIPTS" "$scratch/.gaia/scripts"
  cp -R "$SCRIPTS/../../.claude/hooks/lib" "$scratch/.claude/hooks/lib"
  target="$scratch/.gaia/scripts/$1"
  sed -e "$2" "$target" >"$target.edited" && mv "$target.edited" "$target" && chmod +x "$target"
  if cmp -s "$target" "$SCRIPTS/$1"; then printf 'the edit left %s unchanged\n' "$1" >&2; return 1; fi
  SCRATCH_SCRIPTS="$scratch/.gaia/scripts"
}

@test "failure: a child past the deadline is killed, retried once and published as timed out with cost unknown" {
  scratch_scripts audit-code-review.sh 's/^REVIEW_TIMEOUT_SECONDS=.*/REVIEW_TIMEOUT_SECONDS=1/;s/^SUPERVISOR_GRACE_SECONDS=.*/SUPERVISOR_GRACE_SECONDS=1/'
  stand_in_behaves 'sleep 60'
  ROUNDS_BEFORE="$(state_rounds)"
  run bash "$SCRATCH_SCRIPTS/audit-code-review.sh" run --root "$ALF_ROOT" --pr 7 --run-folder "$RUN" </dev/null
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(jq -r '[.attempts[].exit] | join(",")' "$RECORD")" = 124,124 ]
  expect_not_run 2 2 'timed out' 'estimated cost unknown'
}

@test "failure: an attempt left open on entry counts as failed and the one retry that follows fails too" {
  record open --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --base "$(alf_git rev-parse main)" --head "$(alf_git rev-parse HEAD)" --claude-version 2.1.319
  record attempt-open --run-folder "$RUN" --n 1
  stand_in_behaves 'exit 3'
  failing_review
  [ "$(jq -r '.attempts[0].reason' "$RECORD")" = interrupted ]
  [ "$(jq -r '.attempts[0].cost' "$RECORD")" = unknown ]
  expect_not_run 1 2 'nonzero exit' 'estimated cost unknown'
}

@test "failure: a record held by a live attempt cannot be opened, so the unit stops with exit 1 and starts no review" {
  scratch_scripts audit-code-review.sh 's/^REVIEW_TIMEOUT_SECONDS=.*/REVIEW_TIMEOUT_SECONDS=1/;s/^WAIT_MARGIN_SECONDS=.*/WAIT_MARGIN_SECONDS=0/'
  record open --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --base "$(alf_git rev-parse main)" --head "$(alf_git rev-parse HEAD)" --claude-version 2.1.319
  record attempt-open --run-folder "$RUN" --n 1
  mkdir -p "$RUN/code-review-attempt-1"
  sleep 60 &
  local live_process=$!
  printf '%s\n' "$live_process" >"$RUN/code-review-attempt-1/script.pid"
  cp "$RECORD" "$BATS_TEST_TMPDIR/record-before.json"
  run bash "$SCRATCH_SCRIPTS/audit-code-review.sh" run --root "$ALF_ROOT" --pr 7 --run-folder "$RUN" </dev/null
  kill -KILL "$live_process"
  wait "$live_process" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [ "${lines[$((${#lines[@]} - 1))]}" = 'code-review exit 1' ]
  grep -qF 'could not open the review record (status 4); no review started' <<<"$output"
  [ "$(claude_calls)" -eq 0 ]
  cmp -s "$RECORD" "$BATS_TEST_TMPDIR/record-before.json"
}

@test "failure: attempts exhausted with the last left open publish interrupted and spawn nothing" {
  record open --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --base "$(alf_git rev-parse main)" --head "$(alf_git rev-parse HEAD)" --claude-version 2.1.319
  record attempt-open --run-folder "$RUN" --n 1
  record attempt-close --run-folder "$RUN" --n 1 --exit 3 --cost 0.5 --reason 'nonzero exit'
  record attempt-open --run-folder "$RUN" --n 2
  stand_in_behaves 'cat "$STAND_IN/result"'
  failing_review
  [ "$(jq -r '.attempts[1].reason' "$RECORD")" = interrupted ]
  expect_not_run 0 2 'interrupted' 'estimated cost unknown'
}

@test "failure: a Claude Code below the version floor is not run and spawns nothing" {
  stand_in_behaves 'cat "$STAND_IN/result"'
  printf '2.1.100\n' >"$STAND_IN/version"
  failing_review
  expect_not_run 0 0 'below version floor' 'cost none'
}

@test "failure: a branch with no resolvable base is not run and spawns nothing" {
  stand_in_behaves 'cat "$STAND_IN/result"'
  alf_git update-ref -d refs/remotes/origin/main
  alf_git branch -q -D main
  failing_review
  expect_not_run 0 0 'base unresolved' 'cost none'
}

@test "failure: a fork pull request is not run and spawns nothing" {
  printf '#!/usr/bin/env bash\ncase "$*" in *isCrossRepository*) printf "true\\n"; exit 0 ;; esac\nexit 1\n' >"$STAND_IN/bin/gh"
  failing_review
  expect_not_run 0 0 'fork or unanswered fork check' 'cost none'
}

@test "failure: a fork check gh cannot answer is not run and spawns nothing" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"$STAND_IN/bin/gh"
  failing_review
  expect_not_run 0 0 'fork or unanswered fork check' 'cost none'
}

@test "failure: a working root without the review script is published as predating it, written through the main copy" {
  [ ! -e "$ALF_ROOT/.gaia/scripts/audit-code-review.sh" ]
  ROUNDS_BEFORE="$(state_rounds)"
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = run ]
  record outcome --run-folder "$RUN" --pr 7 --outcome 'not run' --reason 'branch predates the review'
  expect_not_run 0 0 'branch predates the review' 'cost none'
}

# release_branch: .gaia/VERSION differs between the fork point and HEAD.
release_branch() {
  alf_git checkout -q main
  printf '1.0.0\n' >"$ALF_ROOT/.gaia/VERSION"
  alf_git add -f .gaia/VERSION && alf_git commit -q -m version && alf_git push -q origin main 2>/dev/null
  alf_git checkout -q "$ALF_BRANCH" && alf_git fetch -q origin && alf_git merge -q --no-edit origin/main >/dev/null
  printf '2.0.0\n' >"$ALF_ROOT/.gaia/VERSION"
  alf_commit bump
}

@test "failure: a release signal publishes not needed once, and a second wave leaves the record as found" {
  release_branch
  ROUNDS_BEFORE="$(state_rounds)"
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = none ]
  expect_unrun 'not needed' 0 0 'release branch' 'cost none'
  cp "$RECORD" "$BATS_TEST_TMPDIR/release-record.json"
  alf_add_round "[\"$SHELL_MEMBER\"]"
  ROUNDS_BEFORE="$(state_rounds)"
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = none ]
  cmp -s "$RECORD" "$BATS_TEST_TMPDIR/release-record.json"
  expect_unrun 'not needed' 0 0 'release branch' 'cost none'
}

@test "failure: no record with rounds already in history publishes an audit under way" {
  alf_add_round "[\"$SHELL_MEMBER\"]"
  ROUNDS_BEFORE="$(state_rounds)"
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = none ]
  expect_not_run 0 0 'audit already under way' 'cost none'
}

@test "failure: an unreadable round history decides none, starts no review and leaves no record" {
  mkdir -p "${ALF_STATE%/*}"
  printf 'not json {\n' >"$ALF_STATE"
  run --separate-stderr record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$status" -eq 0 ]
  [ "$output" = none ]
  grep -qF 'cannot read the audit round history; no review decided' <<<"$stderr"
  [ ! -e "$RECORD" ]
  [ "$(claude_calls)" -eq 0 ]
  [ "$(published_clause)" = 'not run: no record; cost none.' ]
}

@test "failure: an unreadable record is left as found, starts no review and publishes unreadable" {
  printf 'not json {\n' >"$RECORD"
  cp "$RECORD" "$BATS_TEST_TMPDIR/unreadable-record"
  run record decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes mixed
  [ "$output" = none ]
  review_run
  [ "$status" -eq 0 ]
  [ "$(claude_calls)" -eq 0 ]
  cmp -s "$RECORD" "$BATS_TEST_TMPDIR/unreadable-record"
  [ "$(published_clause)" = 'not run: unreadable record; estimated cost unknown.' ]
  [ "$(state_rounds)" -eq 0 ]
  gates_ignore_record
}

@test "failure: a record that parses with the wrong shape publishes unreadable, never a blank" {
  ran_review
  jq '.findings = "not an array"' "$RECORD" >"$BATS_TEST_TMPDIR/wrong-shape-record"
  cp "$BATS_TEST_TMPDIR/wrong-shape-record" "$RECORD"
  [ "$(published_clause)" = 'not run: unreadable record; estimated cost unknown.' ]
}

@test "failure: a child that moves the tree stops the unit with exit 3 and publishes review moved the tree" {
  stand_in_behaves 'printf moved >>tool.sh'
  ROUNDS_BEFORE="$(state_rounds)"
  review_run
  [ "$status" -eq 3 ]
  [ "${lines[$((${#lines[@]} - 1))]}" = 'code-review exit 3' ]
  expect_not_run 1 1 'review moved the tree' 'estimated cost unknown'
}

@test "failure: a clean review with denials is published as no findings and hands no clean signal to a member" {
  stand_in_result --arg result "$FENCED_EMPTY" '{subtype: "success", is_error: false, local_command: "code_review", total_cost_usd: 0.5,
    permission_denials: [{tool_name: "Read", tool_input: {file_path: "/home/user/.claude/CLAUDE.md"}}], result: $result}'
  ROUNDS_BEFORE="$(state_rounds)"
  review_run
  [ "$status" -eq 0 ]
  [ "$(jq -r .outcome "$RECORD")" = 'ran, no findings' ]
  [ "$(jq -r .denials.count "$RECORD")" -eq 1 ]
  [ "$(published_clause)" = 'ran, no findings, 1 denial (Read); estimated cost $0.50 for the review session only.' ]
  alf_add_round "[\"$SHELL_MEMBER\"]"
  run record assign --root "$ALF_ROOT" --run-folder "$RUN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq '.findings | length' "$RECORD")" -eq 0 ]
  ROUNDS_BEFORE="$(state_rounds)"
  gates_ignore_record
}

@test "failure: a hook-blocked read the result omits still makes the record no findings, never clean" {
  stand_in_result --arg result "$FENCED_EMPTY" '{subtype: "success", is_error: false, local_command: "code_review", total_cost_usd: 0.5, result: $result}'
  stand_in_behaves "printf '{\"tool\":\"Read\",\"path\":\".env\"}\\n' >>'$RUN/code-review-attempt-1/guard-denials.jsonl'; cat \"\$STAND_IN/result\""
  review_run
  [ "$status" -eq 0 ]
  [ "$(jq -r .outcome "$RECORD")" = 'ran, no findings' ]
  [ "$(jq -r .denials.count "$RECORD")" -eq 1 ]
  [ "$(jq -r '.denials.tools | join(",")' "$RECORD")" = Read ]
  [ "$(published_clause)" = 'ran, no findings, 1 denial (Read); estimated cost $0.50 for the review session only.' ]
}

@test "failure: a round with no record publishes no record with cost none" {
  alf_add_round "[\"$SHELL_MEMBER\"]"
  [ ! -e "$RECORD" ]
  [ "$(published_clause_through_eval)" = 'not run: no record; cost none.' ]
  gates_ignore_record
}

@test "failure: a finding count is refused beside not run and not needed, required beside ran, and zero is a count" {
  local values="$BATS_TEST_TMPDIR/count-values.json" body_in="$BATS_TEST_TMPDIR/count-in.md" review
  printf 'body\n' >"$body_in"
  for review in '{"outcome":"not run","reason":"no record","cost":"none","added":0}' \
    '{"outcome":"not needed","reason":"release branch","cost":"none","kept":0}' \
    '{"outcome":"ran","cost":"unknown"}'; do
    jq -c --argjson review "$review" '. + {review: $review}' <<<'{"total":1,"members":{},"grants":0}' >"$values"
    run bash "$SCRIPTS/audit-loop-record.sh" --pr 7 --values-json "$values" --body-in "$body_in" --body-out "$BATS_TEST_TMPDIR/count-out.md"
    [ "$status" -eq 2 ] || { printf 'accepted: %s\n' "$review" >&2; return 1; }
  done
  review='{"outcome":"ran","cost":"unknown","added":0,"kept":0,"dropped":0,"unaccounted":0,"merged":0,"fixed":0,"denials":0,"denial_tools":[],"kept_by_disposition":{"accepted":0,"diverted":0,"filed":0,"fixed":0,"open":0,"waived":0}}'
  jq -c --argjson review "$review" '. + {review: $review}' <<<'{"total":1,"members":{},"grants":0}' >"$values"
  run bash "$SCRIPTS/audit-loop-record.sh" --pr 7 --values-json "$values" --body-in "$body_in" --body-out "$BATS_TEST_TMPDIR/count-out.md"
  [ "$status" -eq 0 ]
  grep -qF 'code review: ran; added 0, kept 0' "$BATS_TEST_TMPDIR/count-out.md"
}

@test "failure: with every member marker earned the merge gate allows with the record present or absent" {
  stand_in_behaves 'exit 3'
  failing_review
  prepare_gate
  mgf_marker code-audit-frontend >/dev/null
  mgf_marker code-audit-shell >/dev/null
  capture_gates
  local with_record="$GATE_RESULT"
  mv "$RECORD" "$RECORD.aside"
  capture_gates
  [ "$with_record" = "$GATE_RESULT" ]
  [ "$(jq -r .outcome "$RECORD.aside")" = 'not run' ]
  grep -qF 'merge 0: ' <<<"$with_record"
  grep -qF 'permissionDecision' <<<"$with_record" && return 1
  true
}

# scratch_hooks <name> <hook-file> <injected-line>: a copy of the hooks and the scripts they
# load, real files, with <injected-line> placed as line 2 of <hook-file>; prints the copy's path.
scratch_hooks() {
  local scratch="$BATS_TEST_TMPDIR/hooks-$1"
  mkdir -p "$scratch/.claude/hooks"
  cp "$REPO_ROOT"/.claude/hooks/pr-merge-audit-check*.sh "$REPO_ROOT/.claude/hooks/audit-loop-bound.sh" "$scratch/.claude/hooks/"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$scratch/.claude/hooks/lib"
  mkdir -p "$scratch/.gaia"
  cp -R "$REPO_ROOT/.gaia/scripts" "$scratch/.gaia/scripts"
  awk -v injected="$3" 'NR == 2 { print injected } { print }' "$scratch/.claude/hooks/$2" >"$scratch/.claude/hooks/$2.edited"
  mv "$scratch/.claude/hooks/$2.edited" "$scratch/.claude/hooks/$2"
  printf '%s\n' "$scratch/.claude/hooks/$2"
}

@test "failure: the comparison goes red on a merge gate that reads the record" {
  stand_in_behaves 'exit 3'
  failing_review
  GATE_HOOK="$(scratch_hooks merge pr-merge-audit-check.sh "[ -f '$RECORD' ] && exit 0")"
  gates_ignore_record 2>"$BATS_TEST_TMPDIR/comparison-errors" && return 1
  grep -qF 'with record:' "$BATS_TEST_TMPDIR/comparison-errors"
  grep -qF 'without:' "$BATS_TEST_TMPDIR/comparison-errors"
}

@test "failure: the comparison goes red on a bound hook that reads the record" {
  stand_in_behaves 'exit 3'
  failing_review
  BOUND_HOOK_UNDER_TEST="$(scratch_hooks bound audit-loop-bound.sh "[ -f '$RECORD' ] && { printf '{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}'; exit 0; }")"
  gates_ignore_record 2>/dev/null && return 1
  true
}
