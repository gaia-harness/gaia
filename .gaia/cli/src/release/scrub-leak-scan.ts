import {readFileSync} from 'node:fs';
import path from 'node:path';
import type {LeakCheckEntry, StaticLeakCheck} from './scrub-config.js';
import {matchesAnyGlob} from './scrub-glob.js';

// Leak check

export type AllowlistWarning = {
  check: string;
  entry: string;
  kind: 'line-allowlist' | 'ref-opt-out';
};

export type Leak = {
  check: string;
  file: string;
  line: number;
  match: string;
};

export type LineAllowlist = {
  isAllowed: (line: string) => boolean;
  unused: () => AllowlistWarning[];
};

/**
 * A check's `line-allowlist`, recording which entries ever exempted a line so
 * the run can report the ones that never did. Nothing else notices when the
 * line an entry was written for is reworded, and a stale entry quietly exempts
 * whatever later matches it. Reported, never failed: an entry can be written
 * ahead of the line it exempts.
 */
export const trackLineAllowlist = (check: LeakCheckEntry): LineAllowlist => {
  const entries = (check['line-allowlist'] ?? []).map(
    (raw) => [raw, new RegExp(raw)] as const
  );
  const unmatched = new Set(entries.map(([raw]) => raw));

  return {
    isAllowed: (line) => {
      let allowed = false;

      for (const [raw, regex] of entries) {
        if (regex.test(line)) {
          unmatched.delete(raw);
          allowed = true;
        }
      }

      return allowed;
    },
    unused: () =>
      [...unmatched].map((entry) => ({
        check: check.id,
        entry,
        kind: 'line-allowlist',
      })),
  };
};

type FileScanArgs = {
  allowlist: LineAllowlist;
  check: LeakCheckEntry;
  files: readonly string[];
  scopeSkip: readonly string[];
  stagingRoot: string;
};

/**
 * A file is scanned when the check's own scope admits it and neither the
 * check's `path-allowlist` nor the transform-wide `scope-skip` withholds it.
 * Both scan loops share this so the two lists can never diverge between them.
 */
export const isInCheckScope = (
  relativePath: string,
  check: LeakCheckEntry,
  scopeSkip: readonly string[]
): boolean =>
  matchesAnyGlob(relativePath, check.scope) &&
  !matchesAnyGlob(relativePath, check['path-allowlist'] ?? []) &&
  !matchesAnyGlob(relativePath, scopeSkip);

/**
 * Shared skeleton for the literal, wikilink, excluded-workflow and refs leak
 * checks (the titles check walks lines itself): walk each file `isInCheckScope`
 * admits, split into lines, skip line-allowlisted lines, and delegate to
 * `findLeaksInLine` for the check-specific match logic (literal regex,
 * wikilink lookup, or excluded-workflow substring search).
 */
export const scanForLeaks = (
  {allowlist, check, files, scopeSkip, stagingRoot}: FileScanArgs,
  findLeaksInLine: (
    line: string,
    lineNumber: number,
    relativePath: string
  ) => readonly Leak[]
): Leak[] => {
  const leaks: Leak[] = [];

  for (const relativePath of files) {
    if (isInCheckScope(relativePath, check, scopeSkip)) {
      const source = readFileSync(path.join(stagingRoot, relativePath), 'utf8');

      for (const [index, line] of source.split('\n').entries()) {
        if (!allowlist.isAllowed(line)) {
          leaks.push(...findLeaksInLine(line, index + 1, relativePath));
        }
      }
    }
  }

  return leaks;
};

export const runLeakCheck = (
  args: Omit<FileScanArgs, 'check'> & {check: StaticLeakCheck}
): readonly Leak[] => {
  const {check} = args;
  const pattern = new RegExp(check.pattern);

  return scanForLeaks(args, (line, lineNumber, relativePath) => {
    const match = pattern.exec(line);

    return match === null ?
        []
      : [
          {
            check: check.id,
            file: relativePath,
            line: lineNumber,
            match: match[0],
          },
        ];
  });
};
