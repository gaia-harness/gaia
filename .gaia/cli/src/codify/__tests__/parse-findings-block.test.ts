import {describe, expect, test, vi} from 'vitest';
import {parseFindingsBlock} from '../parse-findings-block.js';
import type {RejectReason} from '../parse-findings-block.js';

const block = (payload: string): string =>
  [
    'Human-readable summary line.',
    '<!-- gaia-codify:findings:start -->',
    '<!--',
    payload,
    '-->',
    '<!-- gaia-codify:findings:end -->',
  ].join('\n');

const severityEntry = (severity: string): unknown => ({
  area_tags: ['app'],
  finding_class: 'holistic/missing-auth-check',
  severity,
});

describe('parseFindingsBlock', () => {
  test('extracts findings from the HTML-comment payload between the sentinels', () => {
    const body = block(
      JSON.stringify({
        auditor: 'ci',
        findings: [
          {
            area_tags: ['app/components'],
            finding_class: 'react-doctor/no-generic-handler-names',
            severity: 'major',
          },
          {
            area_tags: ['app/routes'],
            finding_class: 'holistic/missing-auth-check',
            severity: 'critical',
          },
        ],
        pr_number: 42,
        schema: 1,
      })
    );

    const parsedBlock = parseFindingsBlock(body);
    expect(parsedBlock).toEqual({
      auditor: 'ci',
      findings: [
        {
          area_tags: ['app/components'],
          finding_class: 'react-doctor/no-generic-handler-names',
          severity: 'major',
        },
        {
          area_tags: ['app/routes'],
          finding_class: 'holistic/missing-auth-check',
          severity: 'critical',
        },
      ],
    });
  });

  test('returns the auditor verbatim alongside [] for an explicit empty findings block', () => {
    const body = block(
      JSON.stringify({auditor: 'ci', findings: [], pr_number: 7, schema: 1})
    );
    expect(parseFindingsBlock(body)).toEqual({auditor: 'ci', findings: []});
  });

  test('returns null when no sentinels are present', () => {
    expect(parseFindingsBlock('just a normal comment')).toBeNull();
  });

  test('returns null when the payload between sentinels is not valid JSON', () => {
    const body = [
      '<!-- gaia-codify:findings:start -->',
      '<!-- { not json } -->',
      '<!-- gaia-codify:findings:end -->',
    ].join('\n');
    expect(parseFindingsBlock(body)).toBeNull();
  });

  test('drops malformed finding entries but keeps well-formed ones', () => {
    const body = block(
      JSON.stringify({
        auditor: 'local',
        findings: [
          {area_tags: 'not-an-array', finding_class: 5, severity: 'major'},
          {
            area_tags: ['app'],
            finding_class: 'knip/exports',
            severity: 'major',
          },
        ],
        pr_number: 9,
        schema: 1,
      })
    );

    expect(parseFindingsBlock(body)).toEqual({
      auditor: 'local',
      findings: [
        {
          area_tags: ['app'],
          finding_class: 'knip/exports',
          severity: 'major',
        },
      ],
    });
  });

  const rejectCases: {
    entry: unknown;
    name: string;
    reason: RejectReason;
    token: string;
  }[] = [
    {
      entry: severityEntry('Critical'),
      name: 'fires onReject naming the unaccepted severity token, UAT-036',
      reason: 'severity',
      token: 'Critical',
    },
    ...['error', 'warning', 'suggestion'].map((retiredToken) => ({
      entry: severityEntry(retiredToken),
      name: `drops a finding carrying the retired severity token "${retiredToken}"`,
      reason: 'severity' as const,
      token: retiredToken,
    })),
    {
      entry: {area_tags: [], severity: 'major'},
      name: 'fires onReject for a missing finding_class',
      reason: 'finding_class',
      token: 'undefined',
    },
    {
      entry: {
        area_tags: [1, 2],
        finding_class: 'knip/exports',
        severity: 'major',
      },
      name: 'fires onReject for malformed area_tags',
      reason: 'area_tags',
      token: '[1,2]',
    },
    {
      entry: 'not-an-object',
      name: 'fires onReject for a non-object entry',
      reason: 'shape',
      token: 'not-an-object',
    },
  ];

  test.each(rejectCases.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {entry, reason, token}) => {
      const body = block(
        JSON.stringify({findings: [entry], pr_number: 1, schema: 1})
      );
      const onReject = vi.fn();

      expect(parseFindingsBlock(body, onReject)).toEqual({
        auditor: '',
        findings: [],
      });
      expect(onReject).toHaveBeenCalledExactlyOnceWith(reason, token);
    }
  );

  test('never fires onReject on a null return (no parseable block)', () => {
    const onReject = vi.fn();

    expect(parseFindingsBlock('just a normal comment', onReject)).toBeNull();
    expect(
      parseFindingsBlock(
        [
          '<!-- gaia-codify:findings:start -->',
          '<!-- { not json } -->',
          '<!-- gaia-codify:findings:end -->',
        ].join('\n'),
        onReject
      )
    ).toBeNull();
    expect(onReject).not.toHaveBeenCalled();
  });

  test.each([
    ['missing', {}],
    ['empty-string', {auditor: ''}],
    ['non-string', {auditor: 7}],
  ])('normalizes a %s auditor to the "" bucket', (_kind, auditorField) => {
    const body = block(
      JSON.stringify({...auditorField, findings: [], pr_number: 1, schema: 1})
    );
    expect(parseFindingsBlock(body)).toEqual({auditor: '', findings: []});
  });

  test.each([
    ['an additive review_bases key', 'member-clearance'],
    ['a member-refusal review_bases reason', 'member-refusal'],
  ])(
    'tolerates %s without altering the parsed result',
    (_label, reviewBasesReason) => {
      const findings = [
        {
          area_tags: ['app/components'],
          finding_class: 'react-doctor/no-generic-handler-names',
          severity: 'major',
        },
      ];
      const withoutReviewBases = block(
        JSON.stringify({auditor: 'local', findings, pr_number: 42, schema: 1})
      );
      const withReviewBases = block(
        JSON.stringify({
          auditor: 'local',
          findings,
          pr_number: 42,
          review_bases: [
            {
              anchor_tree: 'abc123',
              member: 'code-audit-frontend',
              reason: reviewBasesReason,
              sha: 'deadbeef',
            },
          ],
          schema: 1,
        })
      );

      // Pin the concrete shape as well as the relation: an equality alone stays
      // green if a regression makes both sides null, which asserts nothing about
      // additive-key tolerance.
      expect(parseFindingsBlock(withReviewBases)).toEqual({
        auditor: 'local',
        findings,
      });
      expect(parseFindingsBlock(withReviewBases)).toEqual(
        parseFindingsBlock(withoutReviewBases)
      );
    }
  );
});
