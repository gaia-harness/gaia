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
const MAINTAINER_MARKER =
  '.claude/rules/maintainers/harness-triage-threshold.md';

const temporaryRoots: string[] = [];

type Tree = Record<string, string>;

const buildTree = (files: Tree, options: {linkTypescript?: boolean} = {}) => {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'value-sets-')));

  temporaryRoots.push(root);
  execFileSync('git', ['init', '--quiet'], {cwd: root});

  for (const [relativePath, text] of Object.entries(files)) {
    const target = path.join(root, relativePath);

    mkdirSync(path.dirname(target), {recursive: true});
    writeFileSync(target, text);
  }

  if (options.linkTypescript !== false) {
    mkdirSync(path.join(root, 'node_modules'), {recursive: true});
    symlinkSync(CLI_TYPESCRIPT, path.join(root, 'node_modules', 'typescript'));
  }

  return root;
};

const execute = (root: string, argv: string[] = []) => {
  let stdout = '';
  let stderr = '';
  const code = runValueSets(argv, {
    cwd: root,
    loadTypescript,
    writeErr: (text) => {
      stderr += text;
    },
    writeOut: (text) => {
      stdout += text;
    },
  });

  return {code, stderr, stdout};
};

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

describe('runValueSets', () => {
  test('three shared values fail under any names, in one file or across TypeScript and shell, and a clean tree prints the clean line', () => {
    const root = buildTree({
      'apps/web/app/status.ts': `
export type Status = 'draft' | 'ready' | 'merged';
`,
      'scripts/sync.sh': `#!/usr/bin/env bash
statuses=(draft ready merged)
`,
    });
    const across = execute(root);

    expect(across.code).toBe(1);
    expect(across.stdout).toContain('apps/web/app/status.ts');
    expect(across.stdout).toContain('scripts/sync.sh');
    expect(across.stdout).toContain('draft, merged, ready');

    const sameFile = execute(
      buildTree({
        'a.ts': `
export const A = ['x', 'y', 'z'] as const;
export const B = ['z', 'y', 'x'] as const;
`,
      })
    );

    expect(sameFile.code).toBe(1);
    expect(sameFile.stdout).toContain('A (a.ts:2)');
    expect(sameFile.stdout).toContain('B (a.ts:3)');

    const clean = execute(
      buildTree({
        'apps/web/app/status.ts': `
export type Status = 'draft' | 'ready' | 'merged';
`,
      })
    );

    expect(clean).toEqual({
      code: 0,
      stderr: '',
      stdout: 'value-sets: no duplicate value sets\n',
    });
  });

  test('two-value sets and options-only case arms never fail', () => {
    const arm = `#!/usr/bin/env bash
case "$1" in
  -h|--help) echo help ;;
  yes|y) echo yes ;;
esac
`;
    const result = execute(
      buildTree({
        'a.sh': arm,
        'b.sh': arm,
        'c.ts': `export type OnOff = 'on' | 'off';\n`,
        'd.ts': `export type Toggle = 'on' | 'off';\n`,
      })
    );

    expect(result.code).toBe(0);
    expect(result.stdout).toBe('value-sets: no duplicate value sets\n');
  });

  test("a marker off the declaration's line or the comment line above it, or in a block comment, is not read", () => {
    const source = `export const KEYS = ['alpha', 'beta', 'gamma'] as const;\n`;
    const marker = '// sanctioned copy of source.ts#KEYS';
    const placements: Record<string, string> = {
      'blank-gap.ts': `${marker}\n\nexport const COPY = ['alpha', 'beta', 'gamma'] as const;\n`,
      'doc-comment.ts': `/**\n * sanctioned copy of source.ts#KEYS\n */\nexport const COPY = ['alpha', 'beta', 'gamma'] as const;\n`,
      'one-line-block.ts': `/* sanctioned copy of source.ts#KEYS */\nexport const COPY = ['alpha', 'beta', 'gamma'] as const;\n`,
    };

    for (const [name, text] of Object.entries(placements)) {
      const result = execute(buildTree({[name]: text, 'source.ts': source}));

      expect({code: result.code, name}).toEqual({code: 1, name});
      expect(result.stdout).toContain('value-sets: duplicate');
    }

    const shellSource = '#!/usr/bin/env bash\nkinds=(spec plan research)\n';
    const onNameLine = execute(
      buildTree({
        'a.sh':
          '#!/usr/bin/env bash\nkinds=( # sanctioned copy of b.sh#kinds\n  spec\n  plan\n  research\n)\n',
        'b.sh': shellSource,
      })
    );
    const offNameLine = execute(
      buildTree({
        'a.sh':
          '#!/usr/bin/env bash\nkinds=(\n  spec\n  plan # sanctioned copy of b.sh#kinds\n  research\n)\n',
        'b.sh': shellSource,
      })
    );

    expect(onNameLine.code).toBe(0);
    expect(offNameLine.code).toBe(1);
    expect(offNameLine.stdout).toContain('value-sets: duplicate');
  });

  test('computed sets and arrays holding an expansion are not read, and a type annotation never exempts a literal set', () => {
    const wide = `export const WIDE = ['major', 'minor', 'patch', 'nonsemver'] as const;\n`;
    const computed = execute(
      buildTree({
        'a.ts': `${wide}export const narrow = WIDE.filter((value) => value !== 'nonsemver');\n`,
        'b.sh':
          '#!/usr/bin/env bash\nfiles=("$dir"/*.sh other.sh third.sh)\nmore=(other.sh third.sh "$dir"/*.sh)\n',
      })
    );

    expect(computed.code).toBe(0);

    const satisfies = execute(
      buildTree({
        'kind.ts': `export type Kind = 'major' | 'minor' | 'patch' | 'nonsemver';\n`,
        'narrow.ts': `export const narrow = ['major', 'minor', 'patch'] as const satisfies readonly string[];\n`,
      })
    );

    expect(satisfies.code).toBe(1);
    expect(satisfies.stdout).toContain('value-sets: subset');

    const annotated = execute(
      buildTree({
        'kind.ts': `export type Kind = 'major' | 'minor' | 'patch' | 'nonsemver';\n`,
        'narrow.ts': `export const narrow: readonly string[] = ['major', 'minor', 'patch'];\n`,
      })
    );

    expect(annotated.code).toBe(1);
    expect(annotated.stdout).toContain('value-sets: subset');
  });

  test('on an adopter a finding whose every site is harness goes unreported, and the maintainer repo reports it', () => {
    const hook = `#!/usr/bin/env bash
case "$tool" in
  Edit|Write|MultiEdit) echo edit ;;
esac
`;
    const manifest = JSON.stringify({
      files: {
        '.claude/hooks/one.sh': 'owned',
        '.claude/hooks/two.sh': 'owned',
      },
    });
    const harnessOnly: Tree = {
      '.claude/hooks/one.sh': hook,
      '.claude/hooks/two.sh': hook,
      '.gaia/manifest.json': manifest,
    };

    const adopter = execute(buildTree(harnessOnly));

    expect(adopter.code).toBe(0);

    const withAdopterDuplicate = execute(
      buildTree({
        ...harnessOnly,
        'scripts/a.sh': '#!/usr/bin/env bash\nstatuses=(draft ready merged)\n',
        'scripts/b.sh': '#!/usr/bin/env bash\nstatuses=(draft ready merged)\n',
      })
    );

    expect(withAdopterDuplicate.code).toBe(1);
    expect(withAdopterDuplicate.stdout).toContain('scripts/a.sh');
    expect(withAdopterDuplicate.stdout).toContain('scripts/b.sh');
    expect(withAdopterDuplicate.stdout).not.toContain('.claude/hooks');

    const maintainer = execute(
      buildTree({...harnessOnly, [MAINTAINER_MARKER]: 'marker\n'})
    );

    expect(maintainer.code).toBe(1);
    expect(maintainer.stdout).toContain('.claude/hooks/one.sh');
    expect(maintainer.stdout).toContain('.claude/hooks/two.sh');
  });

  test('a scope the check cannot read exits 2 naming the cause and prints no findings', () => {
    const duplicate: Tree = {
      'a.sh': '#!/usr/bin/env bash\nkinds=(spec plan research)\n',
      'b.sh': '#!/usr/bin/env bash\nkinds=(spec plan research)\n',
    };

    const noTypescript = execute(
      buildTree(
        {...duplicate, 'c.ts': 'export const x = 1;\n'},
        {
          linkTypescript: false,
        }
      )
    );

    expect(noTypescript).toEqual({
      code: 2,
      stderr:
        'value-sets: cannot run: the typescript package could not be loaded from this project\n',
      stdout: '',
    });

    const shellOnly = execute(buildTree(duplicate, {linkTypescript: false}));

    expect(shellOnly.code).toBe(1);

    const syntax = execute(
      buildTree({
        ...duplicate,
        'apps/web/app/x.ts':
          'const a = 1;\nconst b = 2;\nconst c = 3;\nconst = ;\n',
      })
    );

    expect(syntax.code).toBe(2);
    expect(syntax.stderr).toBe(
      'value-sets: cannot run: apps/web/app/x.ts has syntax errors at line 4\n'
    );
    expect(syntax.stdout).toBe('');

    const outside = realpathSync(mkdtempSync(path.join(tmpdir(), 'no-git-')));

    temporaryRoots.push(outside);

    const notGit = execute(outside);

    expect(notGit).toEqual({
      code: 2,
      stderr: 'value-sets: cannot run: not inside a git work tree\n',
      stdout: '',
    });

    const badArguments = execute(buildTree(duplicate), ['--bogus']);

    expect(badArguments.code).toBe(2);
    expect(badArguments.stderr).toMatch(/^value-sets: cannot run: /);
    expect(badArguments.stdout).toBe('');
  });

  test('candidates prints the weaker matches as a JSON array and exits 0', () => {
    const weaker = execute(
      buildTree({
        'a.ts': `export type OnOff = 'on' | 'off';\n`,
        'b.ts': `export type Toggle = 'on' | 'off';\n`,
        'c.sh': '#!/usr/bin/env bash\ncase "$1" in\n  -h|--help) ;;\nesac\n',
        'd.sh': '#!/usr/bin/env bash\ncase "$1" in\n  -h|--help) ;;\nesac\n',
      }),
      ['--candidates']
    );

    expect(weaker.code).toBe(0);
    expect(JSON.parse(weaker.stdout)).toEqual([
      {
        kind: 'two-value-duplicate',
        sites: [
          {line: 1, name: 'OnOff', path: 'a.ts'},
          {line: 1, name: 'Toggle', path: 'b.ts'},
        ],
        values: ['off', 'on'],
      },
    ]);

    const none = execute(buildTree({'a.ts': 'export const x = 1;\n'}), [
      '--candidates',
    ]);

    expect(none).toEqual({code: 0, stderr: '', stdout: '[]\n'});

    const noTypescript = execute(
      buildTree({'a.ts': 'export const x = 1;\n'}, {linkTypescript: false}),
      ['--candidates']
    );

    expect(noTypescript.code).toBe(2);
    expect(noTypescript.stdout).toBe('');
  });
});
