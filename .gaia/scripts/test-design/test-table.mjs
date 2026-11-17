#!/usr/bin/env node
// CLI over the test-design table in a plan folder.
//
//   test-table.mjs verify --plan-dir <dir> --keys <file>
//   test-table.mjs covered-flows --plan-dir <dir>
//   test-table.mjs sole-rows --plan-dir <dir> --keys <file>
//   test-table.mjs flag-candidates --plan-dir <dir>
//   test-table.mjs approve --plan-dir <dir> [--auto]
//   test-table.mjs record-security --plan-dir <dir> --root <tree> --row <id>
//   test-table.mjs amend --plan-dir <dir> --root <tree> --changes <file>
//
// Exit 0 ok, 1 refusal or failed check (one `test-table: ...` stderr line
// each), 2 usage. `amend` also prints `checkpoint: <key>` on stdout for each
// requirement-source key a security fold would lose.
//
// Rows and the approved copy: `tests.json`, `tests.approved.json`; the marker
// is `TEST-DESIGN`; the security ledger is `security-tests.jsonl`.

import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {
  appendFileSync,
  existsSync,
  readFileSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

import {
  coveredFlows,
  flagCandidates,
  instructionKeys,
  isSecurity,
  isTestPath,
  keysWithNoRow,
  readTable,
  soleRowKeys,
  tableProblems,
  validateRow,
} from './table.mjs';
import {readSets, setCellProblems} from './set-cells.mjs';
import {
  DELETE_LINE,
  deleteLines,
  deletedPaths,
  EXEMPT_LINE,
  taskDocuments,
  TEST_LINE,
  TEST_PATH,
} from './task-docs.mjs';

const SIGNAL_HELPER = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  'test-signals',
  'extract-test-signals.mjs',
);

const usage = () => {
  process.stderr.write(
    'usage: test-table.mjs verify --plan-dir <dir> --keys <file> | covered-flows --plan-dir <dir> | sole-rows --plan-dir <dir> --keys <file> | flag-candidates --plan-dir <dir> | approve --plan-dir <dir> [--auto] | record-security --plan-dir <dir> --root <tree> --row <id> | amend --plan-dir <dir> --root <tree> --changes <file>\n',
  );
  process.exit(2);
};

const refuseAll = (messages) => {
  for (const message of messages) {
    process.stderr.write(`test-table: ${message}\n`);
  }
  process.exit(1);
};

const refuse = (message) => refuseAll([message]);

const parseOptions = (args, valueFlags, booleanFlags = []) => {
  const options = {};
  for (let index = 0; index < args.length; index++) {
    const flag = args[index];
    if (booleanFlags.includes(flag)) {
      options[flag.slice(2)] = true;
    } else if (valueFlags.includes(flag) && index + 1 < args.length) {
      options[flag.slice(2)] = args[++index];
    } else {
      usage();
    }
  }
  for (const flag of valueFlags) {
    if (options[flag.slice(2)] === undefined) usage();
  }
  return options;
};

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

const serialize = (table) => `${JSON.stringify(table, null, 2)}\n`;

const planPaths = (planDirectory) => ({
  table: path.join(planDirectory, 'tests.json'),
  approved: path.join(planDirectory, 'tests.approved.json'),
  marker: path.join(planDirectory, 'TEST-DESIGN'),
  ledger: path.join(planDirectory, 'security-tests.jsonl'),
});

const loadTable = (file) => {
  try {
    return readTable(file);
  } catch (error) {
    return refuse(error.message);
  }
};

const readKeys = (file) => {
  try {
    return readFileSync(file, 'utf8')
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean);
  } catch {
    return refuse(`cannot read keys file ${file}`);
  }
};

const verify = (args) => {
  const options = parseOptions(args, ['--plan-dir', '--keys']);
  const planDirectory = options['plan-dir'];
  const files = planPaths(planDirectory);
  if (!existsSync(files.table)) refuse('tests.json is missing');
  const table = loadTable(files.table);
  const {rows} = table;
  const failures = tableProblems(rows);

  const keys = readKeys(options.keys);
  const keySet = new Set(keys);
  const covered = coveredFlows(table);
  failures.push(...covered.problems);
  for (const source of covered.sources) {
    if (!keySet.has(source)) failures.push(`coveredFlows cites unknown source ${source}`);
  }
  const recorded = instructionKeys(table);
  failures.push(...recorded.problems);
  for (const source of recorded.sources) {
    if (!keySet.has(source)) failures.push(`instructionKeys cites unknown source ${source}`);
  }
  failures.push(...setCellProblems({rows, sets: readSets(files.table)}, keySet));
  for (const key of keysWithNoRow(keys, table)) {
    failures.push(`requirement key ${key} has no row`);
  }
  for (const row of rows) {
    if (row && typeof row.source === 'string' && !keySet.has(row.source)) {
      failures.push(`row ${row.id} cites unknown source ${row.source}`);
    }
  }

  const usableRows = rows.filter(
    (row) => row && typeof row === 'object' && !Array.isArray(row),
  );
  const documents = taskDocuments(planDirectory);
  const documentStems = new Set(documents.map((document) => document.stem));
  const declared = new Set();
  for (const document of documents) {
    document.lines.forEach((line, index) => {
      if (DELETE_LINE.test(line)) return;
      const match = TEST_LINE.exec(line);
      if (match) {
        const [, file, title] = match;
        declared.add(`${document.stem}\u0000${file}\u0000${title}`);
        const hasRow = usableRows.some(
          (row) =>
            row.task === document.stem && row.file === file && row.title === title,
        );
        if (!hasRow) {
          failures.push(
            `${document.stem} line ${index + 1}: Test line has no row for ${file} "${title}"`,
          );
        }
      } else if (!EXEMPT_LINE.test(line) && TEST_PATH.test(line)) {
        failures.push(
          `${document.stem} line ${index + 1}: test path outside a Test, Flow test or Pin update line`,
        );
      }
    });
  }
  for (const {stem, index, file} of deleteLines(documents)) {
    if (isTestPath(file)) {
      failures.push(
        `${stem} line ${index + 1}: Delete line names a test path; name the code under test instead`,
      );
    }
  }
  const deleted = deletedPaths(documents);
  for (const row of usableRows) {
    if (!Array.isArray(row.deletes)) continue;
    for (const file of row.deletes.filter((path) => !deleted.has(path))) {
      failures.push(`row ${row.id}: deletes ${file}, which no task doc's Delete line names`);
    }
  }
  for (const row of usableRows) {
    if (typeof row.task !== 'string') continue;
    if (!documentStems.has(row.task)) {
      failures.push(`row ${row.id}: task doc ${row.task}.md does not exist`);
    } else if (!declared.has(`${row.task}\u0000${row.file}\u0000${row.title}`)) {
      failures.push(
        `row ${row.id}: ${row.task} has no Test line for ${row.file} "${row.title}"`,
      );
    }
  }

  if (failures.length > 0) refuseAll(failures);
};

// Prints `<id> <key>...` for each row soleRowKeys reports, so the plan audit's
// apply step knows which rows it cannot remove.
const soleRows = (args) => {
  const options = parseOptions(args, ['--plan-dir', '--keys']);
  const files = planPaths(options['plan-dir']);
  if (!existsSync(files.table)) refuse('tests.json is missing');
  for (const {id, keys} of soleRowKeys(readKeys(options.keys), loadTable(files.table))) {
    process.stdout.write(`${id} ${keys.join(' ')}\n`);
  }
};

// Prints `<id> <kind>...` for each row flagCandidates reports, so the plan
// audit's Applied rows check judges each one's flag.
const flagCandidatesCommand = (args) => {
  const options = parseOptions(args, ['--plan-dir']);
  const files = planPaths(options['plan-dir']);
  if (!existsSync(files.table)) refuse('tests.json is missing');
  for (const {id, kinds} of flagCandidates(loadTable(files.table))) {
    process.stdout.write(`${id} ${kinds.join(' ')}\n`);
  }
};

// Prints the source of each valid coveredFlows entry for the shell gates; a
// plan with no tests.json records none. Any problem exits 1 after the valid
// sources print, so a caller treats the broken entry as unrecorded.
const coveredFlowsCommand = (args) => {
  const options = parseOptions(args, ['--plan-dir']);
  const files = planPaths(options['plan-dir']);
  if (!existsSync(files.table)) return;
  // Once approved, the approved copy decides, so a later edit of tests.json
  // cannot record a flow the approved plan still owes a test.
  const source = existsSync(files.approved) ? files.approved : files.table;
  const {sources, problems} = coveredFlows(loadTable(source));
  for (const source of sources) process.stdout.write(`${source}\n`);
  if (problems.length > 0) refuseAll(problems);
};

// A security retire row deletes its code only when the row is valid and every
// `deletes` path is on a task doc's Delete line; anything less reads as kept
// code, which only the maintainer retires.
const deletesItsCode = (row, deleted) =>
  validateRow(row).length === 0 &&
  Array.isArray(row.deletes) &&
  row.deletes.every((file) => deleted.has(file));

// Holds each security retire row a plan approval does not cover: every one
// under --auto, else each one whose code the plan keeps.
const approve = (args) => {
  const options = parseOptions(args, ['--plan-dir'], ['--auto']);
  const files = planPaths(options['plan-dir']);
  if (existsSync(files.approved)) refuse('tests.approved.json already exists');
  if (!existsSync(files.table)) refuse('tests.json is missing');
  const table = loadTable(files.table);
  const deleted = deletedPaths(taskDocuments(options['plan-dir']));
  const held = [];
  for (const row of table.rows) {
    if (row.action !== 'retire' || !isSecurity(row)) continue;
    if (options.auto) row.held = 'auto-mode';
    else if (!deletesItsCode(row, deleted)) row.held = 'kept-code';
    else continue;
    held.push(row.id);
  }
  if (held.length > 0) {
    writeFileSync(
      files.table,
      serialize({...JSON.parse(readFileSync(files.table, 'utf8')), rows: table.rows}),
    );
    for (const id of held) process.stdout.write(`held ${id}\n`);
  }
  const bytes = readFileSync(files.table);
  writeFileSync(files.approved, bytes);
  appendFileSync(files.marker, `approved_sha256: ${sha256(bytes)}\n`);
};

const recordSecurity = (args) => {
  const options = parseOptions(args, ['--plan-dir', '--root', '--row']);
  const files = planPaths(options['plan-dir']);
  const {rows} = loadTable(files.table);
  const row = rows.find((candidate) => candidate.id === options.row);
  if (!row) refuse(`no row ${options.row}`);
  if (!isSecurity(row)) refuse(`row ${row.id} is not a security row`);
  if (!existsSync(path.join(options.root, row.file))) {
    refuse(`row ${row.id}: test file ${row.file} is absent at ${options.root}`);
  }
  let output;
  try {
    output = execFileSync('node', [SIGNAL_HELPER, row.file], {
      cwd: options.root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    return refuse(`signal extraction failed for ${row.file}: ${String(error.stderr ?? error.message).trim()}`);
  }
  const entry = output
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .find((candidate) => candidate.fullName === row.title);
  if (!entry) {
    return refuse(`row ${row.id}: no test "${row.title}" in ${row.file}`);
  }
  appendFileSync(
    files.ledger,
    `${JSON.stringify({row: row.id, file: row.file, title: row.title, signal: entry.signal})}\n`,
  );
};

const amend = (args) => {
  const options = parseOptions(args, ['--plan-dir', '--root', '--changes']);
  const files = planPaths(options['plan-dir']);
  if (!existsSync(files.approved)) refuse('tests.approved.json is missing');
  if (!existsSync(options.root) || !statSync(options.root).isDirectory()) {
    refuse(`root ${options.root} is not a directory`);
  }
  const current = loadTable(files.table);
  const approved = loadTable(files.approved);
  let changes;
  try {
    changes = JSON.parse(readFileSync(options.changes, 'utf8'));
  } catch {
    return refuse(`cannot read changes file ${options.changes}`);
  }
  const removeIds = new Set(changes.remove ?? []);
  const replacements = new Map(
    (changes.replace ?? []).map((row) => [row.id, row]),
  );
  const next = current.rows
    .filter((row) => !removeIds.has(row.id))
    .map((row) => replacements.get(row.id) ?? row);
  next.push(...(changes.add ?? []));

  const problems = tableProblems(next);
  if (problems.length > 0) refuseAll(problems);

  const approvedSecurity = approved.rows.filter(isSecurity);
  const droppedFlags = approvedSecurity.filter((approvedRow) =>
    next.some((row) => row.id === approvedRow.id && !isSecurity(row)),
  );
  if (droppedFlags.length > 0) {
    refuse(
      `security flag dropped on ${droppedFlags.map((row) => row.id).join(', ')}`,
    );
  }
  // drift.mjs reports any change of an approved row's security value as
  // flag-lost, and securityCheck judges by the approved action, so amend
  // refuses a change of either.
  for (const [field, label] of [['security', 'kind'], ['action', 'action']]) {
    const changed = approvedSecurity.filter((approvedRow) =>
      next.some(
        (row) =>
          row.id === approvedRow.id &&
          isSecurity(row) &&
          row[field] !== approvedRow[field],
      ),
    );
    if (changed.length > 0) {
      refuse(`security ${label} changed on ${changed.map((row) => row.id).join(', ')}`);
    }
  }
  const keptKeys = new Set(next.filter(isSecurity).map((row) => row.source));
  const lostKeys = [
    ...new Set(approvedSecurity.map((row) => row.source)),
  ].filter((key) => !keptKeys.has(key));
  if (lostKeys.length > 0) {
    for (const key of lostKeys) process.stdout.write(`checkpoint: ${key}\n`);
    refuse(`security fold loses requirement keys: ${lostKeys.join(', ')}`);
  }

  writeFileSync(files.table, serialize({...JSON.parse(readFileSync(files.table, 'utf8')), rows: next}));
};

const [command, ...rest] = process.argv.slice(2);
const commands = {
  verify,
  'covered-flows': coveredFlowsCommand,
  'sole-rows': soleRows,
  'flag-candidates': flagCandidatesCommand,
  approve,
  'record-security': recordSecurity,
  amend,
};
if (!commands[command]) usage();
commands[command](rest);
