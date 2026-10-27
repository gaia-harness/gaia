import {readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {collectTreeFiles, EVERY_EXTENSION} from '../util/tree-walk.js';
import {extractWikilinks} from '../wiki/util/wikilinks.js';
import {
  compileExcludedRefMatcher,
  deriveExcludedRefTokens,
} from './excluded-refs.js';
import {listGitFiles, parseExcludeLines} from './manifest.js';
import type {
  DerivedLeakCheck,
  LeakCheckEntry,
  RefsDerivedLeakCheck,
} from './scrub-config.js';
import {scanForLeaks} from './scrub-leak-scan.js';
import type {AllowlistWarning, Leak, LineAllowlist} from './scrub-leak-scan.js';

export const RELEASE_EXCLUDE_PATH = '.gaia/release-exclude';
const WORKFLOWS_DIR = '.github/workflows';

// Derived wikilink-to-excluded check

export const isDerivedCheck = (
  check: LeakCheckEntry
): check is DerivedLeakCheck => 'derive' in check;

export const slugFromPath = (filePath: string): string =>
  path.basename(filePath, '.md');

export const isDirectory = (absolutePath: string): boolean => {
  try {
    return statSync(absolutePath).isDirectory();
  } catch {
    return false;
  }
};

/**
 * A `.md` exclude contributes its basename slug directly. A bare-directory
 * exclude contributes the directory's own slug plus the slug of every `.md`
 * page beneath it, the entity pages and dated audit artifacts that are never
 * enumerated as their own exclude lines.
 *
 * Guard-clause early returns (not `continue`): this runs once per line from
 * a plain `for` loop in the caller, not from inside a loop itself.
 */
const addSlugsForExcludeLine = (
  line: string,
  cwd: string,
  addSlug: (value: string) => void
): void => {
  if (line !== 'wiki' && !line.startsWith('wiki/')) return;

  if (line.endsWith('.md')) {
    addSlug(slugFromPath(line));

    return;
  }

  const absolute = path.join(cwd, line);

  if (!isDirectory(absolute)) return;

  addSlug(path.basename(line));

  for (const relative of collectTreeFiles(absolute, EVERY_EXTENSION)) {
    if (relative.endsWith('.md')) addSlug(slugFromPath(relative));
  }
};

/**
 * Build the set of release-excluded wiki slugs from `.gaia/release-exclude`
 * resolved against `cwd`, the source repo.
 *
 * Reading from `cwd` is load-bearing: `release-exclude` excludes itself, so it
 * never reaches the staging tree the other checks scan. Deriving from staging
 * would yield an empty set and pass silently, worse than the drift this fix
 * removes.
 *
 * Slugs are lowercased for the case-insensitive matching Obsidian uses to
 * resolve wikilinks.
 */
const buildExcludedSlugSet = (cwd: string): Set<string> => {
  const lines = parseExcludeLines(
    readFileSync(path.join(cwd, RELEASE_EXCLUDE_PATH), 'utf8')
  );
  const slugs = new Set<string>();

  const addSlug = (value: string): void => {
    slugs.add(value.toLowerCase());
  };

  for (const line of lines) {
    addSlugsForExcludeLine(line, cwd, addSlug);
  }

  return slugs;
};

type DerivedCheckArgs = {
  allowlist: LineAllowlist;
  check: DerivedLeakCheck;
  cwd: string;
  files: readonly string[];
  scopeSkip: readonly string[];
  stagingRoot: string;
};

export const runDerivedWikilinkCheck = ({
  allowlist,
  check,
  cwd,
  files,
  scopeSkip,
  stagingRoot,
}: DerivedCheckArgs): readonly Leak[] => {
  const excludedSlugs = buildExcludedSlugSet(cwd);

  return scanForLeaks(
    {allowlist, check, files, scopeSkip, stagingRoot},
    (line, lineNumber, relativePath) =>
      extractWikilinks(line)
        .filter((target) => excludedSlugs.has(target.toLowerCase()))
        .map((target) => ({
          check: check.id,
          file: relativePath,
          line: lineNumber,
          match: `[[${target}]]`,
        }))
  );
};

// Derived excluded-workflow check

/**
 * Build the set of release-excluded `.github/workflows/*.yml` paths that never
 * reach an adopter machine, derived from `.gaia/release-exclude` resolved
 * against `cwd` (the source repo).
 *
 * `.github/workflows/` is the one distribution-boundary directory where some
 * files ship and some do not, so a curated path alternation
 * cannot blanket it (most workflows ship) and cannot enumerate every excluded
 * one without drifting. This set is derived instead: no adopter installs a
 * workflow from a template, so every excluded workflow is never present on an
 * adopter and a shipped-surface reference to it is a dangling pointer.
 *
 * Reading the exclude list from `cwd` mirrors `buildExcludedSlugSet`: the file
 * excludes itself, so it never reaches the staging tree the other checks scan.
 */
export const buildNeverPresentWorkflowSet = (cwd: string): Set<string> => {
  const lines = parseExcludeLines(
    readFileSync(path.join(cwd, RELEASE_EXCLUDE_PATH), 'utf8')
  );
  const paths = new Set<string>();

  for (const line of lines) {
    if (line.startsWith(`${WORKFLOWS_DIR}/`) && line.endsWith('.yml')) {
      paths.add(line);
    }
  }

  return paths;
};

export const runDerivedWorkflowCheck = ({
  allowlist,
  check,
  cwd,
  files,
  scopeSkip,
  stagingRoot,
}: DerivedCheckArgs): readonly Leak[] => {
  const neverPresent = buildNeverPresentWorkflowSet(cwd);

  if (neverPresent.size === 0) return [];

  return scanForLeaks(
    {allowlist, check, files, scopeSkip, stagingRoot},
    (line, lineNumber, relativePath) =>
      [...neverPresent]
        .filter((excludedPath) => line.includes(excludedPath))
        .map((excludedPath) => ({
          check: check.id,
          file: relativePath,
          line: lineNumber,
          match: excludedPath,
        }))
  );
};

// Derived excluded-refs check

type DerivedRefsCheckArgs = {
  allowlist: LineAllowlist;
  check: RefsDerivedLeakCheck;
  cwd: string;
  files: readonly string[];
  scopeSkip: readonly string[];
  stagingRoot: string;
};

const isExecutableIn =
  (cwd: string) =>
  (relativePath: string): boolean => {
    try {
      // eslint-disable-next-line no-bitwise -- the mode's execute bits
      return (statSync(path.join(cwd, relativePath)).mode & 0o111) !== 0;
    } catch {
      return false;
    }
  };

/**
 * The exclude list and the tracked set both come from `cwd`, the source repo,
 * for the reason `buildExcludedSlugSet` gives: the staging tree holds neither.
 * Tracked rather than present on disk, so a maintainer's local-state directory
 * (`.gaia/local`) derives the same set as a clean CI checkout.
 */
export const runDerivedRefsCheck = ({
  allowlist,
  check,
  cwd,
  files,
  scopeSkip,
  stagingRoot,
}: DerivedRefsCheckArgs): {leaks: Leak[]; warnings: AllowlistWarning[]} => {
  const tokens = deriveExcludedRefTokens({
    excludeLines: parseExcludeLines(
      readFileSync(path.join(cwd, RELEASE_EXCLUDE_PATH), 'utf8')
    ),
    isExecutable: isExecutableIn(cwd),
    optOut: check['ref-opt-out'] ?? [],
    shippedBasenames: new Set(files.map((file) => path.basename(file))),
    tracked: listGitFiles(cwd),
  });
  const matcher = compileExcludedRefMatcher(tokens);

  const leaks = scanForLeaks(
    {allowlist, check, files, scopeSkip, stagingRoot},
    (line, lineNumber, relativePath) =>
      matcher(line, {markdown: relativePath.endsWith('.md')}).map((match) => ({
        check: check.id,
        file: relativePath,
        line: lineNumber,
        match,
      }))
  );

  return {
    leaks,
    warnings: tokens.unusedOptOut.map((entry) => ({
      check: check.id,
      entry,
      kind: 'ref-opt-out',
    })),
  };
};
