import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {
  checkStrippedPair,
  findMemberOnlyLeftovers,
  stripPnpmMember,
  stripPnpmMemberUnchecked,
} from './pnpm-member-strip.js';
import type {PnpmMemberStripOutcome, PrunePolicy} from './pnpm-member-strip.js';

const MEMBER = '.gaia/cli';
const FIXTURE_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../test-fixtures/pnpm-member-strip'
);
const GOLDEN_CASES = ['synthetic', 'repo-fold'] as const;

const readFixture = (caseName: string, fileName: string): string =>
  readFileSync(path.join(FIXTURE_ROOT, caseName, fileName), 'utf8');

const inputFor = (caseName: string) => ({
  lockfile: readFixture(caseName, 'input.lock.fixture.yaml'),
  member: MEMBER,
  workspace: readFixture(caseName, 'input.workspace.fixture.yaml'),
});

const expectStripped = (outcome: PnpmMemberStripOutcome) => {
  if (outcome.kind !== 'stripped') {
    throw new Error(`expected stripped, got ${JSON.stringify(outcome)}`);
  }

  return outcome;
};

// Everything up to and including the second `---` line: the
// packageManagerDependencies document.
const firstDocument = (lockfile: string): string =>
  lockfile.slice(0, lockfile.indexOf('\n---\n') + '\n---\n'.length);

const snapshotBlock = (lockfile: string, key: string): string => {
  const start = lockfile.indexOf(`\n\n  ${key}:`);
  const end = lockfile.indexOf('\n\n', start + 2);

  return end === -1 ? lockfile.slice(start) : lockfile.slice(start, end);
};

describe('stripPnpmMember golden pairs', () => {
  test.each(GOLDEN_CASES)(
    '%s strips to the pair pnpm writes without the member',
    (caseName) => {
      const input = inputFor(caseName);
      const outcome = expectStripped(stripPnpmMember(input));

      expect(outcome.lockfile).toBe(
        readFixture(caseName, 'expected.lock.fixture.yaml')
      );
      expect(outcome.workspace).toBe(
        readFixture(caseName, 'expected.workspace.fixture.yaml')
      );
      expect(firstDocument(outcome.lockfile)).toBe(
        firstDocument(input.lockfile)
      );
    }
  );

  test('the synthetic case drops only entries the member alone reaches', () => {
    const outcome = expectStripped(stripPnpmMember(inputFor('synthetic')));

    expect(outcome.removed.importers).toEqual([MEMBER]);
    // Shared with frontend: survives.
    expect(outcome.removed.snapshots).not.toContain('ms@2.1.3');
    // Two versions, one member-only: only the member's goes.
    expect(outcome.removed.snapshots).toContain('semver@6.3.1');
    expect(outcome.removed.snapshots).not.toContain('semver@7.6.0');
    // Member-only package whose own dependency is shared.
    expect(outcome.removed.packages).toContain('debug@4.4.0');
    // Member-only peer variant of a frontend package: the snapshot goes,
    // the packages entry stays.
    expect(outcome.removed.snapshots).toContain(
      'use-sync-external-store@1.2.2(react@17.0.2)'
    );
    expect(outcome.removed.packages).not.toContain(
      'use-sync-external-store@1.2.2'
    );
    // Alias edges: the alias-only target goes, the alias target frontend
    // also depends on directly survives.
    expect(outcome.removed.snapshots).toContain('string-width@4.2.3');
    expect(outcome.removed.snapshots).not.toContain('strip-ansi@6.0.1');
  });
});

describe('stripPnpmMember refusals', () => {
  type StripInput = ReturnType<typeof inputFor>;

  // `detail` is the part of the refusal text that names the cause: which
  // document carries the version, or which snapshot id is absent. An empty
  // string only asserts that a detail string exists.
  const synthetic = inputFor('synthetic');

  test.each<{
    detail: string;
    file: string;
    input: () => StripInput;
    name: string;
    token: string;
  }>([
    {
      detail: 'document 1',
      file: 'lockfile',
      input: () => inputFor('unknown-version-document-1'),
      name: 'unknown-version-document-1 refuses naming the lockfile with unknown-lockfile-version',
      token: 'unknown-lockfile-version',
    },
    {
      detail: 'document 2',
      file: 'lockfile',
      input: () => inputFor('unknown-version-document-2'),
      name: 'unknown-version-document-2 refuses naming the lockfile with unknown-lockfile-version',
      token: 'unknown-lockfile-version',
    },
    {
      detail: '',
      file: 'workspace',
      input: () => inputFor('member-without-importer'),
      name: 'member-without-importer refuses naming the workspace with member-without-importer',
      token: 'member-without-importer',
    },
    {
      detail: '',
      file: 'lockfile',
      input: () => inputFor('importer-without-member'),
      name: 'importer-without-member refuses naming the lockfile with importer-without-member',
      token: 'importer-without-member',
    },
    {
      detail: 'debug@4.4.0',
      file: 'lockfile',
      input: () => inputFor('missing-snapshot'),
      name: 'missing-snapshot refuses naming the lockfile with missing-snapshot',
      token: 'missing-snapshot',
    },
    {
      detail: '',
      file: 'lockfile',
      input: () => ({
        ...synthetic,
        lockfile: synthetic.lockfile.slice(
          firstDocument(synthetic.lockfile).length
        ),
      }),
      name: 'a lockfile that is not two documents is unparseable',
      token: 'unparseable',
    },
    {
      detail: '',
      file: 'workspace',
      input: () => ({
        ...synthetic,
        workspace: `packages: [frontend, ${MEMBER}]\n`,
      }),
      name: 'a flow-style packages list the line locator cannot edit is unparseable',
      token: 'unparseable',
    },
  ])('$name', ({detail, file, input, token}) => {
    expect(stripPnpmMember(input())).toMatchObject({
      detail: expect.stringContaining(detail),
      file,
      kind: 'refused',
      token,
    });
  });
});

describe('stripPnpmMember no-op', () => {
  test('neither the member nor its importer present returns noop', () => {
    expect(stripPnpmMember(inputFor('noop'))).toEqual({kind: 'noop'});
  });
});

describe('workspace member matching', () => {
  test.each([
    `  - '${MEMBER}'`,
    `  - "${MEMBER}"`,
    `  - ${MEMBER} # maintainer-only member`,
    `- ${MEMBER}`,
  ])('matches the member spelled %s by its parsed value', (memberLine) => {
    const input = inputFor('synthetic');
    const indent = memberLine.startsWith('-') ? '' : '  ';
    const workspace = `packages:\n${indent}- frontend\n${memberLine}\n\nstrictPeerDependencies: false\n`;
    const outcome = expectStripped(stripPnpmMember({...input, workspace}));

    expect(outcome.workspace).toBe(
      `packages:\n${indent}- frontend\n\nstrictPeerDependencies: false\n`
    );
  });
});

describe('findMemberOnlyLeftovers', () => {
  const input = inputFor('synthetic');
  const expected = readFixture('synthetic', 'expected.lock.fixture.yaml');

  const variant = 'use-sync-external-store@1.2.2(react@17.0.2)';

  test.each<{after: string; expected: string[]; name: string}>([
    {
      after: expected,
      expected: [],
      name: 'a correct strip leaves nothing behind',
    },
    {
      after: `${expected}${snapshotBlock(input.lockfile, variant)}\n`,
      expected: [`snapshots[${variant}]`],
      name: 'names a member-only snapshot that survived',
    },
  ])('$name', ({after, expected: leftovers}) => {
    expect(
      findMemberOnlyLeftovers({
        after,
        before: input.lockfile,
        member: MEMBER,
      })
    ).toEqual(leftovers);
  });
});

describe('checkStrippedPair', () => {
  const input = inputFor('synthetic');
  const good = expectStripped(stripPnpmMember(input));

  test('accepts the correct strip', () => {
    expect(checkStrippedPair(input, good)).toBeNull();
  });

  const memberOnlyVariant = 'use-sync-external-store@1.2.2(react@17.0.2)';

  test.each<{
    mutate: () => typeof good;
    name: string;
    refusal: Record<string, unknown>;
  }>([
    {
      mutate: () => ({
        ...good,
        lockfile: `${good.lockfile}${snapshotBlock(input.lockfile, memberOnlyVariant)}\n`,
      }),
      name: 'refuses a pair that keeps a member-only snapshot',
      refusal: {
        detail: expect.stringContaining(memberOnlyVariant),
        token: 'cli-only-key-survives',
      },
    },
    {
      mutate: () => ({
        ...good,
        lockfile: good.lockfile.replace(
          snapshotBlock(good.lockfile, 'ms@2.1.3'),
          ''
        ),
      }),
      name: 'refuses a pair that drops a shared snapshot',
      refusal: {
        detail: expect.stringContaining('ms@2.1.3'),
        token: 'integrity',
      },
    },
    {
      // The first `hasBin` belongs to pnpm's own entry in document 1.
      mutate: () => ({
        ...good,
        lockfile: good.lockfile.replace('hasBin: true', 'hasBin: false'),
      }),
      name: 'refuses a pair whose packageManagerDependencies document changed',
      refusal: {token: 'integrity'},
    },
    {
      mutate: () => ({...good, workspace: input.workspace}),
      name: 'refuses a workspace that still lists the member',
      refusal: {file: 'workspace', token: 'integrity'},
    },
  ])('$name', ({mutate, refusal}) => {
    expect(checkStrippedPair(input, mutate())).toMatchObject(refusal);
  });
});

// Drops every snapshot no remaining importer reaches, pnpm's orphans
// included.
const pruneEverythingUnreachable: PrunePolicy = ({restReach, snapshotIds}) =>
  new Set(snapshotIds.filter((id) => !restReach.has(id)));

// Drops every snapshot whose package the member importer names, shared or
// not.
const pruneEveryMemberNamedPackage: PrunePolicy = ({
  memberDependencyNames,
  snapshotIds,
}) =>
  new Set(
    snapshotIds.filter((id) => {
      const base = id.split('(', 1)[0] as string;

      return memberDependencyNames.has(base.slice(0, base.lastIndexOf('@')));
    })
  );

const differsOnSomeGoldenCase = (policy: PrunePolicy): boolean =>
  GOLDEN_CASES.some((caseName) => {
    const outcome = stripPnpmMemberUnchecked(inputFor(caseName), policy);

    return (
      outcome.kind !== 'stripped' ||
      outcome.lockfile !== readFixture(caseName, 'expected.lock.fixture.yaml')
    );
  });

describe('golden fixtures reject a wrong prune', () => {
  test.each([
    ['prune everything unreachable', pruneEverythingUnreachable],
    [
      'drop every package the member importer names',
      pruneEveryMemberNamedPackage,
    ],
  ])('%s differs from the expected output', (_, policy) => {
    expect(differsOnSomeGoldenCase(policy)).toBe(true);
  });

  test('the repository fold carries an orphan snapshot pnpm keeps', () => {
    const outcome = stripPnpmMemberUnchecked(
      inputFor('repo-fold'),
      pruneEverythingUnreachable
    );

    expect(expectStripped(outcome).lockfile).not.toBe(
      readFixture('repo-fold', 'expected.lock.fixture.yaml')
    );
  });
});
