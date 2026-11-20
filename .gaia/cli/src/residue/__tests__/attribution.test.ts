import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import {attributeBody, CANON_ACCEPT, CANON_WAIVE} from '../attribution.js';

// Fixtures are arrays of lines, and every expected line number is computed
// from the array rather than hand-counted, so reordering a fixture cannot
// silently desync an assertion from its content.
const bodyOf = (lines: readonly string[]): string => lines.join('\n');

const lineOf = (lines: readonly string[], needle: string): number => {
  const index = lines.findIndex((line) => line.includes(needle));

  if (index === -1) {
    throw new Error(`fixture carries no line containing "${needle}"`);
  }

  return index + 1;
};

const key = (className: string, keyPath: string, line: number): string =>
  `<!-- gaia-debt-key: v1 class=${className} path=${keyPath} line=${line} -->`;

const MIXED_LINES = [
  '# Summary',
  `Prose outside any canonical section, carrying ${key('x/prose', 'app/prose.ts', 1)}.`,
  '',
  CANON_ACCEPT,
  '',
  `Intro prose beneath the canonical heading, carrying ${key('x/intro', 'app/intro.ts', 2)} outside any unit.`,
  '',
  `- Accepted one ${key('a/one', 'app/one.ts', 11)}`,
  '- Accepted two, whose key sits on a continuation line',
  `  continued here ${key('a/two', 'app/two.ts', 22)}`,
  '',
  CANON_WAIVE,
  '',
  `- Waived one ${key('w/one', '.gaia/scripts/w.sh', 33)}`,
  '',
  '## Documentation example',
  '',
  `Write the dedup key as ${key('doc/example', 'app/doc.ts', 44)}.`,
];

const FIRST_MATCH_LINES = [
  CANON_ACCEPT,
  `- First unit ${key('a/first', 'app/first.ts', 1)}`,
  '  more text',
  '  and more',
  `  a second key ${key('a/second', 'app/second.ts', 2)}`,
  `- Two keys on one line ${key('b/left', 'app/left.ts', 3)} ${key('b/right', 'app/right.ts', 4)}`,
];

const KEYLESS_LINES = [
  CANON_ACCEPT,
  `- A keyed entry ${key('a/keyed', 'app/keyed.ts', 7)}`,
  '- An entry nobody keyed',
  '  with a continuation line and still no key',
  CANON_WAIVE,
  '- A waived entry nobody keyed either',
];

const INTERRUPTED_LINES = [
  CANON_ACCEPT,
  '- An entry whose key arrives too late',
  '#### An interrupting heading',
  `Now a key ${key('a/late', 'app/late.ts', 9)}`,
];

const MALFORMED_LINES = [
  CANON_ACCEPT,
  `- Absolute path ${key('m/abs', '/etc/passwd', 5)}`,
  `- Traversal path ${key('m/traverse', 'app/../../etc/passwd', 5)}`,
  `- Traversal after normalization ${key('m/normalized', 'app/./../../x', 5)}`,
  `- Leading dash ${key('m/dash', '--upload-pack=x', 5)}`,
  `- Line zero ${key('m/zero', 'app/zero.ts', 0)}`,
];

const NO_V1_LINES = [
  CANON_ACCEPT,
  '- An entry whose key omits the version token <!-- gaia-debt-key: class=n/one path=app/n.ts line=5 -->',
];

const ALL_FIXTURES = [
  MIXED_LINES,
  FIRST_MATCH_LINES,
  KEYLESS_LINES,
  INTERRUPTED_LINES,
  MALFORMED_LINES,
  NO_V1_LINES,
];

describe('attributeBody attributes keyed units under their disposition', () => {
  test.each<{expected: object; lines: readonly string[]; title: string}>([
    {
      expected: {
        entries: [
          {key: {path: 'app/one.ts'}},
          {key: {path: 'app/two.ts'}},
          {key: {path: '.gaia/scripts/w.sh'}},
        ],
        keyless_count: 0,
        malformed: [],
      },
      lines: MIXED_LINES,
      title: 'attributes only keyed units, never a key sitting outside one',
    },
    {
      // Hand-enumerated per entry, not merely "both values occur".
      expected: {
        entries: [
          {disposition: 'accept', key: {path: 'app/one.ts'}},
          {disposition: 'accept', key: {path: 'app/two.ts'}},
          {disposition: 'waive', key: {path: '.gaia/scripts/w.sh'}},
        ],
      },
      lines: MIXED_LINES,
      title:
        'tags each entry with the disposition of the heading it sat beneath',
    },
    {
      expected: {
        entries: [
          {unit_start_line: lineOf(MIXED_LINES, '- Accepted one')},
          {unit_start_line: lineOf(MIXED_LINES, '- Accepted two')},
          {unit_start_line: lineOf(MIXED_LINES, '- Waived one')},
        ],
      },
      lines: MIXED_LINES,
      title:
        'records each entry at its opening bullet line, key on the bullet or on a continuation',
    },
    {
      expected: {
        entries: [
          {raw_key: 'v1 class=a/first path=app/first.ts line=1'},
          {raw_key: 'v1 class=b/left path=app/left.ts line=3'},
        ],
      },
      lines: FIRST_MATCH_LINES,
      title:
        'latches the first key in a unit and emits exactly one entry for it',
    },
    {
      expected: {
        entries: [expect.anything()],
        keyless: [
          {
            disposition: 'accept',
            unit_start_line: lineOf(KEYLESS_LINES, '- An entry nobody keyed'),
          },
          {
            disposition: 'waive',
            unit_start_line: lineOf(KEYLESS_LINES, '- A waived entry'),
          },
        ],
        keyless_count: 2,
      },
      lines: KEYLESS_LINES,
      title:
        'records a keyless unit with its disposition and opening bullet line',
    },
    {
      expected: {entries: [], keyless: []},
      lines: [
        '## Summary',
        `- An entry ${key('a/one', 'app/one.ts', 1)}`,
        '## Accepted residuals',
        `- A near-miss heading ${key('a/two', 'app/two.ts', 2)}`,
      ],
      title: 'attributes nothing in a body carrying no canonical heading',
    },
    {
      expected: {
        entries: [],
        keyless: [
          {
            disposition: 'accept',
            unit_start_line: lineOf(INTERRUPTED_LINES, '- An entry whose key'),
          },
        ],
      },
      lines: INTERRUPTED_LINES,
      title: 'closes an open unit on a heading of any level',
    },
  ])('$title', ({expected, lines}) => {
    expect(attributeBody(bodyOf(lines))).toMatchObject(expected);
  });

  test('derives a failure_mode carrying no newline and no HTML comment', () => {
    const failureModes = ALL_FIXTURES.flatMap((lines) =>
      attributeBody(bodyOf(lines)).entries.map((entry) => entry.failure_mode)
    );

    expect(failureModes.length).toBeGreaterThan(0);

    for (const failureMode of failureModes) {
      expect(failureMode).not.toMatch(/[\n\r]/);
      expect(failureMode).not.toContain('<!--');
      expect(failureMode).not.toContain('-->');
    }

    expect(attributeBody(bodyOf(MIXED_LINES)).entries[0]?.failure_mode).toBe(
      'Accepted one'
    );
  });

  test.each<{expected: string; lines: readonly string[]; title: string}>([
    {
      // The entry wraps, its key sits on a continuation line, and unrelated
      // prose follows a blank line while still inside the unit.
      expected:
        '**`changelog.ts:4`**: the docblock opens `Step 7 of the runbook`, but `release changelog` is `### 5. Graduate`. An indented paragraph still belongs to the item.',
      lines: [
        CANON_WAIVE,
        '',
        '- **`changelog.ts:4`**: the docblock opens `Step 7 of the',
        '  runbook`, but `release changelog` is `### 5. Graduate`.',
        '',
        '  An indented paragraph still belongs to the item.',
        `  ${key('holistic/unclassified', '.gaia/cli/src/release/changelog.ts', 4)}`,
        '',
        'Unindented prose after a blank line is not part of the entry.',
      ],
      title:
        'keeps a wrapped entry whole and stops at the end of its list item',
    },
    {
      // A code span quotes a bare `<!--` opener before the real key comment,
      // which is itself wrapped in a code span.
      expected:
        'quotes the `<!-- gaia-debt-key: v1 ` prefix, never parse behavior.',
      lines: [
        CANON_WAIVE,
        `- quotes the \`<!-- gaia-debt-key: v1 \` prefix, never parse behavior. \`${key('holistic/unclassified', '.gaia/tests/lib/doc-debt-query.bats', 101)}\``,
      ],
      title:
        'does not let a quoted comment opener swallow the text before the real key',
    },
    {
      expected: 'spans `a` `b` stay apart',
      lines: [
        CANON_WAIVE,
        `- spans \`a\`${key('holistic/unclassified', 'app/a.ts', 1)}\`b\` stay apart`,
      ],
      title: 'leaves the code spans on either side of a bare comment intact',
    },
    {
      expected: 'wrapped ( ) and " "',
      lines: [
        CANON_WAIVE,
        `- wrapped (\`${key('holistic/unclassified', 'app/a.ts', 1)}\`) and "\`${key('holistic/unclassified', 'app/b.ts', 2)}\`"`,
      ],
      title: 'strips a code-span-wrapped comment behind opening punctuation',
    },
  ])('$title', ({expected, lines}) => {
    expect(attributeBody(bodyOf(lines)).entries[0]?.failure_mode).toBe(
      expected
    );
  });
});

describe('attributeBody handles malformed keys as the gate does', () => {
  test.each<{expected: object; lines: readonly string[]; title: string}>([
    {
      expected: {
        entries: [],
        keyless: [],
        malformed: [
          {
            disposition: 'accept',
            raw_key: 'v1 class=m/abs path=/etc/passwd line=5',
            reason: expect.stringContaining('absolute prefix'),
            unit_start_line: lineOf(MALFORMED_LINES, '- Absolute path'),
          },
          {
            reason: expect.stringContaining('traversal segment'),
            unit_start_line: lineOf(MALFORMED_LINES, '- Traversal path'),
          },
          {
            reason: expect.stringContaining('traversal segment'),
            unit_start_line: lineOf(
              MALFORMED_LINES,
              '- Traversal after normalization'
            ),
          },
          {
            reason: expect.stringContaining('leading dash'),
            unit_start_line: lineOf(MALFORMED_LINES, '- Leading dash'),
          },
          {
            reason: expect.stringContaining('below 1'),
            unit_start_line: lineOf(MALFORMED_LINES, '- Line zero'),
          },
        ],
      },
      lines: MALFORMED_LINES,
      title:
        'withholds a gate-matching key whose fields fail validation and names why',
    },
    {
      // The gate's grammar requires the v1 token, so it never sees this as a
      // key at all and denies the merge over a keyless unit. Attributing it as
      // malformed here would give the unit two tuples in the conformance
      // comparison against the gate's one.
      expected: {entries: [], keyless: [expect.anything()], malformed: []},
      lines: NO_V1_LINES,
      title:
        'a unit whose only key omits v1 is keyless, exactly as the gate reads it',
    },
    {
      expected: {
        entries: [{key: {path: 'app/services/foo.ts'}}],
        malformed: [],
      },
      lines: [
        CANON_ACCEPT,
        `- Dotted ${key('a/dot', 'app/./services//foo.ts', 1)}`,
      ],
      title: 'a valid path carrying a dot segment collapses and attributes',
    },
  ])('$title', ({expected, lines}) => {
    expect(attributeBody(bodyOf(lines))).toMatchObject(expected);
  });
});

describe('attributeBody, recorded residual section', () => {
  test('reads the section the dispositions renderer prints for a recorded residual as one keyed entry', () => {
    const body = readFileSync(
      new URL(
        '../../../test-fixtures/residue/recorded-residual-section.md',
        import.meta.url
      ),
      'utf8'
    );
    const result = attributeBody(body);

    expect(result.malformed).toStrictEqual([]);
    expect(result.entries).toHaveLength(1);
    expect(result.entries[0]?.disposition).toBe('accept');
    expect(result.entries[0]?.key).toStrictEqual({
      class: 'holistic/unclassified',
      line: 12,
      path: 'app/components/button.test.tsx',
      version: 'v1',
    });
  });
});
