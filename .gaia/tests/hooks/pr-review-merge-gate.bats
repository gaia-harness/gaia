#!/usr/bin/env bats
#
# Flow: the merge is denied while the PR review is incomplete and allowed once
# every finding is disposed and every fix finding is recorded fixed. The journey
# runs the shipped commands at their entry points (the record script, the gate's
# publish and the merge hook) over the merge-gate fixture; the deny line of each
# incomplete state belongs to pr-review-merge-deny.bats.
#
# The record script reads the audit loop's veto state through audit-loop-eval.sh;
# a scratch copy of the scripts folder links every script back to the real one
# and answers only `veto-state`, saying the owner has cleared the veto.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/pr-review-merge-gate.bats < /dev/null
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  . "$BATS_TEST_DIRNAME/helpers/merge-gate-fixture.sh"
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  mgf_init
  write_builtin_descriptor "$REPO"
  RUN_FOLDER="$REPO/.gaia/local/runs/feature"
}

# scratch_scripts: a scripts folder of links to the real scripts, except an
# audit-loop-eval.sh that reports the veto of the one finding as satisfied and
# hands every other subcommand to the real evaluator. Prints the folder.
scratch_scripts() {
  local scratch="$BATS_TEST_TMPDIR/scratch" entry
  mkdir -p "$scratch/.gaia/scripts" "$scratch/.claude/hooks"
  ln -s "$MGF_LIBRARY_DIRECTORY" "$scratch/.claude/hooks/lib"
  for entry in "$MGF_REPO_ROOT"/.gaia/scripts/*; do
    [ "${entry##*/}" = audit-loop-eval.sh ] || ln -s "$entry" "$scratch/.gaia/scripts/${entry##*/}"
  done
  cat > "$scratch/.gaia/scripts/audit-loop-eval.sh" <<STUB
#!/usr/bin/env bash
if [ "\${1-}" = veto-state ]; then
  printf '%s\n' '{"satisfied":[["pr-reviewer","pr-review/pr-1","apps/web/app/x.ts",1]]}'
  exit 0
fi
exec bash "$MGF_REPO_ROOT/.gaia/scripts/audit-loop-eval.sh" "\$@"
STUB
  printf '%s\n' "$scratch/.gaia/scripts"
}

# set_pull_request_body <file>: the pull request's body, as the gh stub answers it.
set_pull_request_body() {
  jq -c --rawfile body "$1" '.body = $body' "$MGF_STUB_DIRECTORY/record.json" > "$MGF_STUB_DIRECTORY/record.next"
  mv "$MGF_STUB_DIRECTORY/record.next" "$MGF_STUB_DIRECTORY/record.json"
}

@test "the merge is allowed once the one finding is disposed fix, fixed and published to the PR body" {
  local scripts record gate head bundle findings body_in body_out
  scripts="$(scratch_scripts)"
  record="$scripts/pr-review-record.sh"
  gate="$MGF_REPO_ROOT/.gaia/scripts/pr-review-gate.sh"
  body_in="$BATS_TEST_TMPDIR/body-in.md"
  body_out="$BATS_TEST_TMPDIR/body-out.md"

  # An in-scope pull request whose member is cleared; its body has no review section yet.
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  mgf_marker code-audit-frontend >/dev/null
  head="$(git -C "$REPO" rev-parse HEAD)"
  printf 'Summary.\n\n<!-- gaia-pr-body-head: %s -->\n' "$head" > "$body_in"
  set_pull_request_body "$body_in"

  bundle="$BATS_TEST_TMPDIR/bundle"
  mkdir -p "$bundle"
  printf 'apps/web/app/x.ts\n' > "$bundle/changed-files.txt"
  jq -n -c --arg head "$head" '{pr: 12, reviewed_head: $head, base: "main", spec: "none",
    spec_author_not_collaborator: false, changelog_present: true, template_present: false}' > "$bundle/meta.json"
  findings="$BATS_TEST_TMPDIR/findings.json"
  jq -n -c '[{file: "apps/web/app/x.ts", line: 1, severity: "Major", summary: "a problem", failure_scenario: "it breaks", verified: true}]' > "$findings"

  # No record yet: the merge is denied.
  mgf_run_merge "gh pr merge 12 --squash"
  assert_denied_by_json || { echo "expected a deny before the review: $output"; return 1; }

  # Open, one attempt, the reviewer's outcome.
  run bash "$record" open --root "$REPO" --run-folder "$RUN_FOLDER" --pr 12 --head "$head" --bundle "$bundle"
  [ "$status" -eq 0 ] && [ "$output" = opened ] || { echo "open: $status $output"; return 1; }
  run bash "$record" attempt-open --run-folder "$RUN_FOLDER"
  [ "$status" -eq 0 ] || { echo "attempt-open: $output"; return 1; }
  run bash "$record" outcome --run-folder "$RUN_FOLDER" --findings "$findings"
  [ "$status" -eq 0 ] || { echo "outcome: $output"; return 1; }

  # Dispose it fix and route it to the path's owner.
  run bash "$record" dispose --run-folder "$RUN_FOLDER" --id pr-1 --disposition fix
  [ "$status" -eq 0 ] || { echo "dispose: $output"; return 1; }
  run bash "$record" route-fix --root "$REPO" --run-folder "$RUN_FOLDER" --id pr-1
  [ "$status" -eq 0 ] && [ "$output" = "veto code-audit-frontend" ] || { echo "route-fix: $status $output"; return 1; }

  # Publish the section while the fix is unrecorded: the gate still denies.
  bash "$gate" publish --root "$REPO" --pr 12 --branch feature --body-in "$body_in" --body-out "$body_out" || return 1
  set_pull_request_body "$body_out"
  mgf_run_merge "gh pr merge 12 --squash"
  grep -qF -- 'not yet fixed' <<<"$output" || { echo "expected a deny for the unfixed finding: $output"; return 1; }

  # Record the fix once the veto is satisfied, publish again, and the merge is allowed.
  run bash "$record" fixed --root "$REPO" --run-folder "$RUN_FOLDER" --id pr-1
  [ "$status" -eq 0 ] || { echo "fixed: $output"; return 1; }
  bash "$gate" publish --root "$REPO" --pr 12 --branch feature --body-in "$body_in" --body-out "$body_out" || return 1
  set_pull_request_body "$body_out"
  mgf_run_merge "gh pr merge 12 --squash"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "merge not allowed: $output $stderr"; return 1; }
}
