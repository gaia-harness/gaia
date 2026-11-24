import {describe, expect, test} from 'vitest';
import {findStrict} from './compare.js';
import type {StrayMarker, ValueSet} from './types.js';

// Every value list is passed inline, never bound to a `const`, so the check
// this module implements does not read these inputs as value sets.

const declaration = (
  path: string,
  line: number,
  name: null | string,
  values: readonly string[],
  markers: readonly string[] = []
): ValueSet => ({
  language: path.endsWith('.sh') ? 'shell' : 'typescript',
  line,
  markers: markers.map((text, index) => ({
    line: line - markers.length + index,
    text,
  })),
  name,
  origin: 'declaration',
  path,
  values,
});

const arm = (
  path: string,
  line: number,
  values: readonly string[],
  markers: readonly string[] = []
): ValueSet => ({
  ...declaration(path, line, null, values, markers),
  language: 'shell',
  origin: 'case-arm',
});

const strict = (
  sets: readonly ValueSet[],
  strayMarkers: readonly StrayMarker[] = []
): readonly string[] => findStrict([{sets, strayMarkers}], new Set());

describe('findStrict', () => {
  test('a three-value set inside a set in another file is reported once, against the smallest superset', () => {
    const wider = declaration('b.ts', 1, 'B', [
      'major',
      'minor',
      'patch',
      'nonsemver',
    ]);
    const widest = declaration('c.ts', 1, 'C', [
      'major',
      'minor',
      'patch',
      'nonsemver',
      'other',
    ]);

    expect(
      strict([
        declaration('a.ts', 1, 'A', ['major', 'minor', 'patch']),
        wider,
        widest,
      ])
    ).toEqual([
      'value-sets: subset: A (a.ts:1) is a subset of B (b.ts:1), which also holds nonsemver',
      'value-sets: subset: B (b.ts:1) is a subset of C (c.ts:1), which also holds other',
    ]);

    expect(
      strict([declaration('a.ts', 1, 'A', ['major', 'minor']), wider, widest])
    ).toEqual([
      'value-sets: subset: B (b.ts:1) is a subset of C (c.ts:1), which also holds other',
    ]);

    expect(
      strict([
        declaration('a.ts', 1, 'A', ['major', 'minor', 'patch']),
        declaration('a.ts', 2, 'B', ['major', 'minor', 'patch', 'nonsemver']),
      ])
    ).toEqual([]);

    expect(
      strict([
        declaration('a.ts', 1, 'A', ['major', 'minor', 'patch']),
        declaration('b.ts', 1, 'B', ['major', 'minor', 'patch', 'nonsemver']),
        declaration('c.ts', 1, 'C', ['major', 'minor', 'patch', 'canary']),
      ])
    ).toEqual([
      'value-sets: subset: A (a.ts:1) is a subset of B (b.ts:1), which also holds nonsemver',
    ]);
  });

  test('a case arm is reported as a copy or a subset of a declaration and is never the superset', () => {
    expect(
      strict([
        declaration('lib.sh', 3, 'kinds', ['spec', 'plan', 'research']),
        arm('run.sh', 12, ['spec', 'plan', 'research']),
      ])
    ).toEqual([
      'value-sets: arm copies set: (case arm) (run.sh:12) repeats kinds (lib.sh:3): plan, research, spec',
    ]);

    expect(
      strict([
        declaration('lib.sh', 3, 'kinds', ['spec', 'plan', 'research']),
        arm('run.sh', 12, ['spec', 'plan']),
      ])
    ).toEqual([]);

    expect(
      strict([
        arm('a.sh', 4, ['Edit', 'Write', 'MultiEdit']),
        arm('b.sh', 9, ['Edit', 'Write', 'MultiEdit']),
      ])
    ).toEqual([
      'value-sets: duplicate: (case arm) (a.sh:4) and (case arm) (b.sh:9) hold Edit, MultiEdit, Write',
    ]);

    expect(
      strict([
        declaration('lib.sh', 3, 'kinds', [
          'spec',
          'plan',
          'research',
          'ledger',
        ]),
        arm('run.sh', 12, ['spec', 'plan', 'research']),
      ])
    ).toEqual([
      'value-sets: subset: (case arm) (run.sh:12) is a subset of kinds (lib.sh:3), which also holds ledger',
    ]);

    expect(
      strict([
        declaration('types.ts', 5, 'Grade', ['A', 'B', 'C', 'n/a']),
        arm('statusline.sh', 20, ['A', 'B', 'C'], ['subset of types.ts#Grade']),
      ])
    ).toEqual([]);

    expect(
      strict([
        arm('a.sh', 4, ['spec', 'plan', 'research']),
        arm('b.sh', 4, ['spec', 'plan', 'research', 'ledger']),
      ])
    ).toEqual([]);
  });

  test('a sanctioned copy passes while it equals its source and fails on drift, a missing source or a copy of a copy', () => {
    const copy = declaration(
      'scripts/keys.sh',
      2,
      'keys',
      ['alpha', 'beta', 'gamma'],
      ['sanctioned copy of apps/web/app/keys.ts#KEYS']
    );

    expect(
      strict([
        declaration('apps/web/app/keys.ts', 1, 'KEYS', [
          'alpha',
          'beta',
          'gamma',
        ]),
        copy,
      ])
    ).toEqual([]);

    expect(
      strict([
        declaration('apps/web/app/keys.ts', 1, 'KEYS', [
          'alpha',
          'beta',
          'gamma',
          'delta',
        ]),
        copy,
      ])
    ).toEqual([
      'value-sets: copy drifted: keys (scripts/keys.sh:2) copies apps/web/app/keys.ts#KEYS; missing delta; extra none',
      'value-sets: subset: keys (scripts/keys.sh:2) is a subset of KEYS (apps/web/app/keys.ts:1), which also holds delta',
    ]);

    expect(strict([copy])).toEqual([
      'value-sets: copy source not found: keys (scripts/keys.sh:2) names apps/web/app/keys.ts#KEYS',
    ]);

    expect(
      strict([
        declaration('apps/web/app/keys.ts', 1, 'KEYS', [
          'alpha',
          'beta',
          'gamma',
        ]),
        copy,
        declaration(
          'scripts/more.sh',
          4,
          'more',
          ['alpha', 'beta', 'gamma'],
          ['sanctioned copy of scripts/keys.sh#keys']
        ),
      ])
    ).toEqual([
      'value-sets: duplicate: KEYS (apps/web/app/keys.ts:1) and more (scripts/more.sh:4) hold alpha, beta, gamma',
      'value-sets: copy of a copy: more (scripts/more.sh:4) names scripts/keys.sh#keys, which is itself a sanctioned copy',
    ]);

    expect(
      strict([
        declaration('apps/web/app/keys.ts', 1, 'KEYS', [
          'alpha',
          'beta',
          'gamma',
        ]),
        declaration(
          'apps/web/app/keys.test.ts',
          8,
          'pinned',
          ['gamma', 'beta', 'alpha'],
          ['sanctioned copy of apps/web/app/keys.ts#KEYS']
        ),
        arm(
          'scripts/keys.sh',
          2,
          ['alpha', 'beta', 'gamma'],
          ['sanctioned copy of apps/web/app/keys.ts#KEYS']
        ),
      ])
    ).toEqual([]);
  });

  test('a subset marker exempts only the subset relation and fails on an extra value, an equal set or a missing source', () => {
    const bucket = declaration('b.ts', 2, 'Bucket', [
      'major',
      'minor',
      'patch',
      'nonsemver',
    ]);

    expect(
      strict([
        declaration(
          'a.ts',
          1,
          null,
          ['major', 'minor', 'patch'],
          ['subset of b.ts#Bucket']
        ),
        bucket,
      ])
    ).toEqual([]);

    expect(
      strict([
        declaration(
          'a.ts',
          1,
          null,
          ['major', 'minor', 'patch', 'canary'],
          ['subset of b.ts#Bucket']
        ),
        bucket,
      ])
    ).toEqual([
      'value-sets: subset holds values its source lacks: (unnamed) (a.ts:1) holds canary, which b.ts#Bucket lacks',
    ]);

    expect(
      strict([
        declaration(
          'a.ts',
          1,
          null,
          ['major', 'minor', 'patch', 'nonsemver'],
          ['subset of b.ts#Bucket']
        ),
        bucket,
      ])
    ).toEqual([
      'value-sets: duplicate: (unnamed) (a.ts:1) and Bucket (b.ts:2) hold major, minor, nonsemver, patch',
      'value-sets: subset equals source: (unnamed) (a.ts:1) holds no value fewer than b.ts#Bucket; it is a duplicate, not a subset',
    ]);

    expect(
      strict([
        declaration(
          'a.ts',
          1,
          null,
          ['major', 'minor', 'patch'],
          ['subset of b.ts#Bucket']
        ),
        bucket,
        declaration('c.ts', 1, null, ['major', 'minor', 'patch']),
      ])
    ).toEqual([
      'value-sets: duplicate: (unnamed) (a.ts:1) and (unnamed) (c.ts:1) hold major, minor, patch',
      'value-sets: subset: (unnamed) (c.ts:1) is a subset of Bucket (b.ts:2), which also holds nonsemver',
    ]);

    expect(
      strict([
        declaration(
          'a.ts',
          1,
          null,
          ['major', 'minor', 'patch'],
          ['subset of b.ts#Bucket']
        ),
      ])
    ).toEqual([
      'value-sets: subset source not found: (unnamed) (a.ts:1) names b.ts#Bucket',
    ]);
  });

  test('each finding prints in its fixed line form with sites and values ordered', () => {
    expect(
      strict([
        declaration('scripts/sync.sh', 7, 'statuses', [
          'draft',
          'ready',
          'merged',
        ]),
        declaration('apps/web/app/status.ts', 3, 'Status', [
          'draft',
          'ready',
          'merged',
        ]),
      ])
    ).toEqual([
      'value-sets: duplicate: Status (apps/web/app/status.ts:3) and statuses (scripts/sync.sh:7) hold draft, merged, ready',
    ]);

    expect(
      strict([
        arm('hooks/c.sh', 5, ['Edit', 'Write', 'MultiEdit']),
        arm('hooks/a.sh', 9, ['Edit', 'Write', 'MultiEdit']),
        arm('hooks/b.sh', 2, ['Edit', 'Write', 'MultiEdit']),
      ])
    ).toEqual([
      'value-sets: duplicate: (case arm) (hooks/a.sh:9) and (case arm) (hooks/b.sh:2) and (case arm) (hooks/c.sh:5) hold Edit, MultiEdit, Write',
    ]);

    expect(
      strict([
        declaration('a.ts', 1, 'A', ['x', 'y', 'z']),
        declaration('a.ts', 2, 'B', ['z', 'y', 'x']),
      ])
    ).toEqual([
      'value-sets: duplicate: A (a.ts:1) and B (a.ts:2) hold x, y, z',
    ]);

    expect(
      strict([
        declaration('a.ts', 1, 'A', ['red', 'green', 'blue']),
        declaration('b.ts', 4, 'B', ['blue', 'green', 'red']),
        declaration('c.ts', 2, 'C', ['red', 'green', 'blue', 'cyan']),
      ])
    ).toEqual([
      'value-sets: duplicate: A (a.ts:1) and B (b.ts:4) hold blue, green, red',
      'value-sets: subset: A (a.ts:1) is a subset of C (c.ts:2), which also holds cyan',
    ]);

    expect(
      strict(
        [
          declaration('z.ts', 1, 'KEYS', ['alpha', 'beta', 'gamma', 'delta']),
          declaration(
            'm.sh',
            2,
            'drifted',
            ['alpha', 'beta', 'gamma', 'omega'],
            ['sanctioned copy of z.ts#KEYS']
          ),
          declaration(
            'b.ts',
            3,
            'gone',
            ['one', 'two', 'three'],
            ['sanctioned copy of q.ts#Q']
          ),
          declaration(
            'c.ts',
            3,
            'lacking',
            ['alpha', 'beta', 'canary'],
            ['subset of z.ts#KEYS']
          ),
          declaration(
            'd.ts',
            3,
            'equal',
            ['alpha', 'beta', 'gamma', 'delta'],
            ['subset of z.ts#KEYS']
          ),
          declaration('e.sh', 3, 'twice', ['p', 'q']),
          declaration('e.sh', 9, 'twice', ['p', 'q']),
          declaration(
            'f.sh',
            5,
            'ambiguous',
            ['p', 'q'],
            ['sanctioned copy of e.sh#twice']
          ),
          declaration(
            'g.sh',
            5,
            'broken',
            ['r', 's'],
            ['sanctioned copy of e.sh']
          ),
          declaration(
            'h.sh',
            5,
            'both',
            ['r', 's'],
            ['sanctioned copy of e.sh#twice', 'subset of e.sh#twice']
          ),
          declaration(
            'j.ts',
            5,
            'chained',
            ['alpha', 'beta', 'gamma', 'omega'],
            ['sanctioned copy of m.sh#drifted']
          ),
          declaration(
            'k.ts',
            5,
            'narrowMarked',
            ['alpha', 'omega'],
            ['subset of d.ts#equal']
          ),
        ],
        [{line: 4, path: 'a.sh', text: 'subset of z.ts#KEYS'}]
      )
    ).toEqual([
      'value-sets: stray marker: a.sh:4 sits above no value set',
      'value-sets: copy source not found: gone (b.ts:3) names q.ts#Q',
      'value-sets: subset holds values its source lacks: lacking (c.ts:3) holds canary, which z.ts#KEYS lacks',
      'value-sets: duplicate: equal (d.ts:3) and KEYS (z.ts:1) hold alpha, beta, delta, gamma',
      'value-sets: subset equals source: equal (d.ts:3) holds no value fewer than z.ts#KEYS; it is a duplicate, not a subset',
      'value-sets: ambiguous source: ambiguous (f.sh:5) names e.sh#twice, which matches lines 3, 9',
      'value-sets: malformed marker: g.sh:4',
      'value-sets: conflicting markers: both (h.sh:5) carries both',
      'value-sets: copy of a copy: chained (j.ts:5) names m.sh#drifted, which is itself a sanctioned copy',
      'value-sets: duplicate: chained (j.ts:5) and drifted (m.sh:2) hold alpha, beta, gamma, omega',
      'value-sets: marked source: narrowMarked (k.ts:5) names d.ts#equal, which itself carries a marker',
      'value-sets: copy drifted: drifted (m.sh:2) copies z.ts#KEYS; missing delta; extra omega',
    ]);
  });

  test('a marker resolves only against collected named sets, and a malformed, stray, ambiguous, conflicting or marked-source marker fails', () => {
    const keys = declaration('apps/web/app/keys.ts', 1, 'KEYS', [
      'alpha',
      'beta',
      'gamma',
    ]);
    const copyNaming = (reference: string): ValueSet =>
      declaration(
        'scripts/keys.sh',
        2,
        'keys',
        ['alpha', 'beta', 'gamma'],
        [`sanctioned copy of ${reference}`]
      );

    expect(strict([keys, copyNaming('./apps/web/app/keys.ts#KEYS')])).toEqual(
      []
    );
    expect(
      strict([keys, copyNaming('apps/web/./lib/../app/keys.ts#KEYS')])
    ).toEqual([]);

    for (const {printed, reference} of [
      {
        printed: '../outside/keys.ts#KEYS',
        reference: '../outside/keys.ts#KEYS',
      },
      {printed: '/etc/keys.ts#KEYS', reference: '/etc/keys.ts#KEYS'},
      {
        printed: '../outside/keys.ts#KEYS',
        reference: 'apps/../../outside/keys.ts#KEYS',
      },
      {
        printed: '.gaia/tests/fixtures/x.sh#KEYS',
        reference: '.gaia/tests/fixtures/x.sh#KEYS',
      },
      {
        printed: 'apps/web/app/keys.ts#Keys',
        reference: 'apps/web/app/keys.ts#Keys',
      },
    ]) {
      expect(strict([keys, copyNaming(reference)])).toEqual([
        'value-sets: duplicate: KEYS (apps/web/app/keys.ts:1) and keys (scripts/keys.sh:2) hold alpha, beta, gamma',
        `value-sets: copy source not found: keys (scripts/keys.sh:2) names ${printed}`,
      ]);
    }

    expect(
      strict([
        arm('run.sh', 6, ['alpha', 'beta', 'gamma']),
        declaration(
          'scripts/copy.sh',
          2,
          'copy',
          ['alpha', 'beta', 'gamma'],
          ['sanctioned copy of run.sh#arm']
        ),
      ])
    ).toEqual([
      'value-sets: arm copies set: (case arm) (run.sh:6) repeats copy (scripts/copy.sh:2): alpha, beta, gamma',
      'value-sets: copy source not found: copy (scripts/copy.sh:2) names run.sh#arm',
    ]);

    expect(
      strict([
        declaration('lib.sh', 3, 'kinds', ['spec', 'plan']),
        declaration('lib.sh', 40, 'kinds', ['spec', 'plan']),
        declaration(
          'run.sh',
          2,
          'copied',
          ['spec', 'plan'],
          ['sanctioned copy of lib.sh#kinds']
        ),
      ])
    ).toEqual([
      'value-sets: ambiguous source: copied (run.sh:2) names lib.sh#kinds, which matches lines 3, 40',
    ]);

    expect(
      strict([
        declaration(
          'run.sh',
          2,
          'copied',
          ['spec', 'plan'],
          ['sanctioned copy of lib.sh']
        ),
      ])
    ).toEqual(['value-sets: malformed marker: run.sh:1']);

    expect(
      strict([
        declaration('lib.sh', 3, 'kinds', ['spec', 'plan', 'research']),
        declaration(
          'run.sh',
          3,
          'copied',
          ['spec', 'plan'],
          ['sanctioned copy of lib.sh#kinds', 'subset of lib.sh#kinds']
        ),
      ])
    ).toEqual([
      'value-sets: conflicting markers: copied (run.sh:3) carries both',
    ]);

    expect(
      strict(
        [],
        [{line: 7, path: 'run.sh', text: 'sanctioned copy of lib.sh#kinds'}]
      )
    ).toEqual(['value-sets: stray marker: run.sh:7 sits above no value set']);

    expect(
      strict([
        declaration('lib.sh', 3, 'kinds', [
          'spec',
          'plan',
          'research',
          'ledger',
        ]),
        declaration(
          'mid.sh',
          3,
          'wide',
          ['spec', 'plan', 'research', 'ledger'],
          ['sanctioned copy of lib.sh#kinds']
        ),
        declaration(
          'run.sh',
          3,
          'narrow',
          ['spec', 'plan'],
          ['subset of mid.sh#wide']
        ),
      ])
    ).toEqual([
      'value-sets: marked source: narrow (run.sh:3) names mid.sh#wide, which itself carries a marker',
    ]);
  });

  test('a set of only numbers is never compared, while a set mixing numbers and words is', () => {
    expect(
      strict([
        declaration('a.sh', 1, 'lines', ['4', '5', '6']),
        declaration('b.sh', 1, 'numbers', ['1', '4', '5', '6', '-2.5']),
        declaration('c.sh', 1, 'copy', ['4', '5', '6']),
      ])
    ).toEqual([]);

    expect(
      strict([
        declaration('a.sh', 1, 'mixed', ['4', '5', 'six']),
        declaration('b.sh', 1, 'copy', ['4', '5', 'six']),
      ])
    ).toEqual([
      'value-sets: duplicate: mixed (a.sh:1) and copy (b.sh:1) hold 4, 5, six',
    ]);
  });
});
