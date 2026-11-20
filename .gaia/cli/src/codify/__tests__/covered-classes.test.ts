import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coveredClassesFromRules} from '../covered-classes.js';
import {markerComment} from '../marker.js';

describe('coveredClassesFromRules', () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), 'gaia-rules-'));
  });

  afterEach(() => {
    rmSync(dir, {force: true, recursive: true});
  });

  const earlierTail =
    '<!-- gaia-harden: promoted from recurring finding_class rule/earlier-tail; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->';

  // The abbreviated-tail row proves the binder is prefix-bound and tail-agnostic
  // on purpose; every other fixture uses markerComment(...) so it cannot drift.
  const cases: {
    expected: string[];
    files: Record<string, string>;
    name: string;
    readDir?: string;
  }[] = [
    {
      expected: ['rule/switch-statement'],
      files: {
        'switch-statement.md': [
          '---',
          'paths: app/**/*.ts',
          '---',
          markerComment('rule/switch-statement'),
          '',
          '# Rule body',
        ].join('\n'),
      },
      name: 'reads the promoted finding_class from a provenance-marked rule',
    },
    {
      expected: [],
      files: {'plain.md': '# Just a rule\nno marker here'},
      name: 'returns an empty set for a directory with no marked rules',
    },
    {
      expected: [],
      files: {},
      name: 'returns an empty set when the directory does not exist',
      readDir: 'nope',
    },
    {
      expected: ['axe/color-contrast', 'knip/exports'],
      files: {
        'a.md':
          '<!-- gaia-harden: promoted from recurring finding_class axe/color-contrast; never for non-recurrence -->',
        'b.md': markerComment('knip/exports'),
      },
      name: 'collects markers across multiple rule files',
    },
    {
      expected: ['rule/current-tail', 'rule/earlier-tail'],
      files: {
        'current-tail.md': markerComment('rule/current-tail'),
        'earlier-tail.md': earlierTail,
      },
      name: 'binds a marker carrying the earlier tail and one carrying the current tail',
    },
  ];

  test.each(cases.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {expected, files, readDir}) => {
      for (const [fileName, content] of Object.entries(files)) {
        writeFileSync(path.join(dir, fileName), content);
      }

      const covered = coveredClassesFromRules(
        readDir === undefined ? dir : path.join(dir, readDir)
      );

      expect(covered).toEqual(new Set(expected));
    }
  );

  test('the current marker tail names /gaia-cleanse', () => {
    expect(markerComment('rule/current-tail')).toContain('/gaia-cleanse');
  });
});
