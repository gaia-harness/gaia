import {describe, expect, test} from 'vitest';
import {toCamelCase, toSnakeCase} from '../object';

describe('object utils', () => {
  test.each([false, 0, '', null])(
    'toSnakeCase and toCamelCase keep the falsy value %j',
    (value) => {
      expect(toSnakeCase(value)).toBe(value);
      expect(toCamelCase(value)).toBe(value);
    }
  );
});
