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

// Returns {rows}, or throws an Error whose message is one line naming why the
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
  return {rows: parsed.rows};
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
