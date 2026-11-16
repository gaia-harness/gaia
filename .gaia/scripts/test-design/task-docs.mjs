// The task docs of a plan folder and the structured lines test-table.mjs reads
// from them; .claude/skills/gaia/references/plan/test-table.md owns the line
// grammar.

import {readFileSync, readdirSync} from 'node:fs';
import path from 'node:path';

import {isTestPath, TEST_FILE_SUFFIX} from './table.mjs';

export const TEST_LINE = /^\s*[-*]\s+Test:\s+(.+?) › (.+?)\s*$/;
export const DELETE_LINE = /^\s*[-*]\s+Delete:\s+(.+?)\s*$/;
export const EXEMPT_LINE = /^\s*[-*]\s+(Test:|Flow test\b|Pin update:)/;
export const TEST_PATH = new RegExp(String.raw`[^\s\x60'"()<>]+\.${TEST_FILE_SUFFIX}\b`);

export const taskDocuments = (planDirectory) =>
  readdirSync(planDirectory)
    .filter((name) => /^task-.+\.md$/.test(name))
    .sort()
    .map((name) => ({
      stem: name.replace(/\.md$/, ''),
      lines: readFileSync(path.join(planDirectory, name), 'utf8').split('\n'),
    }));

export const deleteLines = (documents) =>
  documents.flatMap((document) =>
    document.lines.flatMap((line, index) => {
      const match = DELETE_LINE.exec(line);
      return match ? [{stem: document.stem, index, file: match[1]}] : [];
    }),
  );

// The source paths the plan's task docs mark deleted; a Delete line naming a
// test path marks nothing.
export const deletedPaths = (documents) =>
  new Set(
    deleteLines(documents)
      .map(({file}) => file)
      .filter((file) => !isTestPath(file)),
  );
