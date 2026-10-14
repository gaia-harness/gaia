import {committedFrontendDescriptor} from '../../util/package-fixture.js';
import type {FixtureMap, FixtureProject} from '../types.js';

export const registryFiles = (): Record<string, string> => ({
  '.gaia/packages.json': JSON.stringify([{name: 'frontend', path: 'pkg'}]),
  'pkg/gaia.package.json': JSON.stringify(committedFrontendDescriptor()),
});

const linkedIndex = '# Index\n\n[[Example Page]]\n';

const pageCiting = (reference: string): string =>
  `# Example Page\n\nSee \`${reference}\` for the details.\n`;

const deadPathsProject = (reference: string): FixtureProject => ({
  files: {
    ...registryFiles(),
    '.claude/hooks/present.sh': '#!/usr/bin/env bash\n',
    'wiki/concepts/Example Page.md': pageCiting(reference),
    'wiki/index.md': linkedIndex,
  },
  git: true,
});

const orphansProject = (indexText: string): FixtureProject => ({
  files: {
    ...registryFiles(),
    'wiki/concepts/Example Page.md': '# Example Page\n\nBody text.\n',
    'wiki/index.md': indexText,
  },
  git: true,
});

export const WIKI_FIXTURES: FixtureMap = {
  'wiki.dead-paths': {
    green: () => deadPathsProject('.claude/hooks/present.sh'),
    red: () => deadPathsProject('.claude/hooks/missing.sh'),
  },
  'wiki.orphans': {
    green: () => orphansProject(linkedIndex),
    red: () => orphansProject('# Index\n\nNothing links here.\n'),
  },
};
