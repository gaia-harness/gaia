import {camelCase, snakeCase} from 'lodash-es';
import SparkMD5 from 'spark-md5';

const isObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

export const md5 = (record: Record<string, unknown>): string =>
  SparkMD5.hash(JSON.stringify(record));

export const every = (
  record: Record<string, unknown>,
  predicate: (value: unknown) => boolean
): boolean => {
  const values = Object.values(record);

  return values.length > 0 && values.every(predicate);
};

export const some = (
  record: Record<string, unknown>,
  predicate: (value: unknown) => boolean
): boolean => Object.values(record).some(predicate);

export const isNil = (value: unknown): boolean =>
  value === null || value === undefined;

export const deepRemoveNil = (input: unknown): unknown => {
  if (isNil(input)) {
    return;
  }

  if (Array.isArray(input)) {
    return input.reduce<unknown[]>((accumulated, value) => {
      if (!isNil(value)) {
        accumulated.push(deepRemoveNil(value));
      }

      return accumulated;
    }, []);
  }

  if (isObject(input)) {
    return Object.entries(input).reduce<Record<string, unknown>>(
      (accumulated, [key, value]) => {
        if (!isNil(value)) {
          accumulated[key] = deepRemoveNil(value);
        }

        return accumulated;
      },
      {}
    );
  }

  return input;
};

export const mapKeys = (
  record: Record<string, unknown>,
  transformKey: (key: string) => string
): Record<string, unknown> =>
  Object.entries(record).reduce<Record<string, unknown>>(
    (accumulated, [key, value]) => {
      accumulated[transformKey(key)] = value;

      return accumulated;
    },
    {}
  );

export const mapValues = (
  record: Record<string, unknown>,
  transformValue: (value: unknown) => unknown
): Record<string, unknown> =>
  Object.entries(record).reduce<Record<string, unknown>>(
    (accumulated, [key, value]) => {
      accumulated[key] = transformValue(value);

      return accumulated;
    },
    {}
  );

export const convertCase = (
  transformKey: (text: string) => string,
  input: unknown
): unknown => {
  if (input === undefined) {
    return;
  }

  if (Array.isArray(input)) {
    return input.map((value: unknown) => convertCase(transformKey, value));
  }

  if (isObject(input)) {
    return Object.entries(input).reduce(
      (accumulated: Record<string, unknown>, [key, value]) => {
        if (Array.isArray(value)) {
          accumulated[transformKey(key)] = value.map<unknown>((item) =>
            isObject(item) ? convertCase(transformKey, item) : item
          );
        } else if (isObject(value)) {
          accumulated[transformKey(key)] = convertCase(transformKey, value);
        } else {
          accumulated[transformKey(key)] = value;
        }

        return accumulated;
      },
      {}
    );
  }

  return input;
};

export const toSnakeCase = <T = unknown>(input: unknown): T | undefined =>
  input === undefined ? undefined : (convertCase(snakeCase, input) as T);

export const toCamelCase = <T = unknown>(input: unknown): T | undefined =>
  input === undefined ? undefined : (convertCase(camelCase, input) as T);

export const compact = (
  record: Record<string, unknown>,
  options?: {keepEmptyArray?: boolean; keepFalsy?: boolean}
): Record<string, unknown> =>
  Object.entries(record).reduce<Record<string, unknown>>(
    (accumulated, [key, value]) => {
      if (
        ((options?.keepFalsy && !isNil(value)) || value) &&
        (!Array.isArray(value) || options?.keepEmptyArray || value.length > 0)
      ) {
        accumulated[key] = value;
      }

      return accumulated;
    },
    {}
  );
