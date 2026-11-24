import {afterEach, describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import {createRequire} from 'node:module';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {loadTypescript} from '../util/load-typescript.js';
import {runValueSets} from './index.js';

const roots: string[] = [];

const buildTree = (files: Record<string, string>): string => {
  const root = mkdtempSync(path.join(tmpdir(), 'value-sets-typescript-'));

  roots.push(root);
  execFileSync('git', ['init', '--quiet'], {cwd: root});

  for (const [relativePath, text] of Object.entries(files)) {
    writeFileSync(path.join(root, relativePath), text);
  }

  execFileSync('git', ['add', '--all'], {cwd: root});

  const ownCopy = path.dirname(
    createRequire(import.meta.url).resolve('typescript/package.json')
  );

  mkdirSync(path.join(root, 'node_modules'));
  symlinkSync(ownCopy, path.join(root, 'node_modules', 'typescript'));

  return root;
};

const run = (root: string): {code: number; stderr: string; stdout: string} => {
  let stderr = '';
  let stdout = '';
  const code = runValueSets([], {
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
  for (const root of roots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

describe('typescript reader', () => {
  test('const string arrays, frozen arrays, literal unions and zod enums are compared, and enums, tuple types and mixed unions never are', () => {
    const root = buildTree({
      'a.ts': "export const kinds = ['plan', 'research', 'spec'] as const;\n",
      'b.ts':
        "export const frozen = Object.freeze(['plan', 'research', 'spec']);\n",
      'c.ts': "export type Status = 'draft' | 'ready' | 'merged';\n",
      'd.ts':
        "const statusSchema = z.enum(['draft', 'ready', 'merged']).optional();\n",
      'e.ts': [
        "export enum Shade {Amber = 'amber', Cyan = 'cyan', Teal = 'teal'}",
        "export type Triple = ['amber', 'cyan', 'teal'];",
        "export type Mixed = 'amber' | 'cyan' | 'teal' | Other;",
        "export const mixedArray = ['amber', 'cyan', teal];",
        "export const wrapped = new Set(['amber', 'cyan', 'teal']);",
        "export let reassignable = ['amber', 'cyan', 'teal'];",
        "export const spread = [...WIDE, 'amber'];",
        '',
      ].join('\n'),
      'f.ts': "export const shades = ['amber', 'cyan', 'teal'];\n",
    });

    const result = run(root);

    expect(result.code).toBe(1);
    expect(result.stdout).toContain(
      'value-sets: duplicate: kinds (a.ts:1) and frozen (b.ts:1) hold plan, research, spec'
    );
    expect(result.stdout).toContain(
      'value-sets: duplicate: Status (c.ts:1) and statusSchema (d.ts:1) hold draft, merged, ready'
    );
    expect(result.stdout).not.toContain('amber');
  });
});
