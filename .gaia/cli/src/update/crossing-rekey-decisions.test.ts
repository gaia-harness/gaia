import {afterEach, describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {existsSync, rmSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {
  cacheTree,
  makeBareRepo,
  OLD,
  read,
  rekeyedOf,
  write,
} from './__tests__/crossing-fixture.js';
import {runRekey} from './crossing-rekey.js';

const DECISIONS_SCRIPT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../../scripts/update-decisions.sh'
);
const roots: string[] = [];

const project = (): string => {
  const root = makeBareRepo();

  roots.push(root);

  return root;
};

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

const run = (root: string): ReturnType<typeof runRekey> =>
  runRekey(root, {baselineTag: 'v2.3.0', extraTags: ['v2.2.0']});

describe('runRekey decisions', () => {
  const DECISION_LOG = `${JSON.stringify(
    {
      decisions: [
        {
          baselineTag: 'v2.2.0',
          decision: 'deferred',
          path: OLD('package.json'),
          tag: 'v2.3.0',
        },
        {
          baselineTag: 'v2.3.0',
          decision: 'keep',
          path: OLD('app/x'),
          tag: 'v2.3.0',
        },
        {
          baselineTag: 'v2.3.0',
          decision: 'keep',
          key: 'scripts.test',
          path: OLD('package.json'),
          tag: 'v2.3.0',
        },
        {
          baselineTag: 'v2.3.0',
          decision: 'blend',
          path: '.claude/agents/code-audit-frontend.md',
          tag: 'v2.3.0',
        },
      ],
      schemaVersion: 1,
    },
    null,
    2
  )}\n`;

  const prepared = (): string => {
    const root = project();

    cacheTree(root, 'v2.3.0');
    cacheTree(root, 'v2.2.0');
    write(root, '.gaia/update-decisions.json', DECISION_LOG);

    return root;
  };

  test('rewrites each path, keeps baseline tags and sorts by path then key', () => {
    const root = prepared();
    const outcome = run(root);
    const log = JSON.parse(read(root, '.gaia/update-decisions.json'));

    expect(
      log.decisions.map((entry: {key?: string; path: string}) => [
        entry.path,
        entry.key ?? null,
      ])
    ).toEqual([
      ['.claude/agents/code-audit-frontend.md', null],
      ['apps/web/app/x', null],
      ['apps/web/package.json', null],
      ['apps/web/package.json', 'scripts.test'],
    ]);
    expect(
      log.decisions.map((entry: {baselineTag: string}) => entry.baselineTag)
    ).toEqual(['v2.3.0', 'v2.3.0', 'v2.2.0', 'v2.3.0']);
    expect(outcome.lines).toContain(
      `REKEYED_DECISION\t${OLD('package.json')}\tapps/web/package.json`
    );
    expect(
      outcome.lines.filter((line) => line.startsWith('REKEYED_DECISION'))
    ).toHaveLength(3);
  });

  test('a deferred entry resolves in the rekeyed extra tree', () => {
    const root = prepared();

    run(root);

    expect(
      existsSync(path.join(rekeyedOf(root, 'v2.2.0'), 'apps/web/package.json'))
    ).toBe(true);
  });

  test('the decision log still validates', () => {
    const root = prepared();

    run(root);
    const output = execFileSync(
      'bash',
      [
        DECISIONS_SCRIPT,
        'check',
        '--file',
        path.join(root, '.gaia/update-decisions.json'),
      ],
      {encoding: 'utf8'}
    );

    expect(output).toBe('DECISIONS_OK 4\n');
  });

  test('a second run rewrites nothing', () => {
    const root = prepared();

    run(root);
    const settled = read(root, '.gaia/update-decisions.json');
    const outcome = run(root);

    expect(read(root, '.gaia/update-decisions.json')).toBe(settled);
    expect(
      outcome.lines.filter((line) => line.startsWith('REKEYED_DECISION'))
    ).toEqual([]);
  });

  test('an absent decision log is fine', () => {
    const root = project();

    cacheTree(root, 'v2.3.0');
    writeFileSync(path.join(root, 'marker'), '');

    expect(runRekey(root, {baselineTag: 'v2.3.0', extraTags: []}).exit).toBe(0);
    expect(existsSync(path.join(root, '.gaia/update-decisions.json'))).toBe(
      false
    );
  });

  test('an unreadable decision log stops before any tree is built', () => {
    const root = project();

    cacheTree(root, 'v2.3.0');
    write(root, '.gaia/update-decisions.json', '{not json');
    const outcome = runRekey(root, {baselineTag: 'v2.3.0', extraTags: []});

    expect(outcome.lines[0]).toBe('CROSSING_STOP decisions-unreadable');
    expect(existsSync(rekeyedOf(root, 'v2.3.0'))).toBe(false);
  });
});
