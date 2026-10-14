import {lineOf} from './markdown.js';

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

/** The line of the first quoted occurrence of `key` in JSON `text`, else 1. */
export const lineOfJsonKey = (text: string, key: string): number => {
  const index = text.indexOf(JSON.stringify(key));

  return index === -1 ? 1 : lineOf(text, index);
};
