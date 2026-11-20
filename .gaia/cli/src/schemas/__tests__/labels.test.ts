import {describe, expect, test} from 'vitest';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import type {LabelEntry} from '../labels.js';
import {isCreatable, LabelEntrySchema, LabelRegistrySchema} from '../labels.js';

// Built at runtime so no removed-feature literal lands in the tracked tree.
const REMOVED_FEATURE_NAME = ['gaia', 'ci'].join('-');

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);

const readRegistry = (): unknown =>
  JSON.parse(readFileSync(path.join(repoRoot, '.gaia/labels.json'), 'utf8'));

const baseEntry: LabelEntry = {
  audience: 'adopter',
  axis: 'type',
  blocked: false,
  color: 'abcdef',
  deprecated: false,
  description: 'A valid description',
  features: [],
  managed: true,
  name: 'example',
  reason: null,
  renamedFrom: [],
};

describe('schemas/labels', () => {
  test('the committed .gaia/labels.json parses under LabelRegistrySchema', () => {
    const result = LabelRegistrySchema.safeParse(readRegistry());

    expect(result.success).toBe(true);
  });

  test('the committed deprecated entries carry a null reason', () => {
    const registry = LabelRegistrySchema.parse(readRegistry());
    const deprecatedEntries = registry.labels.filter(
      (entry) => entry.deprecated
    );

    expect(
      deprecatedEntries
        .map((entry) => entry.name)
        .toSorted((a, b) => a.localeCompare(b))
    ).toEqual([REMOVED_FEATURE_NAME]);

    for (const entry of deprecatedEntries) {
      expect(entry.reason).toBeNull();
    }
  });

  test('the removed feature name is rejected as an entry feature', () => {
    const removedFeature = REMOVED_FEATURE_NAME;
    const result = LabelEntrySchema.safeParse({
      ...baseEntry,
      features: [removedFeature],
    });

    expect(result.success).toBe(false);
  });

  test.each([
    {
      description: 'a'.repeat(101),
      name: 'a description of 101 characters is rejected',
      success: false,
    },
    {
      description: 'a'.repeat(100),
      name: 'a description of 100 characters is accepted',
      success: true,
    },
  ])('$name', ({description, success}) => {
    const result = LabelEntrySchema.safeParse({...baseEntry, description});

    expect(result.success).toBe(success);
  });

  test.each<[string, string, boolean]>([
    ['an uppercase color is rejected', 'B60205', false],
    ['a lowercase 6-digit color is accepted', 'b60205', true],
    ['a 3-digit color is rejected', 'b60', false],
    ['a 7-digit color is rejected', 'b60205a', false],
  ])('%s', (_label, color, success) => {
    const result = LabelEntrySchema.safeParse({...baseEntry, color});

    expect(result.success).toBe(success);
  });

  test.each([
    {
      labels: [
        {...baseEntry, color: 'abcdef', name: 'one'},
        {...baseEntry, color: 'abcdef', name: 'two'},
      ],
      message: 'abcdef',
      name: 'two entries sharing a color are rejected, and the message names the color',
    },
    {
      labels: [
        {...baseEntry, color: 'abcdef', name: 'dup'},
        {...baseEntry, color: 'fedcba', name: 'dup'},
      ],
      message: 'dup',
      name: 'two entries sharing a name are rejected',
    },
    {
      labels: [{...baseEntry, description: 'has an em dash — in it'}],
      message: '—',
      name: 'a description containing an em dash is rejected, and the message names the character',
    },
    {
      labels: [{...baseEntry, description: 'has an en dash – in it'}],
      message: '–',
      name: 'a description containing an en dash is rejected, and the message names the character',
    },
  ])('$name', ({labels, message}) => {
    const result = LabelRegistrySchema.safeParse({
      description: 'test registry',
      labels,
      version: 1,
    });

    expect(result.success).toBe(false);
    assert.ok(!result.success);
    expect(
      result.error.issues.some((issue) => issue.message.includes(message))
    ).toBe(true);
  });

  test.each([
    {
      name: 'a blocked entry with a non-null color is rejected',
      overrides: {
        blocked: true,
        color: 'abcdef',
        managed: false,
        reason: 'blocked reason',
      },
    },
    {
      name: 'a blocked entry with managed: true is rejected',
      overrides: {
        blocked: true,
        color: null,
        managed: true,
        reason: 'blocked reason',
      },
    },
    {
      name: 'a blocked entry with reason: null is rejected',
      overrides: {
        blocked: true,
        color: null,
        managed: false,
        reason: null,
      },
    },
    {
      name: 'a non-blocked entry with reason set to a string is rejected',
      overrides: {blocked: false, reason: 'should be null'},
    },
    {
      name: 'a non-blocked entry with a null color is rejected',
      overrides: {blocked: false, color: null, reason: null},
    },
  ])('$name', ({overrides}) => {
    const result = LabelEntrySchema.safeParse({...baseEntry, ...overrides});

    expect(result.success).toBe(false);
  });

  describe('isCreatable', () => {
    const managedAdopterAlways: LabelEntry = {
      ...baseEntry,
      audience: 'adopter',
      blocked: false,
      deprecated: false,
      features: [],
      managed: true,
    };

    const dependabotFeatures: LabelEntry = {
      ...managedAdopterAlways,
      features: ['tech-debt', 'dependabot'],
    };

    test.each([
      {
        audience: 'adopter',
        enabled: [],
        entry: {...managedAdopterAlways, managed: false},
        expected: false,
        name: 'managed: false is never creatable',
      },
      {
        audience: 'adopter',
        enabled: [],
        entry: {...managedAdopterAlways, deprecated: true},
        expected: false,
        name: 'deprecated: true is never creatable',
      },
      {
        audience: 'adopter',
        enabled: [],
        entry: {
          ...managedAdopterAlways,
          blocked: true,
          color: null,
          reason: 'x',
        },
        expected: false,
        name: 'blocked: true is never creatable',
      },
      {
        audience: 'maintainer',
        enabled: [],
        entry: managedAdopterAlways,
        expected: true,
        name: 'the maintainer audience is owed an adopter entry',
      },
      {
        audience: 'adopter',
        enabled: [],
        entry: {...managedAdopterAlways, audience: 'maintainer'},
        expected: false,
        name: 'the adopter audience is never owed a maintainer entry',
      },
      {
        audience: 'adopter',
        enabled: [],
        entry: managedAdopterAlways,
        expected: true,
        name: 'features: [] is creatable with zero features enabled',
      },
      {
        audience: 'adopter',
        enabled: ['dependabot'],
        entry: dependabotFeatures,
        expected: true,
        name: 'features: ["tech-debt", "dependabot"] is creatable when only dependabot is on',
      },
      {
        audience: 'adopter',
        enabled: ['forensics'],
        entry: dependabotFeatures,
        expected: false,
        name: 'features: ["tech-debt", "dependabot"] is not creatable when neither is on',
      },
    ] as const)('$name', ({audience, enabled, entry, expected}) => {
      expect(isCreatable(entry as LabelEntry, audience, [...enabled])).toBe(
        expected
      );
    });
  });
});
