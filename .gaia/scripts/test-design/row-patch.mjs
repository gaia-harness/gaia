// Row patch checks and application, the snapshot, the applied record and the
// judge set for plan-audit-apply.mjs. Library only, no CLI.
//
// A row patch is `{op:"add",row}`, `{op:"change",id,set,expect}` or
// `{op:"remove",id,expect}`. `checkPatch` routes one against a table:
// `fixup` (malformed, left for an agent), `review` (a script check failed, the
// maintainer decides) or `script` (apply it). Nothing here judges a security
// kind from row text.

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
} from 'node:fs';
import path from 'node:path';

import {isSecurity, soleRowKeys, tableProblems, validateRow} from './table.mjs';

const isRecord = (value) =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);

const malformed = (patch) => {
  if (!isRecord(patch)) return 'patch is not an object';
  if (patch.op === undefined) return 'patch has no op';
  if (patch.op === 'add') {
    return isRecord(patch.row) ? null : 'add has no row object';
  }
  if (patch.op !== 'change' && patch.op !== 'remove') {
    return `unknown op ${JSON.stringify(patch.op)}`;
  }
  if (typeof patch.id !== 'string') return `${patch.op} has no row id`;
  if (patch.op === 'remove') {
    return patch.expect === undefined || isRecord(patch.expect)
      ? null
      : 'remove expect is not an object';
  }
  if (!isRecord(patch.set) || Object.keys(patch.set).length === 0) {
    return 'change has no set object';
  }
  if (!isRecord(patch.expect)) return 'change has no expect object';
  const missing = Object.keys(patch.set).filter((field) => !(field in patch.expect));
  return missing.length > 0 ? `change expect misses ${missing.join(', ')}` : null;
};

const newProblems = (before, after) => {
  const known = new Set(tableProblems(before));
  return tableProblems(after).filter((problem) => !known.has(problem));
};

// Returns {route, reason}; `table` is {rows, ...}, `context` is
// {keys: string[], ruledWrong: Set<string>}.
export const checkPatch = (patch, table, context) => {
  const reason = malformed(patch);
  if (reason !== null) return {route: 'fixup', reason};
  const review = (text) => ({route: 'review', reason: text});
  const {rows} = table;
  if (patch.op === 'add') {
    const problems = validateRow(patch.row);
    if (problems.length > 0) return review(`added row is invalid: ${problems[0]}`);
    if (rows.some((row) => row.id === patch.row.id)) {
      return review(`row id ${patch.row.id} already exists`);
    }
    if (!context.keys.includes(patch.row.source)) {
      return review(`source ${patch.row.source} is not a requirement key`);
    }
    const created = newProblems(rows, [...rows, patch.row]);
    return created.length > 0 ? review(created[0]) : {route: 'script', reason: ''};
  }
  const row = rows.find((candidate) => candidate.id === patch.id);
  if (!row) return review(`row ${patch.id} is not in the table`);
  const stale = Object.keys(patch.expect ?? {}).filter(
    (field) => !same(row[field], patch.expect[field]),
  );
  if (stale.length > 0) {
    return review(`expected prior value of ${stale.join(', ')} no longer holds on ${patch.id}`);
  }
  const ruled = context.ruledWrong.has(row.id);
  if (patch.op === 'remove') {
    if (isSecurity(row) && !ruled) return review(`${row.id} is a flagged row; removing it needs the review list`);
    const sole = soleRowKeys(context.keys, table).find((entry) => entry.id === row.id);
    return sole
      ? review(`${row.id} is the sole row of ${sole.keys.join(', ')}`)
      : {route: 'script', reason: ''};
  }
  if ('id' in patch.set && patch.set.id !== row.id) return review('a change never changes the row id');
  if ('source' in patch.set && patch.set.source !== row.source) {
    return review('a fold never changes source');
  }
  if (isSecurity(row) && !ruled) {
    if ('security' in patch.set && patch.set.security !== row.security) {
      return review(`${row.id} is a flagged row; changing its security needs the review list`);
    }
    if (patch.set.action === 'retire') {
      return review(`${row.id} is a flagged row; retiring it needs the review list`);
    }
  }
  const next = {...row, ...patch.set};
  const problems = validateRow(next);
  if (problems.length > 0) return review(`changed row is invalid: ${problems[0]}`);
  const created = newProblems(rows, rows.map((candidate) => (candidate === row ? next : candidate)));
  return created.length > 0 ? review(created[0]) : {route: 'script', reason: ''};
};

export const applyPatch = (table, patch) => {
  if (patch.op === 'add') return {...table, rows: [...table.rows, patch.row]};
  if (patch.op === 'remove') {
    return {...table, rows: table.rows.filter((row) => row.id !== patch.id)};
  }
  return {
    ...table,
    rows: table.rows.map((row) => (row.id === patch.id ? {...row, ...patch.set} : row)),
  };
};

// `${finding}\0${index}` of every change patch that sets a field another
// patch in the list sets on the same row.
export const conflictingPatches = (entries) => {
  const owners = new Map();
  for (const {finding, index, patch} of entries) {
    if (malformed(patch) !== null || patch.op !== 'change') continue;
    for (const field of Object.keys(patch.set)) {
      const key = `${patch.id}\u0000${field}`;
      owners.set(key, [...(owners.get(key) ?? []), `${finding}\u0000${index}`]);
    }
  }
  return new Set([...owners.values()].filter((list) => list.length > 1).flat());
};

export const SNAPSHOT_NAMES = (planDir) => [
  'tests.json',
  'README.md',
  'ORCHESTRATOR.md',
  ...readdirSync(planDir).filter((name) => /^task-.+\.md$/.test(name)).sort(),
];

// Copies the plan documents once; a later call leaves the first snapshot.
export const takeSnapshot = (planDir, applyDir) => {
  const snapshot = path.join(applyDir, 'snapshot');
  if (existsSync(snapshot)) return false;
  const partial = path.join(applyDir, 'snapshot.partial');
  rmSync(partial, {recursive: true, force: true});
  mkdirSync(partial, {recursive: true});
  for (const name of SNAPSHOT_NAMES(planDir)) {
    if (existsSync(path.join(planDir, name))) {
      copyFileSync(path.join(planDir, name), path.join(partial, name));
    }
  }
  renameSync(partial, snapshot);
  return true;
};

const canonical = (value) =>
  JSON.stringify(
    Object.fromEntries(Object.entries(value).sort(([left], [right]) => left.localeCompare(right))),
  );

// Rows new against the snapshot, rows differing from their snapshot row in any
// field, and rows carrying `none` where the snapshot row carried a kind.
export const judgeSet = (snapshotRows, currentRows) => {
  const before = new Map(snapshotRows.map((row) => [row.id, row]));
  const result = [];
  for (const row of currentRows) {
    const prior = before.get(row.id);
    if (!prior) result.push({id: row.id, change: 'added'});
    else if (isSecurity(prior) && !isSecurity(row)) result.push({id: row.id, change: 'unflagged'});
    else if (canonical(prior) !== canonical(row)) result.push({id: row.id, change: 'changed'});
  }
  return result;
};

export const readJson = (file, fallback) => {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
};

// Every finding of `<planDir>/audit/<LENS>.json`, lens files in name order.
export const lensFindings = (planDir) => {
  const auditDir = path.join(planDir, 'audit');
  if (!existsSync(auditDir)) return [];
  return readdirSync(auditDir)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .flatMap((name) => {
      const parsed = readJson(path.join(auditDir, name), null);
      return isRecord(parsed) && Array.isArray(parsed.findings)
        ? parsed.findings.filter((finding) => isRecord(finding) && typeof finding.id === 'string')
        : [];
    });
};
