import type {ProjectFile} from '../types.js';

export const HUMAN_ONLY_HEADERS_PATH = '.gaia/autonomy-human-only-headers.json';

const TOOL_NAME = 'AskUserQuestion';
const MARKER = /\(Recommended\)/g;
const LABEL_LOOKBACK = 80;
const LABEL_DELIMITERS = '`*"“”,:;()\n';
const LABEL_PADDING = '`*"” \t\n';
const HEADER_PADDING = '*:, \t';
const QUOTES_OPEN = '`"“';
const QUOTES_CLOSE = '`"”';

/**
 * The option label a `(Recommended)` marker ends, lowercased; empty for a bare
 * mention of the marker. Plain scans, not a regular expression: the prose they
 * read is unbounded and a backtracking pattern over it is quadratic.
 */
const labelBefore = (text: string, markerIndex: number): string => {
  if (markerIndex > 0 && !/\s/.test(text.charAt(markerIndex - 1))) return '';

  let end = markerIndex;

  while (end > 0 && LABEL_PADDING.includes(text.charAt(end - 1))) end -= 1;

  let start = end;

  while (
    start > 0 &&
    end - start < LABEL_LOOKBACK &&
    !LABEL_DELIMITERS.includes(text.charAt(start - 1))
  )
    start -= 1;

  const tail = text.slice(start, end).toLowerCase();
  const lead = Math.max(tail.lastIndexOf(' or '), tail.lastIndexOf(' and '));

  return (
    lead === -1 ? tail : tail.slice(tail.indexOf(' ', lead + 1) + 1)).trim();
};
const OPTIONS_CLAUSE = /\boptions?\b[^.\n]{0,60}[`*“"](?!AskUserQuestion)[A-Z]/;
const HEADER_WORD = /\bheader\b/gi;
const HUMAN_ONLY = /human-only/i;
const NEUTRAL =
  /recommends? nothing|no recommendation|no option is|no option marked|neither marked|never carries the recommended mark/i;
const FREE_TEXT =
  /\b(?:plain chat (?:message|prompt|question)|plain[- ]text (?:message|prompt|question)|free[- ]text (?:question|prompt)|in plain chat|as a plain (?:chat )?(?:message|prompt|question))\b/i;
const UNATTENDED_FALLBACK =
  /\b(?:unattended|auto mode|autonomy|non-interactive|never ask)\b/i;
const FENCE = /^\s*(?:```|~~~)/;

export type Block = {
  /** 1-based line of the block's first line. */
  line: number;
  text: string;
};

export type Classified = {
  /** A free-text question asked in chat: the block and whether it names an unattended fallback. */
  freeText: readonly {block: Block; hasFallback: boolean}[];
  /** Blocks that name the tool and offer no options: hook docs, prose that only mentions it. */
  mentionOnly: readonly Block[];
  /** Headed blocks: one question each per header, the unit the checks bind to. */
  sites: readonly Site[];
  /** Blocks that offer options with no `header`: no question boundary, so only the zero-recommendation check binds. */
  unheaded: readonly Site[];
};

export type Site = {
  block: Block;
  /** True when the block mentions the marker at all, including a bare `(Recommended)` naming the mark to apply. */
  hasMarker: boolean;
  /** Every header the site names, in order. */
  headers: readonly string[];
  isHumanOnly: boolean;
  isNeutral: boolean;
  /** Header mentions: the number of questions the block asks, at least 1. */
  questionCount: number;
  /** The distinct option labels the site marks `(Recommended)`; one option restated in a lead-in counts once. */
  recommendedLabels: ReadonlySet<string>;
};

/**
 * Paragraph blocks of `text`: runs of non-blank lines, a fenced code block
 * kept whole, and a block ending in a colon joined to the block after it so
 * the lead-in and its option list read as one.
 */
export const blocksOf = (text: string): Block[] => {
  const lines = text.split('\n');
  const raw: Block[] = [];
  let current: string[] = [];
  let start = 0;
  let inFence = false;

  const flush = (): void => {
    if (current.length > 0) {
      raw.push({line: start + 1, text: current.join('\n')});
      current = [];
    }
  };

  lines.forEach((line, index) => {
    if (FENCE.test(line)) inFence = !inFence;

    if (!inFence && line.trim() === '' && !FENCE.test(line)) {
      flush();

      return;
    }

    if (current.length === 0) start = index;
    current.push(line);
  });
  flush();

  const joined: Block[] = [];

  for (const block of raw) {
    const previous = joined.at(-1);

    if (previous?.text.trimEnd().endsWith(':') === true) {
      previous.text = `${previous.text}\n${block.text}`;
    } else {
      joined.push({...block});
    }
  }

  return joined;
};

/** The index of the first character at or after `from` that is not in `characters`; `text.length` when none. */
const skipOver = (text: string, from: number, characters: string): number => {
  let cursor = from;

  while (cursor < text.length && characters.includes(text.charAt(cursor)))
    cursor += 1;

  return cursor;
};

/** The quoted value after each `header` word: `header \`X\``, `header: "X"`, `header is **\`X\`**`. */
const headersOf = (text: string): string[] => {
  const values: string[] = [];

  for (const match of text.matchAll(HEADER_WORD)) {
    let cursor = skipOver(text, match.index + match[0].length, HEADER_PADDING);

    if (text.startsWith('is ', cursor)) cursor += 3;
    cursor = skipOver(text, cursor, '* ');

    if (QUOTES_OPEN.includes(text.charAt(cursor))) {
      const open = skipOver(text, cursor, QUOTES_OPEN);
      let close = open;

      while (close < text.length && !QUOTES_CLOSE.includes(text.charAt(close)))
        close += 1;

      const value = text.slice(open, close).trim();

      if (value !== '') values.push(value);
    }
  }

  return values;
};

const siteOf = (block: Block): Site => {
  const headerMentions = headersOf(block.text).length;

  return {
    block,
    hasMarker: block.text.includes('(Recommended)'),
    headers: headersOf(block.text),
    isHumanOnly: HUMAN_ONLY.test(block.text),
    isNeutral: NEUTRAL.test(block.text),
    questionCount: headerMentions,
    recommendedLabels: new Set(
      [...block.text.matchAll(MARKER)]
        .map((match) => labelBefore(block.text, match.index))
        .filter((label) => label !== '')
    ),
  };
};

/** Classifies every block of one instruction file as a site, a mention, or a free-text question. */
export const classify = (file: ProjectFile): Classified => {
  const sites: Site[] = [];
  const mentionOnly: Block[] = [];
  const unheaded: Site[] = [];
  const freeText: {block: Block; hasFallback: boolean}[] = [];

  for (const block of blocksOf(file.text)) {
    if (FREE_TEXT.test(block.text)) {
      freeText.push({
        block,
        hasFallback: UNATTENDED_FALLBACK.test(block.text),
      });
    }

    if (block.text.includes(TOOL_NAME)) {
      const site = siteOf(block);

      if (site.headers.length > 0) sites.push(site);
      else if (
        block.text.includes('(Recommended)') ||
        OPTIONS_CLAUSE.test(block.text)
      )
        unheaded.push(site);
      else mentionOnly.push(block);
    }
  }

  return {freeText, mentionOnly, sites, unheaded};
};
