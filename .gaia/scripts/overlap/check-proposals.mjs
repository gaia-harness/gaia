#!/usr/bin/env node
// The deterministic half of the overlap pass: layer mapping and the proposal
// check. overlap-check.sh is the caller; it owns the base, the authorship
// answer and the printed shape. This file is the one owner of the layer table
// and the seam list.
//
// Usage:
//   node check-proposals.mjs layer --root <tree> --package-dir <dir>   (NUL-separated paths on stdin)
//   node check-proposals.mjs check --root <tree> --proposals <file>
//        [--package-dir <dir>] [--post-fix]
//
// layer prints a JSON array of {file, layer} for the stdin paths that sit on a
// layer; it reads each Playwright spec under --root to tell real-server from
// browser. check prints {"kept":[...],"discarded":[...]}; a kept element still
// carries the private fields _ranges, _rendered and _present that the caller
// turns into a disposition and removes.
//
// Exit codes: 0 success, 2 usage, 3 unreadable input or no TypeScript.
//
// A citation is verified through the signal extractor, which already resolves
// test and story files, plus the resolvers in citations.mjs: a test with the
// cited fullName exists, the cited line is inside its ranges, and the
// assertion text sits on that line outside a comment. Whether the sibling
// asserts the same property is not decided here.
//
// A demote may name no sibling: `target` carries the subject's own assertion
// lines and the real-server layer it moves to, because the lower test does not
// exist until the fixer writes it. At --post-fix such an entry must carry
// `replacement`, the fixer's new test, which is verified like a sibling and
// must itself open no page.

import {createRequire} from 'node:module';
import {existsSync, readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {loadStems, pathIsSeam, subjectIsSeam} from './test-inspection.mjs';
import {hookSpansOf, isRendered, locateTests, maskComments, verifyCitation} from './citations.mjs';
import {pageUsesOf} from '../spec/page-use.mjs';

const require = createRequire(import.meta.url);
const extractorPath = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  'red-ledger',
  'extract-test-signals.mjs',
);

const fail = (code, message) => {
  process.stderr.write(`overlap-check: ${message}\n`);
  process.exit(code);
};

let ts;
try {
  ts = require('typescript');
} catch {
  fail(3, 'cannot resolve "typescript" from node_modules');
}

const argv = process.argv.slice(2);
const subcommand = argv.shift();
const options = {postFix: false};
for (let index = 0; index < argv.length; index += 1) {
  const argument = argv[index];
  if (argument === '--post-fix') {
    options.postFix = true;
  } else if (['--root', '--proposals', '--package-dir'].includes(argument)) {
    if (index + 1 >= argv.length) fail(2, `${argument} needs a value`);
    options[argument.slice(2)] = argv[index + 1];
    index += 1;
  } else {
    fail(2, `unknown argument ${argument}`);
  }
}

// Layers ----------------------------------------------------------------------

const LAYER_NAMES = {1: 'unit', 2: 'route', 3: 'real-server', 4: 'browser'};
const LAYER_RANKS = {unit: 1, route: 2, 'real-server': 3, browser: 4};
const REAL_SERVER = 3;
const BROWSER = 4;
// The highest rank a seam's sibling must reach: a served refusal shows on the
// real-server layer, so a browser seam may move there and no lower.
const SEAM_CEILING = REAL_SERVER;

const packagePrefix =
  options['package-dir'] === undefined
    ? null
    : options['package-dir'] === '' || options['package-dir'] === '.'
      ? ''
      : `${options['package-dir'].replace(/\/+$/, '')}/`;

const packageRelative = (file) => {
  if (packagePrefix === null) return null;
  if (packagePrefix === '') return file;
  return file.startsWith(packagePrefix) ? file.slice(packagePrefix.length) : null;
};

// Rank 1 unit and story, 2 route, then a Playwright spec, which is real-server
// (3) when it opens no page and browser (4) when it does. The route test folder
// is not a unit layer even for a .tsx test the route glob does not name.
const PLAYWRIGHT = 'playwright';
const RANK_PATTERNS = [
  [PLAYWRIGHT, /^\.playwright\/(.+\/)?[^/]+\.spec\.ts$/],
  [2, /^app\/route-tests\/(.+\/)?[^/]+\.test\.ts$/],
  [2, /^test\/(.+\/)?[^/]+\.server\.test\.ts$/],
  [1, /^app\/(.+\/)?[^/]+\.stories\.tsx$/],
  [1, /^app\/(?!route-tests\/)(.+\/)?[^/]+\.test\.tsx?$/],
  [1, /^test\/(.+\/)?[^/]+\.test\.tsx?$/],
];

const pathRankOf = (file) => {
  const relative = packageRelative(file);
  if (relative === null) return null;
  for (const [rank, pattern] of RANK_PATTERNS) {
    if (pattern.test(relative)) return rank;
  }
  return null;
};

// A file-level layer: any page use anywhere in the spec makes it browser, and
// an unreadable spec is browser, the rank that clears the fewest proposals.
const rankOf = (file) => {
  const rank = pathRankOf(file);
  if (rank !== PLAYWRIGHT) return rank;
  const parsed = parseFile(file);
  return parsed !== null && pageUsesOf(ts, parsed.sourceFile).length === 0 ? REAL_SERVER : BROWSER;
};

// Files -----------------------------------------------------------------------

const fileCache = new Map();
const parseCache = new Map();
let rootDirectory = null;

const isSafeRelative = (file) =>
  typeof file === 'string' &&
  file.length > 0 &&
  !file.startsWith('/') &&
  !file.includes('\0') &&
  !file.split('/').includes('..');

function parseFile(file) {
  if (parseCache.has(file)) return parseCache.get(file);
  let parsed = null;
  if (rootDirectory !== null && isSafeRelative(file) && existsSync(path.join(rootDirectory, file))) {
    try {
      const source = readFileSync(path.join(rootDirectory, file), 'utf8');
      const kind = /\.tsx$/i.test(file) ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
      parsed = {source, sourceFile: ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, kind)};
    } catch {
      parsed = null;
    }
  }
  parseCache.set(file, parsed);
  return parsed;
}

function loadFile(file) {
  if (fileCache.has(file)) return fileCache.get(file);
  let entry = null;
  const parsed = parseFile(file);
  if (parsed !== null) {
    try {
      const {source, sourceFile} = parsed;
      const extracted = spawnSync(process.execPath, [extractorPath, file], {cwd: rootDirectory, encoding: 'utf8'});
      let tests = null;
      if (extracted.status === 0) {
        tests = extracted.stdout
          .split('\n')
          .filter((line) => line.length > 0)
          .map((line) => JSON.parse(line))
          .map((test) => ({
            ...test,
            ranges: test.ranges?.length > 0 ? test.ranges : [[test.firstLine, test.firstLine]],
          }));
      }
      entry = {
        source,
        sourceFile,
        tests,
        isStories: /\.stories\.tsx?$/.test(file),
        rawLines: source.split('\n'),
        maskedLines: maskComments(sourceFile, source).split('\n'),
        calls: null,
      };
    } catch {
      entry = null;
    }
  }
  fileCache.set(file, entry);
  return entry;
}

// The check -------------------------------------------------------------------

const KINDS = new Set(['drop', 'merge', 'demote', 'keep-both']);
const REMOVING = new Set(['drop', 'merge', 'demote']);
const nonEmpty = (value) => typeof value === 'string' && value.trim().length > 0;
const keyOf = (file, fullName) => `${file}\u0000${fullName}`;
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const isLine = (value) => Number.isInteger(value) && value >= 1;
const isCitation = (c) => isObject(c) && isSafeRelative(c.file) && isLine(c.line) && nonEmpty(c.fullName) && nonEmpty(c.assertion);
const isTarget = (t) =>
  isObject(t) &&
  nonEmpty(t.layer) &&
  Array.isArray(t.assertions) &&
  t.assertions.length > 0 &&
  t.assertions.every((a) => isObject(a) && isLine(a.line) && nonEmpty(a.assertion));

// Exactly one of sibling and target; a target only on a demote.
function wellFormed(p) {
  if (!isObject(p)) return false;
  if (!KINDS.has(p.proposal) || !isSafeRelative(p.file) || !nonEmpty(p.fullName)) return false;
  if (typeof p.seam !== 'boolean' || !nonEmpty(p.property) || !nonEmpty(p.actor) || !nonEmpty(p.action)) return false;
  if ((p.sibling === undefined) === (p.target === undefined)) return false;
  if (p.target !== undefined) return p.proposal === 'demote' && isTarget(p.target);
  return isCitation(p.sibling);
}

// At --post-fix a kept browser entry keeps its recorded layer: the fixer may
// have rewritten the subject's file as request-only in place.
const subjectRankOf = (p) =>
  options.postFix && pathRankOf(p.file) === PLAYWRIGHT && (p.layer === 'browser' || p.layer === 'real-server')
    ? LAYER_RANKS[p.layer]
    : rankOf(p.file);

// A per-test layer: a Playwright test is real-server unless a page use sits in
// its own range or a hook, or the file imports a browser launcher. Another test
// in the same file that opens a page does not move this one.
function testRankOf(file, test) {
  const rank = pathRankOf(file);
  if (rank !== PLAYWRIGHT) return rank;
  const entry = loadFile(file);
  if (entry === null) return BROWSER;
  const spans = [...test.ranges, ...hookSpansOf(entry)];
  const opens = pageUsesOf(ts, entry.sourceFile).some(
    (use) => use.reason === 'browser-import' || spans.some(([start, end]) => start <= use.line && use.line <= end),
  );
  return opens ? BROWSER : REAL_SERVER;
}

// The sibling-less demote: null and the rank the property moves to when it
// verifies, else the discard reason.
function checkTarget(p, subjectRank) {
  if (p.target.layer !== 'real-server' || subjectRank !== BROWSER) return {reason: 'target-not-below-subject'};
  if (!options.postFix) {
    const entry = loadFile(p.file);
    for (const assertion of p.target.assertions) {
      const {reason} = verifyCitation(entry, {fullName: p.fullName, ...assertion}, false);
      if (reason !== null) return {reason};
    }
    return {reason: null, rank: REAL_SERVER};
  }
  if (!isCitation(p.replacement)) return {reason: 'replacement-missing'};
  const {reason, test} = verifyCitation(loadFile(p.replacement.file), p.replacement, true);
  if (reason !== null) return {reason};
  const rank = testRankOf(p.replacement.file, test);
  return rank === REAL_SERVER ? {reason: null, rank} : {reason: 'replacement-wrong-layer'};
}

function runCheck() {
  if (!options.root || !options.proposals) fail(2, 'check needs --root and --proposals');
  rootDirectory = path.resolve(options.root);
  let proposals;
  try {
    proposals = JSON.parse(readFileSync(options.proposals, 'utf8'));
  } catch (error) {
    fail(3, `cannot read ${options.proposals} as JSON: ${error.message}`);
  }
  if (!Array.isArray(proposals)) fail(3, `${options.proposals} is not a JSON array`);
  const stems = loadStems(rootDirectory);

  const discarded = [];
  let survivors = [];
  for (const p of proposals) {
    if (!wellFormed(p)) {
      discarded.push({...(p !== null && typeof p === 'object' && !Array.isArray(p) ? p : {value: p}), reason: 'malformed'});
      continue;
    }
    const refuse = (reason) => discarded.push({...p, reason});

    // A subject that is not a test, or sits on no layer, goes before the seam
    // rule: otherwise a wrong name would skip the seam scan.
    const subjectEntry = loadFile(p.file);
    const subject = locateTests(subjectEntry, p.fullName)[0] ?? null;
    if (!subject && !options.postFix) {
      refuse('subject-not-found');
      continue;
    }
    const subjectRank = subjectRankOf(p);
    if (subjectRank === null) {
      refuse('subject-no-layer');
      continue;
    }
    let coverRank;
    if (p.target !== undefined) {
      const target = checkTarget(p, subjectRank);
      if (target.reason !== null) {
        refuse(target.reason);
        continue;
      }
      coverRank = target.rank;
    } else {
      coverRank = rankOf(p.sibling.file);
      if (coverRank === null) {
        refuse('sibling-no-layer');
        continue;
      }
      if (p.sibling.file === p.file && p.sibling.fullName === p.fullName) {
        refuse('self-citation');
        continue;
      }
      const {reason} = verifyCitation(loadFile(p.sibling.file), p.sibling, options.postFix);
      if (reason !== null) {
        refuse(reason);
        continue;
      }
    }
    const effectiveSeam =
      p.seam || pathIsSeam(packageRelative(p.file) ?? p.file) || (subject !== null && subjectIsSeam(subjectEntry, subject, stems));
    if (REMOVING.has(p.proposal) && effectiveSeam && coverRank < Math.min(subjectRank, SEAM_CEILING)) {
      refuse('seam-no-sibling-at-or-above');
      continue;
    }
    if (p.proposal === 'keep-both' && !nonEmpty(p.bug)) {
      refuse('no-distinguishing-bug');
      continue;
    }
    survivors.push({
      proposal: p,
      subjectKey: keyOf(p.file, p.fullName),
      siblingKey: p.sibling === undefined ? null : keyOf(p.sibling.file, p.sibling.fullName),
      kept: {
        ...p,
        seam: effectiveSeam,
        layer: LAYER_NAMES[subjectRank],
        ...(p.sibling === undefined ? {targetLayer: LAYER_NAMES[coverRank]} : {siblingLayer: LAYER_NAMES[coverRank]}),
        _ranges: subject ? subject.ranges : null,
        _rendered: subject ? isRendered(subjectEntry) : false,
        _present: subject !== null,
      },
    });
  }

  // Fixed point: every round judges against the set the round started with, so
  // the outcome does not depend on proposal order.
  for (;;) {
    const mutual = new Set();
    const removed = new Set();
    for (const a of survivors) {
      for (const b of survivors) {
        if (a !== b && a.siblingKey !== null && a.siblingKey === b.subjectKey && b.siblingKey === a.subjectKey) mutual.add(a);
      }
    }
    for (const a of survivors) {
      if (mutual.has(a) || a.siblingKey === null) continue;
      const taken = survivors.some((b) => b !== a && REMOVING.has(b.proposal.proposal) && b.subjectKey === a.siblingKey);
      if (taken) removed.add(a);
    }
    if (mutual.size === 0 && removed.size === 0) break;
    for (const a of mutual) discarded.push({...a.proposal, reason: 'mutual-citation'});
    for (const a of removed) discarded.push({...a.proposal, reason: 'sibling-removed'});
    survivors = survivors.filter((a) => !mutual.has(a) && !removed.has(a));
  }

  process.stdout.write(`${JSON.stringify({kept: survivors.map((a) => a.kept), discarded})}\n`);
  process.exitCode = 0;
}

process.stdout.on('error', (error) => {
  if (error.code === 'EPIPE') process.exit(0);
  throw error;
});

if (subcommand === 'layer') {
  const lines = readFileSync(0, 'utf8').split('\0').filter((line) => line.length > 0);
  const rows = [];
  if (options.root) rootDirectory = path.resolve(options.root);
  for (const file of lines) {
    const rank = rankOf(file);
    if (rank !== null) rows.push({file, layer: LAYER_NAMES[rank]});
  }
  process.stdout.write(`${JSON.stringify(rows)}\n`);
  process.exitCode = 0;
} else if (subcommand === 'check') {
  runCheck();
} else {
  fail(2, 'usage: check-proposals.mjs layer|check ...');
}
