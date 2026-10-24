import {describe, expect, test} from 'vitest';
import {renderCard} from './render-card.js';
import type {FitnessReport} from './render-card.js';

const CATEGORY_NAMES = [
  'authoring',
  'claudemd',
  'frontmatter',
  'hooks',
  'prompt',
  'rules',
  'settings',
  'wiki',
] as const;

const reportWith = (
  grades: Readonly<Record<string, string>>,
  overall: string,
  extra: Partial<Pick<FitnessReport, 'findings' | 'upstream'>> = {}
): FitnessReport => ({
  categories: CATEGORY_NAMES.map((name) => ({
    grade: grades[name] ?? 'A+',
    name,
  })),
  findings: [],
  overall,
  upstream: [],
  ...extra,
});

const mixedReport = (): FitnessReport =>
  reportWith({frontmatter: 'B+', hooks: 'C+', settings: 'B'}, 'C+', {
    findings: [
      {
        category: 'frontmatter',
        file: '.claude/commands/example.md',
        line: 2,
        remediation:
          'description frontmatter is missing; add a concise description of what this command does.',
        rule_id: 'frontmatter.command.description',
        severity: 'warning',
      },
      {
        category: 'hooks',
        file: '.claude/settings.json',
        line: 14,
        remediation: 'Point the hook at a script that exists.',
        rule_id: 'hooks.script-missing',
        severity: 'error',
      },
      {
        category: 'settings',
        file: '.claude/settings.json',
        line: 0,
        remediation: 'Drop the redundant permission entry.',
        rule_id: 'settings.permissions.redundant',
        severity: 'warning',
      },
      {
        category: 'settings',
        file: '.claude/settings.json',
        line: 3,
        remediation: 'Consider narrowing this entry.',
        rule_id: 'settings.permissions.broad',
        severity: 'info',
      },
    ],
  });

const WIDTH_CAP_PLUS_BORDER = 124; // 120-column cap + "| " and " |"

const lineWidths = (card: string): number[] =>
  card.split('\n').map((line) => line.length);

const allEqual = (values: readonly number[]): boolean =>
  values.every((value) => value === values[0]);

describe('renderCard', () => {
  test('renders a mixed report', () => {
    const card = renderCard(mixedReport(), 100);

    expect(card).toMatchSnapshot();
    expect(allEqual(lineWidths(card))).toBe(true);
  });

  test('renders an all n/a report as categories and an overall n/a, no findings block', () => {
    const report = reportWith(
      Object.fromEntries(CATEGORY_NAMES.map((name) => [name, 'n/a'])),
      'n/a'
    );
    const card = renderCard(report, 100);

    expect(card).toMatchSnapshot();
    expect(card).toContain('n/a');
    expect(card).not.toContain('FINDINGS');
    expect(card).not.toContain('UPSTREAM');
    expect(allEqual(lineWidths(card))).toBe(true);
  });

  test('renders upstream findings in their own block pointing at /update-gaia', () => {
    const report = reportWith({}, 'A+', {
      upstream: [
        {
          category: 'hooks',
          file: '.claude/hooks/example.sh',
          line: 1,
          remediation:
            'GAIA ships this file; run /update-gaia to take the upstream fix.',
          rule_id: 'hooks.script-not-executable',
          severity: 'warning',
        },
      ],
    });
    const card = renderCard(report, 100);

    expect(card).toMatchSnapshot();
    expect(card).toContain('UPSTREAM');
    expect(card).toContain('/update-gaia');
    expect(card).not.toContain('FINDINGS');
    expect(allEqual(lineWidths(card))).toBe(true);
  });

  test('renders a clean A+ report without a findings block or footer', () => {
    const card = renderCard(reportWith({}, 'A+'), 100);

    expect(card).toMatchSnapshot();
    expect(card).not.toContain('FINDINGS');
    expect(card).not.toContain('git diff');
    expect(card).toContain('GAIA FITNESS');
  });

  test('every line shares one width so the borders align', () => {
    const widths = lineWidths(renderCard(mixedReport(), 80));

    expect(allEqual(widths)).toBe(true);
    expect(widths[0]).toBeGreaterThan(0);
  });

  test('opens and closes with a full border bar', () => {
    const lines = renderCard(mixedReport(), 80).split('\n');

    expect(lines[0]).toMatch(/^\+-+\+$/);
    expect(lines.at(-1)).toMatch(/^\+-+\+$/);
  });

  test('renders categories alphabetically', () => {
    const report = mixedReport();
    const reversed = [...report.categories];

    reversed.reverse();
    report.categories = reversed;

    const card = renderCard(report, 80);
    const indices = CATEGORY_NAMES.map((name) =>
      card.indexOf(`| ${name === 'claudemd' ? 'CLAUDE.md' : name}`)
    );

    for (const index of indices) expect(index).toBeGreaterThan(-1);

    // Bound to a variable before sorting: canonical/no-use-extend-native's
    // proto-method database predates ES2023 and does not recognize
    // `toSorted` on an inline array-spread expression.
    const indicesCopy = [...indices];
    expect(indices).toEqual(indicesCopy.toSorted((a, b) => a - b));
  });

  test('caps the box at 120 columns on a very wide terminal', () => {
    const report = mixedReport();
    report.findings = [
      {
        category: 'hooks',
        file: '.claude/settings.json',
        line: 1,
        remediation: 'x'.repeat(400),
        rule_id: 'hooks.script-missing',
        severity: 'error',
      },
    ];

    expect(
      Math.max(...lineWidths(renderCard(report, 500)))
    ).toBeLessThanOrEqual(WIDTH_CAP_PLUS_BORDER);
  });

  test('truncates an over-long file path while keeping borders aligned', () => {
    const report = mixedReport();
    report.findings = [
      {
        category: 'hooks',
        file: `.claude/${'nested/'.repeat(40)}hook.sh`,
        line: 9,
        remediation: 'fix it',
        rule_id: 'hooks.script-missing',
        severity: 'error',
      },
    ];

    const card = renderCard(report, 80);

    expect(card).toContain('...');
    expect(allEqual(lineWidths(card))).toBe(true);
  });

  test('keeps a mixed-severity note aligned and summarized', () => {
    const report = mixedReport();
    report.findings = [
      {
        category: 'settings',
        file: '.claude/settings.json',
        line: 3,
        remediation: 'secret-shaped value in env block',
        rule_id: 'settings.env.secret',
        severity: 'error',
      },
      {
        category: 'settings',
        file: '.claude/settings.json',
        line: 9,
        remediation: 'redundant permission entry',
        rule_id: 'settings.permissions.redundant',
        severity: 'info',
      },
    ];

    const card = renderCard(report, 100);

    expect(card).toContain('1 error, 1 info');
    expect(allEqual(lineWidths(card))).toBe(true);
  });

  test('labels the claudemd category as CLAUDE.md in its row and findings header', () => {
    const report = reportWith({claudemd: 'B'}, 'B', {
      findings: [
        {
          category: 'claudemd',
          file: 'CLAUDE.md',
          line: 4,
          remediation: 'Remove the dead path.',
          rule_id: 'claudemd.dead-path',
          severity: 'warning',
        },
      ],
    });
    const card = renderCard(report, 100);

    expect(card).toMatch(/\| CLAUDE\.md +1 warning +B +\|/);
    expect(card).toContain('| CLAUDE.md: B ');
    expect(card).not.toContain('| claudemd');
    expect(card).toContain('claudemd.dead-path');
    expect(allEqual(lineWidths(card))).toBe(true);
  });

  test('shows file:line, and the bare file for a finding with no line', () => {
    const card = renderCard(mixedReport(), 100);

    expect(card).toContain('.claude/settings.json:14');
    expect(card).toMatch(/\[warning\] \.claude\/settings\.json +\|/);
    expect(card).not.toContain('.claude/settings.json:0');
  });
});
