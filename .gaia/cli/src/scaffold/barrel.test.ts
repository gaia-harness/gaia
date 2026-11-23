import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {insertIntoBarrel} from './barrel.js';

type Sandbox = {
  cleanup: () => void;
  dir: string;
};

const setupSandbox = (): Sandbox => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-barrel-'));

  return {
    cleanup: () => {
      rmSync(dir, {force: true, recursive: true});
    },
    dir,
  };
};

const writeBarrel = (dir: string, body: string): string => {
  const filePath = path.join(dir, 'index.ts');
  writeFileSync(filePath, body, 'utf8');

  return filePath;
};

const read = (filePath: string): string => readFileSync(filePath, 'utf8');

describe('insertIntoBarrel', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  describe('insertIntoBarrel places an export alphabetically', () => {
    test.each([
      {
        expected: [
          "export * from './alpha';",
          "export * from './bravo';",
          "export * from './charlie';",
          "export * from './delta';",
          '',
        ].join('\n'),
        initial: [
          "export * from './alpha';",
          "export * from './charlie';",
          "export * from './delta';",
          '',
        ].join('\n'),
        insert: "export * from './bravo';",
        name: 'inserts a new export at the alphabetically correct position',
      },
      {
        expected: [
          "export * from './bravo';",
          "export * from './charlie';",
          "export * from './delta';",
          '',
        ].join('\n'),
        initial: [
          "export * from './charlie';",
          "export * from './delta';",
          '',
        ].join('\n'),
        insert: "export * from './bravo';",
        name: 'inserts before lexicographically-larger first entry',
      },
      {
        expected: [
          "export * from './alpha';",
          "export * from './bravo';",
          "export * from './charlie';",
          '',
        ].join('\n'),
        initial: [
          "export * from './alpha';",
          "export * from './bravo';",
          '',
        ].join('\n'),
        insert: "export * from './charlie';",
        name: 'appends after lexicographically-smaller last entry',
      },
      {
        expected: [
          '// placeholder barrel',
          "export * from './alpha';",
          '',
        ].join('\n'),
        initial: ['// placeholder barrel', ''].join('\n'),
        insert: "export * from './alpha';",
        name: 'appends to a file with no existing export-from lines',
      },
    ])('$name', ({expected, initial, insert}) => {
      const filePath = writeBarrel(sandbox.dir, initial);

      insertIntoBarrel(filePath, insert);

      expect(read(filePath)).toBe(expected);
    });
  });

  test('is idempotent: second call with same line is a no-op', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      ["export * from './alpha';", "export * from './charlie';", ''].join('\n')
    );

    insertIntoBarrel(filePath, "export * from './bravo';");
    const afterFirst = read(filePath);
    insertIntoBarrel(filePath, "export * from './bravo';");
    const afterSecond = read(filePath);

    expect(afterFirst).toBe(afterSecond);
    // Verify only one occurrence of the inserted line.
    const matches = afterSecond.match(/export \* from '\.\/bravo';/gu);
    expect(matches).not.toBeNull();
    expect(matches).toHaveLength(1);
  });

  describe('insertIntoBarrel preserves comments and line endings', () => {
    test.each([
      {
        expected: [
          '// barrel for the foo namespace',
          '',
          "export * from './alpha';",
          "export * from './bravo';",
          "export * from './charlie';",
          '',
        ].join('\n'),
        initial: [
          '// barrel for the foo namespace',
          '',
          "export * from './alpha';",
          "export * from './charlie';",
          '',
        ].join('\n'),
        name: 'preserves leading comments and blank lines',
      },
      {
        expected: [
          "export * from './alpha';",
          "export * from './bravo';",
          '',
        ].join('\n'),
        initial: ["export * from './alpha';", ''].join('\n'),
        name: 'preserves trailing newline at EOF',
      },
      {
        expected: [
          "export * from './alpha';",
          "export * from './bravo';",
          "export * from './charlie';",
        ].join('\n'),
        initial: [
          "export * from './alpha';",
          "export * from './charlie';",
        ].join('\n'),
        name: 'preserves absent trailing newline at EOF',
      },
    ])('$name', ({expected, initial}) => {
      const filePath = writeBarrel(sandbox.dir, initial);

      insertIntoBarrel(filePath, "export * from './bravo';");

      expect(read(filePath)).toBe(expected);
    });
  });

  test('handles named-export form (export {Foo} from)', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      [
        "export {Alpha} from './alpha';",
        "export {Charlie} from './charlie';",
        '',
      ].join('\n')
    );

    insertIntoBarrel(filePath, "export {Bravo} from './bravo';");

    expect(read(filePath)).toBe(
      [
        "export {Alpha} from './alpha';",
        "export {Bravo} from './bravo';",
        "export {Charlie} from './charlie';",
        '',
      ].join('\n')
    );
  });
});
