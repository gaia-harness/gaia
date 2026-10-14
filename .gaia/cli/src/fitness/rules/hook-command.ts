/* eslint-disable no-template-curly-in-string -- these literals are shell text, not templates */
/**
 * Static reading of a hook command string. Nothing here expands, evaluates or
 * runs any part of the command: the splitter only tracks quoting so that a
 * quoted substitution stays one word.
 */

export type ScriptReference =
  /** A recognized root prefix; `remainder` is repo-relative, `viaInterpreter` is set when an interpreter runs it. */
  | {kind: 'anchored'; remainder: string; viaInterpreter?: true}
  /** Absolute, tilde or `$`-anchored with a prefix this reader does not recognize: rooted, never stat'ed. */
  | {kind: 'anchored-unrecognized'}
  /** No path-bearing script token (bare executable, empty command, inline code). */
  | {kind: 'none'}
  /** A repo-relative path, which resolves against wherever the session stands. */
  | {kind: 'relative'; token: string};

const INTERPRETERS: ReadonlySet<string> = new Set([
  'bash',
  'node',
  'python',
  'python3',
  'sh',
  'zsh',
]);

/** Interpreter flags whose next word is inline code, not a script path. */
const INLINE_CODE_FLAGS: ReadonlySet<string> = new Set([
  '--eval',
  '-c',
  '-e',
  '-m',
  '-p',
]);

/**
 * The root prefixes whose resolved directory is knowable from the text alone.
 * The substitution forms hold their own quotes, so the prefix is matched on
 * the word after quote removal and expansion text is kept verbatim.
 */
const RECOGNIZED_ROOT_PREFIXES: readonly string[] = [
  '$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-.}")/',
  '$(git rev-parse --show-toplevel)/',
  '${CLAUDE_PROJECT_DIR}/',
  '$CLAUDE_PROJECT_DIR/',
];

const ASSIGNMENT = /^[A-Z_]\w*=/i;

const COMMAND_TERMINATORS: ReadonlySet<string> = new Set(['\n', '&', ';', '|']);

/**
 * Returns the index just past the `closer` that ends the group opened before
 * `start`. Nested quotes and `$(...)` / `${...}` groups are skipped whole, so
 * a closer inside them does not end the outer group. Unterminated input ends
 * at the end of the text.
 */
const skipPast = (text: string, start: number, closer: string): number => {
  if (closer === "'") {
    const end = text.indexOf("'", start);

    return end === -1 ? text.length : end + 1;
  }

  let index = start;

  while (index < text.length) {
    const character = text[index];
    const pair = text.slice(index, index + 2);

    if (character === closer) return index + 1;

    if (character === '\\') index += 2;
    else if (pair === '$(') index = skipPast(text, index + 2, ')');
    else if (pair === '${') index = skipPast(text, index + 2, '}');
    else if (character === '"' && closer !== '"') {
      index = skipPast(text, index + 1, '"');
    } else if (character === "'" && closer !== '"') {
      index = skipPast(text, index + 1, "'");
    } else index += 1;
  }

  return text.length;
};

type Segment = {next: number; text: string};

/** One quoted run, escape, expansion or plain character of a word. */
const readSegment = (command: string, index: number): Segment => {
  const character = command[index] ?? '';
  const pair = command.slice(index, index + 2);

  if (character === "'" || character === '"') {
    const end = skipPast(command, index + 1, character);

    return {next: end, text: command.slice(index + 1, end - 1)};
  }

  if (character === '\\')
    return {next: index + 2, text: command[index + 1] ?? ''};

  if (pair === '$(' || pair === '${' || character === '`') {
    const closer =
      character === '`' ? '`'
      : pair === '$(' ? ')'
      : '}';
    const end = skipPast(command, index + (character === '`' ? 1 : 2), closer);

    return {next: end, text: command.slice(index, end)};
  }

  return {next: index + 1, text: character};
};

/**
 * Splits the first simple command into words. Quotes are removed and an
 * expansion (`$VAR`, `${VAR}`, `$(...)`, backticks) stays in the word as its
 * literal text.
 */
export const splitCommandWords = (command: string): readonly string[] => {
  const words: string[] = [];
  let word = '';
  let inWord = false;
  let index = 0;

  const flush = () => {
    if (inWord) words.push(word);
    word = '';
    inWord = false;
  };

  while (index < command.length) {
    const character = command[index] ?? '';

    if (COMMAND_TERMINATORS.has(character)) break;

    if (character === ' ' || character === '\t') {
      flush();
      index += 1;
    } else {
      const segment = readSegment(command, index);

      word += segment.text;
      inWord = true;
      index = segment.next;
    }
  }

  flush();

  return words;
};

const classifyToken = (
  token: string,
  viaInterpreter: boolean
): ScriptReference => {
  const prefix = RECOGNIZED_ROOT_PREFIXES.find((candidate) =>
    token.startsWith(candidate)
  );

  if (prefix !== undefined) {
    const remainder = token.slice(prefix.length);

    return viaInterpreter ?
        {kind: 'anchored', remainder, viaInterpreter: true}
      : {kind: 'anchored', remainder};
  }

  if (/^[$/`~]/.test(token)) return {kind: 'anchored-unrecognized'};

  if (!token.includes('/')) return {kind: 'none'};

  return {kind: 'relative', token};
};

/** Finds the script token of a hook command and says how it is anchored. */
export const readScriptReference = (command: string): ScriptReference => {
  const words = splitCommandWords(command);
  let index = 0;

  while (ASSIGNMENT.test(words[index] ?? '')) index += 1;

  const viaInterpreter = INTERPRETERS.has(words[index] ?? '');

  if (viaInterpreter) {
    index += 1;

    while ((words[index] ?? '').startsWith('-')) {
      if (INLINE_CODE_FLAGS.has(words[index] ?? '')) return {kind: 'none'};
      index += 1;
    }
  }

  return classifyToken(words[index] ?? '', viaInterpreter);
};
