import {describe, expect, test} from 'vitest';
import {familyOf, projectModelFromSettings, resolveModel} from './model.js';

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
  test('prefers the file model over the project model', () => {
    expect(resolveModel('opus', 'sonnet')).toBe('opus');
  });

  test('falls back to the project model for inherit or absent', () => {
    expect(resolveModel('inherit', 'sonnet')).toBe('sonnet');
    expect(resolveModel(undefined, 'haiku')).toBe('haiku');
  });

  test('is unresolved when neither names a family', () => {
    expect(resolveModel(undefined, 'unresolved')).toBe('unresolved');
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
