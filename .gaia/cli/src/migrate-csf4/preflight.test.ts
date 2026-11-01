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

  test('a renamed path with different content stays dirty', () => {
    const root = repo();

    moveDirectory(root);
    write(root, 'new/a.stories.tsx', 'export const a = 3;\n');
    git(root, ['add', '-A']);

    expect(dirtyWriteSetPaths(root, writeSet)).toEqual(['new/a.stories.tsx']);
  });

  test('a renamed config path with merged content stays dirty', () => {
    const root = repo();

    moveDirectory(root);
    write(
      root,
      'new/.storybook/main.ts',
      'export default {stories: [], x: 2};\n'
    );

    expect(dirtyWriteSetPaths(root, writeSet)).toEqual([
      'new/.storybook/main.ts',
    ]);
  });

  test('an untracked path is still dirty', () => {
    const root = repo();

    moveDirectory(root);
    write(root, 'new/b.stories.tsx', 'export const b = 1;\n');

    expect(
      dirtyWriteSetPaths(root, [...writeSet, 'new/b.stories.tsx'])
    ).toEqual(['new/b.stories.tsx']);
  });
});
