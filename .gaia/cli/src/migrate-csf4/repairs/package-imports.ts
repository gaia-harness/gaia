/**
 * Adds the `#.storybook/preview` subpath import to an adopter's
 * `package.json`, editing the text so every other key keeps its order,
 * spacing and indentation.
 */
import {PREVIEW_SPECIFIER} from './ast.js';

const TARGET = './.storybook/preview.ts';

type Member = {
  key: string;
  keyStart: number;
  valueEnd: number;
  valueStart: number;
};

const skipWhitespace = (text: string, position: number): number => {
  let index = position;

  while (index < text.length && /\s/u.test(text[index] ?? '')) index += 1;

  return index;
};

const stringEnd = (text: string, quoteIndex: number): number => {
  let index = quoteIndex + 1;

  while (index < text.length && text[index] !== '"')
    index += text[index] === '\\' ? 2 : 1;

  return index + 1;
};

const scalarEnd = (text: string, position: number): number => {
  let index = position;

  while (index < text.length && !/[\s,\]}]/u.test(text[index] ?? ''))
    index += 1;

  return index;
};

const containerEnd = (text: string, position: number): number => {
  let depth = 0;
  let index = position;

  while (index < text.length) {
    const character = text[index];

    if (character === '"') {
      index = stringEnd(text, index);
    } else {
      if (character === '{' || character === '[') depth += 1;
      if (character === '}' || character === ']') depth -= 1;
      index += 1;
      if (depth === 0) return index;
    }
  }

  return index;
};

/** The end of the JSON value starting at `position` (already parsed as valid). */
const valueEnd = (text: string, position: number): number => {
  if (text[position] === '"') return stringEnd(text, position);

  if (text[position] === '{' || text[position] === '[') {
    return containerEnd(text, position);
  }

  return scalarEnd(text, position);
};

/** The members of the JSON object whose `{` sits at `open`. */
const objectMembers = (
  text: string,
  open: number
): {close: number; members: Member[]} => {
  const members: Member[] = [];
  let index = skipWhitespace(text, open + 1);

  while (text[index] === '"') {
    const keyEnd = stringEnd(text, index);
    const key = JSON.parse(text.slice(index, keyEnd)) as string;
    const valueStart = skipWhitespace(text, skipWhitespace(text, keyEnd) + 1);
    const end = valueEnd(text, valueStart);

    members.push({key, keyStart: index, valueEnd: end, valueStart});
    index = skipWhitespace(text, end);
    if (text[index] === ',') index = skipWhitespace(text, index + 1);
  }

  return {close: index, members};
};

const indentBefore = (text: string, position: number): string => {
  const lineStart = text.lastIndexOf('\n', position - 1) + 1;

  return /^[\t ]*/u.exec(text.slice(lineStart, position))?.[0] ?? '';
};

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

/** Ensures `imports["#.storybook/preview"]`; a present entry, conflicting or not, is left alone. */
export const ensurePreviewImportsSubpath = (
  packageJsonText: string
): {changed: boolean; text: string} => {
  const unchanged = {changed: false, text: packageJsonText};
  let parsed: unknown;

  try {
    parsed = JSON.parse(packageJsonText);
  } catch {
    return unchanged;
  }
  if (!isPlainObject(parsed)) return unchanged;
  const {imports} = parsed;

  if (
    imports !== undefined &&
    (!isPlainObject(imports) || PREVIEW_SPECIFIER in imports)
  ) {
    return unchanged;
  }
  const text = packageJsonText;
  const eol =
    text.includes('\r\n') ? '\r\n'
    : text.includes('\n') ? '\n'
    : '';
  const root = objectMembers(text, skipWhitespace(text, 0));
  const indent =
    root.members[0] ? indentBefore(text, root.members[0].keyStart) : '';
  const entry = `"${PREVIEW_SPECIFIER}": "${TARGET}"`;
  const splice = (start: number, end: number, insert: string) => ({
    changed: true,
    text: text.slice(0, start) + insert + text.slice(end),
  });
  const importsMember = root.members.find((member) => member.key === 'imports');

  if (importsMember) {
    const inner = objectMembers(text, importsMember.valueStart);
    const last = inner.members.at(-1);

    if (!last) {
      return splice(
        importsMember.valueStart + 1,
        inner.close,
        `${eol}${indent}${indent}${entry}${eol}${indent}`
      );
    }
    const innerIndent = indentBefore(text, last.keyStart);

    return splice(
      last.valueEnd,
      last.valueEnd,
      `,${eol}${innerIndent}${entry}`
    );
  }
  const block = `"imports": {${eol}${indent}${indent}${entry}${eol}${indent}}`;
  const scripts = root.members.find((member) => member.key === 'scripts');

  if (scripts)
    return splice(
      scripts.keyStart,
      scripts.keyStart,
      `${block},${eol}${indent}`
    );
  const last = root.members.at(-1);

  if (!last)
    return splice(root.close, root.close, `${eol}${indent}${block}${eol}`);

  return splice(last.valueEnd, last.valueEnd, `,${eol}${indent}${block}`);
};
