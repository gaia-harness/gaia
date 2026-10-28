import {afterEach, describe, expect, test} from 'vitest';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {makeHarness} from './run-fixture.js';
import {cleanupRepos, execute, repo, standardFiles} from './run-helpers.js';
import {runMigrateCsf4} from './run.js';

afterEach(cleanupRepos);

describe('verification', () => {
  test('a file missing from the report fails the run even though every other test passes', () => {
    const root = repo(standardFiles);
    const {exit, json} = execute(
      root,
      {},
      {missingFromReport: ['app/b/b.stories.tsx']}
    );

    expect(exit).toBe(1);
    expect(
      json?.files.find((file) => file.path === 'frontend/app/b/b.stories.tsx')
    ).toMatchObject({loaded: false, passed: false});
    expect(
      json?.files.find((file) => file.path === 'frontend/app/a/a.stories.tsx')
    ).toMatchObject({loaded: true, passed: true});
  });

  test('a failing test names its file and fullName', () => {
    const root = repo(standardFiles);
    const {exit, json} = execute(
      root,
      {},
      {failingTests: {'app/a/a.stories.tsx': ['Primary   checks it']}}
    );

    expect(exit).toBe(1);
    expect(
      json?.files.find((file) => file.path === 'frontend/app/a/a.stories.tsx')
        ?.failures
    ).toEqual(['Primary   checks it']);
  });

  test('a typecheck error names its file', () => {
    const root = repo(standardFiles);
    const {exit, json} = execute(
      root,
      {},
      {
        typecheckOutput:
          "app/a/a.stories.tsx(3,1): error TS2304: Cannot find name 'x'.\n",
      }
    );

    expect(exit).toBe(1);
    expect(json?.typecheck).toEqual({
      files: ['frontend/app/a/a.stories.tsx'],
      result: 'fail',
    });
  });

  test('a lint error names its file', () => {
    const root = repo(standardFiles);
    const filePath = path.join(root, 'frontend/app/b/b.stories.tsx');
    const {exit, json} = execute(
      root,
      {},
      {
        eslintJson: JSON.stringify([
          {errorCount: 1, filePath},
          {errorCount: 0, filePath: 'ok'},
        ]),
      }
    );

    expect(exit).toBe(1);
    expect(json?.lint).toEqual({
      files: ['frontend/app/b/b.stories.tsx'],
      result: 'fail',
    });
  });

  test('a story file whose factory-built stories were inlined loads and passes', () => {
    const inlined = `import preview from '#.storybook/preview';
const meta = preview.meta({});
export const ErrorType = meta.story({args: {type: 'error'}});
ErrorType.test('shows the error', async () => {});
`;
    const root = repo({
      ...standardFiles,
      'frontend/app/t/toast.stories.tsx': inlined,
    });
    const {exit, json} = execute(root);

    expect(exit).toBe(0);
    expect(
      json?.files.find(
        (file) => file.path === 'frontend/app/t/toast.stories.tsx'
      )
    ).toMatchObject({loaded: true, passed: true});
    expect(json?.converted).not.toContain('frontend/app/t/toast.stories.tsx');
  });

  test('human output ends with the restore command', () => {
    const root = repo(standardFiles);
    const harness = makeHarness(root);
    const exit = runMigrateCsf4(
      {json: false, updateMerge: false},
      harness.deps
    );
    const lines = harness.out.join('').trim().split('\n');

    expect(exit).toBe(EXIT_CODES.OK);
    expect(lines.at(-1)).toMatch(/^git restore --source=HEAD/u);
  });
});
