// Reader and row validator for the test-design table (`tests.json`). The CLI
// (test-table.mjs) and the drift check import these so the table is parsed in
// one place.

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

// Returns {rows, coveredFlows}, or throws an Error whose message is one line naming why the
// table is unusable.
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
  return {rows: parsed.rows, coveredFlows: parsed.coveredFlows};
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
  if (row.held !== undefined && row.held !== 'auto-mode') {
    reasons.push(`illegal held "${row.held}"`);
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
