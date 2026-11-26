#!/usr/bin/env bats
#
# Suite for .gaia/scripts/pr-review-record.sh, the sole writer of a pull
# request's review record. Each case drives the script through its arguments,
# exit status and output over a record in a fixture run folder, never by
# sourcing its internals. The fix-routing cases read the real audit loop (its
# veto writer, evaluator and roster) over the fixture repository the audit loop
# suites share; the accept case drives the real grant hook.
#
# Maintainer-only. `.gaia/tests` is release-excluded, so this never reaches an
# adopter.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/pr-review-record.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  RECORD="$SCRIPTS/pr-review-record.sh"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS
  export CLAUDE_CODE_ENTRYPOINT=cli
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/pr-review-verdict.sh"
  alf_init
  alf_branch feat/review
  printf 'auditors:\n  - name: code-audit-frontend\n    globs:\n      - "src/**"\n    audience: adopter\n' >"$ALF_ROOT/.gaia/audit-ci.yml"
  alf_fill src/a.sh 6 feature
  alf_commit "feature"
  HEAD_SHA="$ALF_COMMIT"
  BUNDLE="$BATS_TEST_TMPDIR/bundle"
  mkdir -p "$BUNDLE"
  printf 'src/a.sh\nREADME.md\nwiki/Foo.md\n' >"$BUNDLE/changed-files.txt"
  write_meta true
  FINDINGS="$BATS_TEST_TMPDIR/findings.json"
}

# write_meta <changelog-present>: the bundle's meta.json.
write_meta() {
  jq -n -c --arg head "$HEAD_SHA" --argjson changelog "$1" '{pr: 7, reviewed_head: $head, base: "main", spec: "present",
    spec_author_not_collaborator: false, changelog_present: $changelog, template_present: false}' >"$BUNDLE/meta.json"
}

# review_folder <name>: the run folder of a branch called <name>.
review_folder() {
  RUN_FOLDER="$ALF_ROOT/.gaia/local/runs/$1"
}

# open_review: open the record for PR 7 on RUN_FOLDER.
open_review() {
  run bash "$RECORD" open --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --pr 7 --head "$HEAD_SHA" --bundle "$BUNDLE"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = opened ] || return 1
}

# entry <file> <line> <severity> [security-json]: one reviewer entry; an empty
# fourth argument leaves the `security` key out.
entry() {
  jq -n -c --arg file "$1" --argjson line "$2" --arg severity "$3" --arg security "${4-false}" \
    '{file: $file, line: $line, severity: $severity, summary: "summary of \($file)", failure_scenario: "the failing input", verified: true}
      + (if $security == "" then {} else {security: ($security | fromjson)} end)'
}

# write_findings <entry>...: the reviewer's output file, one array.
write_findings() {
  printf '%s\n' "$@" | jq -s -c '.' >"$FINDINGS"
}

# record <subcommand> [args...]: the record script on RUN_FOLDER.
record() {
  run bash "$RECORD" "$@" --run-folder "$RUN_FOLDER"
}

# recorded_findings <jq-expression>: the expression over the record, as text.
recorded() {
  jq -r "$1" "$RUN_FOLDER/pr-review.json"
}

# ran_review <entry>...: open a review, one attempt, and an accepted outcome.
ran_review() {
  open_review || return 1
  record attempt-open
  [ "$status" -eq 0 ] || return 1
  write_findings "$@"
  record outcome --findings "$FINDINGS"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "outcome ingests a valid array, refuses each malformed entry as a no-op, and the section reads No findings or Not run after two silent attempts" {
  local case_number=0 line valid
  valid="$(entry src/a.sh 3 Major)"
  # Each malformed entry: the exact refusal, exit 3, the attempt closed as a no-op.
  while IFS='|' read -r mutation expected; do
    case_number=$((case_number + 1))
    review_folder "malformed-$case_number"
    open_review || return 1
    record attempt-open
    [ "$status" -eq 0 ] || return 1
    write_findings "$(jq -c "$mutation" <<<"$valid")"
    record outcome --findings "$FINDINGS"
    [ "$status" -eq 3 ] || { printf '%s: status %s\n' "$mutation" "$status" >&2; return 1; }
    [ "$output" = "$expected" ] || { printf '%s: got %s\n' "$mutation" "$output" >&2; return 1; }
    [ "$(recorded '.attempts[0] | "\(.state) \(.classifier_exit) \(.refusal)"')" = "closed 1 $expected" ] || return 1
    [ "$(recorded '.outcome')" = null ] || return 1
    [ "$(recorded '.findings | length')" -eq 0 ] || return 1
  done <<'EOF'
.severity = "High"|severity must be Critical, Major or Minor
del(.summary)|missing key: summary
. + {notes: "x"}|unknown key: notes
.line = "12"|line must be a positive integer or null
.verified = "yes"|verified must be boolean
.summary = null|summary must be a string
.failure_scenario = 3|failure_scenario must be a string
.file = "../x.sh"|file not in this PR: ../x.sh
.file = "PR Body"|file not in this PR: PR Body
EOF
  # A file that is not an array is refused the same way.
  review_folder not-an-array
  open_review || return 1
  record attempt-open
  printf '%s\n' '{"file": "src/a.sh"}' >"$FINDINGS"
  record outcome --findings "$FINDINGS"
  [ "$status" -eq 3 ] || return 1
  [ "$(recorded '.attempts[0].classifier_exit')" = 1 ] || return 1
  # Valid entries: numbered in file order, a missing security key stored true.
  review_folder valid
  ran_review "$(entry src/a.sh 3 Major false)" "$(entry "PR body" null Minor "")" || return 1
  [ "$(recorded '.outcome')" = ran ] || return 1
  [ "$(recorded '[.findings[] | "\(.id) \(.file) \(.security) \(.disposition)"] | join(",")')" = "pr-1 src/a.sh false null,pr-2 PR body true null" ] || return 1
  [ "$(recorded '.attempts[0] | "\(.state) \(.classifier_exit)"')" = "closed 0" ] || return 1
  [ "$(recorded '.findings_sha256')" = "$(pr_review_findings_digest "$(cat "$RUN_FOLDER/pr-review.json")")" ] || return 1
  # No findings: an empty array is a real outcome and the section says so.
  review_folder none
  ran_review || return 1
  [ "$(recorded '.findings | length')" -eq 0 ] || return 1
  run bash "$SCRIPTS/pr-review-gate.sh" section --run-folder "$RUN_FOLDER"
  [ "$status" -eq 0 ] || return 1
  line="$(grep -cxF 'No findings.' <<<"$output" || true)"
  [ "$line" -eq 1 ] || { printf '%s\n' "$output" >&2; return 1; }
  # Two silent attempts: not run, and the section says so.
  review_folder silent
  open_review || return 1
  for case_number in 1 2; do
    record attempt-open
    [ "$status" -eq 0 ] || return 1
    record attempt-close --n "$case_number" --classifier-exit 1
    [ "$status" -eq 0 ] || return 1
  done
  record not-run --reason "reviewer silent twice"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(recorded '.outcome + " " + .not_run_reason')" = "not-run reviewer silent twice" ] || return 1
  run bash "$SCRIPTS/pr-review-gate.sh" section --run-folder "$RUN_FOLDER"
  [ "$status" -eq 0 ] || return 1
  grep -qxF 'Not run: reviewer silent twice.' <<<"$output" || { printf '%s\n' "$output" >&2; return 1; }
}

@test "a Critical or security-class finding takes only fix and its class never changes" {
  review_folder class
  ran_review "$(entry src/a.sh 3 Critical false)" "$(entry src/a.sh 4 Major false)" "$(entry src/a.sh 5 Major "")" || return 1
  cp "$RUN_FOLDER/pr-review.json" "$BATS_TEST_TMPDIR/before.json"
  record dispose --id pr-1 --disposition dismiss --reason "not a bug"
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "a Critical or security-class finding takes fix" ] || return 1
  record dispose --id pr-3 --disposition dismiss --reason "not a bug"
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "a Critical or security-class finding takes fix" ] || return 1
  record dispose --id pr-1 --disposition fix --severity Major
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "finding class is fixed at the reviewer's output" ] || return 1
  record dispose --id pr-3 --disposition fix --security false
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "finding class is fixed at the reviewer's output" ] || return 1
  cmp -s "$BATS_TEST_TMPDIR/before.json" "$RUN_FOLDER/pr-review.json" || return 1
  # A Major with security false is an ordinary finding; fix needs no reason.
  record dispose --id pr-2 --disposition dismiss --reason "the fixture date is the test's input"
  [ "$status" -eq 0 ] || return 1
  record dispose --id pr-1 --disposition fix
  [ "$status" -eq 0 ] || return 1
  [ "$(recorded '[.findings[] | .disposition // "none"] | join(",")')" = "fix,dismiss,none" ] || return 1
}

@test "route-fix routes each fix finding, fixed waits on a satisfied veto, and dropped records the member's evidence and makes the finding undecided again" {
  local round
  review_folder feat/review
  # Three recorded audit rounds, so the veto binds from round 4.
  for round in 1 2 3; do
    alf_set_line README.md "$round" "round $round"
    alf_commit "round $round"
    alf_round "$round" code-audit-frontend "$(alf_entries src/b.sh 1 1)" || return 1
  done
  alf_set_line .claude/rules/maintainers/harness-triage-threshold.md 1 marker
  alf_commit marker
  open_review || return 1
  record attempt-open
  write_findings "$(entry src/a.sh 3 Major false)" "$(entry "PR body" null Minor false)" "$(entry wiki/Foo.md 8 Critical false)" \
    "$(entry CHANGELOG.md null Major false)" "$(entry src/a.sh 5 Minor false)"
  record outcome --findings "$FINDINGS"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  for round in 1 2 3 4 5; do
    record dispose --id "pr-$round" --disposition fix
    [ "$status" -eq 0 ] || return 1
  done
  # An owned path writes one veto key, once; the owner reviews it.
  record route-fix --root "$ALF_ROOT" --id pr-1
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "veto code-audit-frontend" ] || return 1
  record route-fix --root "$ALF_ROOT" --id pr-1
  [ "$(jq -c '.keys | map([.member, .finding_class, .path, .line, .effective_from_round, .direction])' "$RUN_FOLDER/vetoes.json")" = \
    '[["pr-reviewer","pr-review/pr-1","src/a.sh",3,4,"summary of src/a.sh"]]' ] || return 1
  # A body finding and a CHANGELOG finding in the maintainer repo have their own routes.
  record route-fix --root "$ALF_ROOT" --id pr-2
  [ "$output" = body ] || return 1
  record route-fix --root "$ALF_ROOT" --id pr-4
  [ "$output" = changelog ] || return 1
  # No owner: a human, exit 4, the finding routed to a human.
  record route-fix --root "$ALF_ROOT" --id pr-3
  [ "$status" -eq 4 ] || return 1
  [ "$output" = "PR review: fix needs a human on an unowned path: wiki/Foo.md" ] || return 1
  [ "$(recorded '[.findings[] | .fix_route // "none"] | join(",")')" = "veto,body,human,changelog,none" ] || return 1
  [ "$(recorded '[.findings[] | .fix_state // "none"] | join(",")')" = "routed,routed,routed,routed,none" ] || return 1
  # A body fix needs no proof; a changelog or human fix needs its commit.
  record fixed --root "$ALF_ROOT" --id pr-2
  [ "$status" -eq 0 ] || return 1
  record fixed --root "$ALF_ROOT" --id pr-4
  [ "$status" -eq 1 ] || return 1
  record fixed --root "$ALF_ROOT" --id pr-4 --commit "$HEAD_SHA"
  [ "$status" -eq 0 ] || return 1
  [ "$(recorded '.review_fix_commits | join(",")')" = "$HEAD_SHA" ] || return 1
  # A veto fix waits for the evaluator's satisfied state.
  record fixed --root "$ALF_ROOT" --id pr-1
  [ "$status" -eq 1 ] || return 1
  [ "$(recorded '.findings[0].fix_state')" = routed ] || return 1
  alf_store_snapshot 3 || return 1
  alf_add_round '[]'
  alf_state_edit '.history.rounds[3].reopened = true'
  alf_stamp 4 40
  alf_dispositions 4 '[{"member":"pr-reviewer","finding_class":"pr-review/pr-1","path":"src/a.sh","line":3,"disposition":"fix","reason":"vetoed"}]'
  jq -n -c '{schema: 1, round: 4, attempt: 1, results: [{member: "pr-reviewer", finding_class: "pr-review/pr-1", path: "src/a.sh", line: 3,
    disposition: "fixed", reason: "done", changed_paths: ["src/a.sh"]}], changed_paths: ["src/a.sh"], reverted_paths: []}' \
    >"$RUN_FOLDER/fixer-4-audit.json"
  alf_set_line src/a.sh 3 "repaired"
  alf_commit "repair the line"
  alf_store_snapshot 4 || return 1
  alf_add_round '["code-audit-frontend"]'
  alf_stamp 5 50
  alf_sidecar code-audit-frontend "$(alf_entries src/b.sh 1 1)" 51
  record fixed --root "$ALF_ROOT" --id pr-1 --commit "$ALF_COMMIT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(recorded '.findings[0].fix_state')" = fixed ] || return 1
  # The veto fix commit is a review fix commit, so the out-of-scope commit check does not see it as a stray.
  [ "$(recorded '.review_fix_commits | index("'"$ALF_COMMIT"'") != null')" = true ] || return 1
  # A routed fix the owner disputes is dropped: undecided again, evidence recorded.
  record route-fix --root "$ALF_ROOT" --id pr-5
  [ "$status" -eq 0 ] || return 1
  jq -e 'any(.keys[]; .finding_class == "pr-review/pr-5")' "$RUN_FOLDER/vetoes.json" >/dev/null || return 1
  record dropped --id pr-5 --by code-audit-frontend --evidence "the line is guarded two calls up"
  [ "$status" -eq 0 ] || return 1
  # The dropped finding's veto is withdrawn so it cannot strand the audit loop; pr-1's stays.
  [ "$(jq -c '.keys | map(.finding_class)' "$RUN_FOLDER/vetoes.json")" = '["pr-review/pr-1"]' ] || return 1
  [ "$(recorded '.findings[4] | "\(.dropped_by)|\(.fix_state)|\(.disposition)"')" = "code-audit-frontend: the line is guarded two calls up|dropped|null" ] || return 1
  record dispose --id pr-5 --disposition dismiss --reason "the line is guarded two calls up"
  [ "$status" -eq 0 ] || return 1
}

# bats test_tags=protected
@test "route-fix refuses an unowned, empty or unnormalized repair path, and any repair path off a veto route, writing no veto; on a routed finding a repair path rewrites its key, an owned enforcement path included" {
  local enforcement_path repair_path expected
  review_folder feat/review
  alf_round 1 code-audit-frontend '[]' || return 1
  ran_review "$(entry src/a.sh 3 Major false)" "$(entry "PR body" null Minor false)" || return 1
  record dispose --id pr-1 --disposition fix
  [ "$status" -eq 0 ] || return 1
  record dispose --id pr-2 --disposition fix
  [ "$status" -eq 0 ] || return 1
  enforcement_path="$(bash -c '. "$1" && printf "%s" "${ENFORCEMENT_PATHS[0]}"' _ "$SCRIPTS/audit-fix-verify-state-lib.sh")"
  [ -n "$enforcement_path" ] || return 1
  while IFS='|' read -r repair_path expected; do
    record route-fix --root "$ALF_ROOT" --id pr-1 --repair-path src/b.sh --repair-path "$repair_path"
    [ "$status" -eq 1 ] || { printf 'repair path "%s" routed: %s %s\n' "$repair_path" "$status" "$output" >&2; return 1; }
    grep -qF -- "$expected" <<<"$output" || { printf 'repair path "%s" refused for another cause: %s\n' "$repair_path" "$output" >&2; return 1; }
  done <<EOF
wiki/Foo.md|repair path to no member
|must be an array of non-empty paths
./src/b.sh|is not a repo-relative path
/src/b.sh|is not a repo-relative path
src/../b.sh|is not a repo-relative path
src//b.sh|is not a repo-relative path
src/./b.sh|is not a repo-relative path
src/|is not a repo-relative path
EOF
  record route-fix --root "$ALF_ROOT" --id pr-2 --repair-path src/b.sh
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "--repair-path needs a veto route; pr-2 routes to body" ] || return 1
  [ ! -e "$RUN_FOLDER/vetoes.json" ] || { cat "$RUN_FOLDER/vetoes.json" >&2; return 1; }
  [ "$(recorded '[.findings[] | .fix_state // "none"] | join(",")')" = "none,none" ] || return 1
  record route-fix --root "$ALF_ROOT" --id pr-1
  [ "$status" -eq 0 ] || return 1
  [ "$(jq -c '.keys | map(has("repair_paths"))' "$RUN_FOLDER/vetoes.json")" = '[false]' ] || return 1
  record route-fix --root "$ALF_ROOT" --id pr-1 --repair-path src/b.sh
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(jq -c '.keys | map([.path, .line, .repair_paths])' "$RUN_FOLDER/vetoes.json")" = '[["src/a.sh",3,["src/b.sh"]]]' ] || return 1
  # An identical re-run is a no-op: the key's start round stays put, so a repair already landed still counts.
  jq -c '.keys[0].effective_from_round = -1' "$RUN_FOLDER/vetoes.json" >"$BATS_TEST_TMPDIR/vetoes.json"
  cp "$BATS_TEST_TMPDIR/vetoes.json" "$RUN_FOLDER/vetoes.json"
  record route-fix --root "$ALF_ROOT" --id pr-1 --repair-path src/b.sh
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(jq -c '.keys | map(.effective_from_round)' "$RUN_FOLDER/vetoes.json")" = '[-1]' ] || return 1
  # An enforcement path is a repair path like any other once a member owns it: the unit drafts it and stops for a human.
  printf '  - name: code-audit-shell\n    globs:\n      - "%s"\n    audience: adopter\n' "$enforcement_path" >>"$ALF_ROOT/.gaia/audit-ci.yml"
  record route-fix --root "$ALF_ROOT" --id pr-1 --repair-path src/b.sh --repair-path "$enforcement_path"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(jq -c --arg enforcement_path "$enforcement_path" '.keys | map(.repair_paths == ([$enforcement_path, "src/b.sh"] | sort))' "$RUN_FOLDER/vetoes.json")" = '[true]' ]
}

@test "dropped refuses a finding with no routed fix and evidence-less input, and a dropped Critical or security-class finding closes only with dismiss" {
  review_folder feat/review
  ran_review "$(entry src/a.sh 3 Critical false)" "$(entry PR\ body null Major true)" "$(entry src/a.sh 5 Major false)" || return 1
  record dispose --id pr-2 --disposition fix
  [ "$status" -eq 0 ] || return 1
  # Never routed: refused, record unchanged.
  cp "$RUN_FOLDER/pr-review.json" "$BATS_TEST_TMPDIR/before.json"
  record dropped --id pr-3 --by code-audit-frontend --evidence "guarded upstream"
  [ "$status" -eq 1 ] || return 1
  cmp -s "$BATS_TEST_TMPDIR/before.json" "$RUN_FOLDER/pr-review.json" || return 1
  # A routed finding needs the member and the evidence.
  record route-fix --root "$ALF_ROOT" --id pr-2
  [ "$status" -eq 0 ] || return 1
  record dropped --id pr-2 --by code-audit-frontend --evidence "   "
  [ "$status" -ne 0 ] || return 1
  # Before the drop a security finding refuses dismiss; after it dismiss is accepted, other non-fix stays refused.
  record dispose --id pr-2 --disposition dismiss --reason "not a bug"
  [ "$status" -eq 1 ] || return 1
  record dropped --id pr-2 --by code-audit-frontend --evidence "guarded upstream"
  [ "$status" -eq 0 ] || return 1
  [ "$(recorded '.findings[1] | "\(.fix_state)|\(.disposition)"')" = "dropped|null" ] || return 1
  record dispose --id pr-2 --disposition waive-out-of-scope --basis triage-threshold --reason "guarded upstream"
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "a Critical or security-class finding takes fix" ] || return 1
  record dispose --id pr-2 --disposition dismiss --reason "guarded upstream"
  [ "$status" -eq 0 ] || return 1
  [ "$(recorded '.findings[1].disposition')" = dismiss ] || return 1
}

@test "open on a record that already has an outcome prints exists and writes nothing" {
  review_folder exists
  ran_review "$(entry src/a.sh 3 Major false)" || return 1
  cp -R "$RUN_FOLDER" "$BATS_TEST_TMPDIR/run-before"
  HEAD_SHA="$(printf 'b%.0s' $(seq 1 40))"
  write_meta false
  run bash "$RECORD" open --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --pr 7 --head "$HEAD_SHA" --bundle "$BUNDLE"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = exists ] || return 1
  diff -r "$BATS_TEST_TMPDIR/run-before" "$RUN_FOLDER" || return 1
}

@test "open on an outcome-less record at a newer head refreshes the reviewed head and the changed-file list and keeps the attempts" {
  review_folder reopen
  open_review || return 1
  record attempt-open
  [ "$status" -eq 0 ] || return 1
  HEAD_SHA="$(printf 'c%.0s' $(seq 1 40))"
  printf 'src/a.sh\nsrc/new.sh\n' >"$BUNDLE/changed-files.txt"
  write_meta true
  run bash "$RECORD" open --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --pr 7 --head "$HEAD_SHA" --bundle "$BUNDLE"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = opened ] || return 1
  [ "$(recorded '.reviewed_head')" = "$HEAD_SHA" ] || return 1
  [ "$(recorded '.attempts | length')" -eq 1 ] || return 1
  grep -qx 'src/new.sh' "$RUN_FOLDER/pr-review-changed-files.txt" || return 1
  # The bundle's spec fields follow too: a body edit moved the closed issue.
  [ "$(recorded '.spec')" = present ] || return 1
  jq -n -c '{spec: "none", spec_author_not_collaborator: true, changelog_present: false, template_present: false}' >"$BUNDLE/meta.json"
  HEAD_SHA="$(printf 'd%.0s' $(seq 1 40))"
  run bash "$RECORD" open --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --pr 7 --head "$HEAD_SHA" --bundle "$BUNDLE"
  [ "$status" -eq 0 ] || return 1
  [ "$(recorded '.spec')" = none ] || return 1
  [ "$(recorded '.spec_author_not_collaborator')" = true ] || return 1
  [ "$(recorded '.changelog_present')" = false ] || return 1
}

@test "a non-fix disposition is accepted only under its rule, accept-residual only after an interactive pr-review-accept line the grant hook records, never after a non-interactive one" {
  local transcript_cli="$BATS_TEST_TMPDIR/tx-cli.jsonl" transcript_sdk="$BATS_TEST_TMPDIR/tx-sdk.jsonl" accept_file prompt_payload
  printf '%s\n' '{"type":"mode","sessionId":"s1"}' '{"type":"user","entrypoint":"cli","sessionId":"s1"}' >"$transcript_cli"
  printf '%s\n' '{"type":"mode","sessionId":"s1"}' '{"type":"user","entrypoint":"sdk-cli","sessionId":"s1"}' >"$transcript_sdk"
  accept_file="$ALF_ROOT/.gaia/local/protected/pr-review-accepts/feat/review.json"
  review_folder feat/review
  ran_review "$(entry src/a.sh 3 Minor false)" "$(entry src/a.sh 4 Minor false)" "$(entry src/a.sh 5 Minor false)" || return 1
  # The audit's rules for the other dispositions.
  record dispose --id pr-2 --disposition divert --reason "private"
  [ "$output" = "divert-not-allowed: pr-2" ] || return 1
  for disposition in dismiss file waive-out-of-scope; do
    record dispose --id pr-2 --disposition "$disposition" --reason "  " --issue 12 --basis triage-threshold
    [ "$status" -eq 1 ] || return 1
    [ "$output" = "empty-reason: pr-2" ] || { printf '%s: %s\n' "$disposition" "$output" >&2; return 1; }
  done
  record dispose --id pr-2 --disposition file --reason "tracked"
  [ "$output" = "file needs an issue number: pr-2" ] || return 1
  record dispose --id pr-2 --disposition waive-out-of-scope --reason "outside the threshold"
  [ "$status" -eq 1 ] || return 1
  case "$output" in "missing-basis: pr-2"*) ;; *) printf '%s\n' "$output" >&2; return 1 ;; esac
  [ "$(recorded '[.findings[] | .disposition // "none"] | join(",")')" = "none,none,none" ] || return 1
  record dispose --id pr-2 --disposition file --reason "tracked" --issue 3801
  [ "$status" -eq 0 ] || return 1
  record dispose --id pr-3 --disposition waive-out-of-scope --reason "outside the threshold" --basis triage-threshold
  [ "$status" -eq 0 ] || return 1
  # accept-residual: refused before any accept, and after a non-interactive line.
  record dispose --id pr-1 --disposition accept-residual --reason "the human agreed"
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "accept-residual needs a human accept: pr-1" ] || return 1
  prompt_payload="$("$REPO_ROOT/.gaia/tests/hooks/helpers/mock-hook-input.sh" user-prompt-submit s1 "pr-review-accept pr-1" |
    jq -c --arg cwd "$ALF_ROOT" --arg transcript_path "$transcript_sdk" '.cwd = $cwd | .transcript_path = $transcript_path')"
  run bash -c 'printf %s "$1" | bash "$2"' _ "$prompt_payload" "$REPO_ROOT/.claude/hooks/audit-loop-grant.sh"
  [ -e "$accept_file" ] && return 1
  record dispose --id pr-1 --disposition accept-residual --reason "the human agreed"
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "accept-residual needs a human accept: pr-1" ] || return 1
  # The same line from an interactive session records the accept.
  prompt_payload="$(jq -c --arg transcript_path "$transcript_cli" '.transcript_path = $transcript_path' <<<"$prompt_payload")"
  run bash -c 'printf %s "$1" | bash "$2"' _ "$prompt_payload" "$REPO_ROOT/.claude/hooks/audit-loop-grant.sh"
  [ "$(jq -r '.accepted | map("\(.pr) \(.id)") | join(",")' "$accept_file")" = "7 pr-1" ] || { printf '%s\n' "$output" >&2; return 1; }
  record dispose --id pr-1 --disposition accept-residual --reason "the human agreed"
  [ "$status" -eq 0 ] || return 1
  [ "$(recorded '.findings[0] | "\(.disposition)|\(.reason)"')" = "accept-residual|the human agreed" ] || return 1
  # The accept names pr-1 only.
  record dispose --id pr-3 --disposition accept-residual --reason "me too"
  [ "$output" = "accept-residual needs a human accept: pr-3" ] || return 1
}

@test "a pr-review-accept line for a Critical or security-class finding records nothing and says it takes fix" {
  local transcript_cli="$BATS_TEST_TMPDIR/tx-cli.jsonl" accept_file prompt_payload finding_number
  printf '%s\n' '{"type":"mode","sessionId":"s1"}' '{"type":"user","entrypoint":"cli","sessionId":"s1"}' >"$transcript_cli"
  accept_file="$ALF_ROOT/.gaia/local/protected/pr-review-accepts/feat/review.json"
  review_folder feat/review
  ran_review "$(entry src/a.sh 3 Critical false)" "$(entry src/a.sh 4 Minor true)" "$(entry src/a.sh 5 Minor false)" || return 1
  for finding_number in 1 2; do
    prompt_payload="$("$REPO_ROOT/.gaia/tests/hooks/helpers/mock-hook-input.sh" user-prompt-submit s1 "pr-review-accept pr-$finding_number" |
      jq -c --arg cwd "$ALF_ROOT" --arg transcript_path "$transcript_cli" '.cwd = $cwd | .transcript_path = $transcript_path')"
    run bash -c 'printf %s "$1" | bash "$2"' _ "$prompt_payload" "$REPO_ROOT/.claude/hooks/audit-loop-grant.sh"
    case "$output" in *"takes fix"*) ;; *) printf '%s\n' "$output" >&2; return 1 ;; esac
    [ -e "$accept_file" ] && return 1
  done
  prompt_payload="$(jq -c '.prompt = "pr-review-accept pr-3"' <<<"$prompt_payload")"
  run bash -c 'printf %s "$1" | bash "$2"' _ "$prompt_payload" "$REPO_ROOT/.claude/hooks/audit-loop-grant.sh"
  [ "$(jq -r '.accepted | map(.id) | join(",")' "$accept_file")" = "pr-3" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "a dispatch that fails on an unloaded agent is not a no-op and records reviewer agent not loaded" {
  review_folder unloaded
  open_review || return 1
  record attempt-open
  [ "$output" = 1 ] || return 1
  record attempt-close --n 1 --dispatch-failed
  [ "$status" -eq 0 ] || return 1
  [ "$(recorded '.attempts[0] | "\(.state) \(.dispatch_failed) \(.classifier_exit)"')" = "closed true null" ] || return 1
  # The failed dispatch counts toward no silent-twice stop.
  record not-run --reason "reviewer silent twice"
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "not run needs two closed no-op attempts" ] || return 1
  record not-run --reason "reviewer agent not loaded"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(recorded '.outcome + " " + .not_run_reason')" = "not-run reviewer agent not loaded" ] || return 1
}
