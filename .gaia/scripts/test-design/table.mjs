// Reader, row and table validators and key-coverage checks for the test-design table
// (`tests.json`). The CLI (test-table.mjs) and the drift check import these so
// the table is parsed in one place.

import {readFileSync} from 'node:fs';

export const LAYERS = [
  'unit',
  'story',
  'route',
  'real-server',
  'browser',
  'flow',
  'shell',
];
export const ACTIONS = ['new', 'reuse', 'extend', 'change', 'retire'];
export const SECURITY_VALUES = ['none', 'access', 'forgery', 'secret'];
export const HELD_VALUES = ['auto-mode', 'kept-code'];

// The test-file suffixes a plan's task-doc lines admit, as a regex source.
export const TEST_FILE_SUFFIX = String.raw`(?:test\.tsx?|spec\.ts|stories\.tsx?|bats)`;
const TEST_FILE = new RegExp(String.raw`\.${TEST_FILE_SUFFIX}$`);
export const isTestPath = (file) => TEST_FILE.test(file);

export const isSecurity = (row) =>
  row.security !== undefined && row.security !== 'none';

export const REQUIRED_FIELDS = [
  'id',
  'source',
  'case',
  'file',
  'title',
  'layer',
  'task',
  'action',
  'security',
];

const isNonEmptyString = (value) =>
  typeof value === 'string' && value.trim() !== '';

// Returns {rows, coveredFlows, instructionKeys}, or throws an Error whose
// message is one line naming why the table is unusable.
export const readTable = (path) => {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch {
    throw new Error(`cannot read ${path}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error(`${path} is not valid JSON`);
  }
  if (
    parsed === null ||
    typeof parsed !== 'object' ||
    !Array.isArray(parsed.rows)
  ) {
    throw new Error(`${path} has no "rows" array`);
  }
  return {
    rows: parsed.rows,
    coveredFlows: parsed.coveredFlows,
    instructionKeys: parsed.instructionKeys,
  };
};

// Returns a list of reasons the row is invalid; empty when it is valid.
export const validateRow = (row) => {
  if (row === null || typeof row !== 'object' || Array.isArray(row)) {
    return ['row is not an object'];
  }
  const reasons = [];
  for (const field of REQUIRED_FIELDS) {
    if (!isNonEmptyString(row[field])) {
      reasons.push(`missing required field "${field}"`);
    }
  }
  if (isNonEmptyString(row.id) && !/^T\d+$/.test(row.id)) {
    reasons.push(`id "${row.id}" is not T plus a number`);
  }
  if (isNonEmptyString(row.task) && !/^task-.+/.test(row.task)) {
    reasons.push(`task "${row.task}" is not a task-<name> stem`);
  }
  for (const [field, legal] of [
    ['layer', LAYERS],
    ['action', ACTIONS],
    ['security', SECURITY_VALUES],
  ]) {
    if (isNonEmptyString(row[field]) && !legal.includes(row[field])) {
      reasons.push(`illegal ${field} "${row[field]}"`);
    }
  }
  if (row.caseKey !== undefined && !isNonEmptyString(row.caseKey)) {
    reasons.push('caseKey is not a non-empty string');
  }
  if (row.action === 'extend' && !isNonEmptyString(row.caseKey)) {
    reasons.push('an extend row needs a caseKey');
  }
  if (row.held !== undefined && !HELD_VALUES.includes(row.held)) {
    reasons.push(`illegal held "${row.held}"`);
  }
  if (row.deletes !== undefined) {
    if (row.action !== 'retire' || !isSecurity(row)) {
      reasons.push('deletes is only for a security retire row');
    }
    if (
      !Array.isArray(row.deletes) ||
      row.deletes.length === 0 ||
      !row.deletes.every(isNonEmptyString)
    ) {
      reasons.push('deletes is not a non-empty array of paths');
    } else if (row.deletes.some(isTestPath)) {
      reasons.push('deletes names a test path, not the code under test');
    } else if (row.deletes.some((file) => /^\/|^\.\.?\/|(^|\/)\.\.(\/|$)/.test(file) || file.includes('\\'))) {
      reasons.push('deletes is not a plain repo-relative path');
    }
  }
  return reasons;
};

// A SPEC flow left with no step a flow test keeps, every step owned by a
// lower-layer row, gets no flow test: a `coveredFlows` entry,
// {source: "flow:<slug>", rows: [ids]}, names those rows in its place. Returns the sources of the valid entries and
// every problem with them that the rows alone can show.
export const coveredFlows = ({rows, coveredFlows: entries}) => {
  if (entries === undefined) return {sources: [], problems: []};
  if (!Array.isArray(entries)) {
    return {sources: [], problems: ['coveredFlows is not an array']};
  }
  const objectRows = rows.filter((row) => row && typeof row === 'object');
  const rowsById = new Map(objectRows.map((row) => [row.id, row]));
  const flowRowBySource = new Map(
    objectRows.filter((row) => row.layer === 'flow').map((row) => [row.source, row.id]),
  );
  const problems = [];
  const seen = new Set();
  const sources = [];
  entries.forEach((entry, index) => {
    const source = entry && typeof entry === 'object' ? entry.source : undefined;
    if (typeof source !== 'string' || !/^flow:\S+$/.test(source)) {
      problems.push(`coveredFlows entry #${index + 1}: source is not a flow:<slug> key`);
      return;
    }
    if (seen.has(source)) problems.push(`coveredFlows names ${source} twice`);
    seen.add(source);
    if (!Array.isArray(entry.rows) || entry.rows.length === 0) {
      problems.push(`coveredFlows ${source} names no rows`);
      return;
    }
    const before = problems.length;
    for (const id of entry.rows) {
      const row = rowsById.get(id);
      if (!row) {
        problems.push(`coveredFlows ${source} names row ${id}, which the table lacks`);
      } else if (row.layer === 'flow') {
        problems.push(`coveredFlows ${source} names flow-layer row ${id}; a covered flow has no flow test`);
      } else if (row.action === 'retire' || row.held !== undefined) {
        problems.push(`coveredFlows ${source} names row ${id}, which is ${row.action === 'retire' ? 'retired' : 'held'} and so runs no test`);
      }
    }
    if (flowRowBySource.has(source)) {
      problems.push(`row ${flowRowBySource.get(source)} is a flow-layer row for ${source}, which coveredFlows records as having no flow test`);
    }
    if (problems.length === before) sources.push(source);
  });
  return {sources, problems};
};

// A scope boundary or directive key that directs the builder rather than stating app
// behavior has no test: an `instructionKeys` entry, {source: "<key>", reason:
// "<what it directs>"}, records it in place of a row. Returns the sources of
// the valid entries and every problem with them that the rows alone can show.
export const instructionKeys = ({rows, instructionKeys: entries}) => {
  if (entries === undefined) return {sources: [], problems: []};
  if (!Array.isArray(entries)) {
    return {sources: [], problems: ['instructionKeys is not an array']};
  }
  const problems = [];
  const seen = new Set();
  const sources = [];
  entries.forEach((entry, index) => {
    const source = entry && typeof entry === 'object' ? entry.source : undefined;
    if (!isNonEmptyString(source)) {
      problems.push(`instructionKeys entry #${index + 1}: source is not a key`);
      return;
    }
    const before = problems.length;
    if (seen.has(source)) problems.push(`instructionKeys names ${source} twice`);
    seen.add(source);
    if (!source.startsWith('scope_boundaries:') && !source.startsWith('directive:')) {
      problems.push(`instructionKeys ${source} is not a scope boundary or directive key`);
    }
    if (!isNonEmptyString(entry.reason)) {
      problems.push(`instructionKeys ${source} has no reason`);
    }
    for (const row of rows.filter((row) => row?.source === source)) {
      problems.push(`row ${row.id} cites ${source}, which instructionKeys records as naming no behavior`);
    }
    if (problems.length === before) sources.push(source);
  });
  return {sources, problems};
};

// Every row problem a table can have on its own: invalid rows, duplicate ids,
// and rows sharing one test without distinct caseKeys.
export const tableProblems = (rows) => {
  const problems = [];
  const seenIds = new Set();
  rows.forEach((row, index) => {
    const label = row && row.id ? `row ${row.id}` : `row #${index + 1}`;
    for (const reason of validateRow(row)) {
      problems.push(`${label}: ${reason}`);
    }
    if (row && typeof row.id === 'string') {
      if (seenIds.has(row.id)) problems.push(`duplicate id ${row.id}`);
      seenIds.add(row.id);
    }
  });
  const byTest = new Map();
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    const key = `${row.file}\u0000${row.title}`;
    byTest.set(key, [...(byTest.get(key) ?? []), row]);
  }
  for (const group of byTest.values()) {
    if (group.length < 2) continue;
    const caseKeys = group.map((row) => row.caseKey);
    const distinct =
      caseKeys.every((caseKey) => typeof caseKey === 'string' && caseKey) &&
      new Set(caseKeys).size === caseKeys.length;
    if (!distinct) {
      problems.push(
        `rows ${group.map((row) => row.id).join(', ')} share ${group[0].file} "${group[0].title}" without distinct caseKeys`,
      );
    }
  }
  return problems;
};

// The requirement keys no row's source, valid coveredFlows entry or valid
// instructionKeys entry cites: verify refuses each one as a key with no row.
export const keysWithNoRow = (keys, table) => {
  const cited = new Set(
    table.rows.filter((row) => row && typeof row === 'object').map((row) => row.source),
  );
  for (const source of coveredFlows(table).sources) cited.add(source);
  for (const source of instructionKeys(table).sources) cited.add(source);
  return keys.filter((key) => !cited.has(key));
};

// Each unflagged retire or change row sharing `file` and `source` with a
// flagged row, with the kinds those rows carry. A candidate, not a verdict:
// one requirement can hold security and non-security parts in one file, so the
// plan audit judges each one.
export const flagCandidates = ({rows}) => {
  const objectRows = rows.filter((row) => row && typeof row === 'object');
  const flagged = objectRows.filter(isSecurity);
  return objectRows
    .filter(
      (row) =>
        (row.action === 'retire' || row.action === 'change') && !isSecurity(row),
    )
    .map((row) => ({
      id: row.id,
      kinds: [
        ...new Set(
          flagged
            .filter((other) => other.file === row.file && other.source === row.source)
            .map((other) => other.security),
        ),
      ].sort(),
    }))
    .filter((entry) => entry.kinds.length > 0);
};

const REPLAN_FIELDS = [
  'file',
  'title',
  'layer',
  'action',
  'security',
  'source',
  'case',
  'task',
  'caseKey',
  'held',
  'deletes',
];

// Each regenerated row no unconsumed snapshot row equals on REPLAN_FIELDS (a
// snapshot row matches at most one regenerated row, so a duplicate is listed),
// with `prior`,
// the snapshot row's id, when that row kept its id, file and title. A
// regeneration can renumber ids, so a changed row moved under another id reads
// as an add with no prior form: the plan audit judges it whole rather than against
// a stranger's old form.
export const replannedRows = (before, after) => {
  const objectRows = (table) =>
    table.rows.filter((row) => row && typeof row === 'object');
  const signature = (row) =>
    JSON.stringify(REPLAN_FIELDS.map((field) => row[field]));
  const snapshotRows = objectRows(before);
  const unconsumed = new Map();
  for (const row of snapshotRows) {
    unconsumed.set(signature(row), (unconsumed.get(signature(row)) ?? 0) + 1);
  }
  const snapshotById = new Map(snapshotRows.map((row) => [row.id, row]));
  return objectRows(after)
    .filter((row) => {
      const left = unconsumed.get(signature(row)) ?? 0;
      if (left === 0) return true;
      unconsumed.set(signature(row), left - 1);
      return false;
    })
    .map((row) => {
      const snapshot = snapshotById.get(row.id);
      const kept = snapshot?.file === row.file && snapshot?.title === row.title;
      return {id: row.id, prior: kept ? row.id : null};
    });
};

// Each row whose removal alone would add a key to keysWithNoRow, with those
// keys: verify would refuse the plan without it.
export const soleRowKeys = (keys, table) => {
  const alreadyUncovered = new Set(keysWithNoRow(keys, table));
  return table.rows
    .filter((row) => row && typeof row === 'object')
    .map((row) => ({
      id: row.id,
      keys: keysWithNoRow(keys, {
        ...table,
        rows: table.rows.filter((other) => other !== row),
      }).filter((key) => !alreadyUncovered.has(key)),
    }))
    .filter((entry) => entry.keys.length > 0);
};
