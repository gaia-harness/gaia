// Readers for lens-brief.mjs: pull prompt text out of the audit docs at render
// time. Nothing of the docs' prompt text is copied here; this module only knows
// where each piece lives (a section heading, a blockquote label, a table
// column) and which slot names each source owns.

import {readFileSync} from 'node:fs';
import path from 'node:path';

export const DOCS = {
  audit: '.claude/skills/gaia/references/spec/audit.md',
  decomposition: '.claude/skills/gaia/references/plan/decomposition-audit.md',
  dispatch: '.claude/skills/gaia/references/spec/lens-dispatch.md',
};

export class Refusal extends Error {}

export const readLines = (root, rel) => {
  try {
    return readFileSync(path.join(root, rel), 'utf8').split('\n');
  } catch {
    throw new Refusal(`cannot read ${rel} under ${root}`);
  }
};

// Lines under the first heading starting with `heading`, up to the next
// heading of the same or a higher level.
export const section = (lines, heading) => {
  const level = heading.match(/^#+/)[0].length;
  const start = lines.findIndex((line) => line.startsWith(heading));
  if (start < 0) throw new Refusal(`no section "${heading}"`);
  const out = [];
  for (const line of lines.slice(start + 1)) {
    const hashes = line.match(/^(#+) /);
    if (hashes && hashes[1].length <= level) break;
    out.push(line);
  }
  return out;
};

// Blockquote blocks of some lines: `before` is the nearest non-blank line above
// the block, `text` the block with its `> ` markers stripped.
export const blockquotes = (lines) => {
  const blocks = [];
  let before = '';
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('>')) {
      if (lines[i].trim()) before = lines[i];
      continue;
    }
    const quoted = [];
    while (i < lines.length && lines[i].startsWith('>')) {
      quoted.push(lines[i].replace(/^> ?/, ''));
      i++;
    }
    i--;
    blocks.push({before, text: quoted.join('\n')});
  }
  return blocks;
};

export const labelledBlockquote = (lines, label) => {
  const block = blockquotes(lines).find((b) => b.before.startsWith(label));
  if (!block?.text.trim()) throw new Refusal(`no blockquote labelled "${label}"`);
  return block.text;
};

// Single-pass slot fill. `values` maps `<slot>` to its value; any slot of the
// closed list present in `text` with no value is reported, never guessed.
// Text a value brings in is not scanned again.
export const fill = (text, values) => {
  const names = Object.keys(values);
  const unfilled = new Set();
  if (!names.length) return text;
  const pattern = new RegExp(
    names.map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'),
    'g',
  );
  const out = text.replace(pattern, (slot) => {
    const value = values[slot];
    if (value === undefined || value === '') {
      unfilled.add(slot);
      return slot;
    }
    return value;
  });
  if (unfilled.size) {
    throw new Refusal(`slot left unfilled: ${[...unfilled].join(', ')}`);
  }
  return out;
};

const cells = (row) =>
  row
    .trim()
    .replace(/^\||\|$/g, '')
    .split('|')
    .map((cell) => cell.trim());

const tableRows = (lines) =>
  lines.filter((line) => line.startsWith('|')).map(cells);

// Preamble slot -> how its row is named in `## Caller slots`.
const PREAMBLE_ROWS = {
  '<ARTIFACT>': (label) => label.startsWith('Artifact under audit'),
  '<critical meaning>': (label) => label === '`critical`',
  '<defect target>': (label) => label === 'Defect target',
  '<evidence form>': (label) => label === 'Evidence form',
  '<FINDINGS_DIR>': (label) => label.startsWith('Findings directory'),
  '<first Read>': (label) => label === 'First Read',
  '<major meaning>': (label) => label === '`major`',
  '<minor meaning>': (label) => label === '`minor`',
  '<write tool>': (label) => label === 'Write tool',
};

export const preambleSlots = (dispatchLines, kind, artifact, specId) => {
  const rows = tableRows(section(dispatchLines, '## Caller slots'));
  const column = kind === 'spec' ? 1 : 2;
  const own =
    kind === 'spec'
      ? {'<DRAFT_PATH>': artifact, '<spec_id>': specId}
      : {'<PLAN_DIR>': artifact};
  const values = {};
  for (const [slot, matches] of Object.entries(PREAMBLE_ROWS)) {
    const row = rows.find((r) => matches(r[0]));
    values[slot] = row?.[column] ? fill(row[column], own) : undefined;
  }
  return values;
};

const BULLET = /^- \*\*(.+?) \(id prefix `([A-Z0-9]+)`[^)]*\)\.\*\* (.*)$/;

// A bullet's text after its bold name, with indented continuation lines.
const bulletFocus = (lines, id) => {
  const start = lines.findIndex((l) => BULLET.exec(l)?.[2] === id);
  if (start < 0) return null;
  const [, name, , first] = BULLET.exec(lines[start]);
  const body = [first];
  for (const line of lines.slice(start + 1)) {
    if (line.trim() && !line.startsWith(' ')) break;
    body.push(line);
  }
  return {focus: body.join('\n').trimEnd(), name};
};

const specialistFocus = (lines, id) => {
  const rows = tableRows(lines);
  const header = rows.find((r) => r[0] === 'ID');
  const nameAt = header?.indexOf('Name');
  const huntAt = header?.indexOf('Hunts for');
  if (!header || nameAt < 0 || huntAt < 0) return null;
  const row = rows.find((r) => r[0] === `\`${id}\``);
  return row ? {focus: row[huntAt], name: row[nameAt]} : null;
};

export const lensSource = (root, kind, id) => {
  const found =
    kind === 'spec'
      ? (() => {
          const lines = section(readLines(root, DOCS.audit), '## 7a.');
          return bulletFocus(lines, id) ?? specialistFocus(lines, id);
        })()
      : bulletFocus(
          section(readLines(root, DOCS.decomposition), '## 4.6a. '),
          id,
        );
  if (!found?.name || !found.focus?.trim()) {
    throw new Refusal(`unknown lens ${id} for kind ${kind}, or empty focus`);
  }
  return found;
};

export const preambleText = (dispatchLines) => {
  const [first] = blockquotes(section(dispatchLines, '## Shared preamble'));
  if (!first?.text.trim()) throw new Refusal('empty shared preamble');
  return first.text;
};

// The directive-wording rules of the 7c Plan-time directive bullet.
export const directiveRules = (root) => {
  const bullet = section(readLines(root, DOCS.audit), '## 7c.').find((l) =>
    l.startsWith('- **Plan-time directive**'),
  );
  const at = bullet?.indexOf('Write it as the property a test proves') ?? -1;
  if (at < 0) throw new Refusal('no Plan-time directive rules in 7c');
  return bullet.slice(at);
};

export const clauseText = (dispatchLines, kind) =>
  labelledBlockquote(
    section(dispatchLines, '## Findings file schema'),
    `Output-format clause, ${kind === 'spec' ? 'SPEC' : 'plan'} part:`,
  );

export const refuterPrompt = (root, kind) => {
  const lines =
    kind === 'spec'
      ? section(readLines(root, DOCS.audit), '### 7b-i.')
      : section(readLines(root, DOCS.decomposition), '## 4.6a-ii. ');
  const block = blockquotes(lines).find((b) =>
    b.text.startsWith('Verify finding'),
  );
  if (!block) throw new Refusal(`no refuter prompt for kind ${kind}`);
  return block.text;
};

// The verdict schema paragraph and its JSON block from 7b-i, which the refuter
// prompt points at ("the verdict schema below"). A plan refuter's schema is the
// same minus the `disposition` field and the label's sentence about it.
export const verdictSchema = (root, kind) => {
  const lines = section(readLines(root, DOCS.audit), '### 7b-i.');
  const start = lines.findIndex((line) => line.startsWith('Verdict schema:'));
  if (start < 0) throw new Refusal('no verdict schema in 7b-i');
  const block = [];
  for (const line of lines.slice(start + 1)) {
    if (line.startsWith('    ')) block.push(line);
    else if (block.length) break;
  }
  if (!block.length) throw new Refusal('no verdict schema block in 7b-i');
  if (kind === 'spec') return `${lines[start]}\n\n${block.join('\n')}`;
  const label = lines[start].split(' `disposition`')[0];
  return `${label}\n\n${block.filter((line) => !line.includes('"disposition"')).join('\n')}`;
};
