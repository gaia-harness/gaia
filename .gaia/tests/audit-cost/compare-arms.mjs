#!/usr/bin/env node
// compare-arms.mjs: turns per-run measure files into the verdicts of an audit
// replay comparison, current harness (baseline arm) against changed harness.
//
//   compare-arms.mjs --kind plan-audit|spec-audit --specs <label>,<label> <measure json>...
//
// Inputs: one measure JSON per run, written by the maintainer sandbox's eval
// ladder: kind, spec, arm (baseline|changed), run, grader_version, base_commit,
// draft_sha256 (spec-audit) or snapshot_sha256 (plan-audit), fidelity
// ({tier, lenses}), first_lens_dispatch_utc, table_applied_utc (plan-audit) or
// audit_written_utc (spec-audit), output_tokens, cache_read_tokens, cost_usd,
// lenses [{lens, output_tokens, wall_s}], apply (plan-audit) and grade
// [{requirement, severity}].
//
// Rule: duration is first lens dispatch to table applied (plan-audit) or to
// audit written (spec-audit), in seconds; a median of two runs is their mean.
// Shorter means the changed median is below the baseline median; there is no
// threshold and no minute target. Equal grade, per SPEC: no changed run has a
// critical; no requirement has a major in both changed runs; no changed run has
// a critical or major on a requirement no baseline run of that SPEC has at that
// severity or higher. Overall equal grade needs every SPEC equal; overall
// shorter compares the medians over all runs of each arm. Structural re-plan
// time is reported on its own and never enters a duration.
//
// Output: pretty-printed JSON report on stdout.
// Exit codes: 0 report written; 1 refusal (a SPEC missing, not exactly two runs
// per arm per SPEC, no baseline arm, grader versions differing, arms that
// started from different inputs); 2 usage error.
import { readFileSync } from 'node:fs';

const USAGE = 'usage: compare-arms.mjs --kind plan-audit|spec-audit --specs <label>,<label> <measure json>...';
const ARMS = ['baseline', 'changed'];
const RANK = { minor: 1, major: 2, critical: 3 };

const fail = (message, code) => {
  process.stderr.write(`compare-arms: ${message}\n`);
  process.exit(code);
};

const argv = process.argv.slice(2);
let kind = null;
let specsArgument = null;
const files = [];
for (let index = 0; index < argv.length; index += 1) {
  if (argv[index] === '--kind') kind = argv[(index += 1)] ?? null;
  else if (argv[index] === '--specs') specsArgument = argv[(index += 1)] ?? null;
  else if (argv[index].startsWith('--')) fail(USAGE, 2);
  else files.push(argv[index]);
}
if (!['plan-audit', 'spec-audit'].includes(kind) || specsArgument === null || files.length === 0) fail(USAGE, 2);
const specs = specsArgument.split(',');
if (specs.length !== 2 || specs.some((label) => label === '') || specs[0] === specs[1]) fail(USAGE, 2);

const END_FIELD = kind === 'plan-audit' ? 'table_applied_utc' : 'audit_written_utc';

const rounded = (value) => (value === null ? null : Number(value.toFixed(6)));
const median = (values) => {
  const numbers = values.filter((value) => typeof value === 'number').sort((left, right) => left - right);
  if (numbers.length === 0) return null;
  const middle = Math.floor(numbers.length / 2);
  return rounded(numbers.length % 2 === 1 ? numbers[middle] : (numbers[middle - 1] + numbers[middle]) / 2);
};

const runs = files.map((file) => {
  let measure;
  try {
    measure = JSON.parse(readFileSync(file, 'utf8'));
  } catch (error) {
    return fail(`${file} is not readable JSON: ${error.message}`, 1);
  }
  if (measure.kind !== kind) fail(`${file} is kind ${measure.kind}, expected ${kind}`, 1);
  if (!ARMS.includes(measure.arm)) fail(`${file} has arm ${measure.arm}, expected baseline or changed`, 1);
  const start = Date.parse(measure.first_lens_dispatch_utc);
  const end = Date.parse(measure[END_FIELD]);
  if (Number.isNaN(start) || Number.isNaN(end)) fail(`${file} lacks a readable first_lens_dispatch_utc or ${END_FIELD}`, 1);
  if (end < start) fail(`${file} ends before it starts`, 1);
  return { file, measure, duration_s: (end - start) / 1000 };
});

for (const { file, measure } of runs) {
  if (!specs.includes(measure.spec)) fail(`${file} is for spec ${measure.spec}, not one of --specs`, 1);
}

const forArm = (spec, arm) => runs.filter((run) => run.measure.spec === spec && run.measure.arm === arm);

for (const spec of specs) {
  const present = runs.filter((run) => run.measure.spec === spec);
  if (present.length === 0) fail(`no runs for spec ${spec}`, 1);
  for (const arm of ARMS) {
    const group = forArm(spec, arm);
    if (group.length === 0 && arm === 'baseline') fail(`no baseline arm for spec ${spec}`, 1);
    if (group.length !== 2) fail(`spec ${spec} arm ${arm} has ${group.length} runs, expected exactly 2`, 1);
    if (new Set(group.map((run) => run.measure.run)).size !== 2) fail(`spec ${spec} arm ${arm} repeats a run number`, 1);
  }
}

const graders = new Set(runs.map((run) => run.measure.grader_version));
if (graders.size !== 1 || graders.has(undefined)) fail(`grader versions differ or are missing: ${[...graders].join(', ')}`, 1);
const graderVersion = [...graders][0];

const fidelityKey = (fidelity) => JSON.stringify({ tier: fidelity?.tier ?? null, lenses: [...(fidelity?.lenses ?? [])].sort() });
const inputFields = kind === 'plan-audit' ? ['snapshot_sha256', 'base_commit'] : ['draft_sha256'];
for (const spec of specs) {
  const group = runs.filter((run) => run.measure.spec === spec);
  for (const field of inputFields) {
    const values = new Set(group.map((run) => run.measure[field]));
    if (values.size !== 1 || values.has(undefined)) fail(`spec ${spec} arms started from different ${field}`, 1);
  }
  if (new Set(group.map((run) => fidelityKey(run.measure.fidelity))).size !== 1) fail(`spec ${spec} arms differ in fidelity tier or lens set`, 1);
}

const severityOf = (run) => {
  const byRequirement = new Map();
  for (const entry of run.measure.grade ?? []) {
    const rank = RANK[entry.severity] ?? 0;
    byRequirement.set(entry.requirement, Math.max(byRequirement.get(entry.requirement) ?? 0, rank));
  }
  return byRequirement;
};

const equalGrade = (baselineRuns, changedRuns) => {
  const reasons = [];
  const changed = changedRuns.map(severityOf);
  const baseline = baselineRuns.map(severityOf);
  changedRuns.forEach((run, index) => {
    for (const [requirement, rank] of changed[index]) if (rank >= RANK.critical) reasons.push(`changed run ${run.measure.run} has a critical on ${requirement}`);
  });
  const requirements = new Set(changed.flatMap((map) => [...map.keys()]));
  for (const requirement of requirements) {
    if (changed.every((map) => (map.get(requirement) ?? 0) >= RANK.major)) reasons.push(`${requirement} has a major in both changed runs`);
    const baselineBest = Math.max(0, ...baseline.map((map) => map.get(requirement) ?? 0));
    for (const [index, map] of changed.entries()) {
      const rank = map.get(requirement) ?? 0;
      if (rank >= RANK.major && rank > baselineBest) reasons.push(`changed run ${changedRuns[index].measure.run} has a ${rank >= RANK.critical ? 'critical' : 'major'} on ${requirement} no baseline run has at that severity`);
    }
  }
  return { equal: reasons.length === 0, reasons: [...new Set(reasons)] };
};

const minorCount = (run) => {
  const byRequirement = severityOf(run);
  return [...byRequirement.values()].filter((rank) => rank === RANK.minor).length;
};

const slowestLens = (run) => {
  const lenses = run.measure.lenses ?? [];
  if (lenses.length === 0) return null;
  const slowest = lenses.reduce((best, lens) => (lens.wall_s > best.wall_s ? lens : best));
  return { lens: slowest.lens, wall_s: slowest.wall_s };
};

const metric = (group, pick) => {
  const values = group.map(pick);
  return { median: median(values), runs: values };
};

const agentMetric = (group, name) => ({
  output_tokens: metric(group, (run) => run.measure.apply?.[name]?.output_tokens ?? null),
  wall_s: metric(group, (run) => run.measure.apply?.[name]?.wall_s ?? null),
});

const armReport = (group) => {
  const report = {
    duration_s: metric(group, (run) => run.duration_s),
    output_tokens: metric(group, (run) => run.measure.output_tokens),
    cache_read_tokens: metric(group, (run) => run.measure.cache_read_tokens),
    cost_usd: metric(group, (run) => run.measure.cost_usd),
    minor_findings: metric(group, minorCount),
    lens_output_tokens: Object.fromEntries(
      [...new Set(group.flatMap((run) => (run.measure.lenses ?? []).map((lens) => lens.lens)))].sort().map((lens) => [lens, metric(group, (run) => (run.measure.lenses ?? []).find((entry) => entry.lens === lens)?.output_tokens ?? null)]),
    ),
    slowest_lens: {
      median_wall_s: median(group.map((run) => slowestLens(run)?.wall_s ?? null)),
      runs: group.map(slowestLens),
    },
  };
  if (kind === 'plan-audit') {
    report.apply_s_per_accepted_finding = metric(group, (run) => {
      const apply = run.measure.apply;
      return apply && apply.accepted_findings > 0 ? rounded(apply.apply_s / apply.accepted_findings) : null;
    });
    report.script_replacements = metric(group, (run) => run.measure.apply?.script_replacements ?? null);
    report.fixup_replacements = metric(group, (run) => run.measure.apply?.fixup_replacements ?? null);
    report.fixup_agent = agentMetric(group, 'fixup_agent');
    report.judge_agent = agentMetric(group, 'judge_agent');
    report.structural_replan_s = metric(group, (run) => run.measure.apply?.structural_replan_s ?? null);
  }
  return report;
};

const section = (baselineRuns, changedRuns) => {
  const grade = equalGrade(baselineRuns, changedRuns);
  const baselineReport = armReport(baselineRuns);
  const changedReport = armReport(changedRuns);
  return {
    baseline: baselineReport,
    changed: changedReport,
    equal_grade: grade.equal,
    equal_grade_reasons: grade.reasons,
    shorter: baselineReport.duration_s.median !== null && changedReport.duration_s.median < baselineReport.duration_s.median,
  };
};

const bySpec = Object.fromEntries(specs.map((spec) => [spec, section(forArm(spec, 'baseline'), forArm(spec, 'changed'))]));
const overall = section(
  specs.flatMap((spec) => forArm(spec, 'baseline')),
  specs.flatMap((spec) => forArm(spec, 'changed')),
);
overall.equal_grade = specs.every((spec) => bySpec[spec].equal_grade);
overall.equal_grade_reasons = specs.flatMap((spec) => bySpec[spec].equal_grade_reasons.map((reason) => `${spec}: ${reason}`));

const report = {
  kind,
  grader_version: graderVersion,
  specs: bySpec,
  overall,
  equal_grade: overall.equal_grade,
  shorter: overall.shorter,
};
process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
