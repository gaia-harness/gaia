#!/usr/bin/env node
// summarize-runs.mjs: round-1 medians over a fixed number of measure JSONs.
//
//   summarize-runs.mjs --bundle before|after --runs <n> <measure json>...
//
// The run count is fixed up front: exit 1 when the file count differs from
// --runs (no silent re-runs, no short sets). Exit 2 on a usage error. Medians
// pool every round-1 dispatch of an agent type (or of a specialist role)
// across the runs; the unit's cost median is per run.
import { readFileSync } from 'node:fs';

const USAGE = 'usage: summarize-runs.mjs --bundle before|after --runs <n> <measure json>...';
const METRICS = ['first_call_context', 'steady_state_context', 'calls', 'cost_usd', 'wall_s', 'tool_s', 'model_s', 'member_plus_children_cost_usd'];

const fail = (message, code) => {
  process.stderr.write(`${message}\n`);
  process.exit(code);
};

const argv = process.argv.slice(2);
let bundle = null;
let runs = null;
const files = [];
for (let index = 0; index < argv.length; index += 1) {
  if (argv[index] === '--bundle') bundle = argv[(index += 1)] ?? null;
  else if (argv[index] === '--runs') runs = Number(argv[(index += 1)]);
  else if (argv[index].startsWith('--')) fail(USAGE, 2);
  else files.push(argv[index]);
}
if (!['before', 'after'].includes(bundle) || !Number.isInteger(runs) || runs < 1) fail(USAGE, 2);
if (files.length !== runs) fail(`summarize-runs: expected ${runs} measure files, got ${files.length}`, 1);

const median = (values) => {
  const sorted = values.filter((value) => typeof value === 'number').sort((left, right) => left - right);
  if (sorted.length === 0) return null;
  const middle = Math.floor(sorted.length / 2);
  const value = sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  return Number(value.toFixed(6));
};

const measures = files.map((file) => {
  const measure = JSON.parse(readFileSync(file, 'utf8'));
  if (measure.schema !== 1) fail(`summarize-runs: ${file} is not a schema-1 measure`, 2);
  return measure;
});

const summarize = (group) => {
  const entry = { runs: new Set(group.map((row) => row.run)).size, dispatches: group.length, median: {} };
  for (const metric of METRICS) entry.median[metric] = median(group.map((row) => row.dispatch[metric] ?? (metric === 'first_call_context' ? row.dispatch.first_call.context : undefined)));
  return entry;
};

const roundOne = measures.flatMap((measure, run) => measure.dispatches.filter((dispatch) => dispatch.round === 1).map((dispatch) => ({ run, dispatch })));
const groupBy = (rows, keyOf) => {
  const groups = new Map();
  for (const row of rows) {
    const key = keyOf(row.dispatch);
    if (key === null) continue;
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  return Object.fromEntries([...groups].sort(([left], [right]) => left.localeCompare(right)).map(([key, group]) => [key, summarize(group)]));
};

const summary = {
  bundle,
  runs,
  unit_cost_usd_median: median(measures.map((measure) => measure.unit?.cost_usd)),
  by_agent_type: groupBy(roundOne, (dispatch) => dispatch.agent_type),
  by_role: groupBy(roundOne, (dispatch) => (dispatch.child_kind === 'specialist' && dispatch.role ? dispatch.role : null)),
};
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
