// Cell coverage of a set-stated rule's case table (`tests.json` `sets`).
//
// A rule stated as sets (the roles that take each action, the statuses each
// action leaves from) owes one case per member of every axis against every
// member of the others, inside the set or out (`.claude/doctrine/testing.md`,
// `## What to test`). The plan records each such rule as a `sets` entry,
// {source, rows: [ids], axes: {<axis>: [members]}}, and each listed row names
// the combinations it tests in `cells`, [{<axis>: <member>, ...}]. A table
// that samples the set leaves a combination with no cell, which a scan of the
// `case` text alone cannot see.

import {readFileSync} from 'node:fs';

import {isNonEmptyString} from './table.mjs';

const isPlainObject = (value) =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

// The `sets` value of the table file, undefined when it has none. readTable
// has already refused an unreadable or unparseable file.
export const readSets = (path) => JSON.parse(readFileSync(path, 'utf8')).sets;

const combinations = (axes) =>
  Object.entries(axes).reduce(
    (partial, [axis, members]) =>
      partial.flatMap((cell) => members.map((member) => ({...cell, [axis]: member}))),
    [{}],
  );

// Labelled in the axes' order, so a cell written in any key order matches its
// combination.
const cellLabel = (names, cell) =>
  names.map((name) => `${name} ${cell[name]}`).join(', ');

// Whether the case text holds the member as a whole word, so `view` is not
// found inside `viewer`.
const namesMember = (caseText, member) =>
  new RegExp(
    String.raw`(?<![\w-])${member.toLowerCase().replaceAll(/[$()*+.?[\\\]^{|}]/g, String.raw`\$&`)}(?![\w-])`,
  ).test(caseText);

const axesProblems = (label, axes) => {
  if (!isPlainObject(axes)) {
    return [`${label} has no axes object`];
  }
  const names = Object.keys(axes);
  if (names.length < 2) return [`${label} names fewer than two axes`];
  const problems = [];
  for (const name of names) {
    const members = axes[name];
    if (!Array.isArray(members) || members.length === 0 || !members.every(isNonEmptyString)) {
      problems.push(`${label} axis ${name} is not a non-empty list of members`);
    } else if (new Set(members).size !== members.length) {
      problems.push(`${label} axis ${name} lists a member twice`);
    }
  }
  return problems;
};

// Each problem with one row's cells against its entry's axes.
const rowCellProblems = (label, row, axes) => {
  if (!Array.isArray(row.cells) || row.cells.length === 0) {
    return [`${label} lists row ${row.id}, which has no cells`];
  }
  const caseText = typeof row.case === 'string' ? row.case.toLowerCase() : '';
  const names = Object.keys(axes);
  const problems = [];
  row.cells.forEach((cell, index) => {
    const where = `row ${row.id} cell #${index + 1}`;
    if (!isPlainObject(cell)) {
      problems.push(`${where} is not an object`);
      return;
    }
    const keys = Object.keys(cell);
    if (keys.length !== names.length || !names.every((name) => keys.includes(name))) {
      problems.push(`${where} does not name exactly the axes ${names.join(', ')} of ${label}`);
      return;
    }
    for (const name of names) {
      if (!axes[name].includes(cell[name])) {
        problems.push(`${where} names ${name} ${cell[name]}, which ${label} does not list`);
      } else if (!namesMember(caseText, cell[name])) {
        problems.push(`${where} names ${name} ${cell[name]}, which the row's case does not`);
      }
    }
  });
  return problems;
};

// Every problem the table's `sets` entries have against its rows and keys: a
// malformed entry, a listed row the table lacks, retires or holds, a cell its
// entry does not allow or its row's case does not name, and each combination
// of an entry's axes no listed row holds. Without a keySet the source check is
// skipped, for a caller that holds no keys file.
export const setCellProblems = ({rows, sets}, keySet) => {
  if (sets === undefined) return [];
  if (!Array.isArray(sets)) return ['sets is not an array'];
  const rowsById = new Map(
    rows.filter((row) => row && typeof row === 'object').map((row) => [row.id, row]),
  );
  const problems = [];
  sets.forEach((entry, index) => {
    if (!isPlainObject(entry)) {
      problems.push(`sets entry #${index + 1} is not an object`);
      return;
    }
    const hasSource = isNonEmptyString(entry.source);
    const label = hasSource ? `sets entry ${entry.source}` : `sets entry #${index + 1}`;
    if (!hasSource) {
      problems.push(`${label} has no source`);
    } else if (keySet && !keySet.has(entry.source)) {
      problems.push(`${label} cites unknown source ${entry.source}`);
    }
    const shape = axesProblems(label, entry.axes);
    if (!Array.isArray(entry.rows) || entry.rows.length === 0) {
      shape.push(`${label} names no rows`);
    }
    if (shape.length > 0) {
      problems.push(...shape);
      return;
    }
    const held = new Set();
    for (const id of entry.rows) {
      const row = rowsById.get(id);
      if (!row) {
        problems.push(`${label} names row ${id}, which the table lacks`);
      } else if (row.action === 'retire' || row.held !== undefined) {
        problems.push(`${label} names row ${id}, which is ${row.action === 'retire' ? 'retired' : 'held'} and so runs no test`);
      } else {
        const rowProblems = rowCellProblems(label, row, entry.axes);
        problems.push(...rowProblems);
        if (rowProblems.length === 0) {
          for (const cell of row.cells) held.add(cellLabel(Object.keys(entry.axes), cell));
        }
      }
    }
    const axisNames = Object.keys(entry.axes);
    for (const cell of combinations(entry.axes)) {
      if (!held.has(cellLabel(axisNames, cell))) {
        problems.push(`${label} has no row for ${cellLabel(axisNames, cell)}`);
      }
    }
  });
  return problems;
};
