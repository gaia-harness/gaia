// Per-case security kinds of a keyless row (`tests.json` row `caseKinds`).
//
// A row with no `caseKey` carries one `security` value for every case its
// `case` names, so a row mixing an access case with a forgery case reads as
// one kind (`.claude/doctrine/testing.md`, `**One kind per case.**`). A flagged
// keyless row that runs a test records each case's kind in `caseKinds`,
// [{case, kind}], so a mixed row is refused mechanically. The labels are the
// planner's; the plan audit's Test design lens judges each one.

import {isNonEmptyString, isSecurity, SECURITY_VALUES} from './table.mjs';

const needsCaseKinds = (row) =>
  isSecurity(row) && row.action !== 'retire' && row.caseKey === undefined;

// Each problem with one row's caseKinds: missing on a row that needs them, a
// malformed entry or illegal kind, two kinds in one row, or one kind that is
// not the row's `security`.
const rowProblems = (row) => {
  if (row.caseKinds === undefined) {
    return needsCaseKinds(row)
      ? [`row ${row.id}: a flagged row with no caseKey needs caseKinds`]
      : [];
  }
  if (!Array.isArray(row.caseKinds) || row.caseKinds.length === 0) {
    return [`row ${row.id}: caseKinds is not a non-empty array`];
  }
  const problems = [];
  row.caseKinds.forEach((entry, index) => {
    const where = `row ${row.id} caseKinds #${index + 1}`;
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
      problems.push(`${where} is not an object`);
      return;
    }
    if (!isNonEmptyString(entry.case)) problems.push(`${where} has no case`);
    if (!SECURITY_VALUES.includes(entry.kind)) {
      problems.push(`${where} has illegal kind "${entry.kind}"`);
    }
  });
  if (problems.length > 0) return problems;
  const kinds = [...new Set(row.caseKinds.map((entry) => entry.kind))];
  if (kinds.length > 1) {
    return [
      `row ${row.id} holds cases of kinds ${kinds.join(', ')}; give each kind its own row`,
    ];
  }
  if (kinds[0] !== row.security) {
    return [
      `row ${row.id}: its caseKinds are ${kinds[0]} but its security is ${row.security}; a flag change updates both`,
    ];
  }
  return [];
};

export const caseKindProblems = (rows) =>
  rows
    .filter((row) => row && typeof row === 'object' && !Array.isArray(row))
    .flatMap(rowProblems);
