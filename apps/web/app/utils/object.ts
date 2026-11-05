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
          accumulated[transformKey(key)] = value.map<unknown>((arrayElement) =>
            isObject(arrayElement) ?
              convertCase(transformKey, arrayElement)
            : arrayElement
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
