import {load as parseYaml} from 'js-yaml';

export type Frontmatter = {
  /** First line of the body, 1-indexed; 1 when there is no frontmatter. */
  bodyStartLine: number;
  data: Record<string, unknown>;
  error: string | undefined;
  ok: boolean;
  /** The text between the fences, unparsed. */
  raw: string;
};

const FENCE_LINE = /^---[ \t]*$/;

const NO_FRONTMATTER: Frontmatter = {
  bodyStartLine: 1,
  data: {},
  error: 'no frontmatter',
  ok: false,
  raw: '',
};

/** Splits a leading `---` YAML block off `text`; never throws. */
export const splitFrontmatter = (text: string): Frontmatter => {
  const lines = (text.startsWith('\uFEFF') ? text.slice(1) : text).split('\n');
  const first = lines[0]?.replace(/\r$/, '');

  if (first === undefined || !FENCE_LINE.test(first)) return NO_FRONTMATTER;

  const closing = lines.findIndex(
    (line, index) => index > 0 && FENCE_LINE.test(line.replace(/\r$/, ''))
  );

  if (closing === -1) {
    return {...NO_FRONTMATTER, error: 'frontmatter is not closed'};
  }

  const raw = lines.slice(1, closing).join('\n');
  const bodyStartLine = closing + 2;

  // js-yaml treats an empty document as an error, but `---\n---` is valid
  // frontmatter that simply declares nothing.
  if (raw.trim() === '') {
    return {bodyStartLine, data: {}, error: undefined, ok: true, raw};
  }

  try {
    const parsed = parseYaml(raw);

    if (parsed === null || parsed === undefined) {
      return {bodyStartLine, data: {}, error: undefined, ok: true, raw};
    }

    if (typeof parsed !== 'object' || Array.isArray(parsed)) {
      return {
        bodyStartLine,
        data: {},
        error: 'frontmatter is not a mapping',
        ok: false,
        raw,
      };
    }

    return {
      bodyStartLine,
      data: parsed as Record<string, unknown>,
      error: undefined,
      ok: true,
      raw,
    };
  } catch (error: unknown) {
    return {
      bodyStartLine,
      data: {},
      error: error instanceof Error ? error.message : String(error),
      ok: false,
      raw,
    };
  }
};

const FENCE_OPEN = /^ {0,3}(`{3,}|~{3,})/;

/**
 * Blanks every fenced code block, fences included, and keeps every line, so a
 * line number in the result is a line number in the input.
 */
export const stripFencedCode = (text: string): string => {
  let fence: string | undefined;

  return text
    .split('\n')
    .map((line) => {
      const match = FENCE_OPEN.exec(line);

      const opening = match?.[1];

      if (fence === undefined) {
        if (opening === undefined) return line;
        fence = opening;

        return '';
      }

      const marker = fence[0] ?? '`';
      const closes =
        match?.[1] !== undefined &&
        match[1].startsWith(marker) &&
        match[1].length >= fence.length &&
        line.trim() === match[1];

      if (closes) fence = undefined;

      return '';
    })
    .join('\n');
};

/** Replaces each inline code span on `line` with spaces of the same length. */
export const stripInlineCode = (line: string): string =>
  line.replaceAll(/(`+)(.+?)\1/g, (span) => ' '.repeat(span.length));

/**
 * The lines of `text` with frontmatter and fenced code blanked (and inline
 * code too, when asked), keeping every line so an index is a line number.
 */
export const bodyLines = (
  text: string,
  {inlineCode = false}: {inlineCode?: boolean} = {}
): string[] => {
  const {bodyStartLine, ok} = splitFrontmatter(text);
  const unframed = text
    .split('\n')
    .map((line, index) => (ok && index + 1 < bodyStartLine ? '' : line))
    .join('\n');
  const lines = stripFencedCode(unframed).split('\n');

  return inlineCode ? lines.map(stripInlineCode) : lines;
};

/** The 1-indexed line of character offset `index` in `text`. */
export const lineOf = (text: string, index: number): number => {
  let line = 1;
  const end = Math.min(index, text.length);

  for (let position = 0; position < end; position += 1) {
    if (text[position] === '\n') line += 1;
  }

  return line;
};

/** Orders strings by UTF-8 bytes, so a sorted report is identical on every locale. */
export const compareBytes = (a: string, b: string): number =>
  Buffer.compare(Buffer.from(a), Buffer.from(b));
