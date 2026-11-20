/**
 * Focus: the two hazards that make `-z` load-bearing rather than a formatting
 * preference. Under the default (non-`-z`) output git applies C-style quoting,
 * so a path carrying a space, a quote, or a non-ASCII byte arrives wrapped in
 * `"` with its bytes escaped, and a rename arrives as one ambiguous
 * `old -> new` payload. Under `-z` neither happens, so the parser's whole job
 * is the rename lookahead: a rename or copy record is followed by a bare
 * origin-path record carrying no status prefix.
 */
import {describe, expect, test} from 'vitest';
import {porcelainZPaths} from './git-status.js';

// Each row holds one or more [stream, paths] cases.
const ROWS: {cases: [string, string[]][]; name: string}[] = [
  {
    cases: [[' M wiki/log.md\0', ['wiki/log.md']]],
    name: 'returns the path of a modified record without its status columns',
  },
  {
    cases: [['R  app/new.ts\0app/old.ts\0', ['app/new.ts', 'app/old.ts']]],
    name: 'takes a rename origin record whole, since it carries no status prefix',
  },
  {
    cases: [['C  app/new.ts\0app/old.ts\0', ['app/new.ts', 'app/old.ts']]],
    name: 'takes a copy origin record whole, exactly as a rename origin',
  },
  {
    cases: [
      [
        'R  Config/new\0Config/old\0 M package.json\0',
        ['Config/new', 'Config/old', 'package.json'],
      ],
    ],
    name: 'does not read an origin path beginning with R or C as a status record',
  },
  {
    cases: [
      [' M wiki/Café Notes.md\0', ['wiki/Café Notes.md']],
      ['?? wiki/"quoted" page.md\0', ['wiki/"quoted" page.md']],
    ],
    name: 'never unquotes, since -z emits raw bytes and a quote can be part of a name',
  },
  {cases: [['', []]], name: 'reports no paths for a clean tree'},
];

describe('porcelainZPaths', () => {
  test.each(ROWS.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {cases}) => {
      expect.hasAssertions();

      for (const [stream, paths] of cases) {
        expect(porcelainZPaths(stream)).toEqual(paths);
      }
    }
  );
});
