#!/usr/bin/env node
// score.mjs: the differential recall verdict over two before runs and two
// after runs of the corpus (run-recall.sh output directories).
//
//   score.mjs --before <run1> <run2> --after <run1> <run2> [--corpus <corpus.json>]
//
// found(entry, run), all matching deterministic (same path, line within
// LINE_WINDOW):
//   member      the member's findings sidecar holds a finding on the path and
//               line whose finding_class prefix equals the entry's class_prefix.
//   specialist  a child classifyChild calls a specialist of the entry's role
//               names `path:line` in its own final reply. The member's merged
//               report never counts: a specialist miss the member papers over
//               is still a specialist miss.
//   refuter     the verdict token (REFUTED, DOWNGRADE, STANDS) of the last
//               refuter child whose prompt's Location: names the path and line,
//               or `none` when no refuter ran for it.
// An entry gates when the before bundle finds it in both runs (refuter: both
// before verdicts agree). The after bundle fails a gating entry only when it
// misses it in both runs (refuter: both after verdicts differ from the before
// verdict).
//
// Prints the verdict JSON. Exit 0 no failure, 1 a recall failure, 2 a usage or
// input error: a missing run directory, or an entry with no result in a run,
// is an error and never a pass.
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { classifyChild, finalReplyText, listAgents } from '../audit-cost/lib/transcripts.mjs';

const SCRIPT_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const LINE_WINDOW = 5;
const USAGE = 'usage: score.mjs --before <run1> <run2> --after <run1> <run2> [--corpus <corpus.json>]';
const VERDICT_TOKEN = /\b(REFUTED|DOWNGRADE|STANDS)\b/;

const fail = (message) => {
  process.stderr.write(`${message}\n`);
  process.exit(2);
};

const parseArguments = (argv) => {
  const options = { corpus: join(SCRIPT_DIRECTORY, 'corpus.json') };
  for (let index = 0; index < argv.length; ) {
    const flag = argv[index];
    if (flag === '--before' || flag === '--after') {
      const runs = argv.slice(index + 1, index + 3);
      if (runs.length !== 2 || runs.some((run) => run.startsWith('--'))) fail(USAGE);
      options[flag.slice(2)] = runs;
      index += 3;
    } else if (flag === '--corpus' && argv[index + 1] !== undefined) {
      options.corpus = argv[index + 1];
      index += 2;
    } else fail(USAGE);
  }
  if (!options.before || !options.after) fail(USAGE);
  return options;
};

const readJson = (path) => {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    return fail(`score: cannot read ${path}: ${error.message}`);
  }
};

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const nearLine = (line, entry) => Number.isInteger(line) && Math.abs(line - entry.line) <= LINE_WINDOW;

const namesLocation = (text, entry) => {
  for (const match of String(text).matchAll(new RegExp(`${escapeRegExp(entry.path)}:(\\d+)`, 'g'))) {
    if (nearLine(Number(match[1]), entry)) return true;
  }
  return false;
};

const agentsOf = (resultDirectory) => {
  const session = join(resultDirectory, 'session.jsonl');
  return existsSync(session) ? listAgents(session) : [];
};

const memberFound = (resultDirectory, entry) => {
  const sidecar = join(resultDirectory, 'findings.json');
  if (!existsSync(sidecar)) return false;
  const findings = readJson(sidecar).findings ?? [];
  return findings.some(
    (finding) => finding?.path === entry.path && nearLine(finding.line, entry) && String(finding.finding_class ?? '').split('/')[0] === entry.class_prefix,
  );
};

const specialistFound = (resultDirectory, entry) =>
  agentsOf(resultDirectory).some((agent) => {
    const child = classifyChild(agent.dispatch);
    return child.kind === 'specialist' && child.role === entry.role && namesLocation(finalReplyText(agent.transcriptPath), entry);
  });

const refuterVerdict = (resultDirectory, entry) => {
  const matching = agentsOf(resultDirectory).filter((agent) => {
    if (classifyChild(agent.dispatch).kind !== 'refuter') return false;
    const location = /Location\**:\**\s*`?([^\s`]+):(\d+)/.exec(agent.dispatch.prompt ?? '');
    return location !== null && location[1] === entry.path && nearLine(Number(location[2]), entry);
  });
  if (matching.length === 0) return 'none';
  return VERDICT_TOKEN.exec(finalReplyText(matching[matching.length - 1].transcriptPath))?.[1] ?? 'none';
};

const observe = (resultDirectory, entry) => {
  if (entry.scorer === 'member') return memberFound(resultDirectory, entry);
  if (entry.scorer === 'specialist') return specialistFound(resultDirectory, entry);
  if (entry.scorer === 'refuter') return refuterVerdict(resultDirectory, entry);
  return fail(`score: entry ${entry.id} has an unknown scorer ${entry.scorer}`);
};

const noopRate = (runs) => {
  let specialists = 0;
  let noops = 0;
  for (const run of runs) {
    const summaryPath = join(run, 'summary.json');
    if (!existsSync(summaryPath)) return null;
    const noop = readJson(summaryPath).noop ?? {};
    specialists += noop.specialists ?? 0;
    noops += noop.noops ?? 0;
  }
  return specialists === 0 ? null : Number((noops / specialists).toFixed(4));
};

const options = parseArguments(process.argv.slice(2));
if (!existsSync(options.corpus)) fail(`score: no corpus at ${options.corpus}`);
const corpus = readJson(options.corpus);
if (corpus.schema !== 1 || !Array.isArray(corpus.entries)) fail(`score: ${options.corpus} is not a schema-1 corpus`);
const runs = [...options.before, ...options.after];
for (const run of runs) if (!existsSync(run)) fail(`score: no run directory ${run}`);
for (const run of runs) {
  for (const entry of corpus.entries) {
    if (!existsSync(join(run, entry.id, 'result.json'))) fail(`score: run ${run} has no result for entry ${entry.id}`);
  }
}

let gating = 0;
const failures = [];
const refuterChildrenAfter = {};
for (const entry of corpus.entries) {
  const [beforeOne, beforeTwo] = options.before.map((run) => observe(join(run, entry.id), entry));
  const [afterOne, afterTwo] = options.after.map((run) => observe(join(run, entry.id), entry));
  if (entry.scorer === 'refuter') {
    if (entry.source === 'planted') refuterChildrenAfter[entry.id] = afterOne !== 'none' && afterTwo !== 'none';
    if (beforeOne !== beforeTwo) continue;
    gating += 1;
    if (afterOne !== beforeOne && afterTwo !== beforeOne) failures.push(entry);
    continue;
  }
  if (!(beforeOne && beforeTwo)) continue;
  gating += 1;
  if (!afterOne && !afterTwo) failures.push(entry);
}

const verdict = {
  schema: 1,
  gating,
  failures: failures.map((entry) => ({ id: entry.id, scorer: entry.scorer, role: entry.role ?? null, member: entry.member })),
  specialist_failures_only: failures.length > 0 && failures.every((entry) => entry.scorer === 'specialist'),
  noop_rate: { before: noopRate(options.before), after: noopRate(options.after) },
  refuter_children_after: refuterChildrenAfter,
};
process.stdout.write(`${JSON.stringify(verdict, null, 2)}\n`);
process.exit(failures.length > 0 ? 1 : 0);
