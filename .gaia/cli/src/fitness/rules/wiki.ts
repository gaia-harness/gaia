import {statSync} from 'node:fs';
import path from 'node:path';
import {scanWikiPaths} from '../../wiki/dead-paths.js';
import {orphansOf} from '../../wiki/orphans.js';
import {computePageIndexAt} from '../../wiki/page-index.js';
import type {RuleContext} from '../context.js';
import {redact} from '../secrets.js';
import type {RawFinding, RuleDefinition} from '../types.js';

const WIKI_DIRECTORY = 'wiki';

const hasWikiDirectory = (context: RuleContext): boolean => {
  try {
    return statSync(
      path.join(context.rootDirectory, WIKI_DIRECTORY)
    ).isDirectory();
  } catch {
    return false;
  }
};

const deadPathsCheck = (context: RuleContext): readonly RawFinding[] => {
  if (!hasWikiDirectory(context)) return [];

  let dead: ReturnType<typeof scanWikiPaths>['dead'];

  try {
    ({dead} = scanWikiPaths(context.rootDirectory));
  } catch (error: unknown) {
    // One unreadable package registry must not stop the other categories.
    const reason = error instanceof Error ? error.message : String(error);

    return [
      {
        file: WIKI_DIRECTORY,
        line: 0,
        message: redact(`The wiki dead-path scan could not run: ${reason}`),
        remediation:
          'Fix the package registry the message names, then run the check again.',
      },
    ];
  }

  return dead
    .filter((reference) => context.allTrackedPaths.has(reference.filePath))
    .map((reference) => ({
      file: reference.filePath,
      line: reference.line,
      message: redact(
        `The wiki cites \`${reference.path}\`, which does not exist in this project.`
      ),
      remediation:
        'Update the citation to the path that exists now, or remove the sentence that depends on it.',
    }));
};

const orphansCheck = (context: RuleContext): readonly RawFinding[] => {
  if (!hasWikiDirectory(context)) return [];

  return orphansOf(computePageIndexAt(context.rootDirectory))
    .filter((orphan) => context.allTrackedPaths.has(orphan.path))
    .map((orphan) => ({
      file: orphan.path,
      line: 0,
      message: 'No other wiki page links to this page.',
      remediation:
        'Link the page from a related page or from wiki/index.md, or delete it if it is no longer needed.',
    }));
};

export const WIKI_RULES: readonly RuleDefinition[] = [
  {
    appliesTo: ['wiki'],
    category: 'wiki',
    check: deadPathsCheck,
    detection:
      'A wiki page cites a backticked repo-relative path that no longer exists on disk.',
    ruleId: 'wiki.dead-paths',
    severity: 'warning',
  },
  {
    appliesTo: ['wiki'],
    category: 'wiki',
    check: orphansCheck,
    detection: 'A wiki page has no inbound wikilink from any other page.',
    ruleId: 'wiki.orphans',
    severity: 'info',
  },
];
