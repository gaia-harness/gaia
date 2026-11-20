/**
 * The CLI (`run`) tests live in `manifest-cli.test.ts`.
 */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  NON_ASCII_STEM,
  QUOTEPATH_PIN_ARGS,
} from '../util/non-ascii-path-fixture.js';
import {
  ADOPTER_OWNED_SENTINELS,
  buildManifest,
  classifyPath,
  computeDrift,
  ManifestSchema,
  parseExcludePatterns,
  serialize,
  validateExcludeText,
} from './manifest.js';
import type {ManifestShape} from './manifest.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-manifest-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', QUOTEPATH_PIN_ARGS, {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});

  const commit = (message: string, files: Record<string, string>): string => {
    for (const [relativePath, contents] of Object.entries(files)) {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    }
    execFileSync('git', ['add', '-A'], {cwd: root});
    execFileSync('git', ['commit', '-q', '-m', message], {cwd: root});

    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim();
  };

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commit,
    root,
  };
};

describe('classifyPath', () => {
  test('wiki/hot.md is not an adopter-owned sentinel', () => {
    expect(ADOPTER_OWNED_SENTINELS.has('wiki/hot.md')).toBe(false);
    expect(ADOPTER_OWNED_SENTINELS.has('wiki/log.md')).toBe(true);
  });

  test.each<{cases: [string, ReturnType<typeof classifyPath>][]; name: string}>(
    [
      {
        cases: [['.gaia/VERSION-dev', null]],
        name: 'treats the local build record as adopter-owned',
      },
      {
        cases: [
          ['wiki/log.md', null],
          ['.gaia/VERSION', null],
          ['.gaia/manifest.json', null],
          ['.gaia/packages.json', null],
          ['.gaia/finding-classes.json', null],
        ],
        name: 'adopter sentinels return null',
      },
      {
        // The root settings file has no package prefix and stays shared. The
        // overlay is the hand-edited input, so it is shared, not generated.
        cases: [
          ['apps/web/.claude/settings.json', null],
          ['.claude/settings.json', 'shared'],
          ['apps/web/.claude/settings.overlay.json', 'shared'],
        ],
        name: 'a registered package settings file is generated and has no class',
      },
      {
        cases: [
          ['apps/web/package.json', 'shared'],
          ['apps/web/gaia.package.json', 'shared'],
          ['apps/web/CLAUDE.md', 'shared'],
          ['apps/web/app/root.tsx', 'owned'],
        ],
        name: 'frontend package descriptor, manifest, and CLAUDE.md are shared',
      },
      {
        cases: [
          ['apps/web/app/styles/theme.css', 'shared'],
          ['apps/web/components.json', 'shared'],
          ['apps/web/app/styles/tailwind.css', 'owned'],
          ['apps/web/app/components/ui/button.tsx', 'owned'],
          ['apps/web/app/components/ui/tests/button.test.tsx', 'owned'],
        ],
        name: 'frontend token values and shadcn config are shared; vendored ui stays owned',
      },
      {
        cases: [
          ['.claude/settings.json', 'shared'],
          ['package.json', 'shared'],
          ['pnpm-workspace.yaml', 'shared'],
          ['CLAUDE.md', 'shared'],
          ['wiki/index.md', 'shared'],
          ['.github/workflows/release.yml', 'shared'],
          ['.github/FUNDING.yml', 'shared'],
        ],
        name: 'shared exact and prefix matches',
      },
      {
        cases: [['.claude/rules/typescript.md', 'shared']],
        name: 'the TypeScript rule is shared, since a newly owned path would overwrite an adopter rule already there',
      },
      {
        cases: [
          ['wiki/concepts/Foo.md', 'wiki-owned'],
          ['wiki/decisions/Bar.md', 'wiki-owned'],
          ['wiki/modules/Baz.md', 'wiki-owned'],
          ['wiki/flows/Qux.md', 'wiki-owned'],
          ['wiki/dependencies/Quux.md', 'wiki-owned'],
          ['wiki/components/Component.md', 'wiki-owned'],
          ['wiki/sources/Source.md', 'wiki-owned'],
          ['wiki/overview.md', 'wiki-owned'],
          ['wiki/README.md', 'wiki-owned'],
        ],
        name: 'wiki-owned exact and prefix matches',
      },
      {
        // Root governance files reach the classifier as 'owned' but are
        // filtered out earlier in `buildManifest` by `.gaia/release-exclude`
        // category 11 (maintainer-only project governance).
        cases: [
          ['app/components/Foo/index.tsx', 'owned'],
          ['.claude/skills/tdd/SKILL.md', 'owned'],
          ['tsconfig.json', 'owned'],
          ['CHANGELOG.md', 'owned'],
          ['README.md', 'owned'],
          ['LICENSE', 'owned'],
        ],
        name: 'default fallback is owned',
      },
    ]
  )('$name', ({cases}) => {
    for (const [filePath, expected] of cases) {
      expect(classifyPath(filePath)).toBe(expected);
    }
  });
});

describe('parseExcludePatterns', () => {
  test.each<{
    count: number;
    matches: [number, string, boolean][];
    name: string;
    text: string;
  }>([
    {
      count: 2,
      matches: [
        [0, '.gaia/scripts/foo.mjs', true],
        [1, 'wiki/entities/Foo.md', true],
      ],
      name: 'strips comments and blank lines',
      text: '# comment\n\n.gaia/scripts\n\n# another\nwiki/entities\n',
    },
  ])('$name', ({count, matches, text}) => {
    const patterns = parseExcludePatterns(text);

    expect(patterns).toHaveLength(count);

    for (const [index, candidate, expected] of matches) {
      expect(patterns[index]?.test(candidate)).toBe(expected);
    }
  });

  test.each<{
    matches: [number, string, boolean][];
    name: string;
    text: string;
  }>([
    {
      matches: [
        [0, '.claude/commands/gaia-release.md', true],
        [0, '.claude/commands/other.md', false],
      ],
      name: 'matches the literal path and its directory-prefix form, not a glob',
      text: '.claude/commands/gaia-release.md\n',
    },
    {
      matches: [
        [0, 'foo*bar', true],
        [0, 'fooXbar', false],
      ],
      name: 'treats a literal * as a literal character, never a glob wildcard',
      text: 'foo*bar\n',
    },
  ])('$name', ({matches, text}) => {
    const patterns = parseExcludePatterns(text);

    expect(patterns.length).toBeGreaterThan(0);

    for (const [index, candidate, expected] of matches) {
      expect(patterns[index]?.test(candidate)).toBe(expected);
    }
  });
});

describe('validateExcludeText', () => {
  test.each<{name: string; text: string}>([
    {
      name: 'rejects a line containing a glob metacharacter',
      text: 'wiki/meta*\n',
    },
    {
      name: 'rejects a line containing a regex character-class bracket',
      text: 'docs/notes[1]\n',
    },
    {name: 'rejects an indented line', text: '  wiki/meta\n'},
  ])('$name', ({text}) => {
    expect(() => validateExcludeText(text)).toThrow(/literal/);
  });

  test.each<{name: string; text: string}>([
    {
      name: 'accepts an all-literal, unindented exclude body',
      text: '# comment\n\n.gaia/scripts\nwiki/entities\n',
    },
    {
      name: 'tolerates CRLF line endings on otherwise-valid literal paths',
      text: '.gaia/cli/src\r\nwiki/entities\r\n',
    },
    {
      name: 'ignores metacharacters inside a comment line',
      text: '# foo* [bar]\nwiki/entities\n',
    },
  ])('$name', ({text}) => {
    expect(() => validateExcludeText(text)).not.toThrow();
  });
});

describe('buildManifest', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('refuses a source tree that tracks the local build record', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.2.3\n',
      '.gaia/VERSION-dev': 'dev.0123456789ab\n',
    });

    expect(() => buildManifest(sandbox.root)).toThrow(/\.gaia\/VERSION-dev/);
  });

  test('builds cleanly when the local build record is not tracked', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.2.3\n',
    });

    expect(() => buildManifest(sandbox.root)).not.toThrow();
  });

  test('produces sorted file map with correct classes', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.2.3\n',
      'app/components/Foo/index.tsx': 'export {};\n',
      'CLAUDE.md': '# CLAUDE\n',
      'wiki/concepts/Bar.md': '# Bar\n',
      'wiki/log.md': '# log\n',
    });

    const manifest = buildManifest(sandbox.root, {
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(manifest.version).toBe('1.2.3');
    expect(manifest.generated).toBe('2026-05-07T00:00:00.000Z');

    const keys = Object.keys(manifest.files);
    // Sort matches buildManifest's localeCompare order.
    expect(keys).toEqual(keys.toSorted((a, b) => a.localeCompare(b)));

    expect(manifest.files['CLAUDE.md']).toBe('shared');
    expect(manifest.files['app/components/Foo/index.tsx']).toBe('owned');
    expect(manifest.files['wiki/concepts/Bar.md']).toBe('wiki-owned');
    expect(manifest.files['wiki/log.md']).toBeUndefined();
    expect(manifest.files['.gaia/VERSION']).toBeUndefined();
    expect(manifest.files['.gaia/manifest.json']).toBeUndefined();
  });

  test('respects release-exclude patterns', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '.gaia/scripts\n',
      '.gaia/scripts/keep-me.mjs': 'console.log("hi");\n',
      '.gaia/VERSION': '0.1.0\n',
      'app/keep.ts': 'export {};\n',
    });

    const manifest = buildManifest(sandbox.root, {
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(manifest.files['.gaia/scripts/keep-me.mjs']).toBeUndefined();
    expect(manifest.files['app/keep.ts']).toBe('owned');
  });

  // Both rows also assert that no key carries a C-quoted backslash: the quoted
  // spelling names no file on disk, so reading it would ship a path the
  // tarball never carries.
  test.each<{
    absent: string[];
    files: Record<string, string>;
    name: string;
    owned: string[];
  }>([
    {
      absent: [`wiki/${NON_ASCII_STEM}.md`],
      files: {
        '.gaia/release-exclude': `wiki/${NON_ASCII_STEM}.md\n`,
        [`wiki/${NON_ASCII_STEM}.md`]: '# nihongo\n',
        'app/keep.ts': 'export {};\n',
      },
      name: 'excludes a non-ASCII path, which git C-quotes under its default core.quotePath',
      owned: ['app/keep.ts'],
    },
    {
      // This case pins `-z` specifically, where the non-ASCII one does not:
      // git C-quotes a control character whatever `core.quotePath` says, so
      // the quotepath setting alone would not recover the real spelling.
      absent: [],
      files: {
        '.gaia/release-exclude': '# none\n',
        'app/two\nlines.ts': 'export {};\n',
      },
      name: 'reads a path carrying a literal newline by its real name',
      owned: ['app/two\nlines.ts'],
    },
  ])('$name', ({absent, files, owned}) => {
    sandbox.commit('seed', {'.gaia/VERSION': '0.1.0\n', ...files});

    const manifest = buildManifest(sandbox.root, {
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    for (const key of absent) {
      expect(manifest.files[key]).toBeUndefined();
    }

    for (const key of owned) {
      expect(manifest.files[key]).toBe('owned');
    }
    expect(
      Object.keys(manifest.files).filter((key) => key.includes('\\'))
    ).toEqual([]);
  });

  test('rejects a glob-shaped exclude line loudly instead of silently mis-excluding', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': 'wiki/meta*\n',
      '.gaia/VERSION': '0.1.0\n',
      'app/keep.ts': 'export {};\n',
    });

    expect(() =>
      buildManifest(sandbox.root, {generatedAt: '2026-05-07T00:00:00.000Z'})
    ).toThrow(/literal/);
  });
});

describe('ManifestSchema: regions', () => {
  const baseFields = {
    files: {},
    generated: '2026-05-07T00:00:00.000Z',
    version: '1.0.0',
  };

  test.each<{input: Record<string, unknown>; name: string}>([
    {
      input: baseFields,
      name: 'accepts a manifest object with no `regions` key',
    },
    {
      input: {...baseFields, regions: []},
      name: 'accepts a manifest object with `regions: []`',
    },
  ])('$name', ({input}) => {
    expect(() => ManifestSchema.parse(input)).not.toThrow();
  });

  test('rejects a declaration with an empty startMarker', () => {
    const regions = [
      {
        endMarker: '<!-- gaia:test:end -->',
        id: 'test-region',
        paths: [],
        regenerate: {args: [], interpreter: 'bash', operand: 'test.sh'},
        startMarker: '',
      },
    ];
    expect(() => ManifestSchema.parse({...baseFields, regions})).toThrow(
      /too small/i
    );
  });
});

const manifestWithRegions = (
  regions: ManifestShape['regions']
): ManifestShape => ({
  files: {},
  generated: '2026-05-07T00:00:00.000Z',
  regions,
  version: '1.0.0',
});

const regionDrift = (
  expected: ManifestShape,
  actual: ManifestShape
): ReturnType<typeof computeDrift>['regionDrift'] =>
  computeDrift(expected, actual).regionDrift;

describe('computeDrift: regionDrift', () => {
  const region = {
    endMarker: '<!-- gaia:test:end -->',
    id: 'test-region',
    paths: ['.claude/agents/a.md', '.claude/agents/b.md'],
    regenerate: {args: [], interpreter: 'bash', operand: 'test.sh'},
    startMarker: '<!-- gaia:test:start -->',
  };

  const onlyA = ['.claude/agents/a.md'];

  test.each<{
    actual: ManifestShape['regions'];
    expected: ManifestShape['regions'];
    name: string;
    result: unknown[];
  }>([
    {
      actual: [{...region, paths: onlyA}],
      expected: [region],
      name: 'a committed manifest missing one region path reports it as missing for that region id',
      result: [
        {extra: [], missing: ['.claude/agents/b.md'], regionId: 'test-region'},
      ],
    },
    {
      actual: [region],
      expected: [{...region, paths: onlyA}],
      name: 'a committed manifest carrying an extra region path reports it in `extra`',
      result: [
        {extra: ['.claude/agents/b.md'], missing: [], regionId: 'test-region'},
      ],
    },
    {
      actual: [{...region, startMarker: '<!-- gaia:other:start -->'}],
      expected: [region],
      name: 'a committed manifest whose startMarker differs reports contractDrift',
      result: [
        expect.objectContaining({
          contractDrift: expect.stringContaining('startMarker'),
        }),
      ],
    },
    {
      actual: [region],
      expected: [region],
      name: 'identical declarations report an empty regionDrift',
      result: [],
    },
    {
      actual: undefined,
      expected: [region],
      name: 'a committed manifest with no `regions` key against an expected manifest that has one reports the id-only-in-expected case',
      result: [{extra: [], missing: region.paths, regionId: 'test-region'}],
    },
  ])('$name', ({actual, expected, result}) => {
    expect(
      regionDrift(manifestWithRegions(expected), manifestWithRegions(actual))
    ).toEqual(result);
  });
});

describe('buildManifest: region round trip', () => {
  // Uses the real REGION_REGISTRY (the `audit-remit` entry), against a
  // sandbox that carries both a roster and an agent definition whose region
  // it declares, so this exercises the same code path production `buildManifest`
  // runs, not a fabricated registry.
  test('ManifestSchema.parse(buildManifest(...)) succeeds on a scan that produces a non-empty regions array, and serialize is deterministic with regions between generated and version', () => {
    const sandbox = setupSandbox();

    try {
      sandbox.commit('seed', {
        '.claude/agents/test-auditor.md': [
          '# Test Auditor',
          '',
          '## Remit and self-skip',
          '',
          '<!-- gaia:audit-remit:start -->',
          '- `app/**`',
          '',
          'Filter the changed-file list against the globs above.',
          '<!-- gaia:audit-remit:end -->',
          '',
        ].join('\n'),
        '.gaia/audit-ci.yml': [
          'auditors:',
          '  - name: test-auditor',
          '    globs:',
          '      - "app/**"',
          '    audience: adopter',
          '    default: true',
          '',
        ].join('\n'),
        '.gaia/release-exclude': '# none\n',
        '.gaia/VERSION': '1.0.0\n',
        'app/foo.ts': 'export {};\n',
      });

      const manifest = buildManifest(sandbox.root, {
        generatedAt: '2026-05-07T00:00:00.000Z',
      });

      expect(manifest.regions).toEqual([
        {
          endMarker: '<!-- gaia:audit-remit:end -->',
          id: 'audit-remit',
          paths: ['.claude/agents/test-auditor.md'],
          regenerate: {
            args: [],
            interpreter: 'bash',
            operand: '.gaia/scripts/write-audit-remits.sh',
          },
          startMarker: '<!-- gaia:audit-remit:start -->',
        },
      ]);
      expect(() => ManifestSchema.parse(manifest)).not.toThrow();

      const once = serialize(manifest);
      const twice = serialize(
        buildManifest(sandbox.root, {generatedAt: '2026-05-07T00:00:00.000Z'})
      );
      expect(once).toBe(twice);

      const keys = Object.keys(JSON.parse(once) as Record<string, unknown>);
      expect(keys.indexOf('generated')).toBeLessThan(keys.indexOf('regions'));
      expect(keys.indexOf('regions')).toBeLessThan(keys.indexOf('version'));
    } finally {
      sandbox.cleanup();
    }
  });
});

// Seeds a sandbox with a small slice of the real repo layout, picking paths
// that exercise every classifier branch, then builds the manifest against it.
const seedManifestSandbox = (): {
  manifest: ReturnType<typeof buildManifest>;
  sandbox: Sandbox;
} => {
  const sandbox = setupSandbox();

  sandbox.commit('seed', {
    '.claude/commands/gaia-init.md': '# init\n',
    '.claude/commands/gaia-release.md': '# release-only\n', // excluded
    '.claude/settings.json': '{}\n',
    '.claude/skills/tdd/SKILL.md': '# tdd\n',
    '.gaia/release-exclude': [
      '# comment',
      '.claude/commands/gaia-release.md',
      '.gaia/scripts',
      '.gaia/release-exclude',
      '.github/CODEOWNERS',
      'CHANGELOG.md',
      'README.md',
      'wiki/entities',
      'wiki/meta',
      '',
    ].join('\n'),
    '.gaia/scripts/legacy.mjs': '// excluded\n', // excluded
    '.gaia/VERSION': '1.0.5\n',
    '.github/CODEOWNERS': '* @maintainer\n',
    '.github/workflows/release.yml': 'name: release\n',
    'app/components/Foo/index.tsx': 'export {};\n',
    'CHANGELOG.md': '# changelog\n', // excluded (root governance, category 11)
    'CLAUDE.md': '# CLAUDE\n',
    'package.json': '{"name":"x"}\n',
    'README.md': '# README\n', // excluded (root governance, category 11)
    'wiki/concepts/Foo.md': '# foo\n',
    'wiki/decisions/Bar.md': '# bar\n',
    'wiki/entities/Skip.md': '# excluded\n', // excluded
    'wiki/index.md': '# index\n',
    'wiki/log.md': '# log\n', // sentinel
    'wiki/overview.md': '# overview\n',
  });

  const manifest = buildManifest(sandbox.root, {
    generatedAt: '2026-05-07T00:00:00.000Z',
  });

  return {manifest, sandbox};
};

describe('classifier category assignment', () => {
  // Regression guard on the classifier's category assignments, independent
  // of whether the legacy script is still around to compare against.
  test('classifies every category correctly', () => {
    const {manifest, sandbox} = seedManifestSandbox();

    try {
      expect(manifest.files['CLAUDE.md']).toBe('shared');
      expect(manifest.files['.claude/commands/gaia-init.md']).toBe('owned');
      expect(
        manifest.files['.claude/commands/gaia-release.md']
      ).toBeUndefined();
      expect(manifest.files['.gaia/scripts/legacy.mjs']).toBeUndefined();
      expect(manifest.files['CHANGELOG.md']).toBeUndefined();
      expect(manifest.files['wiki/log.md']).toBeUndefined();
      expect(manifest.files['wiki/entities/Skip.md']).toBeUndefined();
      expect(manifest.files['wiki/concepts/Foo.md']).toBe('wiki-owned');
      expect(manifest.files['wiki/overview.md']).toBe('wiki-owned');
      expect(manifest.files['wiki/index.md']).toBe('shared');
      expect(manifest.files['.github/workflows/release.yml']).toBe('shared');
      expect(manifest.files['.github/CODEOWNERS']).toBeUndefined();
    } finally {
      sandbox.cleanup();
    }
  });
});
