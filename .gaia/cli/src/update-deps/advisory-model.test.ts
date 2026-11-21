import {describe, expect, test} from 'vitest';
import {
  advisoriesFromAudit,
  applyBaseline,
  classifyCandidates,
  countAdvisories,
  joinAuditToAlerts,
  normalizeAlerts,
  normalizeChain,
  normalizePnpmAudit,
  rankAdvisories,
} from './advisory-model.js';
import type {Advisory, UpdateOffers} from './advisory-model.js';
import {
  ADVISORY_REASON_TEXT,
  ADVISORY_REASON_TOKENS,
  reasonText,
} from './advisory-reasons.js';

const NO_OFFERS: UpdateOffers = {waveA: new Set(), waveB: new Set()};
const NO_APPLY: ReadonlySet<string> = new Set();
const OPEN: ReadonlySet<string> = new Set(['open']);

const auditAdvisory = (overrides: Record<string, unknown>) => ({
  findings: [{paths: ['.>cookie'], version: '0.6.0'}],
  github_advisory_id: 'GHSA-pxg6-pf52-xh8x',
  id: 1_098_765,
  module_name: 'cookie',
  patched_versions: '>=0.7.0',
  severity: 'moderate',
  vulnerable_versions: '<0.7.0',
  ...overrides,
});

const auditReport = (...advisories: Record<string, unknown>[]) => ({
  advisories: Object.fromEntries(
    advisories.map((advisory, index) => [String(index), advisory])
  ),
});

const advisory = (overrides: Partial<Advisory>): Advisory => {
  const [base] = advisoriesFromAudit(
    normalizePnpmAudit(auditReport(auditAdvisory({}))).records
  );

  if (base === undefined) throw new Error('fixture advisory missing');

  return {...base, ...overrides};
};

describe('normalizeChain and the fallback relationship', () => {
  test.each([
    ['.>cookie', ['.', 'cookie'], 'direct', 'cookie'],
    ['.>a>cookie', ['.', 'a', 'cookie'], 'transitive', 'a'],
    ['frontend>cookie', ['frontend', 'cookie'], 'direct', 'cookie'],
    [
      'frontend>react-router>cookie',
      ['frontend', 'react-router', 'cookie'],
      'transitive',
      'react-router',
    ],
  ])('%s', (auditPath, chain, relationship, head) => {
    expect(normalizeChain(auditPath)).toStrictEqual(chain);

    const [built] = advisoriesFromAudit(
      normalizePnpmAudit(
        auditReport(
          auditAdvisory({findings: [{paths: [auditPath], version: '0.6.0'}]})
        )
      ).records
    );

    expect(built?.relationship).toBe(relationship);
    expect(built?.scope).toBe('n/a');
    expect(built?.chains[0]?.[1]).toBe(head);
  });

  test('the parent is the segment before the package', () => {
    expect(normalizeChain('.>a>cookie').at(-2)).toBe('a');
  });
});

describe('normalizePnpmAudit', () => {
  // A rejected record leaves no record behind, so its first patched version
  // reads as undefined.
  test.each(
    [
      {
        firstPatchedVersion: null,
        name: 'a null patched_versions is valid and maps to no patch',
        overrides: {patched_versions: null, patched_versions_unpublished: true},
        rejectedCount: 0,
      },
      {
        firstPatchedVersion: undefined,
        name: 'a malformed patched_versions rejects the record',
        overrides: {patched_versions: '>=1.0.0; rm'},
        rejectedCount: 1,
      },
      {
        firstPatchedVersion: '0.7.0',
        name: 'the first patched version is the range minimum',
        overrides: {},
        rejectedCount: 0,
      },
      {
        firstPatchedVersion: undefined,
        name: 'rejects a non-positive id',
        overrides: {id: -3},
        rejectedCount: 1,
      },
      {
        firstPatchedVersion: undefined,
        name: 'rejects a malformed GHSA id',
        overrides: {github_advisory_id: 'GHSA-0000-0000-0000'},
        rejectedCount: 1,
      },
      {
        firstPatchedVersion: undefined,
        name: 'rejects a module name with a space',
        overrides: {module_name: 'evil pkg'},
        rejectedCount: 1,
      },
      {
        firstPatchedVersion: undefined,
        name: 'rejects an unknown severity',
        overrides: {severity: 'urgent'},
        rejectedCount: 1,
      },
      {
        firstPatchedVersion: undefined,
        name: 'rejects a finding version with a command',
        overrides: {findings: [{paths: ['.>cookie'], version: '1.0.0; rm'}]},
        rejectedCount: 1,
      },
      {
        firstPatchedVersion: undefined,
        name: 'rejects a path segment with a metacharacter',
        overrides: {findings: [{paths: ['.>$(x)>cookie'], version: '0.6.0'}]},
        rejectedCount: 1,
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {firstPatchedVersion, overrides, rejectedCount}) => {
    const result = normalizePnpmAudit(auditReport(auditAdvisory(overrides)));

    expect(result.rejectedCount).toBe(rejectedCount);
    expect(result.records).toHaveLength(1 - rejectedCount);
    expect(result.records[0]?.firstPatchedVersion).toBe(firstPatchedVersion);
  });
});

const alert = (overrides: Record<string, unknown> = {}) => ({
  dependency: {
    manifest_path: 'pnpm-lock.yaml',
    package: {ecosystem: 'npm', name: 'cookie'},
    relationship: 'transitive',
    scope: 'runtime',
  },
  number: 41,
  security_advisory: {
    epss: [{percentage: 0.25, percentile: 0.9}],
    ghsa_id: 'GHSA-pxg6-pf52-xh8x',
    severity: 'high',
  },
  security_vulnerability: {
    first_patched_version: {identifier: '0.7.0'},
    vulnerable_version_range: '< 0.7.0',
  },
  state: 'open',
  ...overrides,
});

const ALERT_RECORD = {
  epssPercentage: 0.25,
  firstPatchedVersion: '0.7.0',
  ghsa: 'GHSA-pxg6-pf52-xh8x',
  manifestPath: 'pnpm-lock.yaml',
  number: 41,
  package: 'cookie',
  relationship: 'transitive',
  scope: 'runtime',
  severity: 'high',
  vulnerableRange: '< 0.7.0',
};

describe('normalizeAlerts', () => {
  test.each(
    [
      {
        alerts: [alert()],
        name: 'keeps the allowlisted fields, EPSS from the array shape',
        records: [ALERT_RECORD],
      },
      {
        alerts: [
          alert({
            security_advisory: {
              epss: {percentage: 0.5},
              ghsa_id: 'GHSA-pxg6-pf52-xh8x',
              severity: 'high',
            },
          }),
          alert({
            security_advisory: {
              epss: [{percentage: 'high'}],
              ghsa_id: 'GHSA-pxg6-pf52-xh8x',
              severity: 'high',
            },
          }),
        ],
        name: 'reads the object EPSS shape and drops a non-finite one',
        records: [
          {...ALERT_RECORD, epssPercentage: 0.5},
          {...ALERT_RECORD, epssPercentage: null},
        ],
      },
      {
        alerts: [
          alert({state: 'fixed'}),
          alert({state: 'dismissed'}),
          alert({
            dependency: {
              manifest_path: 'requirements.txt',
              package: {ecosystem: 'pip', name: 'cookie'},
            },
          }),
        ],
        name: 'skips other states and ecosystems without counting them rejected',
        records: [],
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {alerts, records}) => {
    expect(normalizeAlerts(alerts, OPEN)).toStrictEqual({
      records,
      rejectedCount: 0,
    });
  });
});

describe('baseline', () => {
  test.each(
    [
      {
        checks: [
          {
            baseline: [999],
            expected: {baselineAcknowledged: false, baselineIds: []},
          },
          {
            baseline: [111],
            expected: {baselineAcknowledged: true, baselineIds: [111]},
          },
        ],
        name: 'acknowledges only through pnpm ids, never by module name',
        pnpmIds: [111],
      },
      {
        checks: [
          {
            baseline: [111],
            expected: {baselineAcknowledged: false, baselineIds: []},
          },
        ],
        name: 'an advisory with no pnpm ids is never acknowledged',
        pnpmIds: [],
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {checks, pnpmIds}) => {
    const base = advisory({pnpmIds});

    for (const {baseline, expected} of checks) {
      expect(applyBaseline(base, new Set(baseline))).toMatchObject(expected);
    }
  });

  const acknowledged = advisory({baselineAcknowledged: true, key: 'a'});
  const open = advisory({key: 'b'});

  test.each(
    [
      {
        checks: [
          {alerts: [], audit: [acknowledged, open], count: 1},
          {alerts: [acknowledged, open], audit: [], count: 2},
        ],
        name: 'the audit count drops acknowledged keys; the alerts count does not',
      },
      {
        checks: [
          {
            alerts: [advisory({key: 'a'})],
            audit: [
              advisory({key: 'a'}),
              advisory({key: 'b'}),
              advisory({baselineAcknowledged: true, key: 'c'}),
            ],
            count: 2,
          },
        ],
        name: 'the count is the union of alert keys and unacknowledged audit keys',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {checks}) => {
    for (const {alerts, audit, count} of checks) {
      expect(countAdvisories(alerts, audit)).toBe(count);
    }
  });
});

describe('joinAuditToAlerts', () => {
  test('one advisory per GHSA, with pnpm ids and chains joined by GHSA', () => {
    const alerts = normalizeAlerts(
      [41, 42].map((number) => ({
        dependency: {
          manifest_path: 'pnpm-lock.yaml',
          package: {ecosystem: 'npm', name: 'cookie'},
          relationship: 'transitive',
          scope: 'development',
        },
        number,
        security_advisory: {ghsa_id: 'GHSA-pxg6-pf52-xh8x', severity: 'high'},
        security_vulnerability: {vulnerable_version_range: '< 0.7.0'},
        state: 'open',
      })),
      OPEN
    ).records;
    const audit = normalizePnpmAudit(
      auditReport(
        auditAdvisory({
          findings: [
            {paths: ['frontend>react-router>cookie'], version: '0.6.0'},
          ],
        }),
        auditAdvisory({github_advisory_id: 'GHSA-2222-3333-4444', id: 7})
      )
    ).records;
    const [joined, ...rest] = joinAuditToAlerts(alerts, audit);

    expect(rest).toHaveLength(0);
    expect(joined).toMatchObject({
      alerts: [
        {manifestPath: 'pnpm-lock.yaml', number: 41},
        {manifestPath: 'pnpm-lock.yaml', number: 42},
      ],
      chains: [['frontend', 'react-router', 'cookie']],
      key: 'GHSA-pxg6-pf52-xh8x',
      pathCount: 1,
      pnpmIds: [1_098_765],
      scope: 'development',
    });
  });
});

describe('one GHSA split into several vulnerable ranges', () => {
  const semverRecords = normalizePnpmAudit(
    auditReport(
      auditAdvisory({
        github_advisory_id: 'GHSA-c2qf-rxjj-qqgw',
        id: 1,
        module_name: 'semver',
        patched_versions: '>=5.7.2',
        vulnerable_versions: '<5.7.2',
      }),
      auditAdvisory({
        github_advisory_id: 'GHSA-c2qf-rxjj-qqgw',
        id: 2,
        module_name: 'semver',
        patched_versions: '>=7.5.2',
        vulnerable_versions: '>=7.0.0 <7.5.2',
      })
    )
  ).records;

  test('advisoriesFromAudit unions the ranges and blocks on disagreeing patches', () => {
    const [built, ...rest] = advisoriesFromAudit(semverRecords);

    expect(rest).toHaveLength(0);
    expect(built?.vulnerableRange).toBe('<5.7.2 || >=7.0.0 <7.5.2');
    expect(built?.firstPatchedVersion).toBeNull();
    expect(built?.patchedVersions).toStrictEqual(['5.7.2', '7.5.2']);
  });

  test('joinAuditToAlerts unions the audit ranges the alerts omit', () => {
    const alerts = normalizeAlerts(
      [
        {
          dependency: {
            manifest_path: 'pnpm-lock.yaml',
            package: {ecosystem: 'npm', name: 'semver'},
            relationship: 'transitive',
            scope: 'runtime',
          },
          number: 1,
          security_advisory: {ghsa_id: 'GHSA-c2qf-rxjj-qqgw', severity: 'high'},
          security_vulnerability: {
            first_patched_version: {identifier: '5.7.2'},
            vulnerable_version_range: '< 5.7.2',
          },
          state: 'open',
        },
      ],
      OPEN
    ).records;
    const [joined] = joinAuditToAlerts(alerts, semverRecords);

    expect(joined?.vulnerableRange).toBe('< 5.7.2 || <5.7.2 || >=7.0.0 <7.5.2');
    expect(joined?.firstPatchedVersion).toBeNull();
  });
});

describe('a GHSA spanning several packages', () => {
  const spanning = [
    auditAdvisory({
      findings: [{paths: ['.>@babel/runtime'], version: '7.0.0'}],
      github_advisory_id: 'GHSA-968p-4wvh-cqc8',
      id: 1,
      module_name: '@babel/runtime',
      patched_versions: '>=7.26.10',
    }),
    auditAdvisory({
      findings: [{paths: ['.>@babel/helpers'], version: '7.0.0'}],
      github_advisory_id: 'GHSA-968p-4wvh-cqc8',
      id: 2,
      module_name: '@babel/helpers',
      patched_versions: '>=7.26.10',
    }),
  ];

  test('the pnpm audit source yields one advisory per package', () => {
    const built = advisoriesFromAudit(
      normalizePnpmAudit(auditReport(...spanning)).records
    );

    expect(
      built.map((entry) => [entry.package, entry.key, entry.pnpmIds])
    ).toStrictEqual([
      ['@babel/runtime', 'GHSA-968p-4wvh-cqc8', [1]],
      ['@babel/helpers', 'GHSA-968p-4wvh-cqc8', [2]],
    ]);
    expect(countAdvisories([], built)).toBe(1);
  });

  test('the alerts source yields one advisory per package with its own alerts', () => {
    const alerts = normalizeAlerts(
      [
        [41, '@babel/runtime'],
        [42, '@babel/helpers'],
      ].map(([number, name]) => ({
        dependency: {
          manifest_path: 'pnpm-lock.yaml',
          package: {ecosystem: 'npm', name},
          relationship: 'transitive',
          scope: 'development',
        },
        number,
        security_advisory: {ghsa_id: 'GHSA-968p-4wvh-cqc8', severity: 'high'},
        security_vulnerability: {vulnerable_version_range: '< 7.26.10'},
        state: 'open',
      })),
      OPEN
    ).records;
    const joined = joinAuditToAlerts(
      alerts,
      normalizePnpmAudit(auditReport(...spanning)).records
    );

    expect(
      joined.map((entry) => [entry.package, entry.alerts, entry.pnpmIds])
    ).toStrictEqual([
      ['@babel/runtime', [{manifestPath: 'pnpm-lock.yaml', number: 41}], [1]],
      ['@babel/helpers', [{manifestPath: 'pnpm-lock.yaml', number: 42}], [2]],
    ]);
    expect(countAdvisories(joined, [])).toBe(1);
  });
});

describe('rankAdvisories', () => {
  test.each(
    [
      {
        advisories: [
          advisory({
            epssPercentage: 0.1,
            key: 'high-low-epss',
            severity: 'high',
          }),
          advisory({
            epssPercentage: 0.9,
            key: 'high-high-epss',
            severity: 'high',
          }),
          advisory({
            epssPercentage: 0.01,
            key: 'critical',
            severity: 'critical',
          }),
        ],
        keys: ['critical', 'high-high-epss', 'high-low-epss'],
        name: 'severity first, then EPSS descending, then key',
      },
      {
        advisories: [
          advisory({key: 'pnpm:2', severity: 'low'}),
          advisory({key: 'pnpm:9', severity: 'high'}),
          advisory({key: 'pnpm:3', severity: 'high'}),
          advisory({epssPercentage: 0.001, key: 'pnpm:99', severity: 'high'}),
        ],
        keys: ['pnpm:99', 'pnpm:3', 'pnpm:9', 'pnpm:2'],
        name: 'without EPSS it ranks by severity then key, null EPSS last',
      },
      {
        advisories: [advisory({key: 'b'}), advisory({key: 'a'})],
        keys: ['a', 'b'],
        name: 'two equal advisories tie-break by key ascending',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {advisories, keys}) => {
    expect(rankAdvisories(advisories).map((entry) => entry.key)).toStrictEqual(
      keys
    );
  });
});

describe('classifyCandidates', () => {
  const headChain = [['frontend', 'react-router', 'cookie']];

  test.each(
    (
      [
        {
          expected: {blockedReason: 'no-patch', candidates: []},
          name: 'no patched version blocks with no-patch and no candidates',
          overrides: {firstPatchedVersion: null},
        },
        {
          expected: {
            blockedReason: 'split-patch',
            candidates: ['in-range-refresh'],
          },
          name: 'ranges patched at different versions offer no override and block with split-patch',
          overrides: {
            chains: headChain,
            firstPatchedVersion: null,
            patchedVersions: ['5.7.2', '7.5.2'],
          },
        },
        {
          expected: {blockedReason: 'release-age', candidates: []},
          name: 'a patch inside the release-age window blocks with release-age',
          overrides: {
            insideReleaseAgeWindow: true,
            patchEligibleAt: '2026-10-06T08:00:00.000Z',
          },
        },
        {
          expected: {blockedReason: null, candidates: ['override']},
          name: 'a parent range that refuses the patch omits in-range-refresh',
          overrides: {parentRangeAdmitsPatch: false},
        },
      ] satisfies {
        expected: ReturnType<typeof classifyCandidates>;
        name: string;
        overrides: Partial<Advisory>;
      }[]
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {expected, overrides}) => {
    expect(
      classifyCandidates(advisory(overrides), NO_OFFERS, NO_APPLY)
    ).toStrictEqual(expected);
  });

  test.each(
    [
      {
        applySet: NO_APPLY,
        candidates: ['in-range-refresh', 'override', 'chain-head-major'],
        name: 'a wave_b chain head with an empty apply set yields chain-head-major last',
        offers: {waveA: new Set<string>(), waveB: new Set(['react-router'])},
      },
      {
        applySet: NO_APPLY,
        candidates: ['in-range-refresh', 'chain-head-minor', 'override'],
        name: 'a wave_a chain head yields exactly one chain-head-minor',
        offers: {waveA: new Set(['react-router']), waveB: new Set<string>()},
      },
      {
        applySet: new Set(['react-router']),
        candidates: ['in-range-refresh', 'chain-head-in-run', 'override'],
        name: 'a head in the apply set yields chain-head-in-run and no chain-head-minor',
        offers: {
          waveA: new Set(['react-router']),
          waveB: new Set(['react-router']),
        },
      },
      {
        applySet: NO_APPLY,
        candidates: ['in-range-refresh', 'chain-head-minor', 'override'],
        name: 'an empty apply set never yields chain-head-in-run',
        offers: {
          waveA: new Set(['react-router']),
          waveB: new Set(['react-router']),
        },
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {applySet, candidates, offers}) => {
    expect(
      classifyCandidates(advisory({chains: headChain}), offers, applySet)
        .candidates
    ).toStrictEqual(candidates);
  });
});

// The contract's fixed texts, written out here rather than read from the
// module, so a drifted text fails instead of agreeing with itself.
const CONTRACT_REASON_TEXT = {
  'alerts-disabled': 'Dependabot alerts are disabled',
  'alerts-invalid-response': 'alerts response was not valid JSON',
  'alerts-request-failed': 'alerts request failed',
  'cli-failed': 'advisories refresh failed',
  forbidden: 'token lacks permission to read Dependabot alerts',
  'gh-missing': 'gh not installed',
  'gh-unauthenticated': 'gh not authenticated',
  'jq-missing': 'jq not installed',
  'no-remote': 'no origin remote',
  'non-github-remote': 'origin is not a GitHub remote',
  'pnpm-audit-failed': 'pnpm audit produced no advisories object',
} as const;

describe('reason text', () => {
  test('the token set is exactly the contract set', () => {
    expect(
      ADVISORY_REASON_TOKENS.toSorted((a, b) => a.localeCompare(b))
    ).toStrictEqual(
      Object.keys(CONTRACT_REASON_TEXT).toSorted((a, b) => a.localeCompare(b))
    );
    expect(
      Object.keys(ADVISORY_REASON_TEXT).toSorted((a, b) => a.localeCompare(b))
    ).toStrictEqual(
      Object.keys(CONTRACT_REASON_TEXT).toSorted((a, b) => a.localeCompare(b))
    );
  });

  test.each(Object.entries(CONTRACT_REASON_TEXT))(
    '%s renders its fixed text',
    (token, text) => {
      expect(reasonText([token as keyof typeof CONTRACT_REASON_TEXT])).toBe(
        text
      );
    }
  );

  test('joins several texts with a semicolon, and nothing for no tokens', () => {
    expect(reasonText(['forbidden', 'pnpm-audit-failed'])).toBe(
      'token lacks permission to read Dependabot alerts; pnpm audit produced no advisories object'
    );
    expect(reasonText([])).toBe('');
  });
});
