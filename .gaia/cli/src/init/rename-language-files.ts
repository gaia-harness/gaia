/**
 * The seeded language-file half of `gaia init rename`: writes the project
 * title into the identity keys of the English language files, wherever the
 * value is a quoted string literal. An absent file or key is a clean pass.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {escapeJsLiteralValue} from './util/js-literal.js';
import type {JsLiteralQuote} from './util/js-literal.js';

const COMMON_TS = 'app/languages/en/common.ts';
const INDEX_PAGE_TS = 'app/languages/en/pages/_index.ts';

/**
 * The body of a quoted string literal, for the pattern `literalPattern` builds
 * around it, whose group 2 is the opening quote.
 *
 * `(?!\2)` excludes only the quote the match actually opened with, so a
 * single-quoted literal may hold a bare `"` and a double-quoted one a bare `'`.
 * A class naming both quotes refuses `"Steve's Template"` outright, and a
 * pattern that cannot match is a rewrite that silently does not happen. It
 * cannot re-match this command's own output either: the escaper leaves the
 * non-wrapping quote bare, because it needs no escape, so a title carrying one
 * survives the first rename and then defeats the second.
 *
 * `\n` stays excluded because a JavaScript string literal cannot span a raw
 * line ending. Bounding the body to one line is what keeps a quote further down
 * the file from being read as this literal's closing one, now that the class no
 * longer stops at the other quote character.
 */
const LITERAL_BODY = String.raw`(?:(?!\2)[^\n\\]|\\.)*`;

type LanguageFile = {
  file: string;
  keys: readonly RewriteKey[];
};

/**
 * One rewritable identity key.
 *
 * `prefix` is everything up to the opening quote and carries **no capturing
 * group of its own**: `literalPattern` wraps it in group 1 and opens group 2 for
 * the quote, so both indices `LITERAL_BODY` and the replacer depend on are fixed
 * where the pattern is composed rather than by whoever authored the prefix.
 *
 * `global` is whether the key is rewritten everywhere it appears or only at its
 * first match, which is the one regex flag that varies across the table.
 */
type RewriteKey = {
  global: boolean;
  prefix: string;
};

const flagsFor = (key: RewriteKey): string => (key.global ? 'gmu' : 'mu');

/** The whole property: prefix, opening quote, body, matching close quote. */
const literalPattern = (key: RewriteKey): RegExp =>
  new RegExp(String.raw`(${key.prefix})(['"])${LITERAL_BODY}\2`, flagsFor(key));

/**
 * `source` with `newValue` written into every value `key` matches.
 *
 * A **function** replacement, which is what makes the title safe to splice: in
 * a replacement *string* `$1` and `$&` are match references, so a title
 * carrying one injects part of the file into itself. A backslash does not
 * neutralize them, only `$$` does, so the escape this replaced looked like a
 * guard and was inert. A function receives the value verbatim and interprets
 * nothing.
 *
 * The value is then escaped for the quote the match found, so an ordinary
 * `Steve's App` cannot close the literal early. Both halves are needed: the
 * function form fixes `$`, the escape fixes the quote.
 */
const applyRewrite = (
  source: string,
  key: RewriteKey,
  newValue: string
): string =>
  source.replace(
    literalPattern(key),
    // `literalPattern` captures the quote as `(['"])`, so group 2 is one of the
    // two by construction, which is what the narrower type records.
    (_match: string, prefix: string, quote: JsLiteralQuote) =>
      `${prefix}${quote}${escapeJsLiteralValue(newValue, quote)}${quote}`
  );

/** A key whose value is the title wherever in the file it appears. */
const unscopedKey = (key: string): RewriteKey => ({
  global: true,
  prefix: String.raw`\b${key}\s*:\s*`,
});

/**
 * A key indented at the file's top object level (a single indentation unit).
 * Nested keys with the same name (e.g. a `title` inside a deeper route object)
 * are left untouched so a user-diverged file is preserved.
 */
const topLevelKey = (key: string): RewriteKey => ({
  global: true,
  prefix: String.raw`^\x20\x20${key}\s*:\s*`,
});

/**
 * Every identity key this step rewrites, grouped by the file carrying it.
 *
 * `common.ts` carries a single identity-bearing key. Other `*Name` properties
 * exist there (form labels) but no second `siteName`, so an unscoped rewrite is
 * safe. `_index.ts` has two, each scoped to the top object level: a global
 * `title` rewrite would clobber `title` keys in extra routes a user may have
 * added, which is data loss on a diverged file.
 *
 * Every key is optional. The shipped `_index.ts` carries neither, so a file
 * missing them is a clean pass.
 */
const LANGUAGE_FILES: readonly LanguageFile[] = [
  {file: COMMON_TS, keys: [unscopedKey('siteName')]},
  {
    file: INDEX_PAGE_TS,
    keys: [topLevelKey('heroTitle'), topLevelKey('title')],
  },
];

const renameLanguageFile = (
  cwd: string,
  {file, keys}: LanguageFile,
  title: string
): void => {
  const target = path.join(cwd, file);

  if (!existsSync(target)) return;
  const original = readFileSync(target, 'utf8');
  const next = keys.reduce(
    (source, key) => applyRewrite(source, key, title),
    original
  );

  if (next !== original) {
    atomicWriteFileSync(target, next);
  }
};

/** Writes `title` into every identity key of the seeded language files. */
export const renameLanguageFiles = (
  packageDir: string,
  title: string
): void => {
  for (const languageFile of LANGUAGE_FILES) {
    renameLanguageFile(packageDir, languageFile, title);
  }
};
