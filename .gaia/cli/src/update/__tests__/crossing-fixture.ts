/**
 * Builds a scratch repository shaped like a 2.x install, for the crossing
 * tests. The old root is composed from a bare name so a mechanical path
 * rewrite of this file leaves the fixture describing the old layout.
 */
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

export const OLD_ROOT = 'frontend';

export const OLD = (rest: string): string => `${OLD_ROOT}/${rest}`;

export const git = (root: string, args: string[]): string =>
  execFileSync('git', args, {cwd: root, encoding: 'utf8', stdio: 'pipe'});

export const write = (root: string, file: string, content: string): void => {
  mkdirSync(path.dirname(path.join(root, file)), {recursive: true});
  writeFileSync(path.join(root, file), content);
};

export const read = (root: string, file: string): string =>
  readFileSync(path.join(root, file), 'utf8');

export const DESCRIPTOR = (name: string): string => `{
  "schemaVersion": 1,
  "name": "${name}",
  "globs": {
    "tddUnitTests": ["app/**/*.test.ts"],
    "tddStrictCandidates": [],
    "emergentTests": [],
    "preCommitSource": ["app/**"],
    "doctorConfigs": [],
    "dependencyManifests": ["package.json"]
  },
  "wiki": {
    "sourcePaths": ["app/"],
    "inventoryPaths": [],
    "flowPaths": []
  }
}
`;

export const WORKSPACE = `packages:
  - frontend
  - .gaia/cli

minimumReleaseAge: 4320
`;

export const ROSTER = `# roster header comment
auditors:
  - name: code-audit-frontend
    globs:
      - "${OLD('app/**')}"
      # a comment inside the list
      - "package.json"
      - '${OLD('package.json')}'
    light_hard_full:
      - "${OLD('package.json')}"
    audience: adopter
    default: true
  - name: code-audit-shell
    globs:
      - "**/*.sh"
    audience: adopter
unowned:
  - "*.md"
  - "${OLD('public/**')}"
  - "apps/legacy/docs/**"
  - "packages/shared/**"
`;

export const MANIFEST = `${JSON.stringify(
  {
    files: {
      '.claude/agents/code-audit-frontend.md': 'owned',
      '.gaia/VERSION': 'owned',
      [OLD('app/x.ts')]: 'owned',
      [OLD('package.json')]: 'shared',
    },
    generated: '2026-11-01T00:00:00.000Z',
    version: '2.3.1',
  },
  null,
  2
)}\n`;

export const DECISIONS = `${JSON.stringify(
  {
    decisions: [
      {
        baselineTag: 'v2.3.0',
        decision: 'deferred',
        path: OLD('package.json'),
        tag: 'v2.3.1',
      },
      {
        baselineTag: 'v2.3.0',
        decision: 'keep',
        path: OLD('app/x.ts'),
        tag: 'v2.3.1',
      },
      {
        baselineTag: 'v2.3.0',
        decision: 'keep',
        key: 'scripts.test',
        path: OLD('package.json'),
        tag: 'v2.3.1',
      },
      {
        baselineTag: 'v2.3.0',
        decision: 'keep',
        path: '.claude/agents/code-audit-frontend.md',
        tag: 'v2.3.1',
      },
    ],
    schemaVersion: 1,
  },
  null,
  2
)}\n`;

export type LegacyRepoOptions = {name?: string; registry?: boolean};

/** A committed 2.x-shaped repo on `main`, with an ignored `.env` in the app. */
export const makeLegacyRepo = (options: LegacyRepoOptions = {}): string => {
  const name = options.name ?? OLD_ROOT;
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-crossing-')));

  git(root, ['init', '-q', '-b', 'main']);
  git(root, ['config', 'user.email', 'test@example.com']);
  git(root, ['config', 'user.name', 'Test']);
  git(root, ['config', 'commit.gpgsign', 'false']);
  write(
    root,
    OLD('package.json'),
    `{\n  "name": "${name}",\n  "private": true\n}\n`
  );
  write(root, OLD('gaia.package.json'), DESCRIPTOR(name));
  write(root, OLD('app/x.ts'), 'export const x = 1;\n');
  write(root, OLD('.gitignore'), '.env\nnode_modules\n');
  write(root, OLD('.env'), 'SECRET=abc\n');
  write(root, OLD('node_modules/dep/index.js'), 'module.exports = 1;\n');
  write(root, 'pnpm-workspace.yaml', WORKSPACE);
  write(root, '.gaia/audit-ci.yml', ROSTER);
  write(root, '.gaia/manifest.json', MANIFEST);
  write(root, '.gaia/update-decisions.json', DECISIONS);
  write(root, '.gitignore', '.gaia/local\n.notebook\n');

  if (options.registry !== false) {
    write(
      root,
      '.gaia/packages.json',
      `[{"name":"${name}","path":"${OLD_ROOT}"}]\n`
    );
  }
  git(root, ['add', '-A']);
  git(root, ['commit', '-q', '-m', 'seed']);

  return root;
};

/** Every file on disk outside `.git`, as relative path to content digest. */
export const snapshot = (root: string): Record<string, string> => {
  const files: Record<string, string> = {};

  const visit = (directory: string): void => {
    for (const entry of readdirSync(directory, {withFileTypes: true})) {
      const full = path.join(directory, entry.name);
      const relative = path.relative(root, full);

      if (relative === '.git') {
        // the repository's own storage is never part of the tree under test
      } else if (entry.isDirectory()) {
        visit(full);
      } else {
        files[relative] =
          entry.isSymbolicLink() ? 'symlink' : (
            createHash('sha256').update(readFileSync(full)).digest('hex')
          );
      }
    }
  };

  visit(root);

  return files;
};

/** The index as sorted `git ls-files -s` lines. */
export const indexState = (root: string): string =>
  git(root, ['ls-files', '-s']);

export const CACHE = '.gaia/local/cache/shared/update-gaia';

/** An empty git repository, the project root a rekey run reads its cache from. */
export const makeBareRepo = (): string => {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-rekey-')));

  git(root, ['init', '-q']);

  return root;
};

export const manifestText = (keys: string[]): string =>
  `${JSON.stringify(
    {
      files: Object.fromEntries(
        keys
          .toSorted((left, right) => left.localeCompare(right))
          .map((key) => [key, 'owned'])
      ),
      generated: '2026-11-01T00:00:00.000Z',
      version: '2.3.0',
    },
    null,
    2
  )}\n`;

export const DEFAULT_KEYS = [
  OLD('app/x'),
  OLD('package.json'),
  '.claude/agents/code-audit-frontend/y.md',
  'docs/frontend/z.md',
  '.gaia/VERSION',
];

/** A verified bundle tree in the update cache, one file per manifest key. */
export const cacheTree = (
  root: string,
  tag: string,
  keys: string[] = DEFAULT_KEYS
): string => {
  const tree = path.join(root, CACHE, tag, 'tree');

  for (const key of keys) {
    write(tree, key, `content of ${key}\n`);
  }
  write(tree, '.gaia/manifest.json', manifestText(keys));

  return tree;
};

export const rekeyedOf = (root: string, tag: string): string =>
  path.join(root, CACHE, tag, 'tree-rekeyed');
