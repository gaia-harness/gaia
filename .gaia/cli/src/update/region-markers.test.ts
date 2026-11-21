import {describe, expect, test} from 'vitest';
import {maskRegion, REGION_PLACEHOLDER, scanRegion} from './region-markers.js';

const START = '<!-- gaia:test:start -->';
const END = '<!-- gaia:test:end -->';

describe('scanRegion', () => {
  test('one start, one end, in order → region with correct 1-based lines', () => {
    const source = ['before', START, 'inside a', 'inside b', END, 'after'].join(
      '\n'
    );
    expect(scanRegion(source, START, END)).toEqual({
      endLine: 5,
      kind: 'region',
      startLine: 2,
    });
  });

  test('absent pair → absent', () => {
    const source = ['no markers here', 'just prose'].join('\n');
    expect(scanRegion(source, START, END)).toEqual({kind: 'absent'});
  });

  test.each(
    [
      {
        end: END,
        lines: [START, 'a', START, 'b', END],
        name: 'two starts, one end → duplicate-start',
        reason: 'duplicate-start',
        start: START,
      },
      {
        end: END,
        lines: [START, 'a', END, 'b', END],
        name: 'one start, two ends → duplicate-end',
        reason: 'duplicate-end',
        start: START,
      },
      {
        end: END,
        lines: [START, 'a', 'b'],
        name: 'one start, no end → unbalanced',
        reason: 'unbalanced',
        start: START,
      },
      {
        end: END,
        lines: ['a', 'b', END],
        name: 'no start, one end → unbalanced',
        reason: 'unbalanced',
        start: START,
      },
      {
        end: END,
        lines: [END, 'a', START],
        name: 'end line before start line → inverted',
        reason: 'inverted',
        start: START,
      },
      {
        // One line matches both markers, so `startLine === endLine`. Without the
        // `>=` guard this scans as a zero-length region and maskRegion duplicates
        // the marker line while masking nothing.
        end: START,
        lines: ['a', START, 'b', 'c'],
        name: 'identical start and end markers → inverted, and maskRegion leaves the source alone',
        reason: 'inverted',
        start: START,
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {end, lines, reason, start}) => {
    const source = lines.join('\n');
    expect(scanRegion(source, start, end)).toEqual({
      kind: 'malformed',
      reason,
    });
    expect(maskRegion(source, start, end).masked).toBe(source);
  });

  test.each(
    (
      [
        {
          lines: [
            'Use the `<!-- gaia:test:start -->` marker to delimit it.',
            'prose',
          ],
          markerPairs: [[START, END]],
          name: 'substring-only line → absent (whole-line equality, not marker-strip.ts substring matching)',
        },
        {
          lines: [`  ${START}`, 'a', `${END}  `],
          markerPairs: [[START, END]],
          name: 'leading/trailing whitespace around an otherwise-matching line → not a match',
        },
        {
          lines: [START, 'a', END],
          markerPairs: [
            ['', END],
            [START, ''],
            [' '.repeat(3), END],
            [START, '\t'],
          ],
          name: 'empty and whitespace-only marker arguments → absent',
        },
      ] satisfies {
        lines: string[];
        markerPairs: [string, string][];
        name: string;
      }[]
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {lines, markerPairs}) => {
    const source = lines.join('\n');

    for (const [start, end] of markerPairs) {
      expect(scanRegion(source, start, end)).toEqual({kind: 'absent'});
    }
  });
});

describe('maskRegion', () => {
  test('interior replaced by exactly one placeholder line, marker lines and outside content byte-identical', () => {
    const source = ['before', START, 'inside a', 'inside b', END, 'after'].join(
      '\n'
    );
    const {masked, scan} = maskRegion(source, START, END);
    expect(masked).toBe(
      ['before', START, REGION_PLACEHOLDER, END, 'after'].join('\n')
    );
    expect(scan).toEqual({endLine: 5, kind: 'region', startLine: 2});
  });

  test('empty region (markers on consecutive lines) still yields one placeholder line', () => {
    const source = [START, END].join('\n');
    const {masked} = maskRegion(source, START, END);
    expect(masked).toBe([START, REGION_PLACEHOLDER, END].join('\n'));
  });

  test('every non-region scan: output byte-identical to input', () => {
    const cases = [
      ['no markers here'].join('\n'),
      [START, 'a', START, 'b', END].join('\n'), // duplicate-start
      [START, 'a', END, 'b', END].join('\n'), // duplicate-end
      [START, 'a'].join('\n'), // unbalanced
      [END, 'a', START].join('\n'), // inverted
    ];

    for (const source of cases) {
      expect(maskRegion(source, START, END).masked).toBe(source);
    }
  });

  test('idempotence: masking already-masked output yields the same bytes', () => {
    const source = ['before', START, 'inside a', 'inside b', END, 'after'].join(
      '\n'
    );
    const once = maskRegion(source, START, END).masked;
    const twice = maskRegion(once, START, END).masked;
    expect(twice).toBe(once);
  });

  test('two sources differing only inside their regions, with different region line counts, mask to identical strings', () => {
    const short = ['before', START, 'one line', END, 'after'].join('\n');
    const long = [
      'before',
      START,
      'one line',
      'two line',
      'three line',
      END,
      'after',
    ].join('\n');

    expect(maskRegion(short, START, END).masked).toBe(
      maskRegion(long, START, END).masked
    );
  });

  test('trailing newline preservation', () => {
    const source = `${['before', START, 'inside', END, 'after'].join('\n')}\n`;
    const {masked} = maskRegion(source, START, END);
    expect(masked.endsWith('\n')).toBe(true);
    expect(masked).toBe(
      `${['before', START, REGION_PLACEHOLDER, END, 'after'].join('\n')}\n`
    );
  });
});
