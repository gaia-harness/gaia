/**
 * The `wiki/**` markdown corpus the wiki scanner subcommands read, and the
 * vocabulary they state their exemptions from it in.
 *
 * The corpus and the exemptions live together because their boundaries
 * coincide: a scanner that shares this walk is asking about the same set of
 * pages, so it is also answering the same question about which of them are
 * worth reading. The exemptions are two tiers rather than one list, and each
 * tier's docblock below owns the warrant that decides who may take it; a
 * scanner adds its own narrower entries at its own site, with its own reason.
 *
 * Each scanner asks the same question of the tree before it asks its own:
 * which markdown pages exist under `wiki/`, named the way the rest of the
 * repository names them. Answering it per subcommand is the drift the shared
 * walk exists to close one level down, reintroduced one level up: a scanner's
 * corpus is exactly the set it is trusted to have read, and a private answer
 * that stops normalizing a separator or misses a nested page still returns a
 * plausible list and still greens.
 *
 * An absent `wiki/` directory yields an empty corpus rather than throwing.
 * That is the scanners' own contract with their callers: `gaia wiki` runs on a
 * clone that has not seeded a wiki yet, and reporting nothing found is the
 * honest answer there.
 *
 * The guard reads every `statSync` failure as absence, not `ENOENT` alone, so a
 * `wiki/` that exists but cannot be stated, a symlink loop or a parent without
 * `+x`, also yields an empty corpus and a clean pass over a tree nothing read.
 * That is an accepted miss rather than the condition the guard states: which
 * errors should stop a scan is a question about the scanners, and narrowing it
 * here would answer it for all three without any of them asking.
 */
import {statSync} from 'node:fs';
import path from 'node:path';
import {collectTreeFiles} from '../../util/tree-walk.js';

const WIKI_DIR = 'wiki';

const MARKDOWN_EXTENSIONS: ReadonlySet<string> = new Set(['.md']);

/**
 * The exemption every scanner reading this corpus applies, whatever it asks.
 *
 * `wiki/meta/` holds audit reports, and it is the only exemption whose
 * warrant survives every question these scanners ask: those pages are not
 * pages in the sense any of the scans means, so no scan's finding against one
 * is actionable. Matched by prefix, because it names a directory.
 */
export const WIKI_SCAN_EXEMPT_PREFIXES = ['wiki/meta/'] as const;

/**
 * The page that is append-only rather than hand-edited.
 *
 * **This tier is for CONTENT-ROT scans only, and a scan that asks a different
 * question must not inherit it.** The warrant is that a finding about the
 * *content* of such a page is not rot a human can act on, because the page is
 * written by a tool rather than edited. That reasoning covers a dead citation
 * (`dead-paths`) and an empty section (`empty-sections`), and it does not
 * cover a schema question: a frontmatter gap in a generated page is entirely
 * actionable, at the renderer that generates it, and `gaia wiki frontmatter`
 * is the only scan that would surface such a break before `gaia wiki
 * log-prepend` fails on it. So `frontmatter` takes the base tier above and
 * this one is deliberately not offered to it.
 *
 * Matched exactly, not by prefix: it names one file, and a prefix would also
 * swallow any page whose path merely starts with it.
 *
 * This tier (`wiki/log.md`) and the base tier (`wiki/meta/`) correspond to the
 * two path entries of the Exceptions list in `.claude/rules/wiki-style.md`;
 * its other entries are not wiki pages a scanner walks. The rule exempts
 * both paths from a prose rule about inline historical references; the split
 * into two tiers here is about which *scan* may take which exemption, which
 * that rule never spoke to.
 */
export const GENERATED_CONTENT_EXEMPT_PATHS: ReadonlySet<string> = new Set([
  'wiki/log.md',
]);

/** Whether `relativePath` is exempt from every scan over this corpus. */
export const isWikiScanExempt = (relativePath: string): boolean =>
  WIKI_SCAN_EXEMPT_PREFIXES.some((prefix) => relativePath.startsWith(prefix));

/**
 * Whether `relativePath` is a generated or append-only page, and so exempt
 * from a scan of its content. Read the tier's docblock before adding a caller:
 * a scan that does not ask a content-rot question does not get this exemption.
 */
export const isGeneratedContentExempt = (relativePath: string): boolean =>
  GENERATED_CONTENT_EXEMPT_PATHS.has(relativePath);

/**
 * Every `wiki/**` markdown page under `cwd`, as repo-relative POSIX paths
 * carrying the `wiki/` prefix, sorted. Empty when `cwd` holds no `wiki/`.
 */
export const collectWikiMarkdown = (cwd: string): readonly string[] => {
  const wikiDir = path.join(cwd, WIKI_DIR);

  try {
    statSync(wikiDir);
  } catch {
    return [];
  }

  return collectTreeFiles(wikiDir, MARKDOWN_EXTENSIONS).map((relativePath) =>
    path.posix.join(WIKI_DIR, relativePath)
  );
};
