import {describe, expect, test} from 'vitest';
import {convertCase, toCamelCase, toSnakeCase} from '../object';

describe('object utils', () => {
  test('convertCase', () => {
    expect(convertCase((text) => text, {})).toEqual({});
    const mixedCaseNestedRecord = {
      a: [
        {
          a: 1,
          b: [1],
          c: undefined,
          d: null,
          e: true,
          f: [],
        },
      ],
      b: 'John Doe',
      c: [[1, 2, 3, [4, 5, 6], undefined]],
      d: {
        a: {a: 1},
        b: {a: 2},
        c: undefined,
      },
    };
    expect(
      convertCase((text) => `${text}${text}`, mixedCaseNestedRecord)
    ).toEqual({
      aa: [
        {
          aa: 1,
          bb: [1],
          cc: undefined,
          dd: null,
          ee: true,
          ff: [],
        },
      ],
      bb: 'John Doe',
      cc: [[1, 2, 3, [4, 5, 6], undefined]],
      dd: {
        aa: {aa: 1},
        bb: {aa: 2},
        cc: undefined,
      },
    });
  });

  test.each([false, 0, '', null])(
    'toSnakeCase and toCamelCase keep the falsy value %j',
    (value) => {
      expect(toSnakeCase(value)).toBe(value);
      expect(toCamelCase(value)).toBe(value);
    }
  );
});
