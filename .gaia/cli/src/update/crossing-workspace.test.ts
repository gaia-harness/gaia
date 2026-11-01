import {afterEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {editWorkspacePackages, matchedFolders} from './crossing-workspace.js';
import type {WorkspaceEdit} from './crossing-workspace.js';

const TAIL =
  '\nminimumReleaseAge: 4320\n\n# a comment\nallowBuilds:\n  esbuild: true\n';

const textOf = (edit: WorkspaceEdit): string | undefined =>
  edit.ok ? edit.text : undefined;

describe('editWorkspacePackages', () => {
  test.each([
    ['bare', '  - frontend'],
    ['dot-slash and trailing slash', "  - './frontend/'"],
    ['single quoted', "  - 'frontend'"],
    ['double quoted', '  - "frontend"'],
    ['trailing slash', '  - frontend/'],
  ])(
    'replaces the %s spelling and appends the packages glob',
    (_label, line) => {
      const before = `packages:\n${line}\n  - .gaia/cli\n${TAIL}`;
      const result = editWorkspacePackages(before);

      expect(result.ok).toBe(true);
      expect(textOf(result)).toBe(
        `packages:\n  - ${
          line.includes("'") ? "'apps/*'"
          : line.includes('"') ? '"apps/*"'
          : 'apps/*'
        }\n  - .gaia/cli\n  - packages/*\n${TAIL}`
      );
    }
  );

  test('keeps every other entry in order and the rest of the file byte-identical', () => {
    const before = `# head\npackages:\n  - tools/one\n  - frontend\n  - tools/two\n${TAIL}`;
    const result = editWorkspacePackages(before);

    expect(textOf(result)).toBe(
      `# head\npackages:\n  - tools/one\n  - apps/*\n  - tools/two\n  - packages/*\n${TAIL}`
    );
  });

  test('a finished list is returned unchanged', () => {
    const before = `packages:\n  - apps/*\n  - packages/*\n  - .gaia/cli\n${TAIL}`;
    const result = editWorkspacePackages(before);

    expect(result).toEqual({changed: false, ok: true, text: before});
  });

  test('does not append the packages glob twice, or the apps glob twice', () => {
    const before = `packages:\n  - frontend\n  - apps/*\n  - packages/*\n${TAIL}`;
    const result = editWorkspacePackages(before);

    expect(textOf(result)).toBe(
      `packages:\n  - apps/*\n  - packages/*\n${TAIL}`
    );
  });

  test('refuses a file with no block-style packages list', () => {
    expect(editWorkspacePackages('packages: [frontend]\n').ok).toBe(false);
    expect(editWorkspacePackages('minimumReleaseAge: 1\n').ok).toBe(false);
  });
});

const put = (root: string, file: string, content: string): void => {
  mkdirSync(path.dirname(path.join(root, file)), {recursive: true});
  writeFileSync(path.join(root, file), content);
};

describe('matchedFolders', () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, {force: true, recursive: true});
    }
  });

  test('lists package folders the globs match, flags lifecycle scripts, skips the app home', () => {
    const root = mkdtempSync(path.join(tmpdir(), 'gaia-crossing-ws-'));

    roots.push(root);
    put(root, 'apps/web/package.json', '{}');
    put(
      root,
      'apps/legacy/package.json',
      '{"scripts":{"postinstall":"x","test":"y"}}'
    );
    put(root, 'apps/docs-only/readme.md', 'x');
    put(root, 'packages/lib/package.json', '{"scripts":{"test":"y"}}');

    expect(matchedFolders(root)).toEqual([
      {folder: 'apps/legacy', lifecycle: ['postinstall']},
      {folder: 'packages/lib', lifecycle: []},
    ]);
  });
});
