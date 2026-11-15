#!/usr/bin/env node
// Security rows a regenerated test-design table no longer covers.
//
//   security-rows-lost.mjs --before <tests.json snapshot> --after <tests.json>
//
// A regeneration can renumber ids, so a security row (security not `none`) is
// matched on its `source` plus its `security` kind, counted: the after
// table must hold at least as many security rows of that key and kind as the
// snapshot did. A dropped row, a row set to `none` and a row moved to another
// kind all read as lost. Prints one line per source and kind left short,
// `lost: <kind> <source> (<missing> of <snapshot ids>)`, and nothing when none
// is lost.
//
// Exit 0 compared (stdout says what was lost), 1 a table is unreadable (one
// `security-rows-lost: ...` stderr line), 2 usage.

import {isSecurity, readTable} from './table.mjs';

const usage = () => {
  process.stderr.write(
    'usage: security-rows-lost.mjs --before <file> --after <file>\n',
  );
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
    return readTable(file).rows;
  } catch (error) {
    process.stderr.write(`security-rows-lost: ${error.message}\n`);
    process.exit(1);
  }
};

const pairKey = (row) => JSON.stringify([row.source, row.security]);

const securityPairs = (file) =>
  Map.groupBy(load(file).filter(isSecurity), pairKey);

const snapshotPairs = securityPairs(options.before);
const afterPairs = securityPairs(options.after);

for (const [key, rows] of snapshotPairs) {
  const missing = rows.length - (afterPairs.get(key)?.length ?? 0);
  if (missing > 0) {
    const ids = rows.map((row) => row.id).join(', ');
    process.stdout.write(
      `lost: ${rows[0].security} ${rows[0].source} (${missing} of ${ids})\n`,
    );
  }
}
