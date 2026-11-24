export type PendingHeredoc = {delimiter: string; isTabStripped: boolean};

/** Index just past the `quote` that closes the string opened before `from`; end of file when none does. */
export const skipQuoted = (
  source: string,
  from: number,
  quote: string
): number => {
  let index = from;

  while (index < source.length) {
    if (source[index] === '\\' && quote !== "'") index += 1;
    else if (source[index] === quote) return index + 1;
    index += 1;
  }

  return source.length;
};

/**
 * Consumes heredoc bodies from `from` (the start of the line after a newline);
 * returns the index after the last terminator line, or end of file.
 */
export const skipHeredocBodies = (
  source: string,
  from: number,
  pending: readonly PendingHeredoc[]
): number => {
  let index = from;

  for (const heredoc of pending) {
    let isOpen = true;

    while (isOpen && index < source.length) {
      const lineEnd = source.indexOf('\n', index);
      const stop = lineEnd === -1 ? source.length : lineEnd;
      const raw = source.slice(index, stop).replace(/\r$/, '');
      const candidate = heredoc.isTabStripped ? raw.replace(/^\t+/, '') : raw;

      index = lineEnd === -1 ? source.length : lineEnd + 1;
      isOpen = candidate !== heredoc.delimiter;
    }
  }

  return index;
};

type Brackets = {close: string; isCommand?: boolean; open: string};

const HEREDOC_DELIMITER_BREAKS = ' \t\r\n;&|()<>';
const COMMENT_PRECEDERS = ' \t\n;&|(';

/** The heredoc delimiter at `from`, quotes and escapes removed, and the index just past it. */
const readHeredocDelimiter = (
  source: string,
  from: number
): {end: number; text: string} => {
  let index = from;
  let text = '';

  while (
    index < source.length &&
    !HEREDOC_DELIMITER_BREAKS.includes(source[index] as string)
  ) {
    const character = source[index] as string;

    if (character === '\\') {
      text += source[index + 1] ?? '';
      index += 2;
    } else {
      if (character !== "'" && character !== '"') text += character;
      index += 1;
    }
  }

  return {end: index, text};
};

/**
 * The heredoc a `<<` at `from` opens inside a command substitution, or
 * undefined for a here-string or a lone `<`. An arithmetic `<<` shift followed
 * by a word reads as a heredoc opener; it is not told apart.
 */
const readSubstitutionHeredoc = (
  source: string,
  from: number
): undefined | {end: number; heredoc: PendingHeredoc} => {
  if (source[from + 1] !== '<' || source[from + 2] === '<') return undefined;

  const isTabStripped = source[from + 2] === '-';
  let delimiterStart = from + (isTabStripped ? 3 : 2);

  while (source[delimiterStart] === ' ' || source[delimiterStart] === '\t') {
    delimiterStart += 1;
  }

  const delimiter = readHeredocDelimiter(source, delimiterStart);

  return delimiter.text === '' ?
      undefined
    : {end: delimiter.end, heredoc: {delimiter: delimiter.text, isTabStripped}};
};

/**
 * Where a command substitution's heredoc newline, comment or heredoc operator
 * at `index` ends, or undefined when `index` holds none of them.
 */
const skipCommandNoise = (
  source: string,
  index: number,
  pending: PendingHeredoc[]
): number | undefined => {
  const character = source[index];

  if (character === '\n' && pending.length > 0) {
    const bodyEnd = skipHeredocBodies(source, index + 1, pending);

    pending.length = 0;

    return bodyEnd;
  }

  if (
    character === '#' &&
    COMMENT_PRECEDERS.includes(source[index - 1] ?? '\n')
  ) {
    const lineEnd = source.indexOf('\n', index);

    return lineEnd === -1 ? source.length : lineEnd;
  }

  if (character === '<') {
    const opened = readSubstitutionHeredoc(source, index);

    if (opened === undefined) return undefined;
    pending.push(opened.heredoc);

    return opened.end;
  }

  return undefined;
};

/** Where the escape or quoted string at `index` ends, or undefined when `index` holds neither. */
const skipEscapeOrQuote = (
  source: string,
  index: number
): number | undefined => {
  const character = source[index] as string;

  if (character === '\\') return index + 2;

  return character === "'" || character === '"' ?
      skipQuoted(source, index + 1, character)
    : undefined;
};

/**
 * Index just past the bracket pair opened at `from`, quotes and escapes
 * skipped; end of file when unbalanced. A command substitution (`isCommand`)
 * also skips comments and heredoc bodies, whose quotes and brackets are prose.
 */
export const skipBalanced = (
  source: string,
  from: number,
  {close, isCommand = false, open}: Brackets
): number => {
  let depth = 0;
  let index = from;
  const pending: PendingHeredoc[] = [];

  while (index < source.length) {
    const character = source[index];
    const skipped =
      (isCommand ? skipCommandNoise(source, index, pending) : undefined) ??
      skipEscapeOrQuote(source, index);

    if (skipped === undefined) {
      if (character === open) depth += 1;
      if (character === close) depth -= 1;
      index += 1;
      if (depth === 0) return index;
    } else index = skipped;
  }

  return source.length;
};

export const skipExpansion = (source: string, dollarIndex: number): number => {
  const next = source[dollarIndex + 1];

  if (next === '(') {
    return skipBalanced(source, dollarIndex + 1, {
      close: ')',
      isCommand: source[dollarIndex + 2] !== '(',
      open: '(',
    });
  }

  if (next === '{') {
    return skipBalanced(source, dollarIndex + 1, {close: '}', open: '{'});
  }

  return dollarIndex + 1;
};
