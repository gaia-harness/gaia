import {afterEach, describe, expect, test} from 'vitest';
import {writeFileSync} from 'node:fs';
import path from 'node:path';
import {
  CSF3_PREVIEW,
  CSF3_STORY,
  CSF4_PREVIEW,
  CSF4_STORY,
  FLAGGED_MAIN,
  git,
  makeHarness,
  PLAIN_MAIN,
  read,
  writeTree,
} from './run-fixture.js';
import {
  cleanupRepos,
  execute,
  JSON_KEYS,
  repo,
  standardFiles,
  status,
} from './run-helpers.js';
import {runMigrateCsf4} from './run.js';
import type {MigrateReport} from './types.js';

const dirtyStates: [string, (root: string) => void][] = [
  [
    'a staged change',
    (root) => {
      writeTree(root, {'frontend/notes.txt': 'x'});
      git(root, 'add', 'frontend/notes.txt');
    },
  ],
  [
    'an unstaged change',
    (root) => {
      writeTree(root, {'frontend/package.json': '{"name": "changed"}\n'});
    },
  ],
  [
    'an untracked file',
    (root) => {
      writeTree(root, {'elsewhere/new.txt': 'x'});
    },
  ],
];

afterEach(cleanupRepos);

describe('standalone clean-tree preflight', () => {
  test.each(dirtyStates)('refuses %s and writes nothing', (_name, dirty) => {
    const root = repo(standardFiles);

    dirty(root);
    const before = status(root);
    const storyBefore = read(root, 'frontend/app/a/a.stories.tsx');
    const {exit, harness, json} = execute(root);

    expect(exit).toBe(3);
    expect(json?.refused?.reason).toBe('dirty-tree');
    expect(status(root)).toBe(before);
    expect(read(root, 'frontend/app/a/a.stories.tsx')).toBe(storyBefore);
    expect(harness.calls).toEqual([]);
  });
});

describe('refusals', () => {
  test('a CSF2 file (bind and storiesOf) refuses and names the codemod', () => {
    [
      'export const T = Template.bind({});\nexport default {};\n',
      "storiesOf('x', module);\n",
    ].forEach((source) => {
      const root = repo({
        ...standardFiles,
        'frontend/app/c/c.stories.tsx': source,
      });
      const {exit, harness, json} = execute(root);

      expect(exit).toBe(3);
      expect(json?.refused).toMatchObject({
        paths: ['frontend/app/c/c.stories.tsx'],
        reason: 'csf2',
      });
      expect(harness.err.join('')).toContain('csf-2-to-3');
      expect(status(root)).toBe('');
    });
  });

  test('an unknown-format file refuses', () => {
    const root = repo({
      ...standardFiles,
      'frontend/app/u/u.stories.tsx': 'const x = 1;\n',
    });
    const {exit, json} = execute(root);

    expect(exit).toBe(3);
    expect(json?.refused).toMatchObject({
      paths: ['frontend/app/u/u.stories.tsx'],
      reason: 'unknown-format',
    });
  });

  test('no registered frontend package refuses with the resolver message', () => {
    const root = repo(standardFiles);

    writeFileSync(
      path.join(root, '.gaia/packages.json'),
      '[{"name":"other","path":"x"}]'
    );
    const {exit, harness, json} = execute(root);

    expect(exit).toBe(3);
    expect(json?.refused?.reason).toBe('package-config');
    expect(harness.err.join('')).toContain('gaia-packages:');
  });

  test('a storybook outside ~10.6.0 refuses naming the version', () => {
    const root = repo(standardFiles, '10.7.0');
    const {exit, harness, json} = execute(root);

    expect(exit).toBe(3);
    expect(json?.refused?.reason).toBe('storybook-version');
    expect(harness.err.join('')).toContain('10.7.0');
  });

  test('an unresolvable typescript refuses', () => {
    const root = repo(standardFiles);
    const harness = makeHarness(root, {}, {withoutTypescript: true});
    const exit = runMigrateCsf4({json: true, updateMerge: false}, harness.deps);

    expect(exit).toBe(3);
    expect(
      (JSON.parse(harness.out.join('')) as MigrateReport).refused?.reason
    ).toBe('typescript');
  });

  test('a codemod failure refuses with the network requirement and leaves the tree', () => {
    const root = repo(standardFiles);
    const {exit, harness, json} = execute(root, {}, {codemodExitCode: 1});

    expect(exit).toBe(3);
    expect(json?.refused?.reason).toBe('codemod-fetch');
    expect(harness.err.join('')).toContain('network');
    expect(status(root)).toBe('');
  });

  test('the JSON object has exactly the contract keys, also on a refusal', () => {
    const root = repo({
      ...standardFiles,
      'frontend/app/u/u.stories.tsx': 'const x = 1;\n',
    });
    const {json} = execute(root);

    expect(
      Object.keys(json ?? {}).toSorted((left, right) =>
        left.localeCompare(right)
      )
    ).toEqual(JSON_KEYS);
    expect(json?.typecheck.result).toBe('skipped');
    expect(json?.lint.result).toBe('skipped');
    expect(json?.restore).toBeNull();
  });
});

describe('conversion', () => {
  test('converts, formats the write set only, and reports a restore command naming exactly the changed files', () => {
    const root = repo(standardFiles);
    const {exit, harness, json} = execute(root);

    expect(exit).toBe(0);
    expect(
      Object.keys(json ?? {}).toSorted((left, right) =>
        left.localeCompare(right)
      )
    ).toEqual(JSON_KEYS);
    expect(
      (json?.converted ?? []).toSorted((left, right) =>
        left.localeCompare(right)
      )
    ).toEqual([
      'frontend/.storybook/main.ts',
      'frontend/.storybook/preview.ts',
      'frontend/app/a/a.stories.tsx',
      'frontend/app/b/b.stories.tsx',
      'frontend/package.json',
    ]);
    expect(json?.restore).toBe(
      `git restore --source=HEAD --staged --worktree -- ${json?.converted.join(' ')}`
    );
    expect(json?.unknownAddons).toEqual(['some-addon']);
    expect(json?.files.every((file) => file.loaded && file.passed)).toBe(true);
    expect(read(root, 'frontend/app/a/a.stories.tsx')).toContain('// repaired');
    const fix = harness.calls.find((call) => call.args.includes('--fix'));

    expect(
      fix?.args.slice(5).toSorted((left, right) => left.localeCompare(right))
    ).toEqual(
      json?.converted
        .map((file) => file.replace('frontend/', ''))
        .toSorted((left, right) => left.localeCompare(right))
    );
  });

  test('third-party writes to main, preview and package.json never reach the adopter tree', () => {
    const root = repo(standardFiles);
    const {exit} = execute(root);

    expect(exit).toBe(0);
    expect(read(root, 'frontend/.storybook/main.ts')).toBe(FLAGGED_MAIN);
    expect(read(root, 'frontend/.storybook/preview.ts')).toBe(
      'export default definePreview({});\n'
    );
    expect(read(root, 'frontend/package.json')).toContain(
      '"#.storybook/preview"'
    );
    expect(read(root, 'frontend/package.json')).not.toContain('codemod');
    expect(read(root, 'frontend/app/a/a.stories.tsx')).not.toContain(
      'codemod main'
    );
  });

  test('config the repairs leave unchanged stays byte-identical despite tool rewrites', () => {
    const root = repo({
      ...standardFiles,
      'frontend/.storybook/main.ts': FLAGGED_MAIN,
      'frontend/.storybook/preview.ts': CSF4_PREVIEW,
      'frontend/package.json': '{"imports": {}}\n',
    });
    const {exit, json} = execute(root);

    expect(exit).toBe(0);
    expect(
      (json?.converted ?? []).toSorted((left, right) =>
        left.localeCompare(right)
      )
    ).toEqual(['frontend/app/a/a.stories.tsx', 'frontend/app/b/b.stories.tsx']);
    expect(read(root, 'frontend/.storybook/main.ts')).toBe(FLAGGED_MAIN);
    expect(read(root, 'frontend/.storybook/preview.ts')).toBe(CSF4_PREVIEW);
    expect(read(root, 'frontend/package.json')).toBe('{"imports": {}}\n');
  });

  test('spawn arguments: codemod and msw run in work/, with a pinned cli and exact globs', () => {
    const root = repo(standardFiles);
    const {harness} = execute(root);
    const codemod = harness.calls.find((call) => call.args[0] === 'dlx');
    const msw = harness.calls.find((call) => call.command === 'node');

    expect(codemod?.cwd).not.toBe(harness.packageDir);
    expect(codemod?.cwd).toMatch(/work$/u);
    expect(codemod?.args).toEqual([
      'dlx',
      '@storybook/cli@10.6.3',
      'automigrate',
      'csf-factories',
      '--yes',
      '--skip-install',
      '--skip-doctor',
      '--glob={app/a/a.stories.tsx,app/b/b.stories.tsx}',
    ]);
    expect(msw?.cwd).toBe(codemod?.cwd);
    expect(msw?.args.slice(1)).toEqual([
      '--glob',
      '{app/a/a.stories.tsx,app/b/b.stories.tsx}',
    ]);
  });

  test('a single converted file uses its plain path as the glob', () => {
    const root = repo({
      ...standardFiles,
      'frontend/app/b/b.stories.tsx': CSF4_STORY,
    });
    const {harness} = execute(root);

    expect(
      harness.calls.find((call) => call.args[0] === 'dlx')?.args.at(-1)
    ).toBe('--glob=app/a/a.stories.tsx');
  });

  test('nothing to convert: no codemod, no copies, no write, verification only', () => {
    const root = repo({
      'frontend/.storybook/main.ts': FLAGGED_MAIN,
      'frontend/.storybook/preview.ts': CSF4_PREVIEW,
      'frontend/app/a/a.stories.tsx': CSF4_STORY,
      'frontend/package.json': '{"imports": {}}\n',
    });
    const {exit, harness, json} = execute(root);

    expect(exit).toBe(0);
    expect(json?.converted).toEqual([]);
    expect(json?.restore).toBeNull();
    expect(
      harness.calls.some(
        (call) => call.args[0] === 'dlx' || call.command === 'node'
      )
    ).toBe(false);
    expect(harness.calls.some((call) => call.args.includes('--fix'))).toBe(
      false
    );
    expect(harness.calls.some((call) => call.args.includes('typecheck'))).toBe(
      true
    );
    expect(status(root)).toBe('');
  });
});

const mergedTree = (): string => {
  const root = repo({
    'frontend/.storybook/main.ts': PLAIN_MAIN,
    'frontend/.storybook/preview.ts': CSF3_PREVIEW,
    'frontend/app/adopter/x.stories.tsx': CSF3_STORY,
    'frontend/app/adopter/y.stories.tsx': CSF3_STORY,
    'frontend/app/gaia/g.stories.tsx': CSF3_STORY,
  });

  writeTree(root, {
    'frontend/.storybook/main.ts': FLAGGED_MAIN,
    'frontend/.storybook/preview.ts': CSF4_PREVIEW,
    'frontend/app/gaia/g.stories.tsx': CSF4_STORY,
    'frontend/package.json': '{"imports": {}}\n',
  });

  return root;
};

describe('update-merge', () => {
  const overlaid = [
    'frontend/.storybook/main.ts',
    'frontend/.storybook/preview.ts',
    'frontend/app/gaia/g.stories.tsx',
    'frontend/package.json',
  ];

  test('converts only the adopter stories and leaves the merged overlay byte-identical', () => {
    const root = mergedTree();
    const snapshot = overlaid.map((file) => read(root, file));
    const {exit, json} = execute(root, {updateMerge: true});

    expect(exit).toBe(0);
    expect(
      (json?.converted ?? []).toSorted((left, right) =>
        left.localeCompare(right)
      )
    ).toEqual([
      'frontend/app/adopter/x.stories.tsx',
      'frontend/app/adopter/y.stories.tsx',
    ]);
    expect(overlaid.map((file) => read(root, file))).toEqual(snapshot);
    expect(json?.restore).toBe(
      'git restore --source=HEAD --staged --worktree -- frontend/app/adopter/x.stories.tsx frontend/app/adopter/y.stories.tsx'
    );
  });

  test('an uncommitted edit to an adopter story refuses naming it', () => {
    const root = mergedTree();

    writeTree(root, {
      'frontend/app/adopter/x.stories.tsx': `${CSF3_STORY}// edited\n`,
    });
    const {exit, json} = execute(root, {updateMerge: true});

    expect(exit).toBe(3);
    expect(json?.refused).toMatchObject({
      paths: ['frontend/app/adopter/x.stories.tsx'],
      reason: 'dirty-write-set',
    });
  });

  test('an uncommitted file outside the write set that a tool changes is restored to its pre-run bytes', () => {
    const root = mergedTree();
    const target = path.join(root, 'frontend/app/gaia/g.stories.tsx');
    const {exit, json} = execute(
      root,
      {updateMerge: true},
      {
        duringAny: (command, args) => {
          if (args.includes('--fix') && command === 'pnpm')
            writeFileSync(target, 'tampered\n');
        },
      }
    );

    expect(exit).toBe(1);
    expect(json?.unexpectedChanges).toEqual([
      'frontend/app/gaia/g.stories.tsx',
    ]);
    expect(read(root, 'frontend/app/gaia/g.stories.tsx')).toBe(CSF4_STORY);
    expect(json?.restore).not.toContain('gaia/g.stories');
  });
});
