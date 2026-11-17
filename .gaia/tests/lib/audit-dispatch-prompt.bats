#!/usr/bin/env bats
# Flow test: SPEC audit and plan audit lenses and refuters launch from rendered
# briefs, and a finished lens starts its refuters early. Drives lens-brief.mjs
# and refuter-schedule.mjs at their entry points through the happy path only;
# equality with the source docs, token refusals, cap thresholds and order
# parity belong to the lens-brief and refuter-schedule suites.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is release-excluded.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  BRIEF="$REPO_ROOT/.gaia/scripts/spec/lens-brief.mjs"
  SCHEDULE="$REPO_ROOT/.gaia/scripts/spec/refuter-schedule.mjs"
  [ -f "$BRIEF" ] && [ -f "$SCHEDULE" ] || return 1
}

# brief_path_of <short prompt>: the brief path the prompt tells the agent to read.
brief_path_of() {
  sed -n 's/.*first action is a Read of \([^;]*\);.*/\1/p' <<<"$1"
}

# render_lens <kind> <id> <audit-dir>: renders one lens brief, leaves $output.
render_lens() {
  if [ "$1" = "spec" ]; then
    run node "$BRIEF" lens --kind spec --lens "$2" --artifact "$BATS_TEST_TMPDIR/draft.md" \
      --audit-dir "$3" --repo-root "$REPO_ROOT" --spec-id demo-spec
  else
    run node "$BRIEF" lens --kind plan --lens "$2" --artifact "$BATS_TEST_TMPDIR/plan" \
      --audit-dir "$3" --repo-root "$REPO_ROOT" --spec-path "$BATS_TEST_TMPDIR/plan/README.md"
  fi
  [ "$status" -eq 0 ]
  local brief_path
  brief_path="$(brief_path_of "$output")"
  [ -n "$brief_path" ] && [ -f "$brief_path" ]
}

# brief_for <audit-dir> <kind> <lens>
brief_for() {
  printf '%s/briefs/%s-%s.md' "$1" "$2" "$3"
}

# write_findings <findings file> <lens> <brief file> <id:severity,...>
write_findings() {
  local token entries="" pair
  token="$(grep -o '"brief_token": "[0-9a-f]\{32\}"' "$3" | head -n 1 | grep -o '[0-9a-f]\{32\}')"
  [ -n "$token" ] || return 1
  for pair in ${4//,/ }; do
    entries+="{\"id\":\"${pair%%:*}\",\"severity\":\"${pair##*:}\",\"title\":\"Neutral title\"},"
  done
  mkdir -p "$(dirname "$1")"
  printf '{"dimension":"%s","brief_token":"%s","findings":[%s]}\n' "$2" "$token" "${entries%,}" >"$1"
}

# classify_real <audit-dir> <kind> <findings file> <lens>
classify_real() {
  run node "$BRIEF" classify --findings "$3" --brief "$(brief_for "$1" "$2" "$4")"
  [ "$status" -eq 0 ]
}

# finish <kind> <lens> <lenses> <findings-dir> <state-dir>: one scheduler call.
finish() {
  mkdir -p "$5"
  touch "$5/coverage.jsonl"
  run node "$SCHEDULE" finished --state "$5/state.json" --kind "$1" --tier standard \
    --lenses "$3" --findings-dir "$4" --verdicts-dir "$5/verdicts" \
    --coverage "$5/coverage.jsonl" --lens "$2"
  [ "$status" -eq 0 ]
}

# render_refuter <kind> <audit-dir> <findings-dir> <dispatch line>
render_refuter() {
  local dispatch_lens shape ids verdicts artifact="$BATS_TEST_TMPDIR/draft.md"
  IFS=$'\t' read -r _ dispatch_lens shape ids _ verdicts <<<"$4"
  [ "$1" = "plan" ] && artifact="$BATS_TEST_TMPDIR/plan"
  run node "$BRIEF" refuter --kind "$1" --lens "$dispatch_lens" --findings "$3/$dispatch_lens.json" \
    --brief "$(brief_for "$2" "$1" "$dispatch_lens")" --audit-dir "$2" --artifact "$artifact" \
    --repo-root "$REPO_ROOT" --shape "$shape" --ids "$ids" --verdicts "$verdicts"
  [ "$status" -eq 0 ]
  local brief_path
  brief_path="$(brief_path_of "$output")"
  [ -n "$brief_path" ] && [ -f "$brief_path" ]
}

@test "lenses and refuters launch from rendered briefs and a finished lens starts its refuters early" {
  local spec_audit="$BATS_TEST_TMPDIR/spec-audit" plan_audit="$BATS_TEST_TMPDIR/plan-audit"
  local spec_findings="$spec_audit/findings" lens

  # SPEC audit: render, write and classify every lens of a Standard audit.
  for lens in FG TST COV RT; do
    render_lens spec "$lens" "$spec_audit"
  done
  write_findings "$spec_findings/FG.json" FG "$(brief_for "$spec_audit" spec FG)" "FG-001:critical,FG-002:major"
  write_findings "$spec_findings/TST.json" TST "$(brief_for "$spec_audit" spec TST)" "TST-001:major"
  write_findings "$spec_findings/COV.json" COV "$(brief_for "$spec_audit" spec COV)" ""
  write_findings "$spec_findings/RT.json" RT "$(brief_for "$spec_audit" spec RT)" "RT-001:minor"
  for lens in FG TST COV RT; do
    classify_real "$spec_audit" spec "$spec_findings/$lens.json" "$lens"
  done

  # Plan audit: same journey; its findings files live in the audit dir itself.
  for lens in DP CG COV TD; do
    render_lens plan "$lens" "$plan_audit"
  done
  write_findings "$plan_audit/DP.json" DP "$(brief_for "$plan_audit" plan DP)" "DP-001:minor"
  write_findings "$plan_audit/CG.json" CG "$(brief_for "$plan_audit" plan CG)" ""
  write_findings "$plan_audit/COV.json" COV "$(brief_for "$plan_audit" plan COV)" ""
  write_findings "$plan_audit/TD.json" TD "$(brief_for "$plan_audit" plan TD)" "TD-001:major,TD-002:minor"
  for lens in DP CG COV TD; do
    classify_real "$plan_audit" plan "$plan_audit/$lens.json" "$lens"
  done

  # Plan audit: TD finishes first and its refuter starts while the others run.
  finish plan TD DP,CG,COV,TD "$plan_audit" "$BATS_TEST_TMPDIR/plan-run"
  [ -n "$output" ]
  [ "$(wc -l <<<"$output" | tr -d ' ')" -eq 1 ]
  render_refuter plan "$plan_audit" "$plan_audit" "$output"
  for lens in DP CG COV; do
    finish plan "$lens" DP,CG,COV,TD "$plan_audit" "$BATS_TEST_TMPDIR/plan-run"
    [ -z "$output" ]
  done

  # SPEC audit under the cap: nothing starts until the last lens finishes.
  for lens in FG TST COV; do
    finish spec "$lens" FG,TST,COV,RT "$spec_findings" "$BATS_TEST_TMPDIR/spec-run"
    [ -z "$output" ]
  done
  finish spec RT FG,TST,COV,RT "$spec_findings" "$BATS_TEST_TMPDIR/spec-run"
  [ "$(wc -l <<<"$output" | tr -d ' ')" -eq 3 ]
  local line dispatched=0
  while IFS= read -r line; do
    render_refuter spec "$spec_audit" "$spec_findings" "$line"
    dispatched=$((dispatched + 1))
  done <<<"$output"
  [ "$dispatched" -eq 3 ]
}
