import {afterEach, describe, expect, test} from 'vitest';
import {runCheck} from '../check.js';
import {
  createScratchProject,
  expectFixtureParity,
  FIXTURE_PARITY_TIMEOUT_MS,
} from '../test-support.js';
import type {Finding, FixtureProject} from '../types.js';
import {filler} from './authoring.fixtures.js';
import {
  ceilingsText,
  LINE_LIMIT_FIXTURES,
  maintainerProject,
  SCRIPT_PATH,
} from './line-limit.fixtures.js';
import {CEILINGS_PATH, LINE_LIMIT_RULES} from './line-limit.js';

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

const findingsOf = (project: FixtureProject): readonly Finding[] => {
  const scratch = createScratchProject({...project, git: true});

  cleanups.push(scratch.cleanup);

  return runCheck({
    catalog: LINE_LIMIT_RULES,
    env: scratch.env,
    root: scratch.root,
    scope: 'all',
  }).findings;
};

const summaryOf = (project: FixtureProject): string[] =>
  findingsOf(project).map(
    (finding) => `${finding.severity} ${finding.rule_id} ${finding.file}`
  );

const MAX = 'authoring.harness.max-lines';
const STALE = 'authoring.harness.ceiling-stale';

describe('line-limit rules', () => {
  test(
    'every rule has a red and a green fixture',
    () => {
      expectFixtureParity(LINE_LIMIT_RULES, LINE_LIMIT_FIXTURES);
    },
    FIXTURE_PARITY_TIMEOUT_MS
  );

  test('a new file over the limit is an error that names the limit', () => {
    const [finding] = findingsOf(
      maintainerProject({[SCRIPT_PATH]: filler(401)}, {})
    );

    expect(finding).toMatchObject({
      file: SCRIPT_PATH,
      rule_id: MAX,
      severity: 'error',
    });
    expect(finding?.message).toContain('401 lines');
    expect(finding?.message).toContain('400');
  });

  test('a file at the limit passes', () => {
    expect(
      summaryOf(maintainerProject({[SCRIPT_PATH]: filler(400)}, {}))
    ).toEqual([]);
  });

  test('a grandfathered file at or under its ceiling passes', () => {
    expect(
      summaryOf(
        maintainerProject({[SCRIPT_PATH]: filler(450)}, {[SCRIPT_PATH]: 450})
      )
    ).toEqual([]);
    expect(
      summaryOf(
        maintainerProject({[SCRIPT_PATH]: filler(420)}, {[SCRIPT_PATH]: 450})
      )
    ).toEqual([]);
  });

  test('a grandfathered file grown by one line fails and prints the bump', () => {
    const [finding, ...rest] = findingsOf(
      maintainerProject({[SCRIPT_PATH]: filler(451)}, {[SCRIPT_PATH]: 450})
    );

    expect(rest).toEqual([]);
    expect(finding).toMatchObject({
      file: SCRIPT_PATH,
      rule_id: MAX,
      severity: 'error',
    });
    expect(finding?.message).toContain('ceiling of 450');
    expect(finding?.remediation).toContain(`"${SCRIPT_PATH}": 451`);
  });

  test('a file shrunk to the limit passes, leaving a stale-entry warning', () => {
    expect(
      summaryOf(
        maintainerProject({[SCRIPT_PATH]: filler(400)}, {[SCRIPT_PATH]: 450})
      )
    ).toEqual([`warning ${STALE} ${CEILINGS_PATH}`]);
  });

  test('an entry for a file that no longer exists is a stale-entry warning', () => {
    expect(
      summaryOf(maintainerProject({}, {'.gaia/scripts/gone.sh': 450}))
    ).toEqual([`warning ${STALE} ${CEILINGS_PATH}`]);
  });

  test('without the maintainer marker nothing runs', () => {
    expect(summaryOf({files: {[SCRIPT_PATH]: filler(900)}})).toEqual([]);
  });

  test('in a maintainer repo with no ceilings file every offender fails', () => {
    expect(summaryOf(maintainerProject({[SCRIPT_PATH]: filler(401)}))).toEqual([
      `error ${MAX} ${SCRIPT_PATH}`,
    ]);
  });

  test('an unusable ceilings file is an error and grandfathers nothing', () => {
    const project = maintainerProject({[SCRIPT_PATH]: filler(401)});
    const files = {...project.files, [CEILINGS_PATH]: '{ not json'};

    expect(summaryOf({files})).toEqual([
      `error ${MAX} ${CEILINGS_PATH}`,
      `error ${MAX} ${SCRIPT_PATH}`,
    ]);
    expect(findingsOf({files})[0]?.message).toContain('is not JSON');
  });

  test('a ceilings file with no ceilings object is an error', () => {
    const project = maintainerProject({[SCRIPT_PATH]: filler(401)});
    const files = {...project.files, [CEILINGS_PATH]: '[]\n'};

    expect(findingsOf({files})[0]?.message).toContain(
      'has no "ceilings" object'
    );
  });

  test('a ceiling that is not a positive whole number is an error', () => {
    const project = maintainerProject({[SCRIPT_PATH]: filler(401)});
    const files = {
      ...project.files,
      [CEILINGS_PATH]: ceilingsText({[SCRIPT_PATH]: '401'}),
    };

    expect(summaryOf({files})).toEqual([
      `error ${MAX} ${CEILINGS_PATH}`,
      `error ${MAX} ${SCRIPT_PATH}`,
    ]);
  });

  test.each([
    '.claude/hooks/big.sh',
    '.gaia/cli/src/example/big.ts',
    '.gaia/scripts/big.mjs',
    '.github/audit/big.sh',
    '.github/workflows/big.yml',
    '.github/actions/example/action.yml',
  ])('%s is in scope', (file) => {
    expect(summaryOf(maintainerProject({[file]: filler(401)}, {}))).toEqual([
      `error ${MAX} ${file}`,
    ]);
  });

  test.each([
    '.gaia/tests/lib/big.sh',
    '.gaia/tests/lib/big.bats',
    '.gaia/cli/src/example/big.test.ts',
    '.gaia/cli/src/example/__tests__/big.ts',
    '.gaia/cli/src/example/big.fixtures.ts',
    '.gaia/cli/src/example/big-fixture.ts',
    '.gaia/cli/src/example/fixtures.ts',
    '.gaia/cli/src/example/test-support.ts',
    '.gaia/cli/test-fixtures/example/big.ts',
    '.gaia/cli/gaia',
    '.gaia/state-registry.json',
    '.gaia/release-scrub.yml',
    '.github/ISSUE_TEMPLATE/big.yml',
    '.claude/skills/example/SKILL.md',
    'frontend/app/big.ts',
    'scripts/big.sh',
  ])('%s is out of scope', (file) => {
    expect(summaryOf(maintainerProject({[file]: filler(401)}, {}))).toEqual([]);
  });
});
