// The checks verify and amend share over the optional fields of a table file
// beyond validateRow: set cells (set-cells.mjs) and per-case kinds
// (case-kinds.mjs).

import {caseKindProblems} from './case-kinds.mjs';
import {readSets, setCellProblems} from './set-cells.mjs';

// Without a keySet the sets source check is skipped (amend holds no keys file).
export const rowFieldProblems = (tableFile, rows, keySet) => [
  ...setCellProblems({rows, sets: readSets(tableFile)}, keySet),
  ...caseKindProblems(rows),
];
