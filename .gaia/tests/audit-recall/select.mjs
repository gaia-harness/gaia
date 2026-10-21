#!/usr/bin/env node
// select.mjs: select (or re-check) the recall corpus.
//
//   select.mjs --source <mined findings json> --repo <maintainer checkout>
//              --bundle-before <sha> --bundle-after <sha> --out <corpus.json>
//              [--seed <n>] [--planted-only] [--check]
//
// Selection (the default) reads the mined findings in their file order, keeps
// the eligible ones, shuffles them with the seed, and per member keeps the
// first ten whose replay tree builds against both bundles (build-tree.sh, run
// once per bundle, no model call). The planted entries from
// planted/entries.json are appended, so re-running selection is idempotent:
// the same inputs give a byte-identical file.
//
// --check rebuilds every real entry already in --out against the two given
// bundles without reselecting, prints each failure and exits 2 when any
// fails, 0 otherwise. --planted-only writes a corpus with no real entries and
// needs no --source.
//
// Exit 0 done, 2 a usage or input error or a failed --check, 1 an unexpected
// failure.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { seededShuffle } from './lib/prng.mjs';
import { baseShaFor, git, isAncestor, mainSha, mapLine, resolveHead } from './lib/replay-range.mjs';

const SCRIPT_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const BUILD_TREE = process.env.AUDIT_RECALL_BUILD_TREE || join(SCRIPT_DIRECTORY, 'build-tree.sh');
const PLANTED_ENTRIES = join(SCRIPT_DIRECTORY, 'planted', 'entries.json');
const USAGE =
  'usage: select.mjs --source <mined findings json> --repo <maintainer checkout> --bundle-before <sha> --bundle-after <sha> --out <corpus.json> [--seed <n>] [--planted-only] [--check]';
const DEFAULT_SEED = 122;
const PER_MEMBER = 10;
// The scorer's match window (score.mjs): a finding within this many lines of
// an entry's line matches it.
const LINE_WINDOW = 5;
const ELIGIBLE_SEVERITIES = new Set(['minor', 'warning', 'major', 'error']);
const RETIRED_MEMBERS = new Set(['code-audit-maintainer-prose']);
// A title is committed as data; one naming a working-document id or a
// machine-local path would put that reference in the tree, so such an entry
// is skipped rather than rewritten.
const LOCAL_REFERENCE = /\b(SPEC|UAT|PLAN)-\d|\.notebook\/|\.gaia\/local\/|\/Users\/|\/home\//;

const fail = (message, code = 2) => {
  process.stderr.write(`${message}\n`);
  process.exit(code);
};

const parseArguments = (argv) => {
  const options = { seed: DEFAULT_SEED, plantedOnly: false, check: false };
  const valued = { '--source': 'source', '--repo': 'repo', '--bundle-before': 'bundleBefore', '--bundle-after': 'bundleAfter', '--out': 'out', '--seed': 'seed' };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === '--planted-only') options.plantedOnly = true;
    else if (flag === '--check') options.check = true;
    else if (valued[flag] && argv[index + 1] !== undefined && !argv[index + 1].startsWith('--')) {
      options[valued[flag]] = argv[index + 1];
      index += 1;
    } else fail(USAGE);
  }
  if (!options.repo || !options.bundleBefore || !options.bundleAfter || !options.out) fail(USAGE);
  if (!options.plantedOnly && !options.check && !options.source) fail(USAGE);
  if (!/^\d+$/.test(String(options.seed))) fail(`select: --seed must be a non-negative integer: ${options.seed}`);
  options.seed = Number(options.seed);
  return options;
};

const readJson = (path, what) => {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    return fail(`select: cannot read ${what} ${path}: ${error.message}`);
  }
};

const activeMembers = (repo) =>
  new Set(
    git(repo, 'ls-tree', '--name-only', 'refs/remotes/origin/main', '.claude/agents/')
      .split('\n')
      .map((path) => /^\.claude\/agents\/(code-audit-[\w-]+)\.md$/.exec(path)?.[1])
      .filter((member) => member && !RETIRED_MEMBERS.has(member)),
  );

const entryId = (record) =>
  `real-${record.member.replace(/^code-audit-/, '')}-${createHash('sha256').update([record.session, record.agent_id, record.path, record.line, record.title].join('\u001f')).digest('hex').slice(0, 10)}`;

const classPrefix = (findingClass) => String(findingClass ?? '').split('/')[0];

// One dry build per (bundle, base, head): every entry of one change shares it.
const buildCache = new Map();

const dryBuild = (repo, bundle, base, head, path, line) => {
  const key = [bundle, base, head].join(' ');
  if (!buildCache.has(key)) {
    const parent = mkdtempSync(join(tmpdir(), 'audit-recall-build-'));
    const clone = join(parent, 'tree');
    const run = spawnSync('bash', [BUILD_TREE, '--repo', repo, '--bundle', bundle, '--base', base, '--head', head, '--clone', clone], { encoding: 'utf8' });
    let outcome;
    if (run.status === 0) {
      outcome = { ok: true, clone, parent };
    } else {
      const token = /build-tree: failed: (\S+)/.exec(run.stderr ?? '')?.[1] ?? `build-exit-${run.status}`;
      outcome = { ok: false, reason: token };
      rmSync(parent, { recursive: true, force: true });
    }
    buildCache.set(key, outcome);
  }
  const outcome = buildCache.get(key);
  if (!outcome.ok) return outcome;
  const mapped = mapLine(outcome.clone, head, 'replay', path, line);
  // null: the overlay rewrote the line, or the path is absent at the head or in
  // the replay tree.
  return mapped === null ? { ok: false, reason: 'line-unmappable' } : { ok: true, line: mapped };
};

const releaseBuilds = () => {
  for (const outcome of buildCache.values()) if (outcome.ok) rmSync(outcome.parent, { recursive: true, force: true });
  buildCache.clear();
};

// Both bundles must build, and the finding's line must sit on the same line of
// both replay trees as at the head: an entry carries one line, and a line the
// overlay moved or rewrote would be scored against the wrong code.
const buildBoth = (options, entry) => {
  for (const [label, bundle] of [
    ['before', options.bundleBefore],
    ['after', options.bundleAfter],
  ]) {
    const built = dryBuild(options.repo, bundle, entry.base_sha, entry.head_sha, entry.path, entry.line);
    if (!built.ok) return { ok: false, reason: `${built.reason} (${label})` };
    if (built.line !== entry.line) return { ok: false, reason: `line-moved-by-overlay (${label})` };
  }
  return { ok: true };
};

const plantedEntries = () => (existsSync(PLANTED_ENTRIES) ? readJson(PLANTED_ENTRIES, 'planted entries') : []);

const writeCorpus = (options, entries, skipped) => {
  const corpus = {
    schema: 1,
    seed: options.seed,
    selected_against: mainSha(options.repo),
    selection_bundles: { before: git(options.repo, 'rev-parse', `${options.bundleBefore}^{commit}`), after: git(options.repo, 'rev-parse', `${options.bundleAfter}^{commit}`) },
    entries: [...entries, ...plantedEntries()],
    skipped,
  };
  writeFileSync(options.out, `${JSON.stringify(corpus, null, 2)}\n`);
};

const select = (options) => {
  const members = activeMembers(options.repo);
  const source = options.plantedOnly ? [] : readJson(options.source, 'mined findings');
  if (!Array.isArray(source)) fail(`select: ${options.source} is not a JSON array`);
  const skipped = [];
  const eligible = [];
  for (const record of source) {
    if (!ELIGIBLE_SEVERITIES.has(record?.severity) || !members.has(record?.member)) continue;
    if (typeof record.path !== 'string' || !Number.isInteger(record.line) || typeof record.head_sha !== 'string') continue;
    const id = entryId(record);
    if (!isAncestor(options.repo, record.head_sha, 'refs/remotes/origin/main')) {
      skipped.push({ id, member: record.member, reason: 'unreachable' });
      continue;
    }
    if (LOCAL_REFERENCE.test(record.title ?? '')) {
      skipped.push({ id, member: record.member, reason: 'title-carries-local-reference' });
      continue;
    }
    eligible.push({ id, record });
  }
  const shuffled = seededShuffle(eligible, options.seed);
  const kept = new Map();
  const entries = [];
  for (const { id, record } of shuffled) {
    const count = kept.get(record.member) ?? 0;
    if (count >= PER_MEMBER) continue;
    const head = resolveHead(options.repo, record.head_sha, record.path, record.ts ?? null);
    if (head === null) {
      skipped.push({ id, member: record.member, reason: 'head-unresolved' });
      continue;
    }
    // A finding re-reported in a later round, or a second finding on the same
    // lines, is scored by the same path, line window and class: one entry.
    const twin = entries.find(
      (entry) => entry.member === record.member && entry.head_sha === head && entry.path === record.path && Math.abs(entry.line - record.line) <= LINE_WINDOW && entry.class_prefix === classPrefix(record.class),
    );
    if (twin) {
      skipped.push({ id, member: record.member, reason: `duplicate-of ${twin.id}` });
      continue;
    }
    const base = baseShaFor(options.repo, head);
    if (base === null) {
      skipped.push({ id, member: record.member, reason: 'base-unresolvable' });
      continue;
    }
    const built = buildBoth(options, { head_sha: head, base_sha: base, path: record.path, line: record.line });
    if (!built.ok) {
      skipped.push({ id, member: record.member, reason: built.reason });
      continue;
    }
    kept.set(record.member, count + 1);
    entries.push({
      id,
      source: 'real',
      member: record.member,
      scorer: 'member',
      path: record.path,
      line: record.line,
      class_prefix: classPrefix(record.class),
      head_sha: head,
      base_sha: base,
      origin: { session: record.session, agent_id: record.agent_id, title: record.title },
    });
  }
  releaseBuilds();
  writeCorpus(options, entries, skipped);
  const summary = {};
  for (const entry of entries) summary[entry.member] = (summary[entry.member] ?? 0) + 1;
  process.stdout.write(`${JSON.stringify({ kept: summary, skipped: skipped.length })}\n`);
};

const check = (options) => {
  const corpus = readJson(options.out, 'corpus');
  const failures = [];
  for (const entry of (corpus.entries ?? []).filter((candidate) => candidate.source === 'real')) {
    const built = buildBoth(options, entry);
    if (!built.ok) failures.push(`${entry.id}: ${built.reason}`);
  }
  releaseBuilds();
  for (const failure of failures) process.stdout.write(`check: ${failure}\n`);
  process.exit(failures.length > 0 ? 2 : 0);
};

const options = parseArguments(process.argv.slice(2));
try {
  git(options.repo, 'rev-parse', '--verify', 'refs/remotes/origin/main^{commit}');
} catch {
  fail(`select: --repo has no origin/main: ${options.repo}`);
}
for (const bundle of [options.bundleBefore, options.bundleAfter]) {
  try {
    git(options.repo, 'rev-parse', '--verify', `${bundle}^{commit}`);
  } catch {
    fail(`select: bundle ${bundle} is not a commit in ${options.repo}`);
  }
}
if (options.check) check(options);
else select(options);
