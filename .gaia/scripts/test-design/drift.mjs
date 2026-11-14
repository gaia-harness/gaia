#!/usr/bin/env node
// The deterministic post-build drift check: the tests a branch added, changed
// or deleted, and every row of the plan's test-design table, classified
// against each other. test-drift-check.sh is the entry point; it resolves the
// base, the changed paths and the worthiness ledger and calls this CLI.
//
//   drift.mjs classify --root <tree> --plan-dir <dir> --base <commit> --changed <file>
//   drift.mjs security --root <tree> --plan-dir <dir> --base <commit> --ledger <file>
//
// --changed holds the branch's changed paths, NUL-separated. Exit codes are
// test-drift-check.sh's: 0 ok, 1 an uncovered security row (security only),
// 2 usage or no TEST-DESIGN marker (classify), 3 refusal, reason on stderr.
//
// The matching rule (a row is matched when its test counts and its action
// holds) and the drift JSON are stated in
// .claude/skills/gaia/references/drift-check.md; the rename pairing is:
//   - a missing row whose title is gone from head pairs with an unplanned test
//     in its file whose signal equals the row's base signal: a rename, listed
//     in likelyRenames and in neither missing nor unplanned;
//   - a base test deleted with no row and a new unplanned test of the same
//     signal in its file pair the same way, with row null;
//   - after those, a file left with exactly one such missing row and exactly
//     one new unplanned test lists them as a likely rename and keeps both.

import {readFileSync, realpathSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

import {
  DriftRefusal,
  hasMarker,
  isTestPath,
  latestVerdict,
  loadPlan,
  mergeBaseOf,
  readFiles,
} from './drift-inputs.mjs';

const isSecurity = (row) => row.security !== 'none';
const testKey = (file, title) => `${file}\u0000${title}`;

function counts(side, test, row) {
  if (!test) return false;
  if (side.inspect.skipped(test) || side.inspect.empty(test)) return false;
  return row.caseKey === undefined || side.inspect.caseKeys(test).has(row.caseKey);
}

const authoredBySecurityWriter = (ledger, row, test) =>
  !!test &&
  ledger.some(
    (line) =>
      line.row === row.id && line.file === row.file && line.title === row.title && line.signal === test.signal,
  );

// {matched, head, base}: the row's test at head and at base, and whether the
// row holds by its action.
function evaluateRow(row, sides, ledger) {
  const {head, base} = sides.get(row.file);
  const headTest = head.byName.get(row.title);
  const baseTest = base.byName.get(row.title);
  let matched;
  switch (row.action) {
    case 'new':
      matched = counts(head, headTest, row);
      break;
    case 'reuse':
      matched = counts(head, headTest, row) && !!baseTest && headTest.signal === baseTest.signal;
      break;
    case 'extend':
      matched =
        counts(head, headTest, row) && !(baseTest && base.inspect.caseKeys(baseTest).has(row.caseKey));
      break;
    case 'change':
      matched = counts(head, headTest, row) && !!baseTest && headTest.signal !== baseTest.signal;
      break;
    default:
      matched = row.held ? !!headTest : !headTest;
  }
  if (matched && isSecurity(row) && row.action !== 'retire') {
    matched = authoredBySecurityWriter(ledger, row, headTest);
  }
  return {matched, head: headTest, base: baseTest};
}

function readPlanAndFiles({root, planDir, base, files}) {
  const plan = loadPlan(planDir);
  const mergeBase = mergeBaseOf(root, base);
  const plannedFiles = new Set(plan.rows.map((row) => row.file));
  const sides = readFiles(root, mergeBase, new Set([...files, ...plannedFiles]), plannedFiles);
  return {plan, sides};
}

// The drift JSON for a marked plan.
export function classify({root, planDir, base, changedPaths}) {
  const touched = [...new Set(changedPaths.filter(isTestPath))].sort();
  const {plan, sides} = readPlanAndFiles({root, planDir, base, files: touched});
  const {rows, approvedRows, ledger} = plan;

  const results = new Map(rows.map((row) => [row.id, evaluateRow(row, sides, ledger)]));
  const matchedRows = rows.filter((row) => results.get(row.id).matched);
  let missingRows = rows.filter((row) => !results.get(row.id).matched);

  // A test a row names is planned, except under a security row the security
  // writer did not author it for: that test is unplanned drift.
  const planned = new Set(
    rows
      .filter((row) => !isSecurity(row) || authoredBySecurityWriter(ledger, row, results.get(row.id).head))
      .map((row) => testKey(row.file, row.title)),
  );
  const retired = new Set(rows.filter((row) => row.action === 'retire').map((row) => testKey(row.file, row.title)));

  let unplanned = [];
  let unplannedDeletes = [];
  for (const file of touched) {
    const {head, base} = sides.get(file);
    for (const test of head.list) {
      const before = base.byName.get(test.fullName);
      const newOrChanged = !before || before.signal !== test.signal;
      if (newOrChanged && !planned.has(testKey(file, test.fullName))) {
        unplanned.push({file, title: test.fullName, signal: test.signal, isNew: !before});
      }
    }
    for (const test of base.list) {
      if (!head.byName.has(test.fullName) && !retired.has(testKey(file, test.fullName))) {
        unplannedDeletes.push({file, title: test.fullName, signal: test.signal});
      }
    }
  }

  const likelyRenames = [];
  const goneFromHead = (row) =>
    row.action !== 'retire' && !sides.get(row.file).head.byName.has(row.title);
  for (const row of missingRows.filter(goneFromHead)) {
    const before = results.get(row.id).base;
    const partner = before && unplanned.find((test) => test.file === row.file && test.signal === before.signal);
    if (!partner) continue;
    likelyRenames.push({row: row.id, file: row.file, title: row.title, renamedTo: partner.title});
    unplanned = unplanned.filter((test) => test !== partner);
    unplannedDeletes = unplannedDeletes.filter((test) => test.file !== row.file || test.title !== row.title);
    missingRows = missingRows.filter((candidate) => candidate !== row);
  }
  for (const deleted of [...unplannedDeletes]) {
    const partner = unplanned.find((test) => test.file === deleted.file && test.signal === deleted.signal);
    if (!partner) continue;
    likelyRenames.push({row: null, file: deleted.file, title: deleted.title, renamedTo: partner.title});
    unplanned = unplanned.filter((test) => test !== partner);
    unplannedDeletes = unplannedDeletes.filter((test) => test !== deleted);
  }
  for (const file of touched) {
    const rowsHere = missingRows.filter((row) => row.file === file && goneFromHead(row));
    const testsHere = unplanned.filter((test) => test.file === file && test.isNew);
    if (rowsHere.length === 1 && testsHere.length === 1) {
      likelyRenames.push({row: rowsHere[0].id, file, title: rowsHere[0].title, renamedTo: testsHere[0].title});
    }
  }

  // An unplanned test carrying a missing row's title in another file moved.
  const moved = [];
  for (const test of [...unplanned]) {
    const row = missingRows.find((candidate) => candidate.title === test.title && candidate.file !== test.file);
    if (!row) continue;
    moved.push({row: row.id, file: test.file, title: test.title, signal: test.signal, fromFile: row.file});
    unplanned = unplanned.filter((candidate) => candidate !== test);
    missingRows = missingRows.filter((candidate) => candidate !== row);
  }

  const coveredKeys = new Set(matchedRows.map((row) => row.source));
  const uncoveredKeys = [...new Set(approvedRows.map((row) => row.source))]
    .filter((key) => !coveredKeys.has(key))
    .sort();

  const honesty = [];
  const honestyKeys = new Set();
  for (const row of matchedRows) {
    const {head, base} = results.get(row.id);
    if (!head) continue;
    const newOrChanged = !base || base.signal !== head.signal;
    const key = testKey(row.file, row.title);
    if ((newOrChanged || row.action === 'reuse' || row.action === 'extend') && !honestyKeys.has(key)) {
      honestyKeys.add(key);
      honesty.push({file: row.file, title: row.title, signal: head.signal, row: row.id});
    }
  }

  const plainUnplanned = unplanned.map(({file, title, signal}) => ({file, title, signal}));
  return {
    matched: matchedRows.map((row) => ({
      row: row.id,
      file: row.file,
      title: row.title,
      signal: results.get(row.id).head?.signal ?? null,
    })),
    missing: missingRows.map((row) => ({row: row.id, file: row.file, title: row.title, security: row.security})),
    unplanned: plainUnplanned,
    unplannedDeletes: unplannedDeletes.map(({file, title}) => ({file, title})),
    moved,
    likelyRenames,
    uncoveredKeys,
    honesty,
    fixer: missingRows.map((row) => ({row: row.id})),
    evaluator: [...plainUnplanned, ...moved.map(({file, title, signal, row}) => ({file, title, signal, row}))],
  };
}

// One {row, reason} per approved security row the branch leaves uncovered;
// an empty list for a plan with no TEST-DESIGN marker.
export function securityCheck({root, planDir, base, ledgerPath}) {
  if (!hasMarker(planDir)) return [];
  const {plan, sides} = readPlanAndFiles({root, planDir, base, files: []});
  const uncovered = [];
  for (const approved of plan.approvedRows.filter(isSecurity)) {
    const current = plan.rows.find((row) => row.id === approved.id);
    let reason = null;
    if (!current) reason = 'missing-from-table';
    else if (current.security !== approved.security) reason = 'flag-lost';
    else {
      const {matched, head} = evaluateRow(current, sides, plan.ledger);
      if (!matched) reason = 'no-matching-test';
      else if (head && latestVerdict(ledgerPath, {file: current.file, title: current.title, signal: head.signal}) === 'fix') {
        reason = 'hollow';
      }
    }
    if (reason !== null) uncovered.push({row: approved.id, reason});
  }
  return uncovered;
}

// CLI ---------------------------------------------------------------------------

const fail = (code, message) => {
  process.stderr.write(`test-drift-check: ${message}\n`);
  process.exit(code);
};

const isMain = () => {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
};

if (isMain()) {
  const [command, ...rest] = process.argv.slice(2);
  const options = {};
  for (let index = 0; index < rest.length; index += 2) {
    const flag = rest[index];
    if (!['--root', '--plan-dir', '--base', '--changed', '--ledger'].includes(flag) || index + 1 >= rest.length) {
      fail(2, `unknown or valueless argument ${flag}`);
    }
    options[flag.slice(2)] = rest[index + 1];
  }
  const needed = command === 'classify' ? 'changed' : 'ledger';
  if (!['classify', 'security'].includes(command) || !options.root || !options['plan-dir'] || !options.base || options[needed] === undefined) {
    fail(2, 'usage: drift.mjs classify|security --root <tree> --plan-dir <dir> --base <commit> (--changed <file> | --ledger <file>)');
  }
  const input = {root: options.root, planDir: options['plan-dir'], base: options.base};
  let output = '';
  let status = 0;
  try {
    if (command === 'classify') {
      let changedPaths;
      try {
        changedPaths = readFileSync(options.changed, 'utf8').split('\0').filter((entry) => entry.length > 0);
      } catch (error) {
        fail(3, `cannot read the changed-path list: ${error.message}`);
      }
      output = `${JSON.stringify(classify({...input, changedPaths}))}\n`;
    } else {
      const uncovered = securityCheck({...input, ledgerPath: options.ledger});
      output = uncovered.map(({row, reason}) => `uncovered ${row} ${reason}\n`).join('');
      status = uncovered.length > 0 ? 1 : 0;
    }
  } catch (error) {
    if (!(error instanceof DriftRefusal)) throw error;
    fail(error.code, error.message);
  }
  // Write, then set the exit code: process.exit() after a stdout write can
  // truncate a pipe-backed stdout (extract-test-signals.mjs states the idiom).
  process.stdout.on('error', (error) => {
    if (error.code === 'EPIPE') process.exit(0);
    throw error;
  });
  process.stdout.write(output);
  process.exitCode = status;
}
