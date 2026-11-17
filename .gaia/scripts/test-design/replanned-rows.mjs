#!/usr/bin/env node
// Rows a Structural re-plan added or changed, for the plan audit to hold to
// its Applied rows check.
//
//   replanned-rows.mjs --before <tests.json snapshot> --after <tests.json>
//
// Prints `<id>` for each after row no unmatched snapshot row equals on file,
// title, layer, action, security, source, case, task, caseKey, held, deletes
// and cells (each snapshot row matches at most one after row), followed by ` <id>` when the
// snapshot row under the same id keeps its file and title (its prior form).
// Prints nothing when the re-plan changed no row.
//
// Exit 0 compared, 1 a table is unusable (one `replanned-rows: ...` stderr
// line), 2 usage.

import {readTable, replannedRows} from './table.mjs';

const usage = () => {
  process.stderr.write('usage: replanned-rows.mjs --before <file> --after <file>\n');
  process.exit(2);
};

const args = process.argv.slice(2);
const options = {};
for (let index = 0; index < args.length; index += 2) {
  const flag = args[index];
  const value = args[index + 1];
  if ((flag !== '--before' && flag !== '--after') || value === undefined) {
    usage();
  }
  options[flag.slice(2)] = value;
}
if (!options.before || !options.after) usage();

const load = (file) => {
  try {
    return readTable(file);
  } catch (error) {
    process.stderr.write(`replanned-rows: ${error.message}\n`);
    process.exit(1);
  }
};

for (const {id, prior} of replannedRows(load(options.before), load(options.after))) {
  process.stdout.write(prior === null ? `${id}\n` : `${id} ${prior}\n`);
}
