import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  ReviewTallyInputSchema,
  snapshotFromTally,
  writeReviewSnapshot,
} from '../../schemas/review-snapshot.js';
import type {ReviewSnapshot} from '../../schemas/review-snapshot.js';
import {MERGED_PR_PAGE_CEILING} from '../../util/merged-pr-window.js';
import * as runProcess from '../../util/run-process.js';
import type {ProcessResult} from '../../util/run-process.js';
import {loadDeclineSources} from '../decline-suppression.js';
import type * as DeclineSuppressionModule from '../decline-suppression.js';
import {markerComment} from '../marker.js';
import {TALLY_SCHEMA_VERSION} from '../material-rise.js';
import {run} from '../tally.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  rulesDir: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-tally-'));
  const rulesDir = path.join(root, '.claude', 'rules');

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    rulesDir,
  };
};

const captureStdout = () => {
  const out: string[] = [];
  const spy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    out,
    restore: () => {
      spy.mockRestore();
    },
  };
};

type BlockFinding = {
  area_tags: string[];
  finding_class: string;
  severity: string;
};

// A comment as `gh pr list --json comments` returns it, narrowed to the
// fields the tally reads. Every real findings block is posted by an account
// with write access, so the helpers default to `MEMBER`.
type TallyComment = {authorAssociation?: string; body: string};

const findingsComment = (
  prNumber: number,
  auditor: string,
  findings: BlockFinding[],
  authorAssociation = 'MEMBER'
): TallyComment => ({
  authorAssociation,
  body: [
    'Audit summary.',
    '<!-- gaia-codify:findings:start -->',
    '<!--',
    JSON.stringify({auditor, findings, pr_number: prNumber, schema: 1}),
    '-->',
    '<!-- gaia-codify:findings:end -->',
  ].join('\n'),
});

// Same shape as `findingsComment` but omits the `auditor` key entirely, for
// exercising the parser's missing-auditor normalization to the `''` bucket.
const anonymousFindingsComment = (
  prNumber: number,
  findings: BlockFinding[]
): TallyComment => ({
  authorAssociation: 'MEMBER',
  body: [
    'Audit summary.',
    '<!-- gaia-codify:findings:start -->',
    '<!--',
    JSON.stringify({findings, pr_number: prNumber, schema: 1}),
    '-->',
    '<!-- gaia-codify:findings:end -->',
  ].join('\n'),
});

const ghPr = (prNumber: number, comments: TallyComment[]) => ({
  comments,
  number: prNumber,
});

const stubGh = (prs: unknown[]): ProcessResult => ({
  exitCode: 0,
  stderr: '',
  stdout: JSON.stringify(prs),
});

const parseStdout = (out: string[]): Record<string, unknown> =>
  JSON.parse(out.join('').trim()) as Record<string, unknown>;

const REFERENCE_NOW = new Date('2026-09-18T10:00:00.000Z');

const snapshotPath = (root: string): string =>
  path.join(root, '.gaia', 'local', 'codify', 'reviewed.json');

const writeRawSnapshot = (root: string, contents: string): void => {
  mkdirSync(path.dirname(snapshotPath(root)), {recursive: true});
  writeFileSync(snapshotPath(root), contents);
};

// Stubs a window of `recurring` PRs carrying `findingClass` plus `bystanders`
// audited PRs carrying an unrelated seeded class, so a test can drive both
// the numerator (the class under test) and the denominator
// (`audited_pr_count`) independently.
const stubClassWindow = (args: {
  bystanders: number;
  findingClass: string;
  recurring: number;
}): void => {
  const recurringPrs = Array.from({length: args.recurring}, (_u, index) =>
    ghPr(index + 1, [
      findingsComment(index + 1, 'ci', [
        {area_tags: [], finding_class: args.findingClass, severity: 'major'},
      ]),
    ])
  );
  const bystanderPrs = Array.from({length: args.bystanders}, (_u, index) =>
    ghPr(args.recurring + index + 1, [
      findingsComment(args.recurring + index + 1, 'ci', [
        {
          area_tags: [],
          finding_class: 'holistic/stale-figure',
          severity: 'major',
        },
      ]),
    ])
  );

  vi.spyOn(runProcess, 'runGh').mockReturnValue(
    stubGh([...recurringPrs, ...bystanderPrs])
  );
};

// Stubs the window read as one classless finding per named PR, so a test can
// drive the fallback bucket's distinct-PR count directly.
const stubClasslessWindow = (prNumbers: readonly number[]): void => {
  vi.spyOn(runProcess, 'runGh').mockReturnValue(
    stubGh(
      prNumbers.map((n) =>
        ghPr(n, [
          findingsComment(n, 'ci', [
            {
              area_tags: [],
              finding_class: 'holistic/unclassified',
              severity: 'major',
            },
          ]),
        ])
      )
    )
  );
};

// One full search page of finding-less PRs, created a minute apart, so the
// window walk has an oldest `createdAt` to narrow its next query on.
const fullSearchPage = (topNumber: number) =>
  Array.from({length: MERGED_PR_PAGE_CEILING}, (_, index) => ({
    comments: [] as TallyComment[],
    createdAt: new Date(Date.UTC(2026, 8, 2) - index * 60_000).toISOString(),
    number: topNumber - index,
  }));

const recurringFinding = (prNumber: number) =>
  findingsComment(prNumber, 'ci', [
    {
      area_tags: ['app'],
      finding_class: 'rule/switch-statement',
      severity: 'major',
    },
  ]);

type DeclinesFake = NonNullable<
  NonNullable<Parameters<typeof run>[1]>['declines']
>;

// No decline: every class re-surfaces.
const noDeclines: DeclinesFake = {
  check: () => ({reason: 'no_decline', status: 'resurface'}),
};

// Every class reads as suppressed.
const allSuppressed: DeclinesFake = {
  check: () => ({source: 'committed', status: 'suppressed'}),
};

describe('codify-tally run', () => {
  let sandbox: Sandbox;
  let stdout: ReturnType<typeof captureStdout>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdout = captureStdout();
  });

  afterEach(() => {
    stdout.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('emits a candidate for a class on 3 distinct merged PRs at warning', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1201, [
          findingsComment(1201, 'ci', [
            {
              area_tags: ['app/components'],
              finding_class: 'react-doctor/no-generic-handler-names',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(1188, [
          findingsComment(1188, 'local', [
            {
              area_tags: ['app/hooks'],
              finding_class: 'react-doctor/no-generic-handler-names',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(1175, [
          findingsComment(1175, 'ci', [
            {
              area_tags: ['app/components'],
              finding_class: 'react-doctor/no-generic-handler-names',
              severity: 'major',
            },
          ]),
        ]),
      ])
    );

    const exit = run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });
    expect(exit).toBe(0);

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(1);
    expect(printed.window_days).toBe(90);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.finding_class).toBe(
      'react-doctor/no-generic-handler-names'
    );
    expect(candidates[0]?.distinct_pr_count).toBe(3);
    expect(candidates[0]?.is_oracle).toBe(true);
  });

  test('CI+local findings for the same class across distinct PRs combine into one candidate', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(2, [
          findingsComment(2, 'local', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'critical',
            },
          ]),
        ]),
        ghPr(3, [
          findingsComment(3, 'ci', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'major',
            },
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(1);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.severity_max).toBe('critical');
    expect(candidates[0]?.is_oracle).toBe(false);
  });

  test('two different auditors posting on the same PR both count (#731 regression)', () => {
    // PR 1201 carries a 'ci' block for classA and a 'local' block for classB
    // in the SAME comment list. Under the old last-block-on-the-PR-wins bug,
    // only the local/classB block would survive, so classA would be short one
    // PR and fall below the recurrence threshold.
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1201, [
          findingsComment(1201, 'ci', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'major',
            },
          ]),
          findingsComment(1201, 'local', [
            {
              area_tags: ['app'],
              finding_class: 'axe/color-contrast',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(1188, [
          findingsComment(1188, 'ci', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(1175, [
          findingsComment(1175, 'ci', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'major',
            },
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    const candidates = printed.candidates as Record<string, unknown>[];
    const switchCandidate = candidates.find(
      (c) => c.finding_class === 'rule/switch-statement'
    );
    expect(switchCandidate?.distinct_pr_count).toBe(3);
    expect(switchCandidate?.pr_numbers).toContain(1201);
  });

  test('same auditor re-running on a PR supersedes its own earlier block, not merges', () => {
    // PR 1 carries two 'ci' blocks: the second (classB) must fully replace
    // the first (classA) for that auditor, so classA gets no credit from PR 1.
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {
              area_tags: [],
              finding_class: 'rule/switch-statement',
              severity: 'major',
            },
          ]),
          findingsComment(1, 'ci', [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(2, [
          findingsComment(2, 'ci', [
            {
              area_tags: [],
              finding_class: 'rule/switch-statement',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(3, [
          findingsComment(3, 'ci', [
            {
              area_tags: [],
              finding_class: 'rule/switch-statement',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(4, [
          findingsComment(4, 'ci', [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(5, [
          findingsComment(5, 'ci', [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'major',
            },
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    // classA (rule/switch-statement) only reaches PRs 2 and 3 (2 distinct):
    // PR 1's ci/classA block was superseded by ci/classB on the same PR, so
    // it must not qualify. classB (axe/color-contrast) reaches PRs 1, 4, 5.
    expect(printed.candidate_count).toBe(1);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.finding_class).toBe('axe/color-contrast');
    expect(candidates[0]?.pr_numbers).toEqual(
      expect.arrayContaining([1, 4, 5])
    );
  });

  const colorContrastFinding = {
    area_tags: [],
    finding_class: 'axe/color-contrast',
    severity: 'major',
  };

  test('ignores findings blocks from commenters without repository access, so they neither supersede nor add', () => {
    const forgedFinding = {
      area_tags: ['forged'],
      finding_class: 'rule/switch-statement',
      severity: 'major',
    };
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        // The forged empty block reuses the maintainer's auditor key; it
        // must not erase PR 1's findings.
        ghPr(1, [
          findingsComment(1, 'local', [colorContrastFinding]),
          findingsComment(1, 'local', [], 'NONE'),
        ]),
        ghPr(2, [findingsComment(2, 'local', [colorContrastFinding])]),
        ghPr(3, [findingsComment(3, 'local', [colorContrastFinding])]),
        ghPr(4, [findingsComment(4, 'local', [forgedFinding], 'CONTRIBUTOR')]),
        ghPr(5, [findingsComment(5, 'local', [forgedFinding], 'NONE')]),
        ghPr(6, [
          findingsComment(
            6,
            'local',
            [forgedFinding],
            'FIRST_TIME_CONTRIBUTOR'
          ),
        ]),
      ])
    );

    run([], {cwd: sandbox.root, declines: noDeclines});

    const printed = parseStdout(stdout.out);
    expect(printed.audited_pr_count).toBe(3);
    expect(printed.candidate_count).toBe(1);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.finding_class).toBe('axe/color-contrast');
    expect(candidates[0]?.pr_numbers).toEqual(
      expect.arrayContaining([1, 2, 3])
    );
  });

  test('fails closed on a comment whose authorAssociation is missing or unrecognized', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          {body: findingsComment(1, 'local', [colorContrastFinding]).body},
        ]),
        ghPr(2, [
          findingsComment(2, 'local', [colorContrastFinding], 'MANNEQUIN'),
        ]),
        ghPr(3, [
          findingsComment(3, 'local', [colorContrastFinding], 'member'),
        ]),
        {
          comments: [
            {
              authorAssociation: 7,
              body: findingsComment(4, 'local', [colorContrastFinding]).body,
            },
          ],
          number: 4,
        },
      ])
    );

    run([], {cwd: sandbox.root, declines: noDeclines});

    const printed = parseStdout(stdout.out);
    expect(printed.audited_pr_count).toBe(0);
    expect(printed.candidate_count).toBe(0);
  });

  test('counts findings blocks from OWNER, MEMBER and COLLABORATOR commenters', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [findingsComment(1, 'local', [colorContrastFinding], 'OWNER')]),
        ghPr(2, [
          findingsComment(2, 'local', [colorContrastFinding], 'MEMBER'),
        ]),
        ghPr(3, [
          findingsComment(3, 'local', [colorContrastFinding], 'COLLABORATOR'),
        ]),
      ])
    );

    run([], {cwd: sandbox.root, declines: noDeclines});

    const printed = parseStdout(stdout.out);
    expect(printed.audited_pr_count).toBe(3);
    expect(printed.candidate_count).toBe(1);
  });

  test('two anonymous (missing-auditor) blocks on the same PR collapse, latest wins', () => {
    // Both blocks omit `auditor`, so the parser normalizes each to the same
    // '' bucket: the second (classB) must supersede the first (classA), the
    // same as a same-auditor re-run, not merge as if from different auditors.
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          anonymousFindingsComment(1, [
            {
              area_tags: [],
              finding_class: 'rule/switch-statement',
              severity: 'major',
            },
          ]),
          anonymousFindingsComment(1, [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(2, [
          anonymousFindingsComment(2, [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(3, [
          anonymousFindingsComment(3, [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'major',
            },
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(1);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.finding_class).toBe('axe/color-contrast');
    expect(candidates[0]?.distinct_pr_count).toBe(3);
  });

  test('does not surface a class on only 2 distinct PRs', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {area_tags: [], finding_class: 'knip/exports', severity: 'major'},
          ]),
        ]),
        ghPr(2, [
          findingsComment(2, 'ci', [
            {area_tags: [], finding_class: 'knip/exports', severity: 'major'},
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
  });

  test('does not surface a class found 3 times in a single PR', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {area_tags: [], finding_class: 'knip/exports', severity: 'major'},
            {area_tags: [], finding_class: 'knip/exports', severity: 'major'},
            {area_tags: [], finding_class: 'knip/exports', severity: 'major'},
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
  });

  test('surfaces a suggestion-only recurring class as a candidate (severity-independent)', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'holistic/hardcoded-string',
                severity: 'minor',
              },
            ]),
          ])
        )
      )
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(1);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.severity_max).toBe('minor');
  });

  test('emits a populated unclassified field for a classless recurring finding, excluded from candidates', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: ['app/routes'],
                finding_class: 'holistic/unclassified',
                severity: 'major',
              },
            ]),
          ])
        )
      )
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(0);
    const unclassified = printed.unclassified as Record<string, unknown>;
    expect(unclassified).not.toBeNull();
    expect(unclassified.distinct_pr_count).toBe(3);
    expect(unclassified.severity_max).toBe('major');
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(
      candidates.every((c) => c.finding_class !== 'holistic/unclassified')
    ).toBe(true);
  });

  test('emits a null unclassified field when the classless bucket is below threshold', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {
              area_tags: [],
              finding_class: 'holistic/unclassified',
              severity: 'major',
            },
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    expect(parseStdout(stdout.out).unclassified).toBeNull();
  });

  test('drops a class a promoted rule already covers', () => {
    mkdirSync(sandbox.rulesDir, {recursive: true});
    writeFileSync(
      path.join(sandbox.rulesDir, 'switch.md'),
      markerComment('rule/switch-statement')
    );

    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'rule/switch-statement',
                severity: 'major',
              },
            ]),
          ])
        )
      )
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
  });

  test('drops a decline-suppressed class, then re-surfaces once it crosses the threshold again', () => {
    const gh = stubGh(
      [3, 2, 1].map((n) =>
        ghPr(n, [
          findingsComment(n, 'ci', [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'critical',
            },
          ]),
        ])
      )
    );
    vi.spyOn(runProcess, 'runGh').mockReturnValue(gh);

    // The loader says suppressed: no candidate.
    run([], {cwd: sandbox.root, declines: allSuppressed});
    expect(parseStdout(stdout.out).candidate_count).toBe(0);

    // Fresh evidence: the loader now says resurface: re-surfaces.
    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      declines: {
        check: () => ({reason: 'material_rise', status: 'resurface'}),
      },
    });
    expect(parseStdout(stdout.out).candidate_count).toBe(1);
  });

  test('suppresses every class when no repository root resolves', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'axe/color-contrast',
                severity: 'major',
              },
            ]),
          ])
        )
      )
    );

    // The sandbox is a bare directory, not a git repository.
    run([], {cwd: sandbox.root});

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
  });

  test('reads the real decline sources in process and writes nothing to stderr when a class re-surfaces', () => {
    execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: sandbox.root});
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'axe/color-contrast',
                severity: 'major',
              },
            ]),
          ])
        )
      )
    );
    const stderr = vi
      .spyOn(process.stderr, 'write')
      .mockImplementation(() => true);

    // No decline for the class: the loader answers `no_decline` and
    // reports nothing. Nothing may print.
    run([], {cwd: sandbox.root});

    expect(parseStdout(stdout.out).candidate_count).toBe(1);
    expect(stderr).not.toHaveBeenCalled();
  });

  test('falls back to candidate_count 0 and gh_ok false when gh fails (non-fatal)', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 4,
      stderr: 'gh: not authenticated',
      stdout: '',
    });

    const exit = run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });
    expect(exit).toBe(0);

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(0);
    expect(printed.candidates).toEqual([]);
    expect(printed.gh_ok).toBe(false);
  });

  test('sets gh_ok true on a successful read of a genuinely empty window', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(stubGh([]));

    const exit = run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });
    expect(exit).toBe(0);

    const printed = parseStdout(stdout.out);
    expect(printed.gh_ok).toBe(true);
    expect(printed.candidate_count).toBe(0);
  });

  test('a fallback suppression silences unclassified', () => {
    stubClasslessWindow([3, 2, 1]);

    run([], {cwd: sandbox.root, declines: noDeclines});
    expect(parseStdout(stdout.out).unclassified).not.toBeNull();

    stdout.out.length = 0;
    run([], {cwd: sandbox.root, declines: allSuppressed});

    expect(parseStdout(stdout.out).unclassified).toBeNull();
  });

  test('counts PRs past the first search page, so the 1000-result cap is not the window', () => {
    const first = fullSearchPage(5000).map((pr, index) =>
      index === 0 ? {...pr, comments: [recurringFinding(5000)]} : pr
    );
    vi.spyOn(runProcess, 'runGh')
      .mockReturnValueOnce(stubGh(first))
      .mockReturnValueOnce(
        stubGh([
          {
            ...ghPr(3001, [recurringFinding(3001)]),
            createdAt: '2026-08-01T00:00:00Z',
          },
          {
            ...ghPr(3000, [recurringFinding(3000)]),
            createdAt: '2026-07-31T00:00:00Z',
          },
        ])
      );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.gh_ok).toBe(true);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.finding_class).toBe('rule/switch-statement');
    expect(candidates[0]?.distinct_pr_count).toBe(3);
  });

  test('reads a window the walk cannot finish as unread: gh_ok false, window_truncated', () => {
    vi.spyOn(runProcess, 'runGh').mockImplementation(() =>
      stubGh(fullSearchPage(90_000))
    );

    const stderr = vi
      .spyOn(process.stderr, 'write')
      .mockImplementation(() => true);

    const exit = run([], {cwd: sandbox.root, declines: noDeclines});
    expect(exit).toBe(0);

    const printed = parseStdout(stdout.out);
    expect(printed.gh_ok).toBe(false);
    expect(printed.candidate_count).toBe(0);
    const diagnostic = JSON.parse(String(stderr.mock.calls[0]?.[0])) as Record<
      string,
      unknown
    >;
    expect(diagnostic.code).toBe('window_truncated');
  });

  test('queries the 90-day merged-PR window via gh', () => {
    const ghSpy = vi.spyOn(runProcess, 'runGh').mockReturnValue(stubGh([]));

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const args = ghSpy.mock.calls[0]?.[0] ?? [];
    expect(args).toContain('pr');
    expect(args).toContain('list');
    expect(args).toContain('merged');
    const searchIndex = args.indexOf('--search');
    expect(args[searchIndex + 1]).toMatch(
      /^merged:>=\d{4}-\d{2}-\d{2} sort:created-desc$/
    );
  });

  test('UAT-002/UAT-003: audited_pr_count, tally_schema_version, and no-snapshot triggers', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {
              area_tags: [],
              finding_class: 'holistic/stale-figure',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(2, [findingsComment(2, 'ci', [])]),
        ghPr(3, [
          findingsComment(3, 'ci', [
            {
              area_tags: [],
              finding_class: 'holistic/stale-figure',
              severity: 'major',
            },
          ]),
        ]),
        ghPr(4, []),
        ghPr(5, []),
      ])
    );

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.audited_pr_count).toBe(3);
    expect(printed.tally_schema_version).toBe(TALLY_SCHEMA_VERSION);
    expect(printed.snapshot_present).toBe(false);
    expect(printed.snapshot_reviewed_at).toBeNull();
    expect(printed.triggers).toEqual([]);
    expect(ReviewTallyInputSchema.safeParse(printed).success).toBe(true);
  });

  test('a snapshot written from a first run reads back unchanged on an identical re-run, candidates included', () => {
    stubClassWindow({
      bystanders: 0,
      findingClass: 'holistic/overclaimed-guarantee',
      recurring: 3,
    });

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });
    const firstEmitted = ReviewTallyInputSchema.parse(parseStdout(stdout.out));

    writeReviewSnapshot(
      sandbox.root,
      snapshotFromTally(firstEmitted, REFERENCE_NOW)
    );

    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.snapshot_present).toBe(true);
    expect(printed.snapshot_reviewed_at).toBe(REFERENCE_NOW.toISOString());
    expect(printed.triggers).toEqual([]);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(
      candidates.some(
        (c) => c.finding_class === 'holistic/overclaimed-guarantee'
      )
    ).toBe(true);
    expect(ReviewTallyInputSchema.safeParse(printed).success).toBe(true);
  });

  test('a schema-version mismatch refuses every other trigger, clearing after a fresh snapshot; repeated on an all-clear window', () => {
    stubClassWindow({
      bystanders: 0,
      findingClass: 'holistic/n-plus-one',
      recurring: 3,
    });

    const mismatchedSnapshot: ReviewSnapshot = {
      audited_pr_count: 3,
      classes: {},
      reviewed_at: REFERENCE_NOW.toISOString(),
      tally_schema_version: TALLY_SCHEMA_VERSION + 1,
      unclassified: null,
      version: 1,
      window_days: 90,
    };
    writeReviewSnapshot(sandbox.root, mismatchedSnapshot);

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });
    expect(parseStdout(stdout.out).triggers).toEqual([{type: 'schema_change'}]);

    const firstEmitted = ReviewTallyInputSchema.parse(parseStdout(stdout.out));
    writeReviewSnapshot(
      sandbox.root,
      snapshotFromTally(firstEmitted, REFERENCE_NOW)
    );

    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });
    expect(parseStdout(stdout.out).triggers).toEqual([]);

    // Repeat on an all-clear window (candidate_count 0, unclassified null).
    vi.spyOn(runProcess, 'runGh').mockReturnValue(stubGh([]));
    writeReviewSnapshot(sandbox.root, mismatchedSnapshot);

    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });
    expect(parseStdout(stdout.out).triggers).toEqual([{type: 'schema_change'}]);

    const allClearEmitted = ReviewTallyInputSchema.parse(
      parseStdout(stdout.out)
    );
    writeReviewSnapshot(
      sandbox.root,
      snapshotFromTally(allClearEmitted, REFERENCE_NOW)
    );

    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });
    expect(parseStdout(stdout.out).triggers).toEqual([]);
  });

  test('a malformed snapshot (invalid JSON, and valid JSON failing the schema) is ignored, not trusted', () => {
    stubClassWindow({
      bystanders: 0,
      findingClass: 'holistic/swallowed-error',
      recurring: 3,
    });

    for (const contents of ['{"broken":', '{"version":2}']) {
      writeRawSnapshot(sandbox.root, contents);
      stdout.out.length = 0;
      const stderr = vi
        .spyOn(process.stderr, 'write')
        .mockImplementation(() => true);

      run([], {
        cwd: sandbox.root,
        declines: noDeclines,
      });

      const printed = parseStdout(stdout.out);
      expect(printed.snapshot_present).toBe(false);
      expect(printed.triggers).toEqual([]);
      const candidates = printed.candidates as Record<string, unknown>[];
      expect(candidates.length).toBeGreaterThan(0);
      expect(ReviewTallyInputSchema.safeParse(printed).success).toBe(true);

      const diagnostic = JSON.parse(
        String(stderr.mock.calls[0]?.[0])
      ) as Record<string, unknown>;
      expect(diagnostic.code).toBe('malformed_snapshot');
      stderr.mockRestore();
    }
  });

  test('gh_ok false with a valid snapshot present: triggers empty, audited_pr_count 0, snapshot_present true', () => {
    writeReviewSnapshot(sandbox.root, {
      audited_pr_count: 10,
      classes: {},
      reviewed_at: REFERENCE_NOW.toISOString(),
      tally_schema_version: TALLY_SCHEMA_VERSION,
      unclassified: null,
      version: 1,
      window_days: 90,
    });

    vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 4,
      stderr: 'gh: not authenticated',
      stdout: '',
    });

    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.triggers).toEqual([]);
    expect(printed.audited_pr_count).toBe(0);
    expect(printed.snapshot_present).toBe(true);
  });

  test('20a: a class suppressed at review start is absent from that snapshot, so its later re-surfacing reads as new_class, not rising_class (accepted behavior, never reviewed under that snapshot)', () => {
    stubClassWindow({
      bystanders: 2,
      findingClass: 'holistic/n-plus-one',
      recurring: 3,
    });

    // First run: every class reads as suppressed, so it is absent from both
    // candidates and class_inventory in this run's emitted JSON, and therefore
    // absent from the snapshot built from it.
    run([], {cwd: sandbox.root, declines: allSuppressed});
    const suppressedEmitted = ReviewTallyInputSchema.parse(
      parseStdout(stdout.out)
    );
    expect(
      suppressedEmitted.class_inventory.some(
        (entry) => entry.finding_class === 'holistic/n-plus-one'
      )
    ).toBe(false);

    writeReviewSnapshot(
      sandbox.root,
      snapshotFromTally(suppressedEmitted, REFERENCE_NOW)
    );

    // Second run, same window: an empty fake store stands in for a decline
    // that re-surfaced, so the loader no longer reports it suppressed.
    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      declines: noDeclines,
    });

    expect(parseStdout(stdout.out).triggers).toEqual([
      {finding_class: 'holistic/n-plus-one', type: 'new_class'},
    ]);
  });
});

// Merged PR bodies as `audit-dispositions-check.sh pr-sections` renders them,
// copied from real merged pull requests: a triage waive is
// `- <path>:<line> <class>: <reason>`, an accepted residual carries a wrapped
// dedup key. The trailing lines are what follows the sections in a real body.
const WAIVED_BODY = [
  '## Summary',
  '',
  '- Tightens the decision-prompt lint.',
  '',
  '## Waived below triage threshold (not filed)',
  '',
  '- .gaia/tests/hooks/spec-decision-prompts.bats:36 holistic/drifting-duplicate: a UX-consistency doc lint; narrowing it drops no protection for security, destroyed work, false shipped text or the merge gate, so no criterion 0-5 applies',
  '- .gaia/tests/hooks/spec-decision-prompts.bats:127 holistic/hollow-assertion: a heuristic doc lint over UX wording; a missed case leaves a free-text confirmation, which is workable and meets no criterion 0-5',
  '',
  '🤖 Generated with [Claude Code](https://claude.com/claude-code)',
].join('\n');

const ACCEPTED_BODY = [
  '## Accepted residuals (recorded, not fixed)',
  '',
  '- `frontend/app/utils/date.ts:7` Pre-existing and matches the repo-wide convention for module constants; folding it would rotate the frontend digest after the member cleared.. <!-- gaia-debt-key: v1 class=holistic/unclassified path=frontend/app/utils/date.ts line=7 -->',
  '- `frontend/app/utils/tests/date.test.ts:13` Pre-existing and matches the repo-wide SCREAMING_SNAKE convention; folding it would rotate the frontend digest after the member cleared.. <!-- gaia-debt-key: v1 class=holistic/unclassified path=frontend/app/utils/tests/date.test.ts line=13 -->',
  '',
  'Closes #2929',
  '',
  '🤖 Generated with [Claude Code](https://claude.com/claude-code)',
].join('\n');

const ghPrWithBody = (
  prNumber: number,
  body: unknown,
  comments: TallyComment[]
) => ({body, comments, number: prNumber});

const hooksFinding = (findingClass: string): BlockFinding => ({
  area_tags: ['.gaia/tests/hooks'],
  finding_class: findingClass,
  severity: 'minor',
});

const waivedPr = (prNumber: number, auditors: readonly string[] = ['local']) =>
  ghPrWithBody(
    prNumber,
    WAIVED_BODY,
    auditors.map((auditor) =>
      findingsComment(prNumber, auditor, [
        hooksFinding('holistic/drifting-duplicate'),
        hooksFinding('holistic/hollow-assertion'),
      ])
    )
  );

const WAIVED_PR_NUMBERS = [2817, 2807, 2800] as const;

const inventoryClasses = (printed: Record<string, unknown>): string[] =>
  (printed.class_inventory as {finding_class: string}[]).map(
    (entry) => entry.finding_class
  );

describe('codify-tally run: findings the PR body disposes of', () => {
  let sandbox: Sandbox;
  let stdout: ReturnType<typeof captureStdout>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdout = captureStdout();
  });

  afterEach(() => {
    stdout.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('requests each PR body in the same window read', () => {
    const ghSpy = vi.spyOn(runProcess, 'runGh').mockReturnValue(stubGh([]));

    run([], {cwd: sandbox.root, declines: noDeclines});

    expect(ghSpy).toHaveBeenCalledTimes(1);
    const args = ghSpy.mock.calls[0]?.[0] ?? [];
    const fields = (args[args.indexOf('--json') + 1] ?? '').split(',');

    expect(fields).toContain('body');
    expect(fields).toContain('comments');
  });

  test('a class waived on every PR it appears on is not counted, and the PRs stay audited', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(WAIVED_PR_NUMBERS.map((prNumber) => waivedPr(prNumber)))
    );

    run([], {cwd: sandbox.root, declines: noDeclines});

    const printed = parseStdout(stdout.out);

    expect(printed.candidate_count).toBe(0);
    expect(inventoryClasses(printed)).toEqual([]);
    expect(printed.audited_pr_count).toBe(3);
  });

  test('a waived class in no vocabulary is subtracted before it folds into unclassified', () => {
    const unknownClass = 'billing/double-charge';
    const waivedLine = `- .gaia/tests/hooks/billing.bats:9 ${unknownClass}: workable, meets no criterion`;
    const prWith = (prNumber: number, body: string) =>
      ghPrWithBody(prNumber, body, [
        findingsComment(prNumber, 'local', [hooksFinding(unknownClass)]),
      ]);

    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        WAIVED_PR_NUMBERS.map((prNumber) =>
          prWith(prNumber, '## Summary\n\n- Nothing waived.')
        )
      )
    );
    run([], {cwd: sandbox.root, declines: noDeclines});

    expect(parseStdout(stdout.out).unclassified_window_count).toBe(3);

    stdout.out.length = 0;
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        WAIVED_PR_NUMBERS.map((prNumber) =>
          prWith(
            prNumber,
            `## Waived below triage threshold (not filed)\n\n${waivedLine}\n`
          )
        )
      )
    );
    run([], {cwd: sandbox.root, declines: noDeclines});

    const printed = parseStdout(stdout.out);

    expect(printed.unclassified).toBeNull();
    expect(printed.unclassified_window_count).toBeNull();
    expect(printed.audited_pr_count).toBe(3);
  });

  test('the same findings under a body with no disposing section still count', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        WAIVED_PR_NUMBERS.map((prNumber) =>
          ghPrWithBody(
            prNumber,
            '## Summary\n\n- Nothing waived.',
            waivedPr(prNumber).comments
          )
        )
      )
    );

    run([], {cwd: sandbox.root, declines: noDeclines});

    const candidates = parseStdout(stdout.out).candidates as {
      distinct_pr_count: number;
      finding_class: string;
    }[];

    expect(
      candidates.map((candidate) => [
        candidate.finding_class,
        candidate.distinct_pr_count,
      ])
    ).toEqual([
      ['holistic/drifting-duplicate', 3],
      ['holistic/hollow-assertion', 3],
    ]);
  });

  test('a waive cancels the finding in every auditor block that reported it', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        WAIVED_PR_NUMBERS.map((prNumber) => waivedPr(prNumber, ['ci', 'local']))
      )
    );

    run([], {cwd: sandbox.root, declines: noDeclines});

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
  });

  test('a waive cancels one finding, so a second finding of the class still counts its PR', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        WAIVED_PR_NUMBERS.map((prNumber) =>
          ghPrWithBody(prNumber, WAIVED_BODY, [
            findingsComment(prNumber, 'local', [
              hooksFinding('holistic/drifting-duplicate'),
              hooksFinding('holistic/drifting-duplicate'),
            ]),
          ])
        )
      )
    );

    run([], {cwd: sandbox.root, declines: noDeclines});

    expect(parseStdout(stdout.out).candidate_count).toBe(1);
  });

  test('a waive whose directory matches no area tag cancels nothing', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        WAIVED_PR_NUMBERS.map((prNumber) =>
          ghPrWithBody(prNumber, WAIVED_BODY, [
            findingsComment(prNumber, 'local', [
              {
                area_tags: ['.gaia/scripts'],
                finding_class: 'holistic/drifting-duplicate',
                severity: 'minor',
              },
            ]),
          ])
        )
      )
    );

    run([], {cwd: sandbox.root, declines: noDeclines});

    expect(parseStdout(stdout.out).candidate_count).toBe(1);
  });

  test('accepted residuals cancel by their dedup key, leaving the unmatched finding counted', () => {
    // The block posted beside ACCEPTED_BODY: three classless findings, two of
    // them the accepted residuals.
    const utilsFinding: BlockFinding = {
      area_tags: ['frontend/app/utils'],
      finding_class: 'holistic/unclassified',
      severity: 'minor',
    };
    const testsFinding: BlockFinding = {
      area_tags: ['frontend/app/utils/tests'],
      finding_class: 'holistic/unclassified',
      severity: 'minor',
    };

    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPrWithBody(2931, ACCEPTED_BODY, [
          findingsComment(2931, 'local', [
            utilsFinding,
            utilsFinding,
            testsFinding,
          ]),
        ]),
        ghPrWithBody(2762, ACCEPTED_BODY, [
          findingsComment(2762, 'local', [utilsFinding, testsFinding]),
        ]),
        ghPrWithBody(2649, ACCEPTED_BODY, [
          findingsComment(2649, 'local', [utilsFinding, testsFinding]),
        ]),
      ])
    );

    run([], {cwd: sandbox.root, declines: noDeclines});

    const printed = parseStdout(stdout.out);

    expect(printed.unclassified).toBeNull();
    expect(printed.unclassified_window_count).toBe(1);
  });

  test('a body that is missing or not a string disposes of nothing', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        WAIVED_PR_NUMBERS.map((prNumber, index) => ({
          ...waivedPr(prNumber),
          body: index === 0 ? undefined : 42,
        }))
      )
    );

    run([], {cwd: sandbox.root, declines: noDeclines});

    expect(parseStdout(stdout.out).candidate_count).toBe(2);
  });
});

vi.mock('../decline-suppression.js', async (importOriginal) => {
  const original = await importOriginal<typeof DeclineSuppressionModule>();

  return {...original, loadDeclineSources: vi.fn(original.loadDeclineSources)};
});

const DECLINE_NOW = new Date('2026-10-27T12:00:00.000Z');
const LIVE_DECLINED_AT = '2026-10-20T00:00:00.000Z';
const FAR_GIT_DATE = '2001-01-01T00:00:00Z';

type CommittedDecline = {
  auditedCount?: number;
  count?: number;
  declinedAt?: string;
  findingClass: string;
  formatVersion?: number;
  name: string;
  schemaVersion?: number;
};

// Writes decline files into the sandbox's committed store and commits them.
// Commit and author dates are set far from `declined_at` to show the reader
// never consults them.
const commitDeclines = (root: string, declines: CommittedDecline[]): void => {
  const folder = path.join(root, '.gaia', 'codify-declines');

  mkdirSync(folder, {recursive: true});

  for (const decline of declines) {
    writeFileSync(
      path.join(folder, `${decline.name}.json`),
      `${JSON.stringify(
        {
          declined_at: decline.declinedAt ?? LIVE_DECLINED_AT,
          declined_at_audited_pr_count: decline.auditedCount ?? 3,
          declined_at_pr_count: decline.count ?? 3,
          finding_class: decline.findingClass,
          format_version: decline.formatVersion ?? 1,
          tally_schema_version: decline.schemaVersion ?? TALLY_SCHEMA_VERSION,
        },
        null,
        2
      )}\n`
    );
  }

  execFileSync('git', ['add', '-A'], {cwd: root, stdio: 'ignore'});
  execFileSync(
    'git',
    [
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@example.com',
      'commit',
      '-q',
      '-m',
      'merge',
    ],
    {
      cwd: root,
      env: {
        ...process.env,
        GIT_AUTHOR_DATE: FAR_GIT_DATE,
        GIT_COMMITTER_DATE: FAR_GIT_DATE,
      },
      stdio: 'ignore',
    }
  );
};

const legacyLedgerPath = (root: string): string =>
  path.join(root, '.gaia', 'local', 'codify', 'declines.json');

const legacyDecline = (
  findingClass: string,
  declinedAt = LIVE_DECLINED_AT
) => ({
  declined_at: declinedAt,
  declined_at_audited_pr_count: 3,
  declined_at_pr_count: 3,
  finding_class: findingClass,
  tally_schema_version: TALLY_SCHEMA_VERSION,
});

const writeLegacyLedger = (
  root: string,
  declines: ReturnType<typeof legacyDecline>[]
): string => {
  mkdirSync(path.dirname(legacyLedgerPath(root)), {recursive: true});
  const contents = `${JSON.stringify({declines, version: 2})}\n`;

  writeFileSync(legacyLedgerPath(root), contents);

  return contents;
};

const classFinding = (findingClass: string) => ({
  area_tags: [],
  finding_class: findingClass,
  severity: 'major',
});

// One PR per number, each carrying every named class.
const stubWindowWith = (
  prNumbers: readonly number[],
  classes: readonly string[]
): void => {
  vi.spyOn(runProcess, 'runGh').mockReturnValue(
    stubGh(
      prNumbers.map((n) =>
        ghPr(n, [findingsComment(n, 'ci', classes.map(classFinding))])
      )
    )
  );
};

const range = (count: number): number[] =>
  Array.from({length: count}, (_u, index) => index + 1);

const classesOf = (printed: Record<string, unknown>, key: string): string[] =>
  (printed[key] as {finding_class: string}[]).map(
    (entry) => entry.finding_class
  );

const X = 'rule/use-effect-derived-state';
const UNCLASSIFIED = 'holistic/unclassified';
// A decline of 3 is materially exceeded at 6 PRs, not at 4.
const BELOW_RISE = 4;
const MATERIAL_RISE = 6;

describe('codify-tally run: team declines', () => {
  let sandbox: Sandbox;
  let stdout: ReturnType<typeof captureStdout>;
  let stderrLines: string[];

  const runTally = (options: Parameters<typeof run>[1] = {}): number =>
    run([], {cwd: sandbox.root, now: () => DECLINE_NOW, ...options});

  const printedTally = (): Record<string, unknown> => parseStdout(stdout.out);

  beforeEach(async () => {
    sandbox = setupSandbox();
    stdout = captureStdout();
    stderrLines = [];
    execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: sandbox.root});
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
      stderrLines.push(String(chunk));

      return true;
    });
    const original = await vi.importActual<typeof DeclineSuppressionModule>(
      '../decline-suppression.js'
    );

    vi.mocked(loadDeclineSources)
      .mockReset()
      .mockImplementation(original.loadDeclineSources);
  });

  afterEach(() => {
    stdout.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('never writes the legacy ledger, even for a class absent from the window', () => {
    const before = `${JSON.stringify({
      declines: [legacyDecline('knip/exports')],
      version: 2,
    })}\n`;

    writeLegacyLedger(sandbox.root, [legacyDecline('knip/exports')]);
    stubWindowWith(range(3), [X]);

    expect(runTally()).toBe(0);

    expect(readFileSync(legacyLedgerPath(sandbox.root), 'utf8')).toBe(before);
  });

  test('a committed decline below a material rise moves the class to team_declined only', () => {
    commitDeclines(sandbox.root, [{findingClass: X, name: 'x-1'}]);
    stubWindowWith(range(BELOW_RISE), [X]);

    runTally();

    const printed = printedTally();
    expect(classesOf(printed, 'candidates')).toEqual([]);
    expect(classesOf(printed, 'team_declined')).toEqual([X]);
    expect(printed.candidate_count).toBe(0);
    expect(printed.class_inventory).toEqual([]);
    expect(printed.triggers).toEqual([]);
  });

  test('a committed decline stays out of the triggers against a snapshot that lacks the class', () => {
    commitDeclines(sandbox.root, [{findingClass: X, name: 'x-1'}]);
    stubWindowWith(range(BELOW_RISE), [X]);
    runTally();
    writeReviewSnapshot(
      sandbox.root,
      snapshotFromTally(
        ReviewTallyInputSchema.parse(printedTally()),
        REFERENCE_NOW
      )
    );

    stdout.out.length = 0;
    runTally();

    expect(printedTally().triggers).toEqual([]);
  });

  test('a material rise over the committed decline re-surfaces the class as a candidate', () => {
    commitDeclines(sandbox.root, [{findingClass: X, name: 'x-1'}]);
    stubWindowWith(range(MATERIAL_RISE), [X]);

    runTally();

    const printed = printedTally();
    expect(classesOf(printed, 'candidates')).toEqual([X]);
    expect(printed.team_declined).toEqual([]);
  });

  test('a committed decline from another tally schema version does not suppress', () => {
    commitDeclines(sandbox.root, [
      {findingClass: X, name: 'x-1', schemaVersion: TALLY_SCHEMA_VERSION - 1},
    ]);
    stubWindowWith(range(BELOW_RISE), [X]);

    runTally();

    expect(classesOf(printedTally(), 'candidates')).toEqual([X]);
  });

  test('a decline older than the window lifts the class and the unclassified signal', () => {
    commitDeclines(sandbox.root, [
      {declinedAt: '2026-07-29T11:59:59.000Z', findingClass: X, name: 'x-1'},
      {
        declinedAt: '2026-07-29T11:59:59.000Z',
        findingClass: UNCLASSIFIED,
        name: 'u-1',
      },
    ]);
    stubWindowWith(range(3), [X, UNCLASSIFIED]);

    runTally();

    const printed = printedTally();
    expect(classesOf(printed, 'candidates')).toEqual([X]);
    expect(printed.unclassified).not.toBeNull();
  });

  test('the same declines one day inside the window suppress both', () => {
    commitDeclines(sandbox.root, [
      {declinedAt: '2026-07-30T12:00:00.000Z', findingClass: X, name: 'x-1'},
      {
        declinedAt: '2026-07-30T12:00:00.000Z',
        findingClass: UNCLASSIFIED,
        name: 'u-1',
      },
    ]);
    stubWindowWith(range(3), [X, UNCLASSIFIED]);

    runTally();

    const printed = printedTally();
    expect(classesOf(printed, 'candidates')).toEqual([]);
    expect(classesOf(printed, 'team_declined')).toEqual([X]);
    expect(printed.unclassified).toBeNull();
  });

  test('a live unclassified decline lifts on a material rise of the classless cluster', () => {
    commitDeclines(sandbox.root, [{findingClass: UNCLASSIFIED, name: 'u-1'}]);
    stubWindowWith(range(MATERIAL_RISE), [UNCLASSIFIED]);

    runTally();

    expect(printedTally().unclassified).not.toBeNull();
  });

  test('a live committed decline suppresses however long the class has recurred', () => {
    commitDeclines(sandbox.root, [
      {declinedAt: '2026-08-01T00:00:00.000Z', findingClass: X, name: 'x-1'},
    ]);
    stubWindowWith(range(BELOW_RISE), [X]);

    runTally();

    const printed = printedTally();
    expect(classesOf(printed, 'candidates')).toEqual([]);
    expect(classesOf(printed, 'team_declined')).toEqual([X]);
  });

  test('a legacy-only decline within the window suppresses and leaves the file untouched', () => {
    const before = writeLegacyLedger(sandbox.root, [legacyDecline(X)]);
    stubWindowWith(range(BELOW_RISE), [X]);

    runTally();

    const printed = printedTally();
    expect(classesOf(printed, 'candidates')).toEqual([]);
    expect(classesOf(printed, 'team_declined')).toEqual([X]);
    expect(readFileSync(legacyLedgerPath(sandbox.root), 'utf8')).toBe(before);
  });

  test('a legacy entry older than the window suppresses nothing and the file is untouched', () => {
    const before = writeLegacyLedger(sandbox.root, [
      legacyDecline(X, '2026-07-01T00:00:00.000Z'),
    ]);
    stubWindowWith(range(BELOW_RISE), [X]);

    runTally();

    expect(classesOf(printedTally(), 'candidates')).toEqual([X]);
    expect(readFileSync(legacyLedgerPath(sandbox.root), 'utf8')).toBe(before);
  });

  test('with no legacy ledger and no store the run prints nothing to stderr', () => {
    stubWindowWith(range(BELOW_RISE), [X]);

    expect(runTally()).toBe(0);

    expect(stderrLines).toEqual([]);
  });

  test('reports each skipped decline file and still applies the valid ones', () => {
    commitDeclines(sandbox.root, [
      {findingClass: 'rule/switch-statement', name: 'y-1'},
      {findingClass: X, formatVersion: 9, name: 'x-v9'},
    ]);
    writeFileSync(
      path.join(sandbox.root, '.gaia', 'codify-declines', 'x-bad.json'),
      '{not json'
    );
    stubWindowWith(range(BELOW_RISE), [X, 'rule/switch-statement']);

    expect(runTally()).toBe(0);

    const printed = printedTally();
    expect(classesOf(printed, 'candidates')).toEqual([X]);
    expect(classesOf(printed, 'team_declined')).toEqual([
      'rule/switch-statement',
    ]);
    const reports = stderrLines.map(
      (line) => JSON.parse(line) as Record<string, unknown>
    );
    expect(reports.map((report) => report.code)).toEqual([
      'skipped_decline_file',
      'skipped_decline_file',
    ]);
    expect(reports.map((report) => report.path)).toEqual(
      expect.arrayContaining([
        '.gaia/codify-declines/x-bad.json',
        '.gaia/codify-declines/x-v9.json',
      ])
    );
    expect(
      reports.every((report) => report.subcommand === 'codify-tally')
    ).toBe(true);
  });

  test('a malformed legacy ledger yields one report and suppresses nothing', () => {
    mkdirSync(path.dirname(legacyLedgerPath(sandbox.root)), {recursive: true});
    writeFileSync(legacyLedgerPath(sandbox.root), '{not json');
    stubWindowWith(range(BELOW_RISE), [X]);

    runTally();

    expect(classesOf(printedTally(), 'candidates')).toEqual([X]);
    const reports = stderrLines.map(
      (line) => JSON.parse(line) as Record<string, unknown>
    );
    expect(reports).toHaveLength(1);
    expect(reports[0]?.code).toBe('malformed_decline_ledger');
  });

  test('a promoted rule marker wins over a committed decline', () => {
    commitDeclines(sandbox.root, [{findingClass: X, name: 'x-1'}]);
    stubWindowWith(range(BELOW_RISE), [X]);

    runTally();
    expect(classesOf(printedTally(), 'team_declined')).toEqual([X]);

    mkdirSync(sandbox.rulesDir, {recursive: true});
    writeFileSync(
      path.join(sandbox.rulesDir, 'promoted.md'),
      `${markerComment(X)}\n`
    );
    stdout.out.length = 0;
    runTally();

    const printed = printedTally();
    expect(classesOf(printed, 'candidates')).toEqual([]);
    expect(classesOf(printed, 'team_declined')).toEqual([]);
  });

  test('a clone whose checkout lacks the decline file still sees a candidate, silenced by the snapshot', () => {
    stubWindowWith(range(BELOW_RISE), [X]);
    runTally();
    const first = ReviewTallyInputSchema.parse(printedTally());

    writeReviewSnapshot(sandbox.root, snapshotFromTally(first, REFERENCE_NOW));
    stdout.out.length = 0;
    runTally();

    const printed = printedTally();
    expect(classesOf(printed, 'candidates')).toEqual([X]);
    expect(printed.triggers).toEqual([]);
  });

  test('loads the decline sources once for a run with several at-threshold classes', () => {
    stubWindowWith(range(3), ['rule/a', 'rule/b', 'rule/c']);

    runTally();

    expect(loadDeclineSources).toHaveBeenCalledTimes(1);
  });

  test('the injected clock drives the window start and the decline lapse', () => {
    const ghSpy = vi.spyOn(runProcess, 'runGh').mockReturnValue(stubGh([]));

    runTally();

    const args = ghSpy.mock.calls[0]?.[0] ?? [];
    expect(args[args.indexOf('--search') + 1]).toBe(
      'merged:>=2026-07-29 sort:created-desc'
    );
    expect(loadDeclineSources).toHaveBeenCalledWith(
      expect.objectContaining({now: DECLINE_NOW, windowDays: 90})
    );
  });
});
