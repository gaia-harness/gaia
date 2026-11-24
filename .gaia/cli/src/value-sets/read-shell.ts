import {isMarkerText} from './markers.js';
import {lexShell} from './shell-lexer.js';
import type {ShellComment, ShellToken} from './shell-lexer.js';
import type {
  FileReading,
  MarkerComment,
  StrayMarker,
  ValueSet,
} from './types.js';

type RawSet = Pick<ValueSet, 'line' | 'name' | 'origin' | 'values'>;
type WordToken = Extract<ShellToken, {kind: 'word'}>;

const BOUNDARY_OPERATORS = new Set([
  '\n',
  '&',
  '&&',
  '(',
  ')',
  ';',
  ';;',
  '|',
  '||',
]);
const COMMAND_KEYWORDS = new Set([
  '!',
  'do',
  'elif',
  'else',
  'if',
  'then',
  'until',
  'while',
  '{',
]);
const DECLARATION_COMMANDS = new Set([
  'declare',
  'export',
  'local',
  'readonly',
  'typeset',
]);
const ARRAY_NAME = /^[A-Z_]\w*=$/i;

const isWord = (token: ShellToken | undefined): token is WordToken =>
  token?.kind === 'word';

const isOperator = (token: ShellToken | undefined, text: string): boolean =>
  token?.kind === 'op' && token.text === text;

const isKeyword = (token: ShellToken | undefined, text: string): boolean =>
  isWord(token) && token.isPlain && token.text === text;

/** True when the token at `index` begins a command, so a leading keyword is one. */
const startsCommand = (
  tokens: readonly ShellToken[],
  index: number
): boolean => {
  const previous = tokens[index - 1];

  if (previous === undefined) return true;
  if (previous.kind === 'op') return BOUNDARY_OPERATORS.has(previous.text);

  return previous.isPlain && COMMAND_KEYWORDS.has(previous.text);
};

/** The declaration words (`local -a`, `readonly`) before the array name, or undefined when something else precedes it. */
const declarationPrefix = (
  tokens: readonly ShellToken[],
  nameIndex: number
): string[] | undefined => {
  const prefix: string[] = [];
  let index = nameIndex - 1;

  while (index >= 0) {
    const token = tokens[index];

    if (
      !isWord(token) ||
      !token.isPlain ||
      !(token.text.startsWith('-') || DECLARATION_COMMANDS.has(token.text))
    ) {
      break;
    }
    prefix.unshift(token.text);
    index -= 1;
  }

  if (prefix.length > 0 && !DECLARATION_COMMANDS.has(prefix[0] as string)) {
    return undefined;
  }

  return startsCommand(tokens, index + 1) ? prefix : undefined;
};

const readArray = (
  tokens: readonly ShellToken[],
  nameIndex: number
): RawSet | undefined => {
  const nameToken = tokens[nameIndex];
  const opening = tokens[nameIndex + 1];

  if (
    !isWord(nameToken) ||
    !nameToken.isPlain ||
    !ARRAY_NAME.test(nameToken.text) ||
    !isOperator(opening, '(') ||
    opening?.start !== nameToken.end
  ) {
    return undefined;
  }

  const prefix = declarationPrefix(tokens, nameIndex);

  if (prefix === undefined) return undefined;

  if (prefix.some((word) => word.startsWith('-') && word.includes('A'))) {
    return undefined;
  }

  const values: string[] = [];

  for (let index = nameIndex + 2; index < tokens.length; index += 1) {
    const token = tokens[index];

    if (isOperator(token, ')')) {
      return {
        line: nameToken.line,
        name: nameToken.text.slice(0, -1),
        origin: 'declaration',
        values,
      };
    }

    if (!isOperator(token, '\n')) {
      if (!isWord(token) || !token.isLiteral) return undefined;
      values.push(token.text);
    }
  }

  return undefined;
};

type Pattern = {end: number; line: number; words: WordToken[]};

/** Reads `[(] word {| word} )` at `from`; undefined when the tokens are not an arm's pattern list. */
const readPattern = (
  tokens: readonly ShellToken[],
  from: number
): Pattern | undefined => {
  const words: WordToken[] = [];
  let index = isOperator(tokens[from], '(') ? from + 1 : from;

  for (;;) {
    const word = tokens[index];

    if (!isWord(word)) return undefined;
    words.push(word);

    const separator = tokens[index + 1];

    if (isOperator(separator, ')')) {
      return {end: index + 2, line: (words[0] as WordToken).line, words};
    }
    if (!isOperator(separator, '|')) return undefined;
    index += 2;
  }
};

const emitArm = (pattern: Pattern, sets: RawSet[]): void => {
  const {line, words} = pattern;
  const isEmittable =
    words.length >= 2 &&
    words.every((word) => word.isLiteral) &&
    !words.every((word) => word.text.startsWith('-'));

  if (!isEmittable) return;
  sets.push({
    line,
    name: null,
    origin: 'case-arm',
    values: words.map((word) => word.text),
  });
};

type CaseCursor = {index: number; isExpectingPattern: boolean};

/** Advances past one token or pattern list of a case block; `isDone` when its `esac` was consumed. */
const stepCaseBlock = (
  tokens: readonly ShellToken[],
  cursor: CaseCursor,
  sets: RawSet[]
): boolean => {
  const token = tokens[cursor.index];
  const isCommandStart = startsCommand(tokens, cursor.index);

  if (cursor.isExpectingPattern) {
    if (isOperator(token, '\n') || isOperator(token, ';')) {
      cursor.index += 1;
    } else if (isKeyword(token, 'esac')) {
      cursor.index += 1;

      return true;
    } else {
      const pattern = readPattern(tokens, cursor.index);

      cursor.isExpectingPattern = false;

      if (pattern !== undefined) {
        emitArm(pattern, sets);
        cursor.index = pattern.end;
      }
    }
  } else if (isOperator(token, ';;')) {
    cursor.isExpectingPattern = true;
    cursor.index += 1;
  } else if (isCommandStart && isKeyword(token, 'case')) {
    // eslint-disable-next-line @typescript-eslint/no-use-before-define -- mutual recursion with nested case blocks
    cursor.index = readCaseBlock(tokens, cursor.index + 1, sets);
  } else if (isCommandStart && isKeyword(token, 'esac')) {
    cursor.index += 1;

    return true;
  } else {
    cursor.index += 1;
  }

  return false;
};

/** Reads the arms of the `case` whose keyword ends at `afterCase`; returns the index after its `esac`. */
const readCaseBlock = (
  tokens: readonly ShellToken[],
  afterCase: number,
  sets: RawSet[]
): number => {
  let subjectEnd = afterCase;

  while (subjectEnd < tokens.length && !isKeyword(tokens[subjectEnd], 'in')) {
    subjectEnd += 1;
  }

  const cursor: CaseCursor = {index: subjectEnd + 1, isExpectingPattern: true};
  let isDone = false;

  while (!isDone && cursor.index < tokens.length) {
    isDone = stepCaseBlock(tokens, cursor, sets);
  }

  return cursor.index;
};

const collectSets = (tokens: readonly ShellToken[]): RawSet[] => {
  const sets: RawSet[] = [];
  let caseBlockEnd = 0;

  tokens.forEach((token, index) => {
    const array = readArray(tokens, index);

    if (array !== undefined) sets.push(array);

    if (
      index >= caseBlockEnd &&
      isKeyword(token, 'case') &&
      startsCommand(tokens, index)
    ) {
      caseBlockEnd = readCaseBlock(tokens, index + 1, sets);
    }
  });

  return sets;
};

const markersFor = (
  line: number,
  markerComments: readonly ShellComment[]
): ShellComment[] =>
  markerComments.filter((comment) =>
    comment.isTrailing ? comment.line === line : comment.line === line - 1
  );

/** Reads the literal arrays and case arms of one shell file. Never throws on odd input. */
export const readShellFile = (path: string, text: string): FileReading => {
  const {comments, tokens} = lexShell(text);
  const markerComments = comments.filter((comment) =>
    isMarkerText(comment.body)
  );
  const attached = new Set<ShellComment>();
  const sets: ValueSet[] = collectSets(tokens)
    .toSorted((first, second) => first.line - second.line)
    .map((raw) => {
      const own = markersFor(raw.line, markerComments);
      const markers: MarkerComment[] = own.map((comment) => {
        attached.add(comment);

        return {line: comment.line, text: comment.body};
      });

      return {...raw, language: 'shell', markers, path};
    });
  const strayMarkers: StrayMarker[] = markerComments
    .filter((comment) => !attached.has(comment))
    .map((comment) => ({line: comment.line, path, text: comment.body}));

  return {sets, strayMarkers};
};
