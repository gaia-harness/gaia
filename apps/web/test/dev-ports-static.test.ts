/* eslint-disable unicorn/prevent-abbreviations -- the module under test is named dev-ports */
import {describe, expect, test} from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const frontendDirectory = path.resolve(import.meta.dirname, '..');
const FORBIDDEN_LITERALS = [/\b5173\b/, /\b6006\b/];

const explicitFiles = [
  'vite.config.ts',
  'playwright.config.ts',
  'package.json',
  'dev-ports-vite-plugin.ts',
  'dev-ports-reuse.ts',
];

const listTypeScriptFiles = (directory: string): string[] =>
  fs
    .readdirSync(directory, {recursive: true, withFileTypes: true})
    .filter((entry) => entry.isFile() && /\.tsx?$/.test(entry.name))
    .map((entry) => path.join(entry.parentPath, entry.name))
    .filter((file) => !file.includes(`${path.sep}output${path.sep}`));

const listScannedFiles = (): string[] => [
  ...explicitFiles.map((file) => path.join(frontendDirectory, file)),
  ...listTypeScriptFiles(path.join(frontendDirectory, '.playwright')),
  ...listTypeScriptFiles(path.join(frontendDirectory, '.storybook')),
];

const findLiterals = (files: string[]): string[] =>
  files.flatMap((file) => {
    const text = fs.readFileSync(file, 'utf8');

    return FORBIDDEN_LITERALS.filter((literal) => literal.test(text)).map(
      (literal) => `${file}: ${literal.source}`
    );
  });

describe('port literals in config files', () => {
  test('no scanned config file carries a 5173 or 6006 literal', () => {
    expect(findLiterals(listScannedFiles())).toEqual([]);
  });

  test('the scan covers the playwright and storybook config files', () => {
    const scanned = listScannedFiles();

    expect(scanned).toContain(
      path.join(frontendDirectory, '.playwright', 'global-setup.ts')
    );
    expect(scanned).toContain(
      path.join(frontendDirectory, '.storybook', 'main.ts')
    );
  });

  test.each(['5173', '6006'])(
    'findLiterals catches a hardcoded %s port literal',
    (port) => {
      const scratchDirectory = fs.mkdtempSync(
        path.join(os.tmpdir(), 'dev-ports-static-')
      );
      const scratchFile = path.join(scratchDirectory, 'bad.ts');

      fs.writeFileSync(
        scratchFile,
        `const url = 'http://localhost:${port}';\n`
      );

      try {
        expect(findLiterals([scratchFile])).toHaveLength(1);
      } finally {
        fs.rmSync(scratchDirectory, {force: true, recursive: true});
      }
    }
  );
});
