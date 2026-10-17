/**
 * `gaia wiki frontmatter [--json]` handler.
 *
 * Flags wiki pages missing required frontmatter. The required-field floor is
 * `type` and `status`, the two fields essentially all GAIA pages carry. A
 * page gaps if it is missing the frontmatter block entirely, or if either
 * required field is absent or null.
 *
 * Scans `wiki/**\/*.md` except `wiki/meta/**` (audit reports that do
 * not follow the page frontmatter convention).
 *
 * That is the shared base exemption and nothing else: this scan deliberately
 * does NOT take the generated-content tier the other wiki scanners take.
 * `wiki/log.md` does follow the frontmatter convention, and its renderer emits
 * the floor on purpose, so a gap on it is a real break in the renderer rather
 * than noise about a regenerated file.
 *
 * Nothing downstream catches that break. `gaia wiki log-prepend` reads
 * `wiki/log.md` and fails only when the fence itself is missing or unclosed;
 * it never reads a field, so a missing `type` or `status` passes it. This scan
 * is the only detector, which is why it keeps reading that page.
 *
 * Output: one `path: missing a, b` line per gap, or a clean message. With
 * `--json`, emits { "gaps": [ { path, missing } ] }. Exit 0 always; gaps
 * are informational, not a failure.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {parseFrontmatter} from './util/frontmatter.js';
import {collectWikiMarkdown, isWikiScanExempt} from './util/markdown-corpus.js';

const HELP_TEXT = `Usage: gaia wiki frontmatter [--json]

  Scan wiki/**/*.md (excluding wiki/meta/**) for pages missing required
  frontmatter. Required floor is type and status. Without --json, prints one
  "path: missing a, b" line per gap. With --json, emits
  { "gaps": [ { path, missing } ] }.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const REQUIRED_FIELDS = ['type', 'status'] as const;

type Gap = {
  missing: string[];
  path: string;
};

type RunOptions = {
  cwd?: string;
};

const hasField = (
  frontmatter: ReturnType<typeof parseFrontmatter>['frontmatter'],
  field: string
): boolean => Object.hasOwn(frontmatter, field) && frontmatter[field] !== null;

export const findFrontmatterGaps = (cwd: string): readonly Gap[] => {
  const gaps: Gap[] = [];

  for (const filePath of collectWikiMarkdown(cwd)) {
    if (!isWikiScanExempt(filePath)) {
      const content = readFileSync(path.join(cwd, filePath), 'utf8');
      const {frontmatter} = parseFrontmatter(content);
      const missing = REQUIRED_FIELDS.filter(
        (field) => !hasField(frontmatter, field)
      );

      if (missing.length > 0) {
        gaps.push({missing, path: filePath});
      }
    }
  }

  return gaps;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  let json = false;

  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--json') {
      json = true;
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'wiki frontmatter',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
  }

  try {
    const cwd = options.cwd ?? process.cwd();
    const gaps = findFrontmatterGaps(cwd);

    if (json) {
      process.stdout.write(`${JSON.stringify({gaps}, null, 2)}\n`);

      return EXIT_CODES.OK;
    }

    if (gaps.length === 0) {
      process.stdout.write('No frontmatter gaps found.\n');

      return EXIT_CODES.OK;
    }

    const lines = gaps.map(
      (gap) => `${gap.path}: missing ${gap.missing.join(', ')}`
    );
    process.stdout.write(`${lines.join('\n')}\n`);

    return EXIT_CODES.OK;
  } catch (error) {
    structuredError({
      code: 'frontmatter_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'wiki frontmatter',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
};
