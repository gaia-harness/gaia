#!/usr/bin/env node
// Applies exact text replacements an audit lens wrote for plan documents, and
// hands everything it will not apply on untouched.
//
//   doc-replace.mjs --plan-dir <dir> --items <file> [--dry-run]
//
// Items file: a JSON array of `{finding, index, file, old, new}`, any order.
// `file` names a document at the plan folder's top level. Items are applied in
// (file, finding, index) order, each only when `old` occurs exactly once in the
// file's content as it stands after the earlier replacements in that order.
// Each changed file is written through a temp file in its own folder and then
// renamed. `--dry-run` computes the same result and writes nothing.
//
// Routes, printed as one JSON line on stdout:
//   {"applied":[{finding,index}],
//    "fixup":[{finding,index,reason}],
//    "refused":[{finding,index,reason}]}
// - applied: `old` occurred once and was replaced by `new`.
// - fixup: malformed (not an object, `file`, `old` or `new` not a string, `old`
//   empty, file absent or not a regular file) or `old` matched zero or several
//   times; the item is left for a fix-up agent, untouched.
// - refused: the target is not allowed. The target checks run before the
//   file-absent check, so a nonexistent path outside the plan folder is
//   refused. Refused: a `file` that is not `task-*.md`, `README.md` or
//   `ORCHESTRATOR.md` at the plan folder's top level (so `tests.json`,
//   `KICKOFF.md`, anything under `audit/` and any path leaving the folder),
//   a file that resolves outside the resolved plan folder or is itself a
//   symlink, an `old` whose match falls inside README's `## Test design`
//   section, and an `old` holding a line that starts `- Security writer:`.
//
// Each refusal also prints `doc-replace: <reason>` on stderr.
//
// Exit 0 nothing refused, 1 a refusal or an unreadable plan folder or items
// file, 2 usage.
//
// Exports: `applyReplacements({planDir, items, dryRun})` returns
// `{applied, fixup, refused}`; `targetProblem(planDir, file, old)` returns the
// reason a target is refused, or null.

import {lstatSync, readFileSync, realpathSync} from 'node:fs';
import {basename, dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

import {writeAtomic} from './plan-docs.mjs';

const ALLOWED_NAME = /^(task-.+\.md|README\.md|ORCHESTRATOR\.md)$/;
const SECURITY_WRITER = /^- Security writer:/m;

const occurrences = (text, needle) => {
  const starts = [];
  for (
    let at = text.indexOf(needle);
    at !== -1;
    at = text.indexOf(needle, at + 1)
  ) {
    starts.push(at);
  }
  return starts;
};

// [start, end) of README's `## Test design` section: its heading to the next
// `## ` heading, or the end of the text.
const testDesignSpan = (text) => {
  const heading = /^## Test design[ \t]*$/m.exec(text);
  if (!heading) return null;
  const rest = text.slice(heading.index + heading[0].length);
  const next = /^## /m.exec(rest);
  const end = next
    ? heading.index + heading[0].length + next.index
    : text.length;
  return [heading.index, end];
};

const lineSpans = (text, pattern) => {
  const spans = [];
  let offset = 0;
  for (const line of text.split('\n')) {
    if (pattern.test(line)) spans.push([offset, offset + line.length]);
    offset += line.length + 1;
  }
  return spans;
};

const overlaps = (start, end, spans) =>
  spans.some(([from, to]) => start < to && end > from);

const readIfThere = (path) => {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return null;
  }
};

export function targetProblem(planDir, file, old) {
  if (typeof file !== 'string' || file === '') {
    return 'the target file is not a name';
  }
  let planReal;
  try {
    planReal = realpathSync(planDir);
  } catch {
    return 'the plan folder cannot be resolved';
  }
  const target = resolve(planReal, file);
  if (dirname(target) !== planReal || file.includes('\0')) {
    return `${file} is outside the plan folder's top level`;
  }
  const name = basename(target);
  if (name === 'tests.json' || !ALLOWED_NAME.test(name) || name !== file) {
    return `${file} is not a task doc, README.md or ORCHESTRATOR.md`;
  }
  let stats = null;
  try {
    stats = lstatSync(target);
  } catch {
    // A file that is not there yet has no symlink to refuse.
  }
  if (stats?.isSymbolicLink()) return `${file} is a symlink`;
  if (stats) {
    let real;
    try {
      real = realpathSync(target);
    } catch {
      return `${file} cannot be resolved`;
    }
    if (dirname(real) !== planReal) {
      return `${file} resolves outside the plan folder`;
    }
  }
  if (typeof old !== 'string' || old === '') return null;
  if (SECURITY_WRITER.test(old)) {
    return 'the old text holds a Security writer line';
  }
  const content = readIfThere(target);
  if (content === null) return null;
  const starts = occurrences(content, old);
  if (name === 'README.md') {
    const span = testDesignSpan(content);
    if (span && starts.some((at) => overlaps(at, at + old.length, [span]))) {
      return 'the old text falls inside README.md ## Test design';
    }
  }
  const writerLines = lineSpans(content, SECURITY_WRITER);
  if (starts.some((at) => overlaps(at, at + old.length, writerLines))) {
    return 'the old text reaches a Security writer line';
  }
  return null;
}

const compareText = (left, right) => {
  if (left === right) return 0;
  return left < right ? -1 : 1;
};

const sortKey = (item) => {
  const record = item !== null && typeof item === 'object' ? item : {};
  return [
    typeof record.file === 'string' ? record.file : '',
    String(record.finding ?? ''),
    Number.isFinite(record.index) ? record.index : 0,
  ];
};

const compareItems = (left, right) => {
  const [leftFile, leftFinding, leftIndex] = sortKey(left);
  const [rightFile, rightFinding, rightIndex] = sortKey(right);
  return (
    compareText(leftFile, rightFile) ||
    compareText(leftFinding, rightFinding) ||
    leftIndex - rightIndex
  );
};

const idOf = (item) => {
  const record = item !== null && typeof item === 'object' ? item : {};
  return {finding: record.finding ?? null, index: record.index ?? null};
};

export function applyReplacements({planDir, items, dryRun = false}) {
  const applied = [];
  const fixup = [];
  const refused = [];
  const planReal = realpathSync(planDir);
  const contents = new Map();
  const changed = new Set();

  for (const item of [...items].sort(compareItems)) {
    const id = idOf(item);
    const isRecord = item !== null && typeof item === 'object';
    if (!isRecord || typeof item.file !== 'string') {
      fixup.push({...id, reason: 'malformed item: file is missing'});
      continue;
    }
    const problem = targetProblem(
      planDir,
      item.file,
      typeof item.old === 'string' ? item.old : undefined,
    );
    if (problem !== null) {
      refused.push({...id, reason: problem});
      continue;
    }
    if (typeof item.old !== 'string' || item.old === '') {
      fixup.push({...id, reason: 'malformed item: old is missing or empty'});
      continue;
    }
    if (typeof item.new !== 'string') {
      fixup.push({...id, reason: 'malformed item: new is missing'});
      continue;
    }
    const path = join(planReal, item.file);
    if (!contents.has(path)) {
      const text = lstatSync(path, {throwIfNoEntry: false})?.isFile()
        ? readIfThere(path)
        : null;
      contents.set(path, text);
    }
    const current = contents.get(path);
    if (current === null) {
      fixup.push({...id, reason: `${item.file} is absent or not a file`});
      continue;
    }
    const starts = occurrences(current, item.old);
    if (starts.length !== 1) {
      fixup.push({
        ...id,
        reason: `old text matched ${starts.length} times, not exactly once`,
      });
      continue;
    }
    const [at] = starts;
    contents.set(
      path,
      current.slice(0, at) + item.new + current.slice(at + item.old.length),
    );
    changed.add(path);
    applied.push(id);
  }

  if (!dryRun) {
    for (const path of changed) writeAtomic(path, contents.get(path));
  }
  return {applied, fixup, refused};
}

const usage = () => {
  process.stderr.write(
    'usage: doc-replace.mjs --plan-dir <dir> --items <file> [--dry-run]\n',
  );
  process.exit(2);
};

const main = () => {
  const args = process.argv.slice(2);
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    if (flag === '--dry-run') {
      options.dryRun = true;
    } else if (flag === '--plan-dir' || flag === '--items') {
      const value = args[index + 1];
      if (value === undefined) usage();
      options[flag.slice(2)] = value;
      index += 1;
    } else {
      usage();
    }
  }
  if (!options['plan-dir'] || !options.items) usage();

  let result;
  try {
    const items = JSON.parse(readFileSync(options.items, 'utf8'));
    if (!Array.isArray(items)) throw new Error('items file is not a JSON array');
    result = applyReplacements({
      planDir: options['plan-dir'],
      items,
      dryRun: options.dryRun === true,
    });
  } catch (error) {
    process.stderr.write(`doc-replace: ${error.message}\n`);
    process.exit(1);
  }
  for (const {finding, index, reason} of result.refused) {
    process.stderr.write(`doc-replace: ${finding} ${index}: ${reason}\n`);
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exit(result.refused.length > 0 ? 1 : 0);
};

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
