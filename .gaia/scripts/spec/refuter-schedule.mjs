#!/usr/bin/env node
// Decides which audit refuters may start now, as each lens finishes.
//
// Usage:
//   refuter-schedule.mjs finished --state <file> --kind spec|plan
//     --tier standard|deep --lenses <ID,...> --findings-dir <dir>
//     --verdicts-dir <dir> --coverage <coverage.jsonl> --lens <ID>
//
// Call once per lens, only after its findings file classifies real (or after
// its inline run). The state file (JSON, created on the first call) records the
// finished lenses, their material finding ids and which lenses already got
// their dispatches. Material = severity `critical` or `major` in
// `<findings-dir>/<LENS>.json`.
//
// Output, on stdout, one tab-separated line per dispatch to start now:
//   refuter <LENS> <single|deep|batched|deep-batched> <ids,> <refuter-lens|-> <verdict paths,>
// and, on the last finish of a SPEC Deep audit, `critic run` or `critic skip`.
// Alongside, it appends to --coverage the refuter records the playbook writes
// for those dispatches (the critic skip record included), each refuter record
// carrying the finding ids it covers.
//
// Shape: SPEC Standard batched above 24 material findings, SPEC Deep batched
// above 8, plan kind (only TD is refuted) batched above 24 TD material
// findings, always single otherwise.
//
// Early start: the shape decision is a pure function of (kind, tier, the
// finished lenses' material ids, whether every lens has finished), so the
// dispatched set is the same for any finish order. Batching is certain once the
// finished lenses' material already exceeds the threshold, so each finished
// lens with a material finding gets its batched dispatch then, and each later
// lens at its own finish. Below the threshold nothing prints until the last
// lens finishes. Plan kind prints TD's dispatches at TD's finish.
//
// Exit 0 ok, 1 refusal (lens not in --lenses, a lens finished twice, an
// unreadable findings file or state file), 2 usage.

import {
  appendFileSync,
  existsSync,
  readFileSync,
  realpathSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';

const SCRIPT = 'refuter-schedule';
const STANDARD_CAP = 24;
const DEEP_CAP = 8;
const DEEP_LENSES = [
  ['correctness', 'correctness'],
  ['security/safety', 'security-safety'],
  ['reproduces-as-described', 'reproduces-as-described'],
];
const MATERIAL = new Set(['critical', 'major']);

class Refusal extends Error {
  constructor(message, code = 1) {
    super(message);
    this.code = code;
  }
}

// Pure: which dispatches start now.
// `finished` is an array of {lens, ids}; `dispatched` the lenses already
// dispatched; returns {batched, groups, everyLensFinished, deep} where groups
// are the lenses to dispatch now (each with its material ids), empty when
// nothing starts yet.
export function decide({kind, tier, lenses, finished, dispatched}) {
  const refutedLens = kind === 'plan' ? ['TD'] : lenses;
  const relevant = finished.filter(({lens}) => refutedLens.includes(lens));
  const total = relevant.reduce((sum, {ids}) => sum + ids.length, 0);
  const everyLensFinished = lenses.every((lens) =>
    finished.some((entry) => entry.lens === lens)
  );
  const deep = kind === 'spec' && tier === 'deep';
  const cap = deep ? DEEP_CAP : STANDARD_CAP;
  const batched = total > cap;
  const decided =
    kind === 'plan'
      ? relevant.length > 0
      : batched || everyLensFinished;
  const groups = decided
    ? relevant.filter(
        ({lens, ids}) => ids.length > 0 && !dispatched.includes(lens)
      )
    : [];
  return {batched, groups, everyLensFinished, deep};
}

function dispatchRows({batched, deep}, {lens, ids}, verdictsDir) {
  const verdictPath = (id) => join(verdictsDir, `${id}.json`);
  if (batched) {
    return {
      lines: [
        [
          'refuter',
          lens,
          deep ? 'deep-batched' : 'batched',
          ids.join(','),
          '-',
          ids.map(verdictPath).join(','),
        ],
      ],
      records: [
        {
          phase: 'refuter',
          lens,
          disposition: 'first_pass',
          finding_ids: ids,
        },
      ],
    };
  }
  const lines = [];
  const records = [];
  for (const id of ids) {
    if (deep) {
      for (const [verificationLens, slug] of DEEP_LENSES) {
        lines.push([
          'refuter',
          lens,
          'deep',
          id,
          verificationLens,
          join(verdictsDir, `${id}-${slug}.json`),
        ]);
      }
    } else {
      lines.push(['refuter', lens, 'single', id, '-', verdictPath(id)]);
    }
    records.push({
      phase: 'refuter',
      lens,
      disposition: 'first_pass',
      finding_ids: [id],
    });
  }
  return {lines, records};
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  if (command !== 'finished') {
    throw new Refusal('usage: refuter-schedule.mjs finished <options>', 2);
  }
  const options = {};
  for (let index = 0; index < rest.length; index += 2) {
    const flag = rest[index];
    const value = rest[index + 1];
    if (!flag?.startsWith('--') || value === undefined) {
      throw new Refusal(`bad argument ${flag ?? ''}`, 2);
    }
    options[flag.slice(2)] = value;
  }
  for (const name of [
    'state',
    'kind',
    'tier',
    'lenses',
    'findings-dir',
    'verdicts-dir',
    'coverage',
    'lens',
  ]) {
    if (!options[name]) throw new Refusal(`missing --${name}`, 2);
  }
  if (!['spec', 'plan'].includes(options.kind)) {
    throw new Refusal('--kind must be spec or plan', 2);
  }
  if (!['standard', 'deep'].includes(options.tier)) {
    throw new Refusal('--tier must be standard or deep', 2);
  }
  return options;
}

function readJson(path, what) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    throw new Refusal(`cannot read ${what} ${path}`);
  }
}

function materialIds(path) {
  const parsed = readJson(path, 'findings file');
  if (!Array.isArray(parsed?.findings)) {
    throw new Refusal(`findings file ${path} has no findings array`);
  }
  return parsed.findings
    .filter(
      (finding) =>
        typeof finding?.id === 'string' && MATERIAL.has(finding.severity)
    )
    .map((finding) => finding.id);
}

function run(argv) {
  const options = parseArgs(argv);
  const lenses = options.lenses.split(',').filter(Boolean);
  if (!lenses.includes(options.lens)) {
    throw new Refusal(`lens ${options.lens} is not in --lenses`);
  }
  const state = existsSync(options.state)
    ? readJson(options.state, 'state file')
    : {finished: [], dispatched: []};
  if (
    !Array.isArray(state.finished) ||
    !Array.isArray(state.dispatched)
  ) {
    throw new Refusal(`state file ${options.state} is malformed`);
  }
  if (state.finished.some((entry) => entry.lens === options.lens)) {
    throw new Refusal(`lens ${options.lens} already finished`);
  }
  const ids = materialIds(join(options['findings-dir'], `${options.lens}.json`));
  state.finished.push({lens: options.lens, ids});

  const decision = decide({
    kind: options.kind,
    tier: options.tier,
    lenses,
    finished: state.finished,
    dispatched: state.dispatched,
  });

  const lines = [];
  const records = [];
  for (const group of decision.groups) {
    const rows = dispatchRows(decision, group, options['verdicts-dir']);
    lines.push(...rows.lines.map((fields) => fields.join('\t')));
    records.push(...rows.records);
    state.dispatched.push(group.lens);
  }
  if (decision.deep && decision.everyLensFinished) {
    if (decision.batched) {
      lines.push('critic skip');
      records.push({
        phase: 'completeness',
        lens: 'critic',
        disposition: 'not_applicable',
      });
    } else {
      lines.push('critic run');
    }
  }

  const temporary = `${options.state}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`);
  renameSync(temporary, options.state);
  if (records.length > 0) {
    appendFileSync(
      options.coverage,
      records.map((record) => `${JSON.stringify(record)}\n`).join('')
    );
  }
  if (lines.length > 0) process.stdout.write(`${lines.join('\n')}\n`);
}

if (realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    if (error instanceof Refusal) {
      process.stderr.write(`${SCRIPT}: ${error.message}\n`);
      process.exit(error.code);
    }
    throw error;
  }
}
