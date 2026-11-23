export type ShellComment = {
  /** The comment body: the `#` and surrounding whitespace removed. */
  body: string;
  /** True when a token precedes the comment on its line. */
  isTrailing: boolean;
  line: number;
};

export type ShellLexing = {
  comments: ShellComment[];
  tokens: ShellToken[];
};

export type ShellToken =
  | {
      end: number;
      endLine: number;
      isLiteral: boolean;
      isPlain: boolean;
      kind: 'word';
      line: number;
      start: number;
      text: string;
    }
  | {
      end: number;
      endLine: number;
      kind: 'op';
      line: number;
      start: number;
      text: string;
    };

type LexState = {
  comments: ShellComment[];
  index: number;
  lastTokenEndLine: number;
  line: number;
  pending: PendingHeredoc[];
  tokens: ShellToken[];
};

type PendingHeredoc = {delimiter: string; isTabStripped: boolean};

type Word = {
  end: number;
  isLiteral: boolean;
  isPlain: boolean;
  text: string;
};

const WORD_BREAK_CHARACTERS = ' \t\r\n;&|()<>';
const GLOB_CHARACTERS = '*?[{}';

const countNewlines = (source: string, from: number, to: number): number =>
  source.slice(from, to).split('\n').length - 1;

/** Index just past the `quote` that closes the string opened before `from`; end of file when none does. */
const skipQuoted = (source: string, from: number, quote: string): number => {
  let index = from;

  while (index < source.length) {
    if (source[index] === '\\' && quote !== "'") index += 1;
    else if (source[index] === quote) return index + 1;
    index += 1;
  }

  return source.length;
};

type Brackets = {close: string; open: string};

/** Index just past the bracket pair opened at `from`, quotes and escapes skipped; end of file when unbalanced. */
const skipBalanced = (
  source: string,
  from: number,
  {close, open}: Brackets
): number => {
  let depth = 0;
  let index = from;

  while (index < source.length) {
    const character = source[index];

    if (character === '\\') index += 2;
    else if (character === "'" || character === '"') {
      index = skipQuoted(source, index + 1, character);
    } else {
      if (character === open) depth += 1;
      if (character === close) depth -= 1;
      index += 1;
      if (depth === 0) return index;
    }
  }

  return source.length;
};

const skipExpansion = (source: string, dollarIndex: number): number => {
  const next = source[dollarIndex + 1];

  if (next === '(') {
    return skipBalanced(source, dollarIndex + 1, {close: ')', open: '('});
  }

  if (next === '{') {
    return skipBalanced(source, dollarIndex + 1, {close: '}', open: '{'});
  }

  return dollarIndex + 1;
};

type WordAccumulator = {isLiteral: boolean; isPlain: boolean; text: string};

/** Reads a double-quoted string opened at `from`; returns the index just past it. */
const scanDoubleQuoted = (
  source: string,
  from: number,
  word: WordAccumulator
): number => {
  let index = from + 1;

  while (index < source.length && source[index] !== '"') {
    const character = source[index] as string;

    if (character === '\\') {
      word.text += source[index + 1] ?? '';
      index += 2;
    } else if (character === '$') {
      word.isLiteral = false;
      index = skipExpansion(source, index);
    } else if (character === '`') {
      word.isLiteral = false;
      index = skipQuoted(source, index + 1, '`');
    } else {
      word.text += character;
      index += 1;
    }
  }

  return index + 1;
};

/** Reads one word part at `index` into `word`; returns the index after it. */
const scanWordPart = (
  source: string,
  index: number,
  word: WordAccumulator
): number => {
  const character = source[index] as string;

  if (character === "'") {
    const end = skipQuoted(source, index + 1, "'");

    word.text += source.slice(index + 1, Math.max(index + 1, end - 1));
    word.isPlain = false;

    return end;
  }

  if (character === '"') {
    word.isPlain = false;

    return scanDoubleQuoted(source, index, word);
  }

  if (character === '\\') {
    if (source[index + 1] !== '\n') {
      word.text += source[index + 1] ?? '';
      word.isPlain = false;
    }

    return index + 2;
  }

  if (character === '$' || character === '`') {
    word.isLiteral = false;
    word.isPlain = false;

    return character === '$' ?
        skipExpansion(source, index)
      : skipQuoted(source, index + 1, '`');
  }
  if (GLOB_CHARACTERS.includes(character)) word.isLiteral = false;
  word.text += character;

  return index + 1;
};

const readWord = (source: string, start: number): Word => {
  const word: WordAccumulator = {isLiteral: true, isPlain: true, text: ''};
  let index = start;

  while (
    index < source.length &&
    !WORD_BREAK_CHARACTERS.includes(source[index] as string)
  ) {
    index = scanWordPart(source, index, word);
  }

  return {
    end: Math.min(index, source.length),
    isLiteral: word.isLiteral && !/[$`]/.test(word.text),
    isPlain: word.isPlain,
    text: word.text,
  };
};

/**
 * Consumes heredoc bodies from `from` (the start of the line after a newline);
 * returns the index after the last terminator line, or end of file.
 */
const skipHeredocBodies = (
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

const pushOperator = (state: LexState, text: string, length: number): void => {
  state.tokens.push({
    end: state.index + length,
    endLine: state.line,
    kind: 'op',
    line: state.line,
    start: state.index,
    text,
  });
  state.lastTokenEndLine = state.line;
  state.index += length;
};

const lexNewline = (state: LexState, source: string): void => {
  pushOperator(state, '\n', 1);
  state.line += 1;

  if (state.pending.length > 0) {
    const bodyEnd = skipHeredocBodies(source, state.index, state.pending);

    state.line += countNewlines(source, state.index, bodyEnd);
    state.index = bodyEnd;
    state.pending = [];
  }
  state.lastTokenEndLine = 0;
};

const lexComment = (state: LexState, source: string): void => {
  const lineEnd = source.indexOf('\n', state.index);
  const stop = lineEnd === -1 ? source.length : lineEnd;

  state.comments.push({
    body: source.slice(state.index + 1, stop).trim(),
    isTrailing: state.lastTokenEndLine === state.line,
    line: state.line,
  });
  state.index = stop;
};

const lexSemicolon = (state: LexState, source: string): void => {
  const next = source[state.index + 1];

  if (next === ';') {
    pushOperator(state, ';;', source[state.index + 2] === '&' ? 3 : 2);
  } else if (next === '&') pushOperator(state, ';;', 2);
  else pushOperator(state, ';', 1);
};

const lexAngle = (state: LexState, source: string): void => {
  const next = source[state.index + 1];

  if (next !== '<' || source[state.index + 2] === '<') {
    pushOperator(state, '<', next === '<' ? 3 : 1);

    return;
  }

  const isTabStripped = source[state.index + 2] === '-';
  let delimiterStart = state.index + (isTabStripped ? 3 : 2);

  while (source[delimiterStart] === ' ' || source[delimiterStart] === '\t') {
    delimiterStart += 1;
  }

  const delimiter = readWord(source, delimiterStart);

  state.pending.push({delimiter: delimiter.text, isTabStripped});
  pushOperator(state, '<', delimiter.end - state.index);
};

const lexWord = (state: LexState, source: string): void => {
  const word = readWord(source, state.index);
  const end = Math.max(word.end, state.index + 1);
  const startLine = state.line;

  state.line += countNewlines(source, state.index, end);
  state.tokens.push({
    end,
    endLine: state.line,
    isLiteral: word.isLiteral,
    isPlain: word.isPlain,
    kind: 'word',
    line: startLine,
    start: state.index,
    text: word.text,
  });
  state.lastTokenEndLine = state.line;
  state.index = end;
};

const lexStep = (state: LexState, source: string): void => {
  const character = source[state.index] as string;
  const next = source[state.index + 1];

  if (character === '\n') lexNewline(state, source);
  else if (' \t\r'.includes(character)) state.index += 1;
  else if (character === '\\' && next === '\n') {
    state.index += 2;
    state.line += 1;
  } else if (character === '#') lexComment(state, source);
  else if (character === ';') lexSemicolon(state, source);
  else if (character === '&' || character === '|') {
    pushOperator(
      state,
      next === character ? character + character : character,
      next === character ? 2 : 1
    );
  } else if ('()>'.includes(character)) pushOperator(state, character, 1);
  else if (character === '<') lexAngle(state, source);
  else lexWord(state, source);
};

/**
 * Splits shell text into words, operators and comments. Quoted strings,
 * heredoc bodies and command substitutions yield no tokens of their own and
 * never a comment; a quote or heredoc left open runs to end of file. Never
 * throws.
 */
export const lexShell = (source: string): ShellLexing => {
  const state: LexState = {
    comments: [],
    index: 0,
    lastTokenEndLine: 0,
    line: 1,
    pending: [],
    tokens: [],
  };

  while (state.index < source.length) lexStep(state, source);

  return {comments: state.comments, tokens: state.tokens};
};
