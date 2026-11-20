import {afterEach, describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {dirtyWriteSetPaths} from './preflight.js';

const roots: string[] = [];

const git = (root: string, args: string[]): void => {
  execFileSync('git', args, {cwd: root, stdio: 'ignore'});
};

const write = (root: string, file: string, content: string): void => {
  mkdirSync(path.dirname(path.join(root, file)), {recursive: true});
  writeFileSync(path.join(root, file), content);
};

const repo = (): string => {
  const root = realpathSync(
    mkdtempSync(path.join(tmpdir(), 'gaia-csf4-preflight-'))
  );

  roots.push(root);
  git(root, ['init', '-q']);
  git(root, ['config', 'user.email', 'test@example.com']);
  git(root, ['config', 'user.name', 'Test']);
  git(root, ['config', 'commit.gpgsign', 'false']);
  write(
    root,
    'old/a.stories.tsx',
    'export const a = 1;\nexport const b = 2;\n'
  );
  write(
    root,
    'old/.storybook/main.ts',
    'export default {stories: [], x: 1};\n'
  );
  git(root, ['add', '-A']);
  git(root, ['commit', '-q', '-m', 'seed']);

  return root;
};

const moveDirectory = (root: string): void => {
  mkdirSync(path.join(root, 'new'));
  git(root, ['mv', 'old/a.stories.tsx', 'new/a.stories.tsx']);
  git(root, ['mv', 'old/.storybook', 'new/.storybook']);
};

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

describe('dirtyWriteSetPaths with staged renames', () => {
  const writeSet = ['new/a.stories.tsx', 'new/.storybook/main.ts'];

  test('a pure staged rename reads as clean', () => {
    const root = repo();

    moveDirectory(root);

    expect(dirtyWriteSetPaths(root, writeSet)).toEqual([]);
  });

  test.each([
    {
      expected: ['new/a.stories.tsx'],
      name: 'a renamed path with different content stays dirty',
      paths: writeSet,
      setup: (root: string): void => {
        write(root, 'new/a.stories.tsx', 'export const a = 3;\n');
        git(root, ['add', '-A']);
      },
    },
    {
      expected: ['new/.storybook/main.ts'],
      name: 'a renamed config path with merged content stays dirty',
      paths: writeSet,
      setup: (root: string): void => {
        write(
          root,
          'new/.storybook/main.ts',
          'export default {stories: [], x: 2};\n'
        );
      },
    },
    {
      expected: ['new/b.stories.tsx'],
      name: 'an untracked path is still dirty',
      paths: [...writeSet, 'new/b.stories.tsx'],
      setup: (root: string): void => {
        write(root, 'new/b.stories.tsx', 'export const b = 1;\n');
      },
    },
  ])('$name', ({expected, paths, setup}) => {
    const root = repo();

    moveDirectory(root);
    setup(root);

    expect(dirtyWriteSetPaths(root, paths)).toEqual(expected);
  });
});
