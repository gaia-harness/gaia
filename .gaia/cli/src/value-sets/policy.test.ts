import {afterEach, describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {runValueSets} from './index.js';

const CLEAN_OUTPUT = 'value-sets: no duplicate value sets\n';
const ARRAY_TEXT = 'LIST=(alpha beta gamma)\n';

const duplicateIn = (directory: string): Record<string, string> => ({
  [`${directory}/copy.sh`]: ARRAY_TEXT,
  'scripts/live.sh': ARRAY_TEXT,
});

const roots: string[] = [];

const makeTree = (files: Record<string, string>): string => {
  const root = mkdtempSync(path.join(tmpdir(), 'value-sets-policy-'));

  roots.push(root);
  execFileSync('git', ['init', '-q'], {cwd: root, stdio: 'ignore'});

  for (const [relative, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, relative)), {recursive: true});
    writeFileSync(path.join(root, relative), text);
  }

  execFileSync('git', ['add', '-A'], {cwd: root, stdio: 'ignore'});

  return root;
};

const run = (
  root: string,
  argv: string[]
): {code: number; stderr: string; stdout: string} => {
  let stderr = '';
  let stdout = '';
  const code = runValueSets(argv, {
    cwd: root,
    loadTypescript: () => undefined,
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

describe('value-sets scope policy', () => {
  test("the fixed directories and the config's globs, committed or named by --config, are left out, and a malformed or missing config exits 2", () => {
    for (const directory of [
      'node_modules/pkg',
      'dist',
      'build',
      '.react-router',
      'storybook-static',
      'coverage',
      'fixtures',
      'test-fixtures',
      'scripts/__snapshots__',
    ]) {
      const root = makeTree(duplicateIn(directory));

      expect(run(root, [])).toEqual({
        code: 0,
        stderr: '',
        stdout: CLEAN_OUTPUT,
      });
    }

    const controlRoot = makeTree(duplicateIn('other'));

    expect(run(controlRoot, []).code).toBe(1);

    const committedRoot = makeTree({
      ...duplicateIn('legacy/deep'),
      '.gaia/value-sets.json': JSON.stringify({
        exclude: [{path: 'legacy/**', reason: 'generated'}],
        version: 1,
      }),
    });

    expect(run(committedRoot, []).code).toBe(0);

    const namedRoot = makeTree(duplicateIn('legacy'));

    writeFileSync(
      path.join(namedRoot, 'elsewhere.json'),
      JSON.stringify({
        exclude: [{path: 'legacy/**', reason: 'generated'}],
        version: 1,
      })
    );

    expect(run(namedRoot, ['--config', 'elsewhere.json']).code).toBe(0);
    expect(run(namedRoot, ['--config', 'missing.json'])).toEqual({
      code: 2,
      stderr: 'value-sets: cannot run: cannot read missing.json\n',
      stdout: '',
    });

    const malformedCases: [string, string][] = [
      ['{', '.gaia/value-sets.json: not valid JSON'],
      ['[]', '.gaia/value-sets.json: must hold a JSON object'],
      ['{"version": 2}', '.gaia/value-sets.json: version must be 1'],
      [
        '{"version": 1, "other": true}',
        '.gaia/value-sets.json: unknown key other',
      ],
      [
        '{"version": 1, "exclude": [{"path": "legacy/**"}]}',
        '.gaia/value-sets.json: exclude entry 0 has no reason',
      ],
      [
        '{"version": 1, "exclude": [{"path": "a/**", "reason": "x"}, {"reason": "x"}]}',
        '.gaia/value-sets.json: exclude entry 1 has no path',
      ],
    ];

    for (const [text, reason] of malformedCases) {
      const root = makeTree({
        ...duplicateIn('legacy'),
        '.gaia/value-sets.json': text,
      });

      expect(run(root, [])).toEqual({
        code: 2,
        stderr: `value-sets: cannot run: ${reason}\n`,
        stdout: '',
      });
    }
  });
});
