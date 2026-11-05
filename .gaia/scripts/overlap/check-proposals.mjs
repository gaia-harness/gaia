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
// carries the private fields _ranges, _rendered and _present (a fold-up:
// _subjects, [{file, ranges, rendered}]) and _needsNewTest that the caller
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
//
// The fold-up kind and the unit reason a removing proposal with a unit-test
// cover owes are described, with the shape checks and the fixed point, in
// fold-up.mjs.

import {createRequire} from 'node:module';
import {existsSync, readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {loadStems, pathIsSeam, subjectIsSeam} from './test-inspection.mjs';
import {hookSpansOf, isRendered, locateTests, maskComments, verifyCitation} from './citations.mjs';
import {
  REMOVING,
  checkFoldUp,
  isCitation,
  isSafeRelative,
  isStoryFile,
  keyOf,
  nonEmpty,
  settle,
  unitReasonProblem,
  wellFormed,
} from './fold-up.mjs';
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
// an unreadable spec is browser too: no citation in it can verify, so its rank
// clears nothing.
const rankOf = (file) => {
  const rank = pathRankOf(file);
  if (rank !== PLAYWRIGHT) return rank;
  const parsed = parseFile(file);
  return parsed !== null && pageUsesOf(ts, parsed.sourceFile, path.join(rootDirectory, file)).length === 0 ? REAL_SERVER : BROWSER;
};

// Files -----------------------------------------------------------------------

const fileCache = new Map();
const parseCache = new Map();
let rootDirectory = null;

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
  const opens = pageUsesOf(ts, entry.sourceFile, path.join(rootDirectory, file)).some(
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
  const seamOf = (flag, file, entry, test) =>
    flag || pathIsSeam(packageRelative(file) ?? file) || (test !== null && subjectIsSeam(entry, test, stems));
  const foldUpContext = {
    postFix: options.postFix,
    loadFile,
    rankOf,
    seamOf,
    seamCeiling: SEAM_CEILING,
    layerName: (rank, isStory) => (isStory ? 'story' : LAYER_NAMES[rank]),
  };

  const discarded = [];
  const survivors = [];
  for (const p of proposals) {
    if (!wellFormed(p)) {
      discarded.push({...(p !== null && typeof p === 'object' && !Array.isArray(p) ? p : {value: p}), reason: 'malformed'});
      continue;
    }
    const refuse = (reason) => discarded.push({...p, reason});
    if (p.proposal === 'fold-up') {
      const {reason, kept, subjectKeys, coverKey} = checkFoldUp(p, foldUpContext);
      if (reason === null) survivors.push({proposal: p, subjectKeys, coverKey, kept});
      else refuse(reason);
      continue;
    }

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
    // Null stays for a demote that needs a new test: it has no cover yet.
    let coverRank = null;
    if (p.target !== undefined) {
      const target = checkTarget(p, subjectRank);
      if (target.reason !== null) {
        refuse(target.reason);
        continue;
      }
      coverRank = target.rank;
    } else if (p.sibling !== undefined) {
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
    const effectiveSeam = seamOf(p.seam, p.file, subjectEntry, subject);
    if (REMOVING.has(p.proposal) && effectiveSeam && coverRank !== null && coverRank < Math.min(subjectRank, SEAM_CEILING)) {
      refuse('seam-no-sibling-at-or-above');
      continue;
    }
    const unitProblem = unitReasonProblem(p, subjectRank, coverRank, p.sibling !== undefined && isStoryFile(p.sibling.file));
    if (unitProblem !== null) {
      refuse(unitProblem);
      continue;
    }
    if (p.proposal === 'keep-both' && !nonEmpty(p.bug)) {
      refuse('no-distinguishing-bug');
      continue;
    }
    survivors.push({
      proposal: p,
      subjectKeys: [keyOf(p.file, p.fullName)],
      coverKey: p.sibling === undefined ? null : keyOf(p.sibling.file, p.sibling.fullName),
      kept: {
        ...p,
        seam: effectiveSeam,
        layer: LAYER_NAMES[subjectRank],
        ...(coverRank === null ? {} : p.sibling === undefined ? {targetLayer: LAYER_NAMES[coverRank]} : {siblingLayer: LAYER_NAMES[coverRank]}),
        _ranges: subject ? subject.ranges : null,
        _rendered: subject ? isRendered(subjectEntry) : false,
        _present: subject !== null,
        ...(p.needsNewTest === undefined ? {} : {_needsNewTest: true}),
      },
    });
  }

  const settled = settle(survivors, discarded);
  process.stdout.write(`${JSON.stringify({kept: settled.map((a) => a.kept), discarded})}\n`);
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
