import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  classifyOwnership,
  effectiveOwnership,
  OWNERSHIP_CLASSIFIER_ENV,
} from './ownership.js';
import type {FileKind, Ownership} from './types.js';

let directory: string;

beforeEach(() => {
  directory = mkdtempSync(path.join(tmpdir(), 'gaia-ownership-'));
});

afterEach(() => {
  rmSync(directory, {force: true, recursive: true});
});

const writeStub = (body: string): string => {
  const stub = path.join(directory, 'classifier.sh');

  writeFileSync(stub, `#!/usr/bin/env bash\n${body}\n`);

  return stub;
};

const classify = (stub: string, paths: readonly string[]) =>
  classifyOwnership({
    env: {[OWNERSHIP_CLASSIFIER_ENV]: stub},
    paths,
    root: directory,
  });

/** Echoes every path after `--` with the given class. */
const echoWith = (className: string): string =>
  String.raw`shift 3; for p in "$@"; do printf '${className}\t%s\n' "$p"; done`;

describe('classifyOwnership', () => {
  test('maps each path to the class on the same line, by order', () => {
    const stub = writeStub(
      String.raw`shift 3; printf 'adopter\ta\n'; printf 'gaia-shipped\tb\n'; printf 'third-party\tc\n'`
    );
    const result = classify(stub, ['a.md', 'b.md', 'c.md']);

    expect([...result.entries()]).toEqual([
      ['a.md', 'adopter'],
      ['b.md', 'gaia-shipped'],
      ['c.md', 'third-party'],
    ]);
  });

  test.each<[string, readonly string[], () => NodeJS.ProcessEnv]>([
    [
      'a classifier that exits non-zero leaves every path unknown',
      ['a.md', 'b.md'],
      () => ({
        [OWNERSHIP_CLASSIFIER_ENV]: writeStub(`${echoWith('adopter')}\nexit 3`),
      }),
    ],
    [
      'a classifier that prints one line too few leaves every path unknown',
      ['a.md', 'b.md'],
      () => ({
        [OWNERSHIP_CLASSIFIER_ENV]: writeStub(
          String.raw`shift 3; printf 'adopter\ta\n'`
        ),
      }),
    ],
    [
      'an unrecognised class leaves every path unknown',
      ['a.md'],
      () => ({[OWNERSHIP_CLASSIFIER_ENV]: writeStub(echoWith('landlord'))}),
    ],
    [
      'a missing classifier leaves every path unknown',
      ['a.md'],
      () => ({[OWNERSHIP_CLASSIFIER_ENV]: path.join(directory, 'absent.sh')}),
    ],
    [
      'no classifier at the root leaves every path unknown',
      ['a.md'],
      () => ({}),
    ],
  ])('%s', (_name, paths, makeEnvironment) => {
    const result = classifyOwnership({
      env: makeEnvironment(),
      paths,
      root: directory,
    });

    expect([...result.values()]).toEqual(paths.map(() => 'unknown'));
  });

  test('a path with a control character is unknown and never reaches the classifier', () => {
    const record = path.join(directory, 'argv.txt');
    const stub = writeStub(
      `printf '%s\\n' "$@" > '${record}'\n${echoWith('adopter')}`
    );
    const result = classify(stub, ['good.md', 'bad\nname.md', 'tab\tname.md']);

    expect(result.get('good.md')).toBe('adopter');
    expect(result.get('bad\nname.md')).toBe('unknown');
    expect(result.get('tab\tname.md')).toBe('unknown');

    const argv = readFileSync(record, 'utf8');

    expect(argv).toContain('good.md');
    expect(argv).not.toContain('bad');
    expect(argv).not.toContain('tab');
  });

  test('spawns with only PATH, HOME, LANG and LC_ALL from the environment', () => {
    const record = path.join(directory, 'env.txt');
    const stub = writeStub(`env > '${record}'\n${echoWith('adopter')}`);

    process.env.GAIA_FITNESS_TEST_LEAK = 'leaked';

    try {
      classify(stub, ['a.md']);
    } finally {
      delete process.env.GAIA_FITNESS_TEST_LEAK;
    }

    expect(readFileSync(record, 'utf8')).not.toContain(
      'GAIA_FITNESS_TEST_LEAK'
    );
  });

  test('passes --root and the paths after a -- separator', () => {
    const record = path.join(directory, 'argv.txt');
    const stub = writeStub(
      `printf '%s\\n' "$@" > '${record}'\n${echoWith('adopter')}`
    );

    classify(stub, ['-dash.md']);

    expect(readFileSync(record, 'utf8').split('\n').slice(0, 4)).toEqual([
      '--root',
      directory,
      '--',
      '-dash.md',
    ]);
  });
});

describe('effectiveOwnership', () => {
  test.each<[string, Ownership, FileKind[], Ownership]>([
    [
      'upgrades an ignored settings-local file to adopter',
      'ignored',
      ['settings-local'],
      'adopter',
    ],
    [
      'upgrades an ignored claudemd-local file to adopter',
      'ignored',
      ['claudemd-local'],
      'adopter',
    ],
    [
      'leaves an ignored file of any other kind ignored',
      'ignored',
      ['rule'],
      'ignored',
    ],
    [
      'leaves a classified gaia-shipped local file untouched',
      'gaia-shipped',
      ['settings-local'],
      'gaia-shipped',
    ],
    [
      'leaves an unknown local file untouched',
      'unknown',
      ['claudemd-local'],
      'unknown',
    ],
  ])('%s', (_name, classified, kinds, expected) => {
    expect(effectiveOwnership(classified, kinds)).toBe(expected);
  });
});
