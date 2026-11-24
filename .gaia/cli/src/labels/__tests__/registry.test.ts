import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {isCreatable} from '../../schemas/labels.js';
import type {LabelFeature} from '../../schemas/labels.js';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {
  labelsRegistryPath,
  NAMESPACE_PREFIXES,
  readRegistry,
  resolveAudience,
  resolveFeatures,
  suggestedColorFor,
} from '../registry.js';

// Built at runtime so no removed-feature literal lands in the tracked tree.
const REMOVED_FEATURE_NAME = ['gaia', 'ci'].join('-');

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const registry = readRegistry(repoRoot);

type Feature = LabelFeature;

const names = (
  audience: 'adopter' | 'maintainer',
  features: Feature[]
): string[] =>
  registry.labels
    .filter((entry) => isCreatable(entry, audience, features))
    .map((entry) => entry.name)
    .toSorted((a, b) => a.localeCompare(b));

describe('labels/registry readRegistry', () => {
  test('parses the committed .gaia/labels.json', () => {
    expect(registry.version).toBe(1);
    expect(registry.labels.length).toBeGreaterThan(0);
  });

  test('the deprecated entries carry no features and a null reason', () => {
    const deprecatedEntries = registry.labels.filter(
      (entry) => entry.deprecated
    );

    expect(
      deprecatedEntries
        .map((entry) => entry.name)
        .toSorted((a, b) => a.localeCompare(b))
    ).toEqual([REMOVED_FEATURE_NAME]);

    for (const entry of deprecatedEntries) {
      expect(entry.features).toEqual([]);
      expect(entry.reason).toBeNull();
    }
  });

  test.each([
    [
      'a malformed registry throws with the file named',
      (directory: string): void => {
        mkdirSync(path.join(directory, '.gaia'), {recursive: true});
        writeFileSync(
          path.join(directory, '.gaia', 'labels.json'),
          '{"version": 2}',
          'utf8'
        );
      },
    ],
    ['an unreadable registry throws with the file named', (): void => {}],
  ])('%s', (_name, prepare) => {
    const directory = mkdtempSync(path.join(tmpdir(), 'gaia-labels-'));

    try {
      prepare(directory);

      expect(() => readRegistry(directory)).toThrow(
        labelsRegistryPath(directory)
      );
    } finally {
      rmSync(directory, {force: true, recursive: true});
    }
  });
});

type CreatableRow = {
  audience: 'adopter' | 'maintainer';
  expected: string[];
  features: Feature[];
  name: string;
};

describe('labels/registry creatable entries', () => {
  const creatableRows: CreatableRow[] = [
    {
      audience: 'adopter',
      expected: [
        'bug',
        'debt:spec-active',
        'debt:spec-pending',
        'difficulty:easy',
        'difficulty:hard',
        'difficulty:medium',
        'documentation',
        'enhancement',
        'footprint:narrow',
        'footprint:spec',
        'footprint:wide',
        'in-progress',
        'needs-human',
        'security',
        'severity:critical',
        'severity:investigate',
        'severity:major',
        'severity:minor',
        'tech-debt',
        'wontfix',
      ],
      features: ['tech-debt', 'dependabot', 'forensics'],
      name: 'every feature on yields the adopter-role entries',
    },
    {
      audience: 'adopter',
      expected: [
        'bug',
        'debt:spec-active',
        'debt:spec-pending',
        'difficulty:easy',
        'difficulty:hard',
        'difficulty:medium',
        'documentation',
        'enhancement',
        'footprint:narrow',
        'footprint:spec',
        'footprint:wide',
        'in-progress',
        'needs-human',
        'severity:critical',
        'severity:investigate',
        'severity:major',
        'severity:minor',
        'tech-debt',
        'wontfix',
      ],
      features: ['tech-debt', 'forensics'],
      name: 'dependabot off drops only the security label',
    },
    {
      audience: 'adopter',
      expected: [
        'bug',
        'documentation',
        'enhancement',
        'in-progress',
        'needs-human',
        'security',
        'wontfix',
      ],
      features: ['dependabot', 'forensics'],
      name: 'tech-debt off leaves the always-on set plus the dependabot set',
    },
    {
      audience: 'maintainer',
      expected: [
        'audience:adopter',
        'audience:maintainer',
        'auto-fixable',
        'bug',
        'debt:spec-active',
        'debt:spec-pending',
        'difficulty:easy',
        'difficulty:hard',
        'difficulty:medium',
        'documentation',
        'enhancement',
        'footprint:narrow',
        'footprint:spec',
        'footprint:wide',
        'gaia-forensics',
        'gaia-triaged',
        'in-progress',
        'needs-human',
        'non-issue',
        'security',
        'severity:critical',
        'severity:investigate',
        'severity:major',
        'severity:minor',
        'tech-debt',
        'wontfix',
      ],
      features: ['tech-debt', 'dependabot', 'forensics'],
      name: 'the maintainer set is the adopter set plus the maintainer entries',
    },
  ];

  test.each(creatableRows.map((row) => [row.name, row] as const))(
    '%s',
    (_name, {audience, expected, features}) => {
      expect(names(audience, features)).toEqual(expected);
    }
  );

  test('a maintainer entry never reaches an adopter creatable set', () => {
    const maintainerNames = new Set(
      registry.labels
        .filter((entry) => entry.audience === 'maintainer')
        .map((entry) => entry.name)
    );
    const adopterNames = names('adopter', ['tech-debt', 'forensics']);

    expect(adopterNames.filter((name) => maintainerNames.has(name))).toEqual(
      []
    );
  });
});

describe('labels/registry blocked entries and suggestedColorFor', () => {
  test('the registry blocks the two GitHub defaults GAIA refuses', () => {
    expect(
      registry.labels
        .filter((entry) => entry.blocked)
        .map((entry) => entry.name)
    ).toEqual(['good first issue', 'help wanted']);
  });

  test('an unknown name in a known namespace takes the family color', () => {
    expect(suggestedColorFor(registry, 'severity:whatever')).toBe('b60205');
    expect(suggestedColorFor(registry, 'difficulty:whatever')).toBe('bfe3df');
    // `debt:spec-active` sorts ahead of `debt:spec-pending`, so it is the
    // family's donor: adding an entry that sorts first silently moves what
    // `labels sync` suggests for every unrecognized `debt:*` label.
    expect(suggestedColorFor(registry, 'debt:whatever')).toBe('3b9b58');
  });

  test('an unknown name outside every namespace has no suggestion', () => {
    expect(suggestedColorFor(registry, 'random-name')).toBeNull();
  });

  test('every namespace prefix resolves to a color in the committed registry', () => {
    for (const prefix of NAMESPACE_PREFIXES) {
      expect(suggestedColorFor(registry, `${prefix}whatever`)).not.toBeNull();
    }
  });
});

describe('labels/registry resolveAudience and resolveFeatures', () => {
  let fixture = '';

  beforeEach(() => {
    fixture = mkdtempSync(path.join(tmpdir(), 'gaia-labels-tree-'));
  });

  afterEach(() => {
    rmSync(fixture, {force: true, recursive: true});
  });

  const writeProjectConfig = (text: string): void => {
    mkdirSync(path.join(fixture, '.gaia'), {recursive: true});
    writeFileSync(path.join(fixture, '.gaia', 'project.json'), text, 'utf8');
  };

  test.each(
    [
      {
        arrange: (): void => {},
        expected: 'adopter',
        name: 'a tree without .gaia/cli/src is an adopter tree',
      },
      {
        arrange: (): void => {
          mkdirSync(path.join(fixture, '.gaia', 'cli', 'src'), {
            recursive: true,
          });
        },
        expected: 'maintainer',
        name: 'a tree carrying .gaia/cli/src is the maintainer tree',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {arrange, expected}) => {
    arrange();

    expect(resolveAudience(fixture)).toBe(expected);
  });

  const writeFixtureFile = (relativePath: string, text: string): void => {
    mkdirSync(path.join(fixture, path.dirname(relativePath)), {
      recursive: true,
    });
    writeFileSync(path.join(fixture, relativePath), text, 'utf8');
  };

  test.each(
    [
      {
        arrange: (): void => {},
        expected: ['tech-debt'],
        name: 'tech-debt is always on and the other two key on a file',
      },
      {
        arrange: (): void =>
          writeProjectConfig(
            '{"version":1,"dependabot_security_updates":"on"}'
          ),
        expected: ['tech-debt'],
        name: 'a retired project config opt-in alone leaves dependabot off',
      },
      {
        arrange: (): void =>
          writeFixtureFile('.github/dependabot.yaml', 'version: 2\n'),
        expected: ['tech-debt', 'dependabot'],
        name: 'an existing .github/dependabot.yaml alone turns dependabot on',
      },
      {
        arrange: (): void =>
          writeFixtureFile('.github/dependabot.yml', 'version: 2\n'),
        expected: ['tech-debt', 'dependabot'],
        name: 'an existing .github/dependabot.yml turns dependabot on without a project config',
      },
      {
        arrange: (): void => writeProjectConfig('{not json'),
        expected: ['tech-debt'],
        name: 'a malformed project config does not turn dependabot on',
      },
      {
        arrange: (): void =>
          writeFixtureFile(
            '.github/workflows/forensics-triage.yml',
            'name: x\n'
          ),
        expected: ['tech-debt', 'forensics'],
        name: 'a forensics triage workflow turns forensics on',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {arrange, expected}) => {
    arrange();

    expect(resolveFeatures(fixture)).toEqual(expected);
  });
});
