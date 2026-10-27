import {readFileSync} from 'node:fs';
import path from 'node:path';
import {escapeRegExp} from '../util/escape-regexp.js';
import {collectTreeFiles, EVERY_EXTENSION} from '../util/tree-walk.js';
import {parseExcludeLines} from './manifest.js';
import type {TitleDerivedLeakCheck} from './scrub-config.js';
import {
  isDirectory,
  RELEASE_EXCLUDE_PATH,
  slugFromPath,
} from './scrub-derived-checks.js';
import {isInCheckScope} from './scrub-leak-scan.js';
import type {Leak, LineAllowlist} from './scrub-leak-scan.js';

// Derived excluded-titles check

// Exclude BOTH brackets from the inner class: a wikilink target never contains
// one, and excluding `[` keeps overlapping `[[` prefixes from forcing a rescan
// (linear, not polynomial).
const WIKILINK_SPAN = /\[\[[^[\]]*\]\]/g;
const INLINE_CODE_SPAN = /`[^`]*`/g;

// Adds the page title(s) contributed by one `.gaia/release-exclude` line: a
// `.md` exclude contributes its own case-preserved basename; a bare-directory
// exclude contributes the case-preserved basename of every `.md` page beneath
// it, and NOT the directory basename itself (a directory name is not a page a
// reader follows, and as a lowercase common word it appears in ordinary prose).
// Guard-clause early returns (not `continue`): this runs once per line from a
// plain `for` loop in the caller, not from inside a loop itself.
const addTitlesForExcludeLine = (
  line: string,
  cwd: string,
  addTitle: (value: string) => void
): void => {
  if (line !== 'wiki' && !line.startsWith('wiki/')) return;

  if (line.endsWith('.md')) {
    addTitle(slugFromPath(line));

    return;
  }

  const absolute = path.join(cwd, line);

  if (!isDirectory(absolute)) return;

  for (const relative of collectTreeFiles(absolute, EVERY_EXTENSION)) {
    if (relative.endsWith('.md')) addTitle(slugFromPath(relative));
  }
};

/**
 * Build the set of release-excluded wiki page TITLES from `.gaia/release-exclude`
 * resolved against `cwd`, the source repo.
 *
 * Distinct from `buildExcludedSlugSet`: titles are case-PRESERVED (bare prose is
 * matched case-sensitively) and the bare-directory basename is never
 * contributed. Reading from `cwd` is load-bearing: `release-exclude` excludes
 * itself, so a staging read yields an empty set and passes silently.
 */
const buildExcludedTitleSet = (cwd: string): Set<string> => {
  const lines = parseExcludeLines(
    readFileSync(path.join(cwd, RELEASE_EXCLUDE_PATH), 'utf8')
  );
  const titles = new Set<string>();

  for (const line of lines) {
    addTitlesForExcludeLine(line, cwd, (value) => titles.add(value));
  }

  return titles;
};

// Case-sensitive (no `i` flag), whole-token: alphanumerics AND hyphens are
// token-internal, so `Bundle-time Scrub` never fires inside `Bundle-time
// Scrubbing` and `CLI-Binary-Split` never fires inside `CLI-Binary-Split-Extra`
// or `Pre-CLI-Binary-Split`. The boundaries are also why the shared escaper's
// omission of `-` is safe here: hyphen adjacency is decided by them, not by
// the escape set.
const titleToRegex = (title: string): RegExp =>
  new RegExp(String.raw`(?<![\w-])${escapeRegExp(title)}(?![\w-])`);

// A fence delimiter opens or closes a fenced code block: a line whose trimmed
// text begins with three backticks or three tildes.
const isFenceDelimiter = (line: string): boolean => {
  const trimmed = line.trim();

  return trimmed.startsWith('```') || trimmed.startsWith('~~~');
};

// Remove `[[wikilink]]` and inline `` `code` `` spans (the span only, keeping
// surrounding text) so a title inside either is not matched while a bare title
// sharing the line still is. Order is independent: neither strip reintroduces
// the other's delimiters.
const stripSkippedSpans = (line: string): string =>
  line.replaceAll(WIKILINK_SPAN, '').replaceAll(INLINE_CODE_SPAN, '');

type TitleMatcher = {regex: RegExp; title: string};

/**
 * Scan one post-strip staging file for bare-title leaks with its OWN full
 * line-stream walk (not `scanForLeaks`), tracking fenced-code-block state per
 * file. Every line is observed so a fence delimiter always toggles state, even
 * a line-allowlisted one; routing this through `scanForLeaks` would drop
 * allowlisted lines before the walk and desync the fence counter.
 */
const findTitleLeaksInFile = (
  file: {content: string; id: string; path: string},
  matchers: readonly TitleMatcher[],
  isAllowed: (line: string) => boolean
): Leak[] => {
  const leaks: Leak[] = [];
  let insideFence = false;

  for (const [index, line] of file.content.split('\n').entries()) {
    if (isFenceDelimiter(line)) {
      insideFence = !insideFence;
    } else if (!insideFence && !isAllowed(line)) {
      const residue = stripSkippedSpans(line);

      for (const {regex, title} of matchers) {
        if (regex.test(residue)) {
          leaks.push({
            check: file.id,
            file: file.path,
            line: index + 1,
            match: title,
          });
        }
      }
    }
  }

  return leaks;
};

type DerivedTitleCheckArgs = {
  allowlist: LineAllowlist;
  check: TitleDerivedLeakCheck;
  cwd: string;
  files: readonly string[];
  scopeSkip: readonly string[];
  stagingRoot: string;
};

export const runDerivedTitleCheck = ({
  allowlist,
  check,
  cwd,
  files,
  scopeSkip,
  stagingRoot,
}: DerivedTitleCheckArgs): readonly Leak[] => {
  const optOut = new Set(check['title-opt-out']);
  const matchers: TitleMatcher[] = [...buildExcludedTitleSet(cwd)]
    .filter((title) => !optOut.has(title))
    .map((title) => ({regex: titleToRegex(title), title}));

  if (matchers.length === 0) return [];

  const leaks: Leak[] = [];

  for (const relativePath of files) {
    if (isInCheckScope(relativePath, check, scopeSkip)) {
      const content = readFileSync(
        path.join(stagingRoot, relativePath),
        'utf8'
      );

      leaks.push(
        ...findTitleLeaksInFile(
          {content, id: check.id, path: relativePath},
          matchers,
          allowlist.isAllowed
        )
      );
    }
  }

  return leaks;
};
