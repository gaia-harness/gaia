// Block parsing and literal extraction for the cross-file cleanse candidate
// script, which imports `parseBlocks` from here.

// Blocks: YAML frontmatter is skipped; a fenced code block is one block; a
// heading is its own block and carries no literals; each top-level list item
// with its continuation lines is one block; each table row is one block;
// otherwise a run of non-blank lines is one block. A line holding only a
// maintainer-only start or end marker comment is not content, and a block
// between the markers carries maintainer_only: true.
//
// Literals: the trimmed, whitespace-collapsed text of each inline code span
// and each non-blank fenced line, kept at 3 or more characters containing a
// digit, a space, or one of / . - _ = $ : ; repo-style paths in prose (a token
// with a slash ending in .sh, .md, .mjs, .json, .yml or .bats); and numbers
// with a unit in prose (500 lines, 72h, 30 days), normalized to number plus
// unit. Document frequency (df) is the number of scanned files carrying it.

// One alternation, never the start or end marker spelled whole: the release
// leak check refuses either full marker string in any shipped file.
const MARKER_LINE = /^<!--\s*gaia:maintainer-only:(start|end)\s*-->$/;
const markerKind = (trimmedLine) => MARKER_LINE.exec(trimmedLine)?.[1];
const UNIT_PATTERN =
  '(?:lines?|words?|tokens?|chars?|characters?|days?|hours?|h|minutes?|mins?|seconds?|secs?|ms|s|files?|clusters?|bytes?|kb|mb|rounds?|attempts?|entries|items?|members?|pages?|sentences?|steps?|issues?|times)';

const collapse = (text) => text.replace(/\s+/g, ' ').trim();
const DISTINCTIVE = /[\d\s/.\-_=$:]/;
const isLiteral = (text) => text.length >= 3 && DISTINCTIVE.test(text);

const FENCE = /^\s*(```+|~~~+)/;
const fenceChar = (line) => FENCE.exec(line)?.[1][0];
const HEADING = /^\s{0,3}#{1,6}(\s|$)/;
const TOP_LIST_ITEM = /^ {0,1}([-*+]|\d+[.)])\s/;
const TABLE_ROW = /^\s*\|/;
const TABLE_SEPARATOR = /^\s*\|[\s|:-]*\|?\s*$/;
const CODE_SPAN = /(`+)([^`]+?)\1(?!`)/g;
const BARE_PATH = new RegExp(
  '(?:^|[\\s(\\[<"\'*])((?:[\\w.@~$-]+/)+[\\w.@-]+\\.(?:sh|md|mjs|json|yml|bats))(?=$|[\\s)\\]>,;:"\'*.])',
  'g',
);
const NUMBER_UNIT = new RegExp(
  `(?<![\\w.#])(\\d+(?:\\.\\d+)?)\\s?(${UNIT_PATTERN})(?![\\w])`,
  'gi',
);

const normalizeUnit = (unit) => {
  const lower = unit.toLowerCase();
  if (lower === 's' || lower === 'ms') return lower;
  if (lower === 'entries') return 'entry';
  return lower.replace(/s$/, '');
};

const literalsOf = (lines) => {
  const found = new Set();
  const add = (text) => {
    const value = collapse(text);
    if (isLiteral(value)) found.add(value);
  };
  const prose = [];
  let fence = null;
  for (const line of lines) {
    const char = fenceChar(line);
    if (fence === null && char) {
      fence = char;
    } else if (fence !== null && char === fence) {
      fence = null;
    } else if (fence !== null) {
      add(line);
    } else {
      prose.push(line);
    }
  }
  const text = prose.join(' ');
  for (const span of text.matchAll(CODE_SPAN)) add(span[2]);
  const outsideSpans = text.replace(CODE_SPAN, ' ');
  for (const bare of outsideSpans.matchAll(BARE_PATH)) add(bare[1]);
  for (const number of outsideSpans.matchAll(NUMBER_UNIT)) {
    add(`${number[1]} ${normalizeUnit(number[2])}`);
  }
  const percents = outsideSpans.matchAll(/(?<![\w.#])(\d+(?:\.\d+)?)%/g);
  for (const percent of percents) add(`${percent[1]}%`);
  return found;
};

export const parseBlocks = (content) => {
  const lines = content.split('\n');
  const blocks = [];
  let maintainerOnly = false;
  let start = 0;
  if (lines[0]?.trim() === '---') {
    const close = lines.findIndex((line, index) => index > 0 && line.trim() === '---');
    if (close > 0) start = close + 1;
  }
  const push = (from, to) => {
    let end = to;
    while (end > from && lines[end].trim() === '') end -= 1;
    const slice = lines.slice(from, end + 1);
    const literals = literalsOf(slice);
    if (literals.size === 0) return;
    blocks.push({
      endLine: end + 1,
      literals,
      maintainerOnly,
      startLine: from + 1,
      text: slice.join('\n'),
    });
  };
  const isBoundary = (line) =>
    line.trim() === '' ||
    HEADING.test(line) ||
    FENCE.test(line) ||
    TABLE_ROW.test(line) ||
    TOP_LIST_ITEM.test(line) ||
    MARKER_LINE.test(line.trim());
  let i = start;
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();
    const kind = trimmed === '' ? undefined : markerKind(trimmed);
    const opener = fenceChar(line);
    if (trimmed === '') {
      i += 1;
    } else if (kind) {
      maintainerOnly = kind === 'start';
      i += 1;
    } else if (HEADING.test(line)) {
      i += 1;
    } else if (opener) {
      let j = i + 1;
      while (j < lines.length) {
        if (fenceChar(lines[j]) === opener) break;
        j += 1;
      }
      push(i, Math.min(j, lines.length - 1));
      i = j + 1;
    } else if (TABLE_ROW.test(line)) {
      if (!TABLE_SEPARATOR.test(line)) push(i, i);
      i += 1;
    } else if (TOP_LIST_ITEM.test(line)) {
      let j = i + 1;
      let fence = null;
      let last = i;
      while (j < lines.length) {
        const next = lines[j];
        const char = fenceChar(next);
        if (fence !== null) {
          if (char === fence) fence = null;
          last = j;
        } else if (next.trim() === '') {
          const following = lines.slice(j + 1).findIndex((x) => x.trim() !== '');
          if (following < 0 || !/^\s+\S/.test(lines[j + 1 + following])) break;
        } else if (/^\s+\S/.test(next)) {
          if (char) fence = char;
          last = j;
        } else if (isBoundary(next)) {
          break;
        } else {
          last = j;
        }
        j += 1;
      }
      push(i, last);
      i = last + 1;
    } else {
      let j = i + 1;
      while (j < lines.length && !isBoundary(lines[j])) j += 1;
      push(i, j - 1);
      i = j;
    }
  }
  return blocks;
};
