#!/usr/bin/env node
// Checks and applies the fixes a plan audit's lenses wrote as row patches and
// exact text replacements.
//
//   plan-audit-apply.mjs prepare   --plan-dir <dir> --keys <file> [--exclude <id,...>]
//   plan-audit-apply.mjs apply     --plan-dir <dir> --keys <file> --decisions <file>
//   plan-audit-apply.mjs judge-set --plan-dir <dir> --out <file>
//   plan-audit-apply.mjs flag      --plan-dir <dir> --row <id> --kind access|forgery|secret
//                                  [--cases <JSON array of the row's cases>]
//
// Working folder `<dir>/audit/apply/`: the first `prepare` snapshots the plan
// documents and later runs keep that snapshot; `prepared.json`, `applied.json`,
// `fixup.json` and `review.json` hold the round. `prepare` prints one
// `<route> <finding> <patch|replacement> <index> <reason>` line per fixup or
// review item. `apply` prints `applied <n> fixup <n> review <n>
// replacements-script <n> replacements-fixup <n>` (applied counts row patches
// applied); the review items are in `review.json`.
//
// Exit 0 ok, 1 refusal (one `plan-audit-apply: <reason>` stderr line), 2
// usage, 3 `apply` with `structural: true` in the decisions (nothing written).
// `flag` on a row that needs `caseKinds` (flagged, no `caseKey`, not
// `retire`) re-kinds the entries the row has, or writes one per `--cases`
// entry; with neither it refuses, writing nothing, so step 4.5 never meets a
// flagged row the script left without them.

import {readFileSync} from 'node:fs';
import path from 'node:path';

import {apply, flagRow, prepare} from './plan-audit-round.mjs';
import {writeAtomic} from './plan-docs.mjs';
import {judgeSet, readJson} from './row-patch.mjs';
import {readTable} from './table.mjs';

const COMMANDS = {
  prepare: ['--plan-dir', '--keys', '--exclude?'],
  apply: ['--plan-dir', '--keys', '--decisions'],
  'judge-set': ['--plan-dir', '--out'],
  flag: ['--plan-dir', '--row', '--kind', '--cases?'],
};

const usage = () => {
  process.stderr.write(
    'usage: plan-audit-apply.mjs prepare|apply|judge-set|flag --plan-dir <dir> ... (see the header)\n',
  );
  process.exit(2);
};

const refuse = (message, code = 1) => {
  process.stderr.write(`plan-audit-apply: ${message}\n`);
  process.exit(code);
};

const parse = (command, args) => {
  const spec = COMMANDS[command];
  if (!spec) usage();
  const names = spec.map((flag) => flag.replace('?', ''));
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    if (!names.includes(args[index]) || args[index + 1] === undefined) usage();
    options[args[index].slice(2)] = args[index + 1];
  }
  for (const flag of spec) {
    if (!flag.endsWith('?') && options[flag.slice(2)] === undefined) usage();
  }
  return options;
};

const main = () => {
  const [command, ...args] = process.argv.slice(2);
  const options = parse(command, args);
  const planDir = options['plan-dir'];
  try {
    if (command === 'prepare') {
      const exclude = options.exclude ? options.exclude.split(',').filter(Boolean) : [];
      for (const line of prepare({planDir, keysFile: options.keys, exclude})) {
        process.stdout.write(`${line}\n`);
      }
    } else if (command === 'apply') {
      const decisions = JSON.parse(readFileSync(options.decisions, 'utf8'));
      if (decisions === null || typeof decisions !== 'object') throw new Error('decisions file is not an object');
      if (decisions.structural === true) refuse('a structural finding survived; nothing applied', 3);
      const counts = apply({planDir, keysFile: options.keys, decisions});
      process.stdout.write(
        `applied ${counts.applied} fixup ${counts.fixup} review ${counts.review} replacements-script ${counts.scriptReplacements} replacements-fixup ${counts.fixupReplacements}\n`,
      );
    } else if (command === 'judge-set') {
      const snapshotFile = path.join(planDir, 'audit', 'apply', 'snapshot', 'tests.json');
      if (readJson(snapshotFile, null) === null) throw new Error('no snapshot: run prepare first');
      const set = judgeSet(readTable(snapshotFile).rows, readTable(path.join(planDir, 'tests.json')).rows);
      writeAtomic(options.out, `${JSON.stringify(set, null, 2)}\n`);
    } else {
      if (!['access', 'forgery', 'secret'].includes(options.kind)) usage();
      const cases = options.cases === undefined ? undefined : JSON.parse(options.cases);
      flagRow({planDir, row: options.row, kind: options.kind, cases});
    }
  } catch (error) {
    refuse(error.message);
  }
};

main();
