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
// a lone `}` at the `@test` line's own indentation. firstLine and ranges are
// 1-based inclusive lines of that block.
//
// signal: "sha256:" + lowercase-hex sha256 of the block's lines with comment
// lines (first non-blank character `#`) dropped, each line trimmed, and every
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
//   6  an unterminated `@test` block

import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

export class BatsFileRefusal extends Error {}

const TEST_LINE = /^(\s*)@test\s+(?:"((?:[^"\\]|\\.)*)"|'([^']*)')\s*\{\s*$/;

function undoDoubleQuoteEscapes(title) {
  return title.replace(/\\(["\\$`])/g, '$1');
}

function normalize(lines) {
  return lines
    .filter((line) => !line.trimStart().startsWith('#'))
    .map((line) => line.trim())
    .join('\n')
    .replace(/\s+/g, ' ')
    .trim();
}

// Returns the test records of a bats source; throws BatsFileRefusal on an
// unterminated block.
export function extractBatsSignals(source) {
  const lines = source.split('\n');
  const records = [];
  for (let index = 0; index < lines.length; index++) {
    const match = TEST_LINE.exec(lines[index].replace(/\r$/, ''));
    if (!match) {
      continue;
    }
    const [, indent, doubleQuoted, singleQuoted] = match;
    const title =
      doubleQuoted === undefined
        ? singleQuoted
        : undoDoubleQuoteEscapes(doubleQuoted);
    const closer = `${indent}}`;
    let end = -1;
    for (let cursor = index + 1; cursor < lines.length; cursor++) {
      if (lines[cursor].replace(/\s+$/, '') === closer) {
        end = cursor;
        break;
      }
    }
    if (end === -1) {
      throw new BatsFileRefusal(
        `unterminated @test block "${title}" starting at line ${index + 1}`,
      );
    }
    const signal = createHash('sha256')
      .update(normalize(lines.slice(index, end + 1)))
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
