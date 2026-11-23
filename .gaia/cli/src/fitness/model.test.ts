import {describe, expect, test} from 'vitest';
import {familyOf, projectModelFromSettings, resolveModel} from './model.js';
import type {ModelFamily} from './types.js';

describe('familyOf', () => {
  test.each([
    ['opus', 'opus'],
    ['claude-sonnet-5-5', 'sonnet'],
    ['Fable', 'fable'],
    ['claude-haiku-4', 'haiku'],
  ])('maps %s to %s', (value, expected) => {
    expect(familyOf(value)).toBe(expected);
  });

  test.each(['inherit', 'gpt-9', 42, undefined])(
    'maps %s to nothing',
    (value) => {
      expect(familyOf(value)).toBeUndefined();
    }
  );
});

describe('resolveModel', () => {
  test.each<[string, unknown, ModelFamily, ModelFamily]>([
    ['prefers the file model over the project model', 'opus', 'sonnet', 'opus'],
    [
      'falls back to the project model for inherit',
      'inherit',
      'sonnet',
      'sonnet',
    ],
    ['falls back to the project model for absent', undefined, 'haiku', 'haiku'],
    [
      'is unresolved when neither names a family',
      undefined,
      'unresolved',
      'unresolved',
    ],
  ])('%s', (_name, fileModel, projectModel, expected) => {
    expect(resolveModel(fileModel, projectModel)).toBe(expected);
  });
});

describe('projectModelFromSettings', () => {
  test('reads the model from settings text', () => {
    expect(projectModelFromSettings('{"model":"claude-opus-4"}')).toBe('opus');
  });

  test('is unresolved for missing, invalid or model-less settings', () => {
    expect(projectModelFromSettings(undefined)).toBe('unresolved');
    expect(projectModelFromSettings('{ nope')).toBe('unresolved');
    expect(projectModelFromSettings('{}')).toBe('unresolved');
    expect(projectModelFromSettings('[]')).toBe('unresolved');
  });
});
