// The drift check's inputs: the plan folder's table files, and each test file
// read at the branch's head (the working tree, or with `committed` HEAD, which
// the security check uses) and at the merge base, through
// the one test-identity extractor. Every unusable input throws a DriftRefusal
// whose code is the exit code test-drift-check.sh documents.

import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

import {
  batsEmpty,
  batsSkipped,
  caseTableLiterals,
  hasEmptyBody,
  isSkipped,
  typescriptModule,
} from './skip-detect.mjs';
import {readTable, validateRow} from './table.mjs';

export {isTestPath} from './table.mjs';

const EXTRACTOR = fileURLToPath(
  new URL('../test-signals/extract-test-signals.mjs', import.meta.url),
);
const OUTPUT_LIMIT = 64 * 1024 * 1024;

export class DriftRefusal extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const refuse = (message) => {
  throw new DriftRefusal(3, message);
};

const APPROVED_LINE = /^approved_sha256:\s*([0-9a-f]{64})\s*$/m;

export const hasMarker = (planDir) => existsSync(path.join(planDir, 'TEST-DESIGN'));

// {rows, approvedRows, ledger}: the current table, the approved copy (checked
// against the marker's hash), and the security writer's authorship lines.
export function loadPlan(planDir) {
  const marker = path.join(planDir, 'TEST-DESIGN');
  if (!existsSync(marker)) {
    throw new DriftRefusal(2, `no TEST-DESIGN marker in ${planDir}`);
  }
  const approvedPath = path.join(planDir, 'tests.approved.json');
  if (!existsSync(approvedPath)) {
    refuse('the marker has no approved copy: tests.approved.json is missing');
  }
  let approvedBytes;
  let markerText;
  try {
    approvedBytes = readFileSync(approvedPath);
    markerText = readFileSync(marker, 'utf8');
  } catch (error) {
    return refuse(`cannot read the approved copy or the marker: ${error.message}`);
  }
  const recorded = APPROVED_LINE.exec(markerText);
  if (!recorded) refuse('the marker carries no approved_sha256 line');
  const actual = createHash('sha256').update(approvedBytes).digest('hex');
  if (actual !== recorded[1]) {
    refuse("tests.approved.json does not match the marker's approved_sha256");
  }
  let approvedRows;
  let rows;
  try {
    approvedRows = readTable(approvedPath).rows;
  } catch (error) {
    return refuse(`unreadable approved copy: ${error.message}`);
  }
  try {
    rows = readTable(path.join(planDir, 'tests.json')).rows;
  } catch (error) {
    return refuse(`unreadable table: ${error.message}`);
  }
  rows.forEach((row, index) => {
    const reasons = validateRow(row);
    if (reasons.length > 0) {
      refuse(`unreadable table: row ${row?.id ?? `#${index + 1}`}: ${reasons.join('; ')}`);
    }
  });
  return {rows, approvedRows, ledger: readSecurityLedger(planDir)};
}

function readSecurityLedger(planDir) {
  const ledgerPath = path.join(planDir, 'security-tests.jsonl');
  if (!existsSync(ledgerPath)) return [];
  return readFileSync(ledgerPath, 'utf8')
    .split('\n')
    .filter((line) => line.trim() !== '')
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch {
        return refuse(`security-tests.jsonl line ${index + 1} is not JSON`);
      }
    });
}

// A lookup of the latest worthiness-ledger verdict recorded for one test at
// one signal, or undefined, built from one read of the ledger. An unreadable
// line is skipped: the ledger is append-only and a torn line names no test.
export function latestVerdicts(ledgerPath) {
  const verdicts = new Map();
  const keyOf = (file, title, signal) => `${file}\0${title}\0${signal}`;
  if (ledgerPath && existsSync(ledgerPath)) {
    for (const line of readFileSync(ledgerPath, 'utf8').split('\n')) {
      if (line.trim() === '') continue;
      let record;
      try {
        record = JSON.parse(line);
      } catch {
        continue;
      }
      verdicts.set(keyOf(record.file, record.fullName, record.signal), record.verdict);
    }
  }
  return ({file, title, signal}) => verdicts.get(keyOf(file, title, signal));
}

const git = (root, args) =>
  spawnSync('git', ['-C', root, ...args], {encoding: 'utf8', maxBuffer: OUTPUT_LIMIT});

// The commit `<base>...HEAD` diffs from, so a file's base version is the one
// the branch's change set was computed against.
export function mergeBaseOf(root, base) {
  const result = git(root, ['merge-base', base, 'HEAD']);
  if (result.status !== 0 || result.stdout.trim() === '') {
    refuse(`cannot find the merge base of ${base} and HEAD in ${root}`);
  }
  return result.stdout.trim();
}

// The head version of a file: the working tree's, or with `committed` the one
// in HEAD, which is what a merge acts on.
const headText = (root, file, committed) => {
  if (committed) {
    if (git(root, ['cat-file', '-e', `HEAD:${file}`]).status !== 0) return null;
    const shown = git(root, ['show', `HEAD:${file}`]);
    if (shown.status !== 0) refuse(`cannot read ${file} at HEAD`);
    return shown.stdout;
  }
  const absolute = path.join(root, file);
  if (!existsSync(absolute)) return null;
  try {
    return readFileSync(absolute, 'utf8');
  } catch (error) {
    return refuse(`cannot read ${file}: ${error.message}`);
  }
};

const baseText = (root, mergeBase, file) => {
  if (git(root, ['cat-file', '-e', `${mergeBase}:${file}`]).status !== 0) return null;
  const shown = git(root, ['show', `${mergeBase}:${file}`]);
  if (shown.status !== 0) refuse(`cannot read ${file} at ${mergeBase}`);
  return shown.stdout;
};

function extract(file, text, where) {
  const args = [EXTRACTOR, file, '--stdin', '--report-unmatchable'];
  const result = spawnSync(process.execPath, args, {
    input: text,
    encoding: 'utf8',
    maxBuffer: OUTPUT_LIMIT,
  });
  if (result.status !== 0) {
    refuse(`the extractor refused ${file} at ${where}: ${String(result.stderr).trim()}`);
  }
  return result.stdout
    .split('\n')
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
}

function inspectorFor(file, text) {
  if (/\.bats$/.test(file)) {
    const entry = {lines: text.split('\n')};
    return {
      skipped: (test) => batsSkipped(entry, test),
      empty: (test) => batsEmpty(entry, test),
      caseKeys: () => new Set(),
    };
  }
  const ts = typescriptModule();
  if (ts === null) refuse('cannot resolve "typescript" from node_modules');
  const kind = /\.tsx$/i.test(file) ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const entry = {
    sourceFile: ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, kind),
    isStories: /\.stories\.tsx?$/.test(file),
    calls: null,
  };
  return {
    skipped: (test) => isSkipped(entry, test),
    empty: (test) => hasEmptyBody(entry, test),
    caseKeys: (test) => caseTableLiterals(entry, test),
  };
}

const EMPTY_SIDE = {list: [], byName: new Map(), duplicates: [], inspect: null};

// One version of one test file: its tests in file order, the first test of
// each full name, the full names that repeat, and its source inspector.
function readSide(file, text, where) {
  if (text === null) return EMPTY_SIDE;
  const extracted = extract(file, text, where);
  // Only the head must be fully identifiable; a base test no title names
  // cannot be planned against, so it is left out there.
  const list = extracted.filter((test) => !test.unmatchable);
  const unmatchable = extracted.find((test) => test.unmatchable);
  if (unmatchable && where === 'head') {
    refuse(
      `${file} at ${where}: the test at line ${unmatchable.firstLine} has a title, or an enclosing describe title, that is not a string literal`,
    );
  }
  const byName = new Map();
  const duplicates = [];
  for (const test of list) {
    if (byName.has(test.fullName)) duplicates.push(test.fullName);
    else byName.set(test.fullName, test);
  }
  return {list, byName, duplicates, inspect: inspectorFor(file, text)};
}

export const existsAtHead = (root, file, committed = false) =>
  committed
    ? git(root, ['cat-file', '-e', `HEAD:${file}`]).status === 0
    : existsSync(path.join(root, file));

// Map of file -> {head, base} for every file named; `committed` reads the head
// from HEAD instead of the working tree. A file absent on a side
// reads as having no tests there. A planned file holding a repeated full name
// is refused: a row could not tell which test it names.
export function readFiles(root, mergeBase, files, plannedFiles, committed = false) {
  const sides = new Map();
  for (const file of files) {
    const head = readSide(file, headText(root, file, committed), 'head');
    if (plannedFiles.has(file) && head.duplicates.length > 0) {
      refuse(`duplicate full name "${head.duplicates[0]}" in planned file ${file}`);
    }
    sides.set(file, {head, base: readSide(file, baseText(root, mergeBase, file), 'base')});
  }
  return sides;
}
