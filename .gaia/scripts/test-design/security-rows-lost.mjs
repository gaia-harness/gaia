#!/usr/bin/env node
// Security rows a regenerated test-design table no longer covers.
//
//   security-rows-lost.mjs --before <tests.json snapshot> --after <tests.json>
//
// A regeneration can renumber ids, so a security row (security not `none`) is
// matched on its `source`, its `security` kind and, when the snapshot row
// carries one, its `caseKey`. A snapshot row with a caseKey is lost unless the
// after table holds a security row of the same source, kind and caseKey, or
// of the same source, kind and id that keeps the snapshot row's file and title
// and carries a caseKey, so a dropped case swapped for another case of the same
// source and kind under a new id reads as lost, and so does an id reused by a
// row of another file or title or by a row with no caseKey. A same-id match
// whose caseKey differs is not lost: it prints
// `reworded: <kind> <source> <id> (<old caseKey> -> <new caseKey>)`, each
// caseKey JSON-encoded. Snapshot rows without a caseKey are counted per source
// and kind against the after rows that no keyed snapshot row matched, and the
// id pass never takes an after row those keyless rows need. A
// dropped row, a row set to `none` and a row moved to another kind all read
// as lost. Prints one line per source and kind left short,
// `lost: <kind> <source> (<missing> of <snapshot ids>)`, and nothing when none
// is lost or reworded. The ids are the lost keyed rows, plus every keyless
// snapshot id of the pair when a keyless row is left short.
//
// Exit 0 compared (stdout says what was lost or reworded), 1 a table is
// unusable (one `security-rows-lost: ...` stderr line), 2 usage.

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
  const unmatched = [];
  for (const row of rows.filter((candidate) => candidate.caseKey)) {
    const match = available.findIndex(
      (candidate) => candidate.caseKey === row.caseKey,
    );
    if (match === -1) unmatched.push(row);
    else available.splice(match, 1);
  }
  // Runs after every exact caseKey match, so a renumbered case keeps its
  // after row and a reused id cannot claim it.
  const keylessCount = rows.filter((candidate) => !candidate.caseKey).length;
  const lostIds = [];
  for (const row of unmatched) {
    // An id is planner-assigned and a regeneration renumbers it, so a shared id
    // alone does not prove the same test.
    const match =
      available.length > keylessCount
        ? available.findIndex(
            (candidate) =>
              candidate.id === row.id &&
              candidate.caseKey &&
              candidate.file === row.file &&
              candidate.title === row.title,
          )
        : -1;
    if (match === -1) {
      lostIds.push(row.id);
      continue;
    }
    const [after] = available.splice(match, 1);
    process.stdout.write(
      `reworded: ${row.security} ${row.source} ${row.id} (${JSON.stringify(row.caseKey)} -> ${JSON.stringify(after.caseKey)})\n`,
    );
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
