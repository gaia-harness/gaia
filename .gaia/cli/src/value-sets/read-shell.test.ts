import {afterEach, describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {loadTypescript} from '../util/load-typescript.js';
import {runValueSets} from './index.js';

const CLI_TYPESCRIPT = realpathSync(
  path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    '../../node_modules/typescript'
  )
);

const temporaryRoots: string[] = [];

const buildTree = (files: Record<string, string>): string => {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'value-sets-')));

  temporaryRoots.push(root);
  execFileSync('git', ['init', '--quiet'], {cwd: root});

  for (const [relativePath, text] of Object.entries(files)) {
    const target = path.join(root, relativePath);

    mkdirSync(path.dirname(target), {recursive: true});
    writeFileSync(target, text);
  }

  mkdirSync(path.join(root, 'node_modules'), {recursive: true});
  symlinkSync(CLI_TYPESCRIPT, path.join(root, 'node_modules', 'typescript'));

  return root;
};

const execute = (files: Record<string, string>) => {
  let stdout = '';
  const code = runValueSets([], {
    cwd: buildTree(files),
    loadTypescript,
    writeErr: () => {},
    writeOut: (text) => {
      stdout += text;
    },
  });

  return {code, stdout};
};

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

describe('shell reader through runValueSets', () => {
  test('shell arrays and mixed arms compare case-sensitively with quotes stripped, and associative arrays, heredoc bodies and quoted strings are never read', () => {
    const quoted = execute({
      'a.sh': `grades=('A+' "A" A-)\n`,
      'b.sh': 'grades=(A+ A A-)\n',
    });

    expect(quoted.code).toBe(1);
    expect(quoted.stdout).toContain('A, A+, A-');
    expect(quoted.stdout).toContain('a.sh:1');
    expect(quoted.stdout).toContain('b.sh:1');

    expect(
      execute({
        'a.sh': 'kinds=(Spec Plan Research)\n',
        'b.sh': 'kinds=(spec plan research)\n',
      }).code
    ).toBe(0);

    expect(
      execute({
        'a.sh': 'declare -A map=([a]=1 [b]=2 [c]=3)\n',
        'b.sh': 'declare -A map=([a]=1 [b]=2 [c]=3)\n',
      }).code
    ).toBe(0);

    const local = execute({
      'a.sh': 'f() {\n  local -a kinds=(spec plan research)\n}\n',
      'b.sh': 'kinds=(spec plan research)\n',
    });

    expect(local.code).toBe(1);
    expect(local.stdout).toContain('a.sh:2');
    expect(local.stdout).toContain('b.sh:1');

    expect(
      execute({
        'lib.sh': 'kinds=(spec plan research)\n',
        'make.bats': [
          'cat > script.sh <<EOF',
          '# sanctioned copy of lib.sh#kinds',
          'kinds=(spec plan research)',
          'EOF',
          '',
        ].join('\n'),
      }).code
    ).toBe(0);

    expect(
      execute({
        'lib.sh': 'kinds=(spec plan research)\n',
        'say.sh': 'echo "case x in spec|plan|research) ;;"\n',
      }).code
    ).toBe(0);

    const mixed = execute({
      'a.sh': 'case $1 in\n  -v|--verbose|verbose) ;;\nesac\n',
      'b.sh': 'case $1 in\n  -v|--verbose|verbose) ;;\nesac\n',
    });

    expect(mixed.code).toBe(1);
    expect(mixed.stdout).toContain('--verbose, -v, verbose');
  });

  test('a heredoc apostrophe inside a command substitution and a left shift in a bare arithmetic command do not hide a later array', () => {
    expect(
      execute({
        'a.sh': [
          'text=$(cat <<EOF',
          "it's a heredoc with an apostrophe",
          'EOF',
          ')',
          'kinds=(spec plan research)',
          '',
        ].join('\n'),
        'b.sh': 'kinds=(spec plan research)\n',
      }).code
    ).toBe(1);

    expect(
      execute({
        'a.sh': '((flags = 1 << 3))\nkinds=(spec plan research)\n',
        'b.sh': 'kinds=(spec plan research)\n',
      }).code
    ).toBe(1);
  });
});
