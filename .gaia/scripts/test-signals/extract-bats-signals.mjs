#!/usr/bin/env node
// Extract per-test (fullName, content signal) pairs from a bats file, for the
// worthiness audit and the merge-time presence gate that read a bats flow test
// through the one entry point, ./extract-test-signals.mjs (which dispatches a
// path ending `.bats` here before it resolves TypeScript). Node built-ins only.
//
// Invocation:
//   node .gaia/scripts/test-signals/extract-bats-signals.mjs <path>
//
// Output (stdout): one JSON object per `@test "<title>" {` block, in file order:
//   {"fullName":"...","signal":"sha256:...","kind":"runtime","firstLine":N,
//    "ranges":[[start,end]]}
// fullName is the title with the bats escapes undone (a double-quoted title
// reads \" \\ \$ and \` as the escaped character; a single-quoted title is
// literal). A block runs from its `@test` line to the first later line that is
// a lone `}` at the `@test` line's own indentation, outside any heredoc body; a
// one-line `@test "<title>" { ...; }` is a block of that single line. firstLine
// and ranges are 1-based inclusive lines of that block.
//
// signal: "sha256:" + lowercase-hex sha256 of the block's lines with comment
// lines (first non-blank character `#`, outside a heredoc body) dropped, each line trimmed, and every
// whitespace run collapsed to one space. A comment reword or a reformat leaves
// it unchanged; any edit to what the test executes changes it. A trailing
// comment on a command line is part of that line and does change it.
//
// kind is always "runtime": a bats test has no type-level form.
//
// Exit codes (each failure writes one stderr line and nothing to stdout):
//   0  success, including zero tests (emits nothing)
//   2  missing path argument
//   4  cannot read the file
//   6  an unterminated `@test` block, or an `@test` line the pattern misses

import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

export class BatsFileRefusal extends Error {}

const TEST_LINE =
  /^(\s*)@test\s+(?:"((?:[^"\\]|\\.)*)"|'([^']*)')\s*\{(.*)$/;
const TEST_KEYWORD = /^\s*@test\b/;
// One scan token per match: a here-string or a quoted string (both skipped, so
// a `<<` quoted as data opens nothing) or a heredoc opener.
const HEREDOC_TOKEN =
  /<<<|(<<-?)\s*(?:"([^"]+)"|'([^']+)'|\\?([A-Za-z_]\w*))|"(?:[^"\\]|\\.)*"|'[^']*'/g;

function findHeredocOpener(line) {
  for (const token of line.matchAll(HEREDOC_TOKEN)) {
    if (token[1] !== undefined) {
      return {
        marker: token[2] ?? token[3] ?? token[4],
        stripTabs: token[1] === '<<-',
      };
    }
  }
  return null;
}

function undoDoubleQuoteEscapes(title) {
  return title.replace(/\\(["\\$`])/g, '$1');
}

// A heredoc body line keeps its text whole: a `#` there is data the test
// writes, not a comment.
function normalize(lines, verbatimIndexes) {
  return lines
    .filter(
      (line, index) =>
        verbatimIndexes.has(index) || !line.trimStart().startsWith('#'),
    )
    .map((line) => line.trim())
    .join('\n')
    .replace(/\s+/g, ' ')
    .trim();
}

// Finds the closing line of a block opened at `index`, skipping heredoc bodies
// so a `}` inside one does not end it. A heredoc opener the scan misreads (a
// `<<` in arithmetic, or inside a quoted string that spans lines) swallows
// lines up to the next line equal to the misread marker; with no such line it
// ends unterminated and refuses.
function findBlockEnd(lines, index, closer) {
  const heredocLines = new Set();
  let marker = null;
  let stripTabs = false;
  for (let cursor = index + 1; cursor < lines.length; cursor++) {
    const line = lines[cursor].replace(/\r$/, '');
    if (marker !== null) {
      heredocLines.add(cursor);
      if ((stripTabs ? line.replace(/^\t+/, '') : line) === marker) {
        marker = null;
      }
      continue;
    }
    if (line.replace(/\s+$/, '') === closer) {
      return {end: cursor, heredocLines};
    }
    if (line.trimStart().startsWith('#')) {
      continue;
    }
    const opener = findHeredocOpener(line);
    if (opener) {
      ({marker, stripTabs} = opener);
    }
  }
  return {end: -1, heredocLines};
}

// Returns the test records of a bats source; throws BatsFileRefusal on an
// unterminated block or an `@test` line the pattern does not read.
export function extractBatsSignals(source) {
  const lines = source.split('\n');
  const records = [];
  for (let index = 0; index < lines.length; index++) {
    const text = lines[index].replace(/\r$/, '');
    const match = TEST_LINE.exec(text);
    if (!match) {
      if (TEST_KEYWORD.test(text)) {
        throw new BatsFileRefusal(`unrecognized @test line at line ${index + 1}`);
      }
      continue;
    }
    const [, indent, doubleQuoted, singleQuoted, afterBrace] = match;
    const title =
      doubleQuoted === undefined
        ? singleQuoted
        : undoDoubleQuoteEscapes(doubleQuoted);
    const rest = afterBrace.trim();
    const isOneLine =
      rest !== '' && !rest.startsWith('#') && rest.endsWith('}');
    let end = index;
    let heredocLines = new Set();
    if (!isOneLine) {
      ({end, heredocLines} = findBlockEnd(lines, index, `${indent}}`));
    }
    if (end === -1) {
      throw new BatsFileRefusal(
        `unterminated @test block "${title}" starting at line ${index + 1}`,
      );
    }
    const verbatimIndexes = new Set(
      [...heredocLines].map((lineIndex) => lineIndex - index),
    );
    const signal = createHash('sha256')
      .update(normalize(lines.slice(index, end + 1), verbatimIndexes))
      .digest('hex');
    records.push({
      fullName: title,
      signal: `sha256:${signal}`,
      kind: 'runtime',
      firstLine: index + 1,
      ranges: [[index + 1, end + 1]],
    });
    index = end;
  }
  return records;
}

// The bats branch of the one entry point, ./extract-test-signals.mjs: same
// stdout, same exit codes (0, 4, 6), stderr prefixed with that entry point's
// name. Always exits the process.
export function runBatsSignalsCli(filePath, useStdin) {
  let source;
  try {
    source = readFileSync(useStdin ? 0 : filePath, 'utf8');
  } catch (err) {
    process.stderr.write(
      `extract-test-signals: cannot read ${filePath}: ${err.message}\n`,
    );
    process.exit(4);
  }
  try {
    const out = extractBatsSignals(source)
      .map((record) => JSON.stringify(record))
      .join('\n');
    if (out) {
      process.stdout.write(`${out}\n`);
    }
  } catch (err) {
    if (!(err instanceof BatsFileRefusal)) {
      throw err;
    }
    process.stderr.write(`extract-test-signals: ${filePath}: ${err.message}\n`);
    process.exit(6);
  }
  process.exit(0);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const filePath = process.argv.slice(2).find((a) => !a.startsWith('--'));
  if (!filePath) {
    process.stderr.write('extract-bats-signals: missing <path> argument\n');
    process.exit(2);
  }
  let source;
  try {
    source = readFileSync(filePath, 'utf8');
  } catch (err) {
    process.stderr.write(
      `extract-bats-signals: cannot read ${filePath}: ${err.message}\n`,
    );
    process.exit(4);
  }
  try {
    const out = extractBatsSignals(source)
      .map((record) => JSON.stringify(record))
      .join('\n');
    if (out) {
      process.stdout.write(`${out}\n`);
    }
  } catch (err) {
    if (!(err instanceof BatsFileRefusal)) {
      throw err;
    }
    process.stderr.write(`extract-bats-signals: ${filePath}: ${err.message}\n`);
    process.exit(6);
  }
}
