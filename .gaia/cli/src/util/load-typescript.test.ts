import {afterEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {loadTypescript} from './load-typescript.js';

const roots: string[] = [];

/** A workspace root holding the only `typescript`, and a package folder beneath it with none. */
const makeWorkspace = (): string => {
  const root = mkdtempSync(path.join(tmpdir(), 'load-typescript-'));
  const compiler = path.join(root, 'node_modules', 'typescript');

  roots.push(root);
  mkdirSync(compiler, {recursive: true});
  writeFileSync(
    path.join(compiler, 'package.json'),
    '{"name":"typescript","main":"index.js"}'
  );
  writeFileSync(path.join(compiler, 'index.js'), 'module.exports = {};\n');
  mkdirSync(path.join(root, 'apps', 'web'), {recursive: true});

  return path.join(root, 'apps', 'web');
};

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

describe('loadTypescript', () => {
  test('resolves a workspace-root install, and refuses it when gated on the package folder', () => {
    const packageDirectory = makeWorkspace();

    expect(loadTypescript(packageDirectory)).toBeDefined();
    expect(loadTypescript(packageDirectory, {isGated: true})).toBeUndefined();
  });
});
