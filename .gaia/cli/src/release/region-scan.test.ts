/**
 * Fixtures are built in a temp dir with a fabricated registry entry (not the
 * real `audit-remit` markers), so these cases are hermetic and independent
 * of `.gaia/audit-ci.yml` / `region-registry.ts`, which has its own suite.
 *
 * One case deliberately uses the real `REGION_REGISTRY` instead, because what
 * it pins is a property of the shipped `audit-remit` entry rather than of the
 * scan: that the default registry is what a caller passing no override gets.
 * It still builds its fixture in the temp dir.
 */
import {describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import type {RegionRegistryEntry} from './region-registry.js';
import {scanRegionDeclarations} from './region-scan.js';

const START = '<!-- gaia:test-region:start -->';
const END = '<!-- gaia:test-region:end -->';

type Sandbox = {cleanup: () => void; root: string};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-region-scan-'));

  return {
    cleanup: () => rmSync(root, {force: true, recursive: true}),
    root,
  };
};

const writeFile = (root: string, relPath: string, content: string): void => {
  const absPath = path.join(root, relPath);
  mkdirSync(path.dirname(absPath), {recursive: true});
  writeFileSync(absPath, content, 'utf8');
};

const buildEntry = (
  overrides: Partial<RegionRegistryEntry> = {}
): RegionRegistryEntry => ({
  args: [],
  endMarker: END,
  id: 'test-region',
  interpreter: 'bash',
  operand: 'test-regen.sh',
  rewrites: () => new Set(),
  startMarker: START,
  ...overrides,
});

describe('scanRegionDeclarations', () => {
  test('a shipped path carrying the pair, present in rewrites → declared', () => {
    const sandbox = setupSandbox();

    try {
      writeFile(sandbox.root, 'a.md', [START, 'body', END].join('\n'));
      const entry = buildEntry({rewrites: () => new Set(['a.md'])});

      const [declaration] = scanRegionDeclarations(
        sandbox.root,
        {'a.md': 'owned'},
        [entry]
      );

      expect(declaration).toEqual({
        endMarker: END,
        id: 'test-region',
        paths: ['a.md'],
        regenerate: {args: [], interpreter: 'bash', operand: 'test-regen.sh'},
        startMarker: START,
      });
    } finally {
      sandbox.cleanup();
    }
  });

  test.each([
    {
      content: [START, 'body', END].join('\n'),
      file: 'orphan.md',
      name: 'a shipped path carrying the pair that is not in rewrites throws, naming the path',
      pattern: /orphan\.md/,
      rewrites: [] as string[],
    },
    {
      content: [START, 'a', START, 'b', END].join('\n'),
      file: 'dup.md',
      name: 'duplicated markers throw naming the malformation',
      pattern: /duplicate-start/,
      rewrites: ['dup.md'],
    },
  ])('$name', ({content, file, pattern, rewrites}) => {
    const sandbox = setupSandbox();

    try {
      writeFile(sandbox.root, file, content);
      const entry = buildEntry({rewrites: () => new Set(rewrites)});

      expect(() =>
        scanRegionDeclarations(sandbox.root, {[file]: 'owned'}, [entry])
      ).toThrow(pattern);
    } finally {
      sandbox.cleanup();
    }
  });

  test('paths are sorted with localeCompare', () => {
    const sandbox = setupSandbox();

    try {
      writeFile(sandbox.root, 'z.md', [START, 'body', END].join('\n'));
      writeFile(sandbox.root, 'a.md', [START, 'body', END].join('\n'));
      const entry = buildEntry({rewrites: () => new Set(['a.md', 'z.md'])});

      const [declaration] = scanRegionDeclarations(
        sandbox.root,
        {'a.md': 'owned', 'z.md': 'owned'},
        [entry]
      );

      expect(declaration).toBeDefined();
      expect(declaration?.paths).toEqual(['a.md', 'z.md']);
    } finally {
      sandbox.cleanup();
    }
  });

  test.each([
    {
      disk: {'withheld.md': [START, 'body', END].join('\n')},
      name: 'a path carrying the pair but absent from shippedFiles is not declared',
      rewrites: ['withheld.md'],
      shipped: {} as Record<string, string>,
    },
    {
      disk: {'prose.md': `Use the \`${START}\` marker to delimit it.\n`},
      name: 'marker text as a substring of longer prose is not declared',
      rewrites: ['prose.md'],
      shipped: {'prose.md': 'owned'},
    },
    {
      disk: {'plain.md': 'nothing here\n'},
      name: 'a registry entry finding no carrying shipped path declares paths: [] without throwing',
      rewrites: [] as string[],
      shipped: {'plain.md': 'owned'},
    },
    {
      disk: {} as Record<string, string>,
      name: 'a shippedFiles path missing from disk is skipped, not thrown',
      rewrites: [] as string[],
      shipped: {'ghost.md': 'owned'},
    },
  ])('$name', ({disk, rewrites, shipped}) => {
    const sandbox = setupSandbox();

    try {
      for (const [file, content] of Object.entries(disk)) {
        writeFile(sandbox.root, file, content);
      }

      const entry = buildEntry({rewrites: () => new Set(rewrites)});

      const declarations = scanRegionDeclarations(sandbox.root, shipped, [
        entry,
      ]);

      expect(declarations).toEqual([
        {
          endMarker: END,
          id: 'test-region',
          paths: [],
          regenerate: {
            args: [],
            interpreter: 'bash',
            operand: 'test-regen.sh',
          },
          startMarker: START,
        },
      ]);
    } finally {
      sandbox.cleanup();
    }
  });

  test('defaults to REGION_REGISTRY when no registry override is passed', () => {
    const sandbox = setupSandbox();

    try {
      const declarations = scanRegionDeclarations(sandbox.root, {});
      expect(declarations.map((declaration) => declaration.id)).toEqual([
        'audit-remit',
      ]);
    } finally {
      sandbox.cleanup();
    }
  });
});
