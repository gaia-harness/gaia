// Plan-folder document upkeep for plan-audit-apply.mjs: the README
// `## Test design` render, the task docs' `- Test:` lines and the
// ORCHESTRATOR.md `- Security writer:` lines. Library only, no CLI.
//
// Every write goes through a temp file in the file's own folder and a rename.
// The README render follows `.claude/skills/gaia/references/plan/test-table.md`
// (`## README rendering`): columns id, source, case, file, title, layer, task,
// action, security, then one line per `instructionKeys` entry.

import {readFileSync, renameSync, writeFileSync} from 'node:fs';
import path from 'node:path';

import {TEST_LINE} from './task-docs.mjs';

const COLUMNS = [
  'id',
  'source',
  'case',
  'file',
  'title',
  'layer',
  'task',
  'action',
  'security',
];

export const writeAtomic = (file, text) => {
  const temp = path.join(
    path.dirname(file),
    `.${path.basename(file)}.plan-apply.tmp`,
  );
  writeFileSync(temp, text);
  renameSync(temp, file);
};

const cell = (value) =>
  String(value ?? '')
    .replaceAll('|', '\\|')
    .replaceAll('\n', ' ');

const renderTable = ({rows, instructionKeys}) => {
  const tableLines = [
    `| ${COLUMNS.join(' | ')} |`,
    `| ${COLUMNS.map(() => '---').join(' | ')} |`,
    ...rows.map((row) => `| ${COLUMNS.map((column) => cell(row[column])).join(' | ')} |`),
  ];
  const keyLines = (Array.isArray(instructionKeys) ? instructionKeys : []).map(
    (entry) => `- \`${entry.source}\`: ${entry.reason}`,
  );
  return {tableLines, keyLines};
};

// Re-renders the table and the instruction-key lines inside README's
// `## Test design` section; every other line stays. A README with no such
// section or table comes back unchanged.
export const renderReadme = (text, table) => {
  const lines = text.split('\n');
  const heading = lines.findIndex((line) => /^## Test design[ \t]*$/.test(line));
  if (heading < 0) return text;
  let end = lines.findIndex((line, at) => at > heading && /^## /.test(line));
  if (end < 0) end = lines.length;
  const start = lines.findIndex(
    (line, at) => at > heading && at < end && line.startsWith('|'),
  );
  if (start < 0) return text;
  let tableEnd = start;
  while (tableEnd < end && lines[tableEnd].startsWith('|')) tableEnd += 1;
  let probe = tableEnd;
  while (probe < end && lines[probe].trim() === '') probe += 1;
  let runEnd = probe;
  while (runEnd < end && /^- `[^`]+`: /.test(lines[runEnd])) runEnd += 1;
  const replaceEnd = runEnd > probe ? runEnd : tableEnd;
  const {tableLines, keyLines} = renderTable(table);
  const fresh = keyLines.length > 0 ? [...tableLines, '', ...keyLines] : tableLines;
  return [...lines.slice(0, start), ...fresh, ...lines.slice(replaceEnd)].join('\n');
};

const testKey = (row) => `${row.task}\u0000${row.file}\u0000${row.title}`;

const keySet = (rows) => new Set(rows.map(testKey));

const readDoc = (planDir, stem) => {
  try {
    return readFileSync(path.join(planDir, `${stem}.md`), 'utf8').split('\n');
  } catch {
    return null;
  }
};

// Keeps each owning task doc's `- Test:` lines in step with the rows: a line
// goes only when no remaining row of that task names its file and title, and a
// new line follows the doc's last `- Test:` line.
export const syncTestLines = (planDir, beforeRows, afterRows) => {
  const before = keySet(beforeRows);
  const after = keySet(afterRows);
  const edits = new Map();
  const edit = (stem) => {
    if (!edits.has(stem)) edits.set(stem, {remove: [], add: []});
    return edits.get(stem);
  };
  for (const key of before) {
    if (!after.has(key)) {
      const [stem, file, title] = key.split('\u0000');
      edit(stem).remove.push({file, title});
    }
  }
  for (const key of after) {
    if (!before.has(key)) {
      const [stem, file, title] = key.split('\u0000');
      edit(stem).add.push({file, title});
    }
  }
  for (const [stem, {remove, add}] of edits) {
    let lines = readDoc(planDir, stem);
    if (lines === null) continue;
    lines = lines.filter((line) => {
      const match = TEST_LINE.exec(line);
      return !(match && remove.some(({file, title}) => match[1] === file && match[2] === title));
    });
    for (const {file, title} of add) {
      const present = lines.some((line) => {
        const match = TEST_LINE.exec(line);
        return match && match[1] === file && match[2] === title;
      });
      if (present) continue;
      let last = -1;
      lines.forEach((line, at) => {
        if (/^\s*[-*]\s+Test:/.test(line)) last = at;
      });
      const fresh = `- Test: ${file} › ${title}`;
      if (last >= 0) lines.splice(last + 1, 0, fresh);
      else if (lines.at(-1) === '') lines.splice(lines.length - 1, 0, fresh);
      else lines.push(fresh);
    }
    writeAtomic(path.join(planDir, `${stem}.md`), lines.join('\n'));
  }
};

// The README `| Phase <N> |` row naming the backticked task stem, as N.
export const phaseOfTask = (readmeText, stem) => {
  for (const line of readmeText.split('\n')) {
    const match = /^\|\s*Phase\s+(\d+)\s*\|/.exec(line);
    if (match && line.includes(`\`${stem}\``)) return Number(match[1]);
  }
  return null;
};

// [start, end) lines of the `**Phase <N>, ` entry outside fenced blocks.
const phaseEntry = (lines, phase) => {
  let fenced = false;
  let start = -1;
  for (let at = 0; at < lines.length; at += 1) {
    const line = lines[at];
    if (line.trim().startsWith('```')) fenced = !fenced;
    if (fenced) continue;
    if (start >= 0 && (/^\*\*Phase /.test(line) || /^## /.test(line))) return [start, at];
    if (start < 0 && line.startsWith(`**Phase ${phase}, `)) start = at;
  }
  return start >= 0 ? [start, lines.length] : null;
};

// Lists `rowId` on the phase entry's `- Security writer: <k> rows (<ids>)`
// line, raising the count, or adds the line after the entry's Tasks line.
// Returns the new ORCHESTRATOR.md text, or null when the entry is absent.
export const addSecurityWriterRow = (text, phase, rowId) => {
  const lines = text.split('\n');
  const span = phaseEntry(lines, phase);
  if (span === null) return null;
  const [start, end] = span;
  for (let at = start; at < end; at += 1) {
    const match = /^(\s*- Security writer: )\d+ rows \(([^)]*)\)\s*$/.exec(lines[at]);
    if (!match) continue;
    const ids = match[2].split(',').map((id) => id.trim()).filter(Boolean);
    if (!ids.includes(rowId)) ids.push(rowId);
    lines[at] = `${match[1]}${ids.length} rows (${ids.join(', ')})`;
    return lines.join('\n');
  }
  let after = start;
  for (let at = start; at < end; at += 1) {
    if (/^\s*- Tasks\b/.test(lines[at])) after = at;
  }
  if (after === start) {
    for (let at = start + 1; at < end; at += 1) {
      if (/^\s*- /.test(lines[at])) {
        after = at;
        break;
      }
    }
  }
  lines.splice(after + 1, 0, `- Security writer: 1 rows (${rowId})`);
  return lines.join('\n');
};
