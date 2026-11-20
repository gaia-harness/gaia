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

  test.each([
    {
      camel: {
        profileData: {homeTown: {zipCode: '1'}},
        userRecords: [{firstName: 'a', parentId: null}],
      },
      name: 'nested object, array of objects and null value',
      snake: {
        profile_data: {home_town: {zip_code: '1'}},
        user_records: [{first_name: 'a', parent_id: null}],
      },
    },
    {
      camel: {data: {matrix: [[{cellValue: 1}]]}},
      name: 'array nested inside a property array',
      snake: {data: {matrix: [[{cell_value: 1}]]}},
    },
  ])(
    'toSnakeCase and toCamelCase convert keys deeply: $name',
    ({camel, snake}) => {
      expect(toSnakeCase(camel)).toEqual(snake);
      expect(toCamelCase(snake)).toEqual(camel);
    }
  );
});
