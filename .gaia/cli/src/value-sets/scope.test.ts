import {afterEach, describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {collectScope} from './scope.js';

const roots: string[] = [];

const git = (root: string, ...args: string[]): void => {
  execFileSync(
    'git',
    [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ],
    {cwd: root, stdio: 'ignore'}
  );
};

const makeTree = (files: Record<string, string>): string => {
  const root = mkdtempSync(path.join(tmpdir(), 'value-sets-scope-'));

  roots.push(root);
  git(root, 'init', '-q');

  for (const [relative, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, relative)), {recursive: true});
    writeFileSync(path.join(root, relative), text);
  }

  return root;
};

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

describe('collectScope', () => {
  test('scope is every tracked, staged or untracked regular file read from the working tree, by extension or shebang', () => {
    const root = makeTree({
      '.gitignore': 'ignored.sh\n',
      'a/cjs.cts': 'export {};\n',
      'a/esm.mts': 'export {};\n',
      'a/readme.md': '# not code\n',
      'a/tracked.ts': 'export const tracked = 1;\n',
      'a/view.tsx': 'export const view = 1;\n',
      'a/zsh-script.zsh': 'echo zsh\n',
      'bin/bash-shebang': '#!/bin/bash\necho one\n',
      'bin/env-shebang': '#!/usr/bin/env bash\necho two\n',
      'bin/env-split-shebang': '#!/usr/bin/env -S bash -e\necho three\n',
      'bin/no-shebang': 'echo five\n',
      'bin/zsh-shebang': '#!/bin/zsh\necho four\n',
      'scripts/link-target.sh': 'echo target\n',
      'scripts/modified.sh': 'echo committed\n',
      'scripts/pipe.sh': 'echo pipe\n',
      'scripts/removed.sh': 'echo removed\n',
      'scripts/run.bash': 'echo bash\n',
      'scripts/run.bats': 'echo bats\n',
    });

    git(root, 'add', '-A');
    git(root, 'commit', '-q', '-m', 'initial');

    writeFileSync(
      path.join(root, 'scripts/modified.sh'),
      'echo working tree\n'
    );
    unlinkSync(path.join(root, 'scripts/removed.sh'));
    unlinkSync(path.join(root, 'scripts/pipe.sh'));
    execFileSync('mkfifo', [path.join(root, 'scripts/pipe.sh')]);
    symlinkSync('link-target.sh', path.join(root, 'scripts/link.sh'));
    writeFileSync(path.join(root, 'staged.sh'), 'echo staged\n');
    git(root, 'add', 'staged.sh');
    writeFileSync(path.join(root, 'untracked.ts'), 'export const u = 1;\n');
    writeFileSync(path.join(root, 'ignored.sh'), 'echo ignored\n');
    mkdirSync(path.join(root, 'scripts/directory.sh'));

    const scope = collectScope({exclude: [], root});

    const files = 'files' in scope ? scope.files : [];

    expect(scope.ok).toBe(true);
    expect(files.map((file) => `${file.language} ${file.path}`)).toEqual([
      'typescript a/cjs.cts',
      'typescript a/esm.mts',
      'typescript a/tracked.ts',
      'typescript a/view.tsx',
      'shell bin/bash-shebang',
      'shell bin/env-shebang',
      'shell bin/env-split-shebang',
      'shell scripts/link-target.sh',
      'shell scripts/modified.sh',
      'shell scripts/run.bash',
      'shell scripts/run.bats',
      'shell staged.sh',
      'typescript untracked.ts',
    ]);
    expect(
      files.find((file) => file.path === 'scripts/modified.sh')?.text
    ).toBe('echo working tree\n');
  });
});
