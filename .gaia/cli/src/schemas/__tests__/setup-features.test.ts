import {describe, expect, test} from 'vitest';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {SetupFeatureSchema, SetupFeaturesSchema} from '../setup-features.js';
import type {SetupFeature} from '../setup-features.js';

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);

// The set that shipped first. Every id outside it must declare `standalone`.
const FROZEN_IDS = [
  'install-tools',
  'install-plugins',
  'chmod-statusline',
  'bootstrap-env',
  'sandbox',
  'statusline-left',
  'github-repository',
  'push-protection',
  'branch-protection',
  'gaia-audit-check',
  'delete-branch-on-merge',
  'dependabot-posture',
  'squash-only',
  'label-sync',
  'isolation-policy',
  'sandbox-recommendation',
] as const;

const baseFeature: SetupFeature = {
  admin: false,
  id: 'example-feature',
  reference: '.claude/commands/setup-gaia.md',
  required: false,
  scope: 'project',
  standalone: true,
};

const listOf = (features: unknown[]): unknown => ({
  description: 'A valid description',
  features,
  version: 1,
});

/** Ids that are not in the frozen set yet declare `standalone: false`. */
const nonStandaloneNewIds = (features: readonly SetupFeature[]): string[] =>
  features
    .filter(
      (feature) =>
        !(FROZEN_IDS as readonly string[]).includes(feature.id) &&
        !feature.standalone
    )
    .map((feature) => feature.id);

const committed = SetupFeaturesSchema.parse(
  JSON.parse(
    readFileSync(path.join(repoRoot, '.gaia/setup-features.json'), 'utf8')
  )
);

describe('committed .gaia/setup-features.json', () => {
  test('holds the frozen ids in order', () => {
    expect(committed.features.map((feature) => feature.id)).toEqual([
      ...FROZEN_IDS,
    ]);
  });

  test.each(
    committed.features.map((feature) => [feature.id, feature] as const)
  )('%s declares every field and a reference that exists', (_id, feature) => {
    expect(SetupFeatureSchema.safeParse(feature).success).toBe(true);
    expect(existsSync(path.join(repoRoot, feature.reference))).toBe(true);
  });

  test('no id outside the frozen set is non-standalone', () => {
    expect(nonStandaloneNewIds(committed.features)).toEqual([]);
  });

  test('the frozen ids are all non-standalone', () => {
    expect(committed.features.every((feature) => !feature.standalone)).toBe(
      true
    );
  });
});

describe('SetupFeaturesSchema guards', () => {
  test('accepts a valid fixture list', () => {
    expect(SetupFeaturesSchema.safeParse(listOf([baseFeature])).success).toBe(
      true
    );
  });

  test('rejects a duplicate id, naming it and its index', () => {
    const result = SetupFeaturesSchema.safeParse(
      listOf([baseFeature, baseFeature])
    );

    expect(result.success).toBe(false);
    expect(JSON.stringify(result.error?.issues)).toContain(
      'duplicate setup feature id: example-feature'
    );
    expect(result.error?.issues[0]?.path).toEqual(['features', 1, 'id']);
  });

  test('rejects an id that is not kebab-case', () => {
    expect(
      SetupFeaturesSchema.safeParse(
        listOf([{...baseFeature, id: 'Squash_Only'}])
      ).success
    ).toBe(false);
  });

  test('rejects an entry missing standalone', () => {
    const withoutStandalone: Record<string, unknown> = {...baseFeature};
    delete withoutStandalone.standalone;

    expect(
      SetupFeaturesSchema.safeParse(listOf([withoutStandalone])).success
    ).toBe(false);
  });

  test('rejects an unknown scope', () => {
    expect(
      SetupFeaturesSchema.safeParse(
        listOf([{...baseFeature, scope: 'organization'}])
      ).success
    ).toBe(false);
  });

  test('rejects a reference with a parent segment or a leading slash', () => {
    for (const reference of ['../outside.md', 'a/../b.md', '/etc/passwd']) {
      expect(
        SetupFeaturesSchema.safeParse(listOf([{...baseFeature, reference}]))
          .success
      ).toBe(false);
    }
  });

  test('rejects an em dash in the description', () => {
    expect(
      SetupFeaturesSchema.safeParse({
        description: ['bad', 'text'].join(String.fromCodePoint(0x20_14)),
        features: [],
        version: 1,
      }).success
    ).toBe(false);
  });

  test('strips an unknown extra field instead of rejecting it', () => {
    const result = SetupFeaturesSchema.parse(
      listOf([{...baseFeature, futureField: 1}])
    );

    expect(result.features[0]).not.toHaveProperty('futureField');
  });

  test('the new-id predicate flags a non-standalone id outside the frozen set', () => {
    expect(nonStandaloneNewIds([{...baseFeature, standalone: false}])).toEqual([
      'example-feature',
    ]);
    expect(nonStandaloneNewIds([baseFeature])).toEqual([]);
  });
});
