#!/usr/bin/env bats
# Suite for the arm comparator under .gaia/tests/audit-cost/compare-arms.mjs.
# Measure files are generated here from neutral spec labels; nothing is read
# from the shared checkout but the script itself.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  COMPARE="$REPO_ROOT/.gaia/tests/audit-cost/compare-arms.mjs"
  MEASURES="$BATS_TEST_TMPDIR/measures"
  mkdir -p "$MEASURES"
  MAKE_RUN="$BATS_TEST_TMPDIR/make-run.mjs"
  # make-run.mjs <kind> <spec> <arm> <run> <duration_s> [<json overrides>]
  # writes $MEASURES/<spec>-<arm>-<run>.json.
  cat >"$MAKE_RUN" <<'JS'
import { writeFileSync } from 'node:fs';
const [kind, spec, arm, run, duration, overrides = '{}'] = process.argv.slice(2);
const start = Date.parse('2026-01-01T00:00:00Z');
const end = new Date(start + Number(duration) * 1000).toISOString();
const measure = {
  kind, spec, arm, run: Number(run), grader_version: 'g1', base_commit: 'abc',
  draft_sha256: 'draft', snapshot_sha256: 'snap',
  fidelity: { tier: 'standard', lenses: ['FG', 'TST'] },
  first_lens_dispatch_utc: new Date(start).toISOString(),
  output_tokens: 1000, cache_read_tokens: 5000, cost_usd: 1.5,
  lenses: [{ lens: 'FG', output_tokens: 300, wall_s: 40 }, { lens: 'TST', output_tokens: 200, wall_s: 90 }],
  apply: { accepted_findings: 4, apply_s: 8, script_replacements: 3, fixup_replacements: 1,
    fixup_agent: { output_tokens: 111, wall_s: 12 }, judge_agent: { output_tokens: 222, wall_s: 7 }, structural_replan_s: null },
  grade: [],
  ...JSON.parse(overrides),
};
if (kind === 'plan-audit') measure.table_applied_utc = end; else measure.audit_written_utc = end;
writeFileSync(`${process.env.MEASURES}/${spec}-${arm}-${run}.json`, JSON.stringify(measure));
JS
}

# mk <kind> <spec> <arm> <run> <duration> [overrides]
mk() {
  MEASURES="$MEASURES" node "$MAKE_RUN" "$@"
}

# full_set <kind> <changed duration> [<overrides for every changed run>]
# writes a valid two-spec set: two runs per arm per spec, baseline 100 and 120.
full_set() {
  local kind="$1" changed_duration="$2" changed_overrides="$3" spec
  [ -n "$changed_overrides" ] || changed_overrides='{}'
  rm -f "$MEASURES"/*.json
  for spec in spec-a spec-b; do
    mk "$kind" "$spec" baseline 1 100
    mk "$kind" "$spec" baseline 2 120
    mk "$kind" "$spec" changed 1 "$changed_duration" "$changed_overrides"
    mk "$kind" "$spec" changed 2 "$changed_duration" "$changed_overrides"
  done
}

compare() {
  local kind="$1"
  shift
  run node "$COMPARE" --kind "$kind" --specs spec-a,spec-b "$@" "$MEASURES"/*.json
}

# report_value <js expression over r>: prints it from the last compare output.
report_value() {
  printf '%s' "$output" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const r=JSON.parse(s);process.stdout.write(String($1))})"
}

@test "equal grade follows the pair rule against the current-harness arm" {
  # Not equal: a critical in a changed run.
  full_set spec-audit 90
  mk spec-audit spec-a changed 1 90 '{"grade":[{"requirement":"R1","severity":"critical"}]}'
  compare spec-audit
  [ "$status" -eq 0 ] || return 1
  [ "$(report_value 'r.equal_grade')" = "false" ] || return 1

  # Not equal: one requirement with a major in both changed runs.
  full_set spec-audit 90
  mk spec-audit spec-a baseline 1 100 '{"grade":[{"requirement":"R1","severity":"major"}]}'
  mk spec-audit spec-a changed 1 90 '{"grade":[{"requirement":"R1","severity":"major"}]}'
  mk spec-audit spec-a changed 2 90 '{"grade":[{"requirement":"R1","severity":"major"}]}'
  compare spec-audit
  [ "$status" -eq 0 ] || return 1
  [ "$(report_value 'r.equal_grade')" = "false" ] || return 1

  # Not equal: a major on a requirement no baseline run had.
  full_set spec-audit 90
  mk spec-audit spec-a changed 1 90 '{"grade":[{"requirement":"R9","severity":"major"}]}'
  compare spec-audit
  [ "$status" -eq 0 ] || return 1
  [ "$(report_value 'r.equal_grade')" = "false" ] || return 1

  # Equal: a major in one changed run that a baseline run also had, minors elsewhere.
  full_set spec-audit 90
  mk spec-audit spec-a baseline 1 100 '{"grade":[{"requirement":"R1","severity":"major"}]}'
  mk spec-audit spec-a changed 1 90 '{"grade":[{"requirement":"R1","severity":"major"},{"requirement":"R2","severity":"minor"}]}'
  mk spec-audit spec-b changed 2 90 '{"grade":[{"requirement":"R3","severity":"minor"}]}'
  compare spec-audit
  [ "$status" -eq 0 ] || return 1
  [ "$(report_value 'r.equal_grade')" = "true" ] || return 1
}

@test "plan audit comparison decides shorter on medians with re-plan time apart" {
  full_set plan-audit 90
  compare plan-audit
  [ "$status" -eq 0 ] || return 1
  [ "$(report_value 'r.shorter')" = "true" ] || return 1
  [ "$(report_value 'r.specs["spec-a"].baseline.duration_s.median')" = "110" ] || return 1
  [ "$(report_value 'r.specs["spec-a"].baseline.apply_s_per_accepted_finding.median')" = "2" ] || return 1

  # An equal median is not shorter.
  full_set plan-audit 110
  compare plan-audit
  [ "$status" -eq 0 ] || return 1
  [ "$(report_value 'r.shorter')" = "false" ] || return 1

  # Re-plan time is reported apart and never enters the compared duration.
  full_set plan-audit 90 '{"apply":{"accepted_findings":4,"apply_s":8,"script_replacements":3,"fixup_replacements":1,"fixup_agent":{"output_tokens":1,"wall_s":1},"judge_agent":{"output_tokens":1,"wall_s":1},"structural_replan_s":500}}'
  compare plan-audit
  [ "$status" -eq 0 ] || return 1
  [ "$(report_value 'r.shorter')" = "true" ] || return 1
  [ "$(report_value 'r.specs["spec-a"].changed.duration_s.median')" = "90" ] || return 1
  [ "$(report_value 'r.specs["spec-a"].changed.structural_replan_s.median')" = "500" ] || return 1
}

@test "spec audit comparison measures first lens dispatch to report written" {
  full_set spec-audit 90
  compare spec-audit
  [ "$status" -eq 0 ] || return 1
  [ "$(report_value 'r.specs["spec-a"].changed.duration_s.runs.join(",")')" = "90,90" ] || return 1
  [ "$(report_value 'r.specs["spec-a"].shorter')" = "true" ] || return 1
  [ "$(report_value 'r.specs["spec-b"].shorter')" = "true" ] || return 1
  [ "$(report_value 'r.shorter')" = "true" ] || return 1
  [ "$(report_value 'r.equal_grade')" = "true" ] || return 1

  # A slower changed arm on one SPEC is decided on that SPEC and overall.
  mk spec-audit spec-b changed 1 400
  mk spec-audit spec-b changed 2 400
  compare spec-audit
  [ "$status" -eq 0 ] || return 1
  [ "$(report_value 'r.specs["spec-a"].shorter')" = "true" ] || return 1
  [ "$(report_value 'r.specs["spec-b"].shorter')" = "false" ] || return 1
  [ "$(report_value 'r.shorter')" = "false" ] || return 1
}

@test "report lists every metric per arm beside the baseline" {
  full_set spec-audit 90 '{"output_tokens":700,"cache_read_tokens":4000,"cost_usd":1.1,"grade":[{"requirement":"R2","severity":"minor"},{"requirement":"R3","severity":"minor"}]}'
  compare spec-audit
  [ "$status" -eq 0 ] || return 1
  [ "$(report_value 'r.grader_version')" = "g1" ] || return 1
  local arm
  for arm in baseline changed; do
    [ "$(report_value "typeof r.specs['spec-a'].$arm.duration_s.median")" = "number" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.duration_s.runs.length")" = "2" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.output_tokens.runs.length")" = "2" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.cache_read_tokens.runs.length")" = "2" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.cost_usd.runs.length")" = "2" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.minor_findings.runs.length")" = "2" ] || return 1
  done
  [ "$(report_value "r.specs['spec-a'].changed.output_tokens.median")" = "700" ] || return 1
  [ "$(report_value "r.specs['spec-a'].changed.cache_read_tokens.median")" = "4000" ] || return 1
  [ "$(report_value "r.specs['spec-a'].changed.cost_usd.median")" = "1.1" ] || return 1
  [ "$(report_value "r.specs['spec-a'].changed.minor_findings.median")" = "2" ] || return 1
  [ "$(report_value "r.specs['spec-a'].baseline.minor_findings.median")" = "0" ] || return 1
}

@test "comparison refuses a set missing either frozen SPEC" {
  local kind
  for kind in plan-audit spec-audit; do
    rm -f "$MEASURES"/*.json
    mk "$kind" spec-a baseline 1 100
    mk "$kind" spec-a baseline 2 100
    mk "$kind" spec-a changed 1 90
    mk "$kind" spec-a changed 2 90
    compare "$kind"
    [ "$status" -eq 1 ] || return 1
  done
}

@test "comparison refuses a set without two runs per arm on each SPEC" {
  full_set spec-audit 90
  rm "$MEASURES/spec-b-changed-2.json"
  compare spec-audit
  [ "$status" -eq 1 ] || return 1

  full_set spec-audit 90
  mk spec-audit spec-b baseline 3 100
  compare spec-audit
  [ "$status" -eq 1 ] || return 1
}

@test "comparison refuses arms that started from different inputs" {
  full_set spec-audit 90
  mk spec-audit spec-a changed 1 90 '{"draft_sha256":"other"}'
  compare spec-audit
  [ "$status" -eq 1 ] || return 1

  full_set plan-audit 90
  mk plan-audit spec-a changed 1 90 '{"snapshot_sha256":"other"}'
  compare plan-audit
  [ "$status" -eq 1 ] || return 1

  full_set plan-audit 90
  mk plan-audit spec-a changed 1 90 '{"base_commit":"other"}'
  compare plan-audit
  [ "$status" -eq 1 ] || return 1

  full_set spec-audit 90
  mk spec-audit spec-a changed 1 90 '{"fidelity":{"tier":"deep","lenses":["FG","TST"]}}'
  compare spec-audit
  [ "$status" -eq 1 ] || return 1

  full_set spec-audit 90
  mk spec-audit spec-a changed 1 90 '{"fidelity":{"tier":"standard","lenses":["FG"]}}'
  compare spec-audit
  [ "$status" -eq 1 ] || return 1
}

@test "comparison refuses arms graded by different grader versions" {
  full_set spec-audit 90
  mk spec-audit spec-a changed 1 90 '{"grader_version":"g2"}'
  compare spec-audit
  [ "$status" -eq 1 ] || return 1

  full_set spec-audit 90
  rm "$MEASURES"/spec-a-baseline-1.json "$MEASURES"/spec-a-baseline-2.json "$MEASURES"/spec-b-baseline-1.json "$MEASURES"/spec-b-baseline-2.json
  compare spec-audit
  [ "$status" -eq 1 ] || return 1
}

@test "report lists per-lens output tokens and the slowest lens per arm" {
  full_set spec-audit 90
  compare spec-audit
  [ "$status" -eq 0 ] || return 1
  local arm
  for arm in baseline changed; do
    [ "$(report_value "r.specs['spec-a'].$arm.lens_output_tokens.FG.median")" = "300" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.lens_output_tokens.TST.median")" = "200" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.slowest_lens.median_wall_s")" = "90" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.slowest_lens.runs[0].lens")" = "TST" ] || return 1
  done
}

@test "plan audit report lists script and fix-up replacement counts and agent costs" {
  full_set plan-audit 90
  compare plan-audit
  [ "$status" -eq 0 ] || return 1
  local arm
  for arm in baseline changed; do
    [ "$(report_value "r.specs['spec-a'].$arm.script_replacements.median")" = "3" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.fixup_replacements.median")" = "1" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.fixup_agent.output_tokens.median")" = "111" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.fixup_agent.wall_s.median")" = "12" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.judge_agent.output_tokens.median")" = "222" ] || return 1
    [ "$(report_value "r.specs['spec-a'].$arm.judge_agent.wall_s.median")" = "7" ] || return 1
  done
}
