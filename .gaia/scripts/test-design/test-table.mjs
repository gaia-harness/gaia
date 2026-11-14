#!/usr/bin/env node
// CLI over the test-design table in a plan folder.
//
//   test-table.mjs verify --plan-dir <dir> --keys <file>
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
  readdirSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

import {readTable, validateRow} from './table.mjs';

const SIGNAL_HELPER = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  'test-signals',
  'extract-test-signals.mjs',
);

const TEST_LINE = /^\s*[-*]\s+Test:\s+(.+?) › (.+?)\s*$/;
const EXEMPT_LINE = /^\s*[-*]\s+(Test:|Flow test\b|Pin update:)/;
const TEST_PATH = /[^\s`'"()<>]+\.(?:test\.tsx?|spec\.ts|stories\.tsx?|bats)\b/;

const usage = () => {
  process.stderr.write(
    'usage: test-table.mjs verify --plan-dir <dir> --keys <file> | approve --plan-dir <dir> [--auto] | record-security --plan-dir <dir> --root <tree> --row <id> | amend --plan-dir <dir> --root <tree> --changes <file>\n',
  );
  process.exit(2);
};

const refuse = (message) => {
  process.stderr.write(`test-table: ${message}\n`);
  process.exit(1);
};

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

const isSecurity = (row) => row.security !== undefined && row.security !== 'none';

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

// Every row problem a table can have on its own: invalid rows, duplicate ids,
// and rows sharing one test without distinct caseKeys.
const tableProblems = (rows) => {
  const problems = [];
  const seenIds = new Set();
  rows.forEach((row, index) => {
    const label = row && row.id ? `row ${row.id}` : `row #${index + 1}`;
    for (const reason of validateRow(row)) {
      problems.push(`${label}: ${reason}`);
    }
    if (row && typeof row.id === 'string') {
      if (seenIds.has(row.id)) problems.push(`duplicate id ${row.id}`);
      seenIds.add(row.id);
    }
  });
  const byTest = new Map();
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    const key = `${row.file}\u0000${row.title}`;
    byTest.set(key, [...(byTest.get(key) ?? []), row]);
  }
  for (const group of byTest.values()) {
    if (group.length < 2) continue;
    const caseKeys = group.map((row) => row.caseKey);
    const distinct =
      caseKeys.every((caseKey) => typeof caseKey === 'string' && caseKey) &&
      new Set(caseKeys).size === caseKeys.length;
    if (!distinct) {
      problems.push(
        `rows ${group.map((row) => row.id).join(', ')} share ${group[0].file} "${group[0].title}" without distinct caseKeys`,
      );
    }
  }
  return problems;
};

const taskDocuments = (planDirectory) =>
  readdirSync(planDirectory)
    .filter((name) => /^task-.+\.md$/.test(name))
    .sort()
    .map((name) => ({
      stem: name.replace(/\.md$/, ''),
      lines: readFileSync(path.join(planDirectory, name), 'utf8').split('\n'),
    }));

const verify = (args) => {
  const options = parseOptions(args, ['--plan-dir', '--keys']);
  const planDirectory = options['plan-dir'];
  const files = planPaths(planDirectory);
  if (!existsSync(files.table)) refuse('tests.json is missing');
  const {rows} = loadTable(files.table);
  const failures = tableProblems(rows);

  let keys;
  try {
    keys = readFileSync(options.keys, 'utf8')
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean);
  } catch {
    return refuse(`cannot read keys file ${options.keys}`);
  }
  const keySet = new Set(keys);
  const citedKeys = new Set(
    rows.filter((row) => row && typeof row === 'object').map((row) => row.source),
  );
  for (const key of keys) {
    if (!citedKeys.has(key)) failures.push(`requirement key ${key} has no row`);
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

  if (failures.length > 0) {
    for (const failure of failures) {
      process.stderr.write(`test-table: ${failure}\n`);
    }
    process.exit(1);
  }
};

const approve = (args) => {
  const options = parseOptions(args, ['--plan-dir'], ['--auto']);
  const files = planPaths(options['plan-dir']);
  if (existsSync(files.approved)) refuse('tests.approved.json already exists');
  if (!existsSync(files.table)) refuse('tests.json is missing');
  const table = loadTable(files.table);
  let bytes;
  if (options.auto) {
    const held = [];
    for (const row of table.rows) {
      if (row.action === 'retire' && isSecurity(row)) {
        row.held = 'auto-mode';
        held.push(row.id);
      }
    }
    if (held.length > 0) {
      bytes = serialize({...JSON.parse(readFileSync(files.table, 'utf8')), rows: table.rows});
      writeFileSync(files.table, bytes);
      for (const id of held) process.stdout.write(`held ${id}\n`);
    }
  }
  bytes = readFileSync(files.table);
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
  if (problems.length > 0) {
    for (const problem of problems) {
      process.stderr.write(`test-table: ${problem}\n`);
    }
    process.exit(1);
  }

  const approvedSecurity = approved.rows.filter(isSecurity);
  const droppedFlags = approvedSecurity.filter((approvedRow) =>
    next.some((row) => row.id === approvedRow.id && !isSecurity(row)),
  );
  if (droppedFlags.length > 0) {
    refuse(
      `security flag dropped on ${droppedFlags.map((row) => row.id).join(', ')}`,
    );
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
  approve,
  'record-security': recordSecurity,
  amend,
};
if (!commands[command]) usage();
commands[command](rest);
