import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  classifyOwnership,
  effectiveOwnership,
  OWNERSHIP_CLASSIFIER_ENV,
} from './ownership.js';

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

  test('a classifier that exits non-zero leaves every path unknown', () => {
    const stub = writeStub(`${echoWith('adopter')}\nexit 3`);
    const result = classify(stub, ['a.md', 'b.md']);

    expect([...result.values()]).toEqual(['unknown', 'unknown']);
  });

  test('a classifier that prints one line too few leaves every path unknown', () => {
    const stub = writeStub(String.raw`shift 3; printf 'adopter\ta\n'`);
    const result = classify(stub, ['a.md', 'b.md']);

    expect([...result.values()]).toEqual(['unknown', 'unknown']);
  });

  test('an unrecognised class leaves every path unknown', () => {
    const stub = writeStub(echoWith('landlord'));

    expect([...classify(stub, ['a.md']).values()]).toEqual(['unknown']);
  });

  test('a missing classifier leaves every path unknown', () => {
    const result = classifyOwnership({
      env: {[OWNERSHIP_CLASSIFIER_ENV]: path.join(directory, 'absent.sh')},
      paths: ['a.md'],
      root: directory,
    });

    expect([...result.values()]).toEqual(['unknown']);
  });

  test('no classifier at the root leaves every path unknown', () => {
    const result = classifyOwnership({
      env: {},
      paths: ['a.md'],
      root: directory,
    });

    expect([...result.values()]).toEqual(['unknown']);
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
  test('upgrades an ignored per-machine local file to adopter', () => {
    expect(effectiveOwnership('ignored', ['settings-local'])).toBe('adopter');
    expect(effectiveOwnership('ignored', ['claudemd-local'])).toBe('adopter');
  });

  test('leaves an ignored file of any other kind ignored', () => {
    expect(effectiveOwnership('ignored', ['rule'])).toBe('ignored');
  });

  test('leaves a classified local file untouched', () => {
    expect(effectiveOwnership('gaia-shipped', ['settings-local'])).toBe(
      'gaia-shipped'
    );
    expect(effectiveOwnership('unknown', ['claudemd-local'])).toBe('unknown');
  });
});
