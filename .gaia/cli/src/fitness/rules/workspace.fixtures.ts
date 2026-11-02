import type {FixtureMap, FixtureProject} from '../types.js';

const descriptor = (name: string): string =>
  JSON.stringify({
    globs: {
      dependencyManifests: [],
      doctorConfigs: [],
      emergentTests: [],
      preCommitSource: [],
      tddStrictCandidates: [],
      tddUnitTests: [],
    },
    name,
    schemaVersion: 1,
    wiki: {flowPaths: [], inventoryPaths: [], sourcePaths: []},
  });

const packageJson = (name: string): string => JSON.stringify({name});

/** A workspace of `apps/*` members, with `registered` listed in the registry. */
export const workspaceProject = (
  folders: readonly string[],
  registered: readonly string[]
): FixtureProject => {
  const files: Record<string, string> = {
    '.gaia/packages.json': JSON.stringify(
      registered.map((folder) => ({
        name: folder.split('/').at(-1),
        path: folder,
      }))
    ),
    'CLAUDE.md': '# Project\n',
    'pnpm-workspace.yaml': 'packages:\n  - apps/*\n',
  };

  for (const folder of folders) {
    files[`${folder}/package.json`] = packageJson(folder);
  }

  for (const folder of registered) {
    files[`${folder}/gaia.package.json`] = descriptor(
      folder.split('/').at(-1) ?? folder
    );
  }

  return {files, git: true};
};

export const WORKSPACE_FIXTURES: FixtureMap = {
  'settings.workspace-member-unregistered': {
    green: () => workspaceProject(['apps/extra'], ['apps/extra']),
    red: () => workspaceProject(['apps/extra'], []),
  },
  'settings.workspace-member-unregistrable': {
    green: () => workspaceProject(['apps/extra'], ['apps/extra']),
    red: () => workspaceProject(['apps/Legacy'], []),
  },
};
