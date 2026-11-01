#!/usr/bin/env node
// The deterministic half of the overlap pass: layer mapping and the proposal
// check. overlap-check.sh is the caller; it owns the base, the authorship
// answer and the printed shape. This file is the one owner of the layer table
// and the seam list.
//
// Usage:
//   node check-proposals.mjs layer --package-dir <dir>      (NUL-separated paths on stdin)
//   node check-proposals.mjs check --root <tree> --proposals <file>
//        [--package-dir <dir>] [--post-fix]
//
// layer prints a JSON array of {file, layer} for the stdin paths that sit on a
// layer. check prints {"kept":[...],"discarded":[...]}; a kept element still
// carries the private fields _ranges, _rendered and _present that the caller
// turns into a disposition and removes.
//
// Exit codes: 0 success, 2 usage, 3 unreadable input or no TypeScript.
//
// A citation is verified through the signal extractor, which already resolves
// test and story files: a test with the cited fullName exists, the cited line
// is inside its ranges, and the assertion text sits on that line outside a
// comment. Whether the sibling asserts the same property is not decided here.

import {createRequire} from 'node:module';
import {existsSync, readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

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

const LAYER_NAMES = {1: 'unit', 2: 'route', 3: 'e2e'};

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

// Rank 1 unit and story, 2 route, 3 e2e. The route test folder is not a unit
// layer even for a .tsx test the route glob does not name.
const RANK_PATTERNS = [
  [3, /^\.playwright\/(.+\/)?[^/]+\.spec\.ts$/],
  [2, /^app\/route-tests\/(.+\/)?[^/]+\.test\.ts$/],
  [2, /^test\/(.+\/)?[^/]+\.server\.test\.ts$/],
  [1, /^app\/(.+\/)?[^/]+\.stories\.tsx$/],
  [1, /^app\/(?!route-tests\/)(.+\/)?[^/]+\.test\.tsx?$/],
  [1, /^test\/(.+\/)?[^/]+\.test\.tsx?$/],
];

const rankOf = (file) => {
  const relative = packageRelative(file);
  if (relative === null) return null;
  for (const [rank, pattern] of RANK_PATTERNS) {
    if (pattern.test(relative)) return rank;
  }
  return null;
};

// Seams -----------------------------------------------------------------------

const BUILT_IN_STEMS = [
  'auth', 'session', 'login', 'permission', 'role', 'owner', 'forbid', 'refus',
  'deny', 'deni', 'hide', 'hid', 'hidden', 'forg', 'csrf', 'escap', 'sanitiz',
  'inject', 'transaction', 'integrity',
];
const REFUSAL_STATUS_WORDS = new Set(['401', '403', '404']);
const REFUSAL_HELPER_NAME =
  /refus|deny|deni|forbid|notfound|not_found|unauthori[sz]ed|unauthenticated/i;
const BY_ROLE_CALL = /^(get|query|find)(All)?ByRole$/;

const wordsOf = (text) =>
  text
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    .split(/[^A-Za-z0-9]+/)
    .filter((word) => word.length > 0)
    .map((word) => word.toLowerCase());

// A project word list only ever adds to the built-in stems.
const loadStems = (root) => {
  const stems = [...BUILT_IN_STEMS];
  const extra = path.join(root, '.gaia', 'overlap-seams.txt');
  if (existsSync(extra)) {
    for (const line of readFileSync(extra, 'utf8').split('\n')) {
      const word = line.trim().toLowerCase();
      if (word.length > 0 && !word.startsWith('#')) stems.push(word);
    }
  }
  return stems;
};

const wordsHitSeam = (words, stems) =>
  words.some((word) => REFUSAL_STATUS_WORDS.has(word) || stems.some((stem) => word.includes(stem))) ||
  /\bnot found\b/.test(words.join(' '));

const pathIsSeam = (file) => /auth|session/i.test(file);

// Files -----------------------------------------------------------------------

const fileCache = new Map();
let rootDirectory = '';

const isSafeRelative = (file) =>
  typeof file === 'string' &&
  file.length > 0 &&
  !file.startsWith('/') &&
  !file.includes('\0') &&
  !file.split('/').includes('..');

function commentSpansOf(sourceFile, source) {
  const raw = [];
  const walkTokens = (node) => {
    const children = node.getChildren(sourceFile);
    if (children.length === 0) {
      for (const range of ts.getLeadingCommentRanges(source, node.getFullStart()) ?? []) raw.push([range.pos, range.end]);
      for (const range of ts.getTrailingCommentRanges(source, node.getEnd()) ?? []) raw.push([range.pos, range.end]);
      return;
    }
    for (const child of children) walkTokens(child);
  };
  walkTokens(sourceFile);
  // JSX text that looks like a comment is not one.
  const jsxText = [];
  const findJsxText = (node) => {
    if (node.kind === ts.SyntaxKind.JsxText) jsxText.push([node.pos, node.end]);
    ts.forEachChild(node, findJsxText);
  };
  ts.forEachChild(sourceFile, findJsxText);
  return raw.filter(([a, b]) => !jsxText.some(([x, y]) => a < y && x < b));
}

function loadFile(file) {
  if (fileCache.has(file)) return fileCache.get(file);
  let entry = null;
  const absolute = path.join(rootDirectory, file);
  if (isSafeRelative(file) && existsSync(absolute)) {
    try {
      const source = readFileSync(absolute, 'utf8');
      const sourceFile = ts.createSourceFile(
        file,
        source,
        ts.ScriptTarget.Latest,
        true,
        /\.tsx$/i.test(file) ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
      );
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
      const spans = commentSpansOf(sourceFile, source);
      let masked = '';
      let cursor = 0;
      for (const [a, b] of [...spans].sort((p, q) => p[0] - q[0])) {
        if (a < cursor) continue;
        masked += source.slice(cursor, a) + source.slice(a, b).replace(/[^\n]/g, ' ');
        cursor = b;
      }
      masked += source.slice(cursor);
      entry = {
        source,
        sourceFile,
        tests,
        isStories: /\.stories\.tsx?$/.test(file),
        rawLines: source.split('\n'),
        maskedLines: masked.split('\n'),
        calls: null,
      };
    } catch {
      entry = null;
    }
  }
  fileCache.set(file, entry);
  return entry;
}

const lineAt = (entry, position) => entry.sourceFile.getLineAndCharacterOfPosition(position).line + 1;

const testsNamed = (entry, fullName) => (entry?.tests ?? []).filter((test) => test.fullName === fullName);
const rangesHold = (test, line) => test.ranges.some(([start, end]) => start <= line && line <= end);

// Skips -----------------------------------------------------------------------

const SKIP_PROPERTIES = new Set(['skip', 'todo', 'fixme']);
const SKIP_ROOTS = new Set(['xit', 'xtest', 'xdescribe']);
const STRUCTURAL_ROOTS = new Set(['test', 'it', 'describe', 'suite']);

function calleeShape(node) {
  let expression = node.expression;
  for (;;) {
    if (ts.isCallExpression(expression)) expression = expression.expression;
    else if (ts.isTaggedTemplateExpression(expression)) expression = expression.tag;
    else break;
  }
  const properties = [];
  while (ts.isPropertyAccessExpression(expression)) {
    properties.push(expression.name.text);
    expression = expression.expression;
  }
  return {root: ts.isIdentifier(expression) ? expression.text : null, properties};
}

const callsOf = (entry) => {
  if (entry.calls === null) {
    entry.calls = [];
    const collect = (node) => {
      if (ts.isCallExpression(node)) entry.calls.push(node);
      ts.forEachChild(node, collect);
    };
    collect(entry.sourceFile);
  }
  return entry.calls;
};

function isSkipped(entry, test) {
  const region = entry.isStories ? test.ranges[test.ranges.length - 1] : test.ranges[0];
  const call = callsOf(entry).find(
    (node) =>
      lineAt(entry, node.getStart(entry.sourceFile)) === region[0] && lineAt(entry, node.getEnd() - 1) === region[1],
  );
  if (!call) return false;
  const own = calleeShape(call);
  if (SKIP_ROOTS.has(own.root)) return true;
  if (own.properties.some((name) => SKIP_PROPERTIES.has(name)) && (STRUCTURAL_ROOTS.has(own.root) || own.properties.includes('test'))) {
    return true;
  }
  for (let ancestor = call.parent; ancestor; ancestor = ancestor.parent) {
    if (!ts.isCallExpression(ancestor)) continue;
    const shape = calleeShape(ancestor);
    if (SKIP_ROOTS.has(shape.root)) return true;
    if (STRUCTURAL_ROOTS.has(shape.root) && shape.properties.some((name) => SKIP_PROPERTIES.has(name))) return true;
  }
  // An unconditional test.skip() or test.fixme() in the body skips the test.
  let bodySkips = false;
  const scan = (node) => {
    if (ts.isCallExpression(node) && node !== call && node.arguments.length === 0) {
      const shape = calleeShape(node);
      if (shape.root === 'test' && shape.properties.length === 1 && ['skip', 'fixme'].includes(shape.properties[0])) {
        bodySkips = true;
      }
    }
    ts.forEachChild(node, scan);
  };
  scan(call);
  return bodySkips;
}

// Citations -------------------------------------------------------------------

const collapse = (text) => text.replace(/\s+/g, ' ').trim();
const holdsText = (line, needle) => line !== undefined && (line.includes(needle) || collapse(line).includes(collapse(needle)));

// null when the sibling is verified, else the discard reason.
function verifySibling(sibling) {
  const entry = loadFile(sibling.file);
  const candidates = testsNamed(entry, sibling.fullName);
  if (candidates.length === 0) return 'citation-unverified';
  const needle = sibling.assertion;
  if (!options.postFix) {
    if (!holdsText(entry.rawLines[sibling.line - 1], needle)) return 'citation-unverified';
    if (!holdsText(entry.maskedLines[sibling.line - 1], needle)) return 'citation-not-live';
    const test = candidates.find((candidate) => rangesHold(candidate, sibling.line));
    if (!test) return 'citation-unverified';
    return isSkipped(entry, test) ? 'citation-not-live' : null;
  }
  // The recorded line may have moved under a same-file edit, so look for the
  // text anywhere in the named test.
  let notLive = false;
  for (const test of candidates) {
    for (const [start, end] of test.ranges) {
      for (let line = start; line <= end; line += 1) {
        if (holdsText(entry.maskedLines[line - 1], needle)) {
          if (!isSkipped(entry, test)) return null;
          notLive = true;
        } else if (holdsText(entry.rawLines[line - 1], needle)) {
          notLive = true;
        }
      }
    }
  }
  return notLive ? 'citation-not-live' : 'citation-unverified';
}

// Subject seam scan -----------------------------------------------------------

function subjectIsSeam(entry, test, stems) {
  const found = [];
  let helperHit = false;
  const inside = (node) => {
    const line = lineAt(entry, node.getStart(entry.sourceFile));
    return test.ranges.some(([start, end]) => start <= line && line <= end);
  };
  const visit = (node) => {
    if (ts.isCallExpression(node)) {
      const callee = node.expression;
      const name = ts.isIdentifier(callee) ? callee.text : ts.isPropertyAccessExpression(callee) ? callee.name.text : null;
      // getByRole('button', {name}) names an accessibility role, not a
      // permission: drop the call with its arguments, keep what it hangs off.
      if (name !== null && BY_ROLE_CALL.test(name)) {
        if (ts.isPropertyAccessExpression(callee)) visit(callee.expression);
        return;
      }
      if (name !== null && inside(node) && REFUSAL_HELPER_NAME.test(name)) helperHit = true;
    }
    const textual =
      ts.isIdentifier(node) ||
      ts.isStringLiteral(node) ||
      ts.isNoSubstitutionTemplateLiteral(node) ||
      ts.isNumericLiteral(node) ||
      node.kind === ts.SyntaxKind.TemplateHead ||
      node.kind === ts.SyntaxKind.TemplateMiddle ||
      node.kind === ts.SyntaxKind.TemplateTail;
    if (textual && inside(node)) found.push(node.text);
    ts.forEachChild(node, visit);
  };
  visit(entry.sourceFile);
  const words = [...wordsOf(test.fullName), ...found.flatMap(wordsOf)];
  return helperHit || wordsHitSeam(words, stems);
}

// The check -------------------------------------------------------------------

const KINDS = new Set(['drop', 'merge', 'demote', 'keep-both']);
const REMOVING = new Set(['drop', 'merge', 'demote']);
const nonEmpty = (value) => typeof value === 'string' && value.trim().length > 0;
const MARKER = /^\/\/ gaia-uat-contract sha256:/;
const keyOf = (file, fullName) => `${file}\u0000${fullName}`;

function wellFormed(p) {
  if (p === null || typeof p !== 'object' || Array.isArray(p)) return false;
  if (!KINDS.has(p.proposal) || !isSafeRelative(p.file) || !nonEmpty(p.fullName)) return false;
  if (typeof p.seam !== 'boolean' || !nonEmpty(p.property) || !nonEmpty(p.actor) || !nonEmpty(p.action)) return false;
  const s = p.sibling;
  if (s === null || typeof s !== 'object' || Array.isArray(s)) return false;
  return isSafeRelative(s.file) && Number.isInteger(s.line) && s.line >= 1 && nonEmpty(s.fullName) && nonEmpty(s.assertion);
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
    const subject = testsNamed(subjectEntry, p.fullName)[0] ?? null;
    if (!subject && !options.postFix) {
      refuse('subject-not-found');
      continue;
    }
    const subjectRank = rankOf(p.file);
    if (subjectRank === null) {
      refuse('subject-no-layer');
      continue;
    }
    const siblingRank = rankOf(p.sibling.file);
    if (siblingRank === null) {
      refuse('sibling-no-layer');
      continue;
    }
    if (p.sibling.file === p.file && p.sibling.fullName === p.fullName) {
      refuse('self-citation');
      continue;
    }
    const citation = verifySibling(p.sibling);
    if (citation !== null) {
      refuse(citation);
      continue;
    }
    const effectiveSeam =
      p.seam || pathIsSeam(packageRelative(p.file) ?? p.file) || (subject !== null && subjectIsSeam(subjectEntry, subject, stems));
    if (REMOVING.has(p.proposal) && effectiveSeam && siblingRank < subjectRank) {
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
      siblingKey: keyOf(p.sibling.file, p.sibling.fullName),
      kept: {
        ...p,
        seam: effectiveSeam,
        layer: LAYER_NAMES[subjectRank],
        siblingLayer: LAYER_NAMES[siblingRank],
        _ranges: subject ? subject.ranges : null,
        _rendered: subject ? MARKER.test(subjectEntry.rawLines[0] ?? '') : false,
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
        if (a !== b && a.siblingKey === b.subjectKey && b.siblingKey === a.subjectKey) mutual.add(a);
      }
    }
    for (const a of survivors) {
      if (mutual.has(a)) continue;
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
