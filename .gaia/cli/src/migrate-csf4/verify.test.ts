import typescript from 'typescript';
import {afterEach, describe, expect, test} from 'vitest';
import {rmSync} from 'node:fs';
import {inventoryStoryFiles} from './inventory.js';
import {makeRepo} from './run-fixture.js';
import {exactFilesGlob} from './tools.js';
import {judgeStoryFile, parseEslintFiles, parseTscFiles} from './verify.js';

const context = {packageDir: '/r/frontend', repoRoot: '/r'};
const roots: string[] = [];

afterEach(() => {
  roots
    .splice(0)
    .forEach((root) => rmSync(root, {force: true, recursive: true}));
});

describe('judgeStoryFile', () => {
  test('absent from the report is not loaded', () => {
    expect(judgeStoryFile('a', undefined)).toMatchObject({
      loaded: false,
      passed: false,
    });
  });

  test('failed with no assertions is not loaded', () => {
    expect(
      judgeStoryFile('a', {assertionResults: [], status: 'failed'})
    ).toMatchObject({loaded: false});
  });

  test('zero tests is not loaded', () => {
    expect(
      judgeStoryFile('a', {assertionResults: [], status: 'passed'})
    ).toMatchObject({loaded: false, tests: 0});
  });

  test('a failed assertion is loaded, not passed, and named', () => {
    expect(
      judgeStoryFile('a', {
        assertionResults: [
          {fullName: 'ok', status: 'passed'},
          {fullName: 'S   t', status: 'failed'},
        ],
        status: 'failed',
      })
    ).toEqual({
      failures: ['S   t'],
      loaded: true,
      passed: false,
      path: 'a',
      tests: 2,
    });
  });
});

describe('parsers', () => {
  test('tsc plain and pretty lines become repo-relative files', () => {
    expect(
      parseTscFiles(
        'app/a.tsx(1,2): error TS1: x\napp/b.tsx:3:4 - error TS2: y\nnoise',
        context
      )
    ).toEqual(['frontend/app/a.tsx', 'frontend/app/b.tsx']);
  });

  test('eslint json keeps only files with errors; garbage is undefined', () => {
    expect(
      parseEslintFiles(
        JSON.stringify([
          {errorCount: 0, filePath: '/r/frontend/a.ts'},
          {errorCount: 2, filePath: '/r/frontend/b.ts'},
        ]),
        context
      )
    ).toEqual(['frontend/b.ts']);
    expect(parseEslintFiles('not json', context)).toBeUndefined();
  });
});

describe('exactFilesGlob', () => {
  test('one file is a plain path, several are a brace group, specials are escaped', () => {
    expect(exactFilesGlob(['a/b.stories.tsx'])).toBe('a/b.stories.tsx');
    expect(exactFilesGlob(['a.tsx', 'b.tsx'])).toBe('{a.tsx,b.tsx}');
    expect(exactFilesGlob(['a/(x).tsx'])).toBe(String.raw`a/\(x\).tsx`);
  });
});

const inventory = (
  files: Record<string, string>
): ReturnType<typeof inventoryStoryFiles> => {
  const root = makeRepo(files);

  roots.push(root);

  return inventoryStoryFiles(typescript, `${root}/frontend`);
};

describe('inventoryStoryFiles', () => {
  test('reads literal globs relative to the config directory and skips docs pages', () => {
    const result = inventory({
      'frontend/.storybook/main.ts':
        "export default {stories: ['../app/**/*.mdx', '../app/**/*.stories.@(ts|tsx)']};\n",
      'frontend/app/a.stories.tsx': 'x',
      'frontend/app/docs.mdx': 'x',
      'frontend/other/b.stories.tsx': 'x',
    });

    expect(result.storyFiles).toEqual(['app/a.stories.tsx']);
    expect(result.fallbackReason).toBeUndefined();
  });

  test('non-literal globs fall back to the default app glob and say why', () => {
    const result = inventory({
      'frontend/.storybook/main.ts':
        "const g = '../x'; export default {stories: [g]};\n",
      'frontend/app/a.stories.tsx': 'x',
      'frontend/other/b.stories.tsx': 'x',
    });

    expect(result.storyFiles).toEqual(['app/a.stories.tsx']);
    expect(result.fallbackReason).toContain('not all string literals');
  });
});
