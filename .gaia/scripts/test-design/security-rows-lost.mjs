#!/usr/bin/env node
// Security rows a regenerated test-design table no longer covers.
//
//   security-rows-lost.mjs --before <tests.json snapshot> --after <tests.json>
//
// A regeneration can renumber ids, so a security row (security not `none`) is
// matched on its `source`, its `security` kind and, when the snapshot row
// carries one, its `caseKey`. A snapshot row with a caseKey is lost unless the
// after table holds a security row of the same source, kind and caseKey, so a
// dropped case swapped for another case of the same source and kind reads as
// lost. Snapshot rows without a caseKey are counted per source and kind against
// the after rows that no keyed snapshot row matched. A dropped row, a row set
// to `none` and a row moved to another kind all read as lost. Prints one line
// per source and kind left short,
// `lost: <kind> <source> (<missing> of <snapshot ids>)`, and nothing when none
// is lost. The ids are the lost keyed rows, plus every keyless snapshot id of
// the pair when a keyless row is left short.
//
// Exit 0 compared (stdout says what was lost), 1 a table is unusable (one
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
  const available = [...(afterPairs.get(key) ?? [])];
  const lostIds = [];
  for (const row of rows.filter((candidate) => candidate.caseKey)) {
    const match = available.findIndex(
      (candidate) => candidate.caseKey === row.caseKey,
    );
    if (match === -1) lostIds.push(row.id);
    else available.splice(match, 1);
  }
  const keyless = rows.filter((candidate) => !candidate.caseKey);
  // Keyless snapshot rows take the after rows no keyed snapshot row matched.
  const keylessMissing = Math.max(0, keyless.length - available.length);
  const missing = lostIds.length + keylessMissing;
  if (missing > 0) {
    const keylessIds = keylessMissing > 0 ? keyless.map((row) => row.id) : [];
    const ids = [...lostIds, ...keylessIds].join(', ');
    process.stdout.write(
      `lost: ${rows[0].security} ${rows[0].source} (${missing} of ${ids})\n`,
    );
  }
}
