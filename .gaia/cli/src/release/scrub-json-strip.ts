import {readFileSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import type {
  JsonStripArrayElementTransform,
  JsonStripTransform,
} from './scrub-config.js';
import {matchesAnyGlob} from './scrub-glob.js';

// JSON strip

export type JsonStripResult = {
  filesTouched: readonly string[];
  keysRemoved: number;
};

/**
 * Split a dot-notation key path into segments.
 *
 * `scripts.test:forensics` → `['scripts', 'test:forensics']`
 */
export const parseKeyPath = (key: string): string[] => key.split('.');

const deleteKeyPath = (
  obj: Record<string, unknown>,
  segments: readonly string[]
): boolean => {
  if (segments.length === 0) return false;

  const [head, ...rest] = segments as [string, ...string[]];

  if (rest.length === 0) {
    if (!Object.hasOwn(obj, head)) return false;

    delete obj[head];

    return true;
  }

  const next = obj[head];

  if (typeof next !== 'object' || next === null || Array.isArray(next)) {
    return false;
  }

  return deleteKeyPath(next as Record<string, unknown>, rest);
};

/**
 * Strips the configured key paths from one JSON file in place. Returns the
 * count of keys actually removed (0 for a non-object file or a file with no
 * matching keys); the file is rewritten only when that count is positive.
 */
const stripJsonKeysFromFile = (
  absolutePath: string,
  relativePath: string,
  keySegments: readonly (readonly string[])[]
): number => {
  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(absolutePath, 'utf8'));
  } catch (error) {
    throw new Error(
      `Failed to parse JSON at ${relativePath}: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  const isPlainObject =
    typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed);

  if (!isPlainObject) return 0;

  const obj = parsed as Record<string, unknown>;
  let removed = 0;

  for (const segments of keySegments) {
    if (deleteKeyPath(obj, segments)) removed += 1;
  }

  if (removed > 0) {
    atomicWriteFileSync(absolutePath, `${JSON.stringify(obj, null, 2)}\n`);
  }

  return removed;
};

export const applyJsonStrip = (
  stagingRoot: string,
  files: readonly string[],
  transform: JsonStripTransform
): JsonStripResult => {
  const filesTouched: string[] = [];
  let keysRemoved = 0;
  const keySegments = transform.keys.map((k) => parseKeyPath(k));

  for (const relativePath of files) {
    if (matchesAnyGlob(relativePath, transform.paths)) {
      const absolutePath = path.join(stagingRoot, relativePath);
      const removed = stripJsonKeysFromFile(
        absolutePath,
        relativePath,
        keySegments
      );

      if (removed > 0) {
        filesTouched.push(relativePath);
        keysRemoved += removed;
      }
    }
  }

  return {filesTouched, keysRemoved};
};

// JSON strip array element

export type JsonStripArrayElementResult = {
  elementsRemoved: number;
  filesTouched: readonly string[];
};

type ResolvedSelector = {
  match: Readonly<Record<string, string>>;
  segments: readonly SelectorSegment[];
};
type SelectorSegment = {isArray: boolean; key: string};

/**
 * Split a selector path into ordered segments. A `[]` suffix marks a segment
 * whose value is an array: `PreToolUse[]` iterates each element of the
 * `PreToolUse` array, and a trailing `[]` names the array elements are removed
 * from. A segment without `[]` is a plain object-key descent.
 *
 * `hooks.PreToolUse[].hooks[]` →
 *   [{key:'hooks',isArray:false}, {key:'PreToolUse',isArray:true},
 *    {key:'hooks',isArray:true}]
 */
const parseSelectorPath = (selectorPath: string): SelectorSegment[] =>
  selectorPath.split('.').map((raw) => {
    const isArray = raw.endsWith('[]');

    return {isArray, key: isArray ? raw.slice(0, -2) : raw};
  });

/**
 * An element matches when it is a plain object and every `match` entry equals
 * the element's own value for that key. An empty `match` never reaches here
 * (the schema rejects it), so this cannot degenerate into matching everything.
 */
const elementMatchesSelector = (
  element: unknown,
  match: Readonly<Record<string, string>>
): boolean => {
  if (
    typeof element !== 'object' ||
    element === null ||
    Array.isArray(element)
  ) {
    return false;
  }

  const record = element as Record<string, unknown>;

  return Object.entries(match).every(([key, value]) => record[key] === value);
};

/**
 * Walk `segments` from `node`, removing every matching element from the array
 * the terminal `[]` segment names. Purely defensive: any structural surprise
 * (a missing key, or a value whose shape does not match the segment kind) ends
 * the walk with zero removals rather than throwing, so a selector that has
 * drifted from the file cannot corrupt it. Returns the count removed.
 */
const removeMatchingArrayElements = (
  node: unknown,
  segments: readonly SelectorSegment[],
  match: Readonly<Record<string, string>>
): number => {
  if (segments.length === 0) return 0;

  if (typeof node !== 'object' || node === null || Array.isArray(node)) {
    return 0;
  }

  const [segment, ...rest] = segments as [
    SelectorSegment,
    ...SelectorSegment[],
  ];
  const child = (node as Record<string, unknown>)[segment.key];

  if (!segment.isArray) {
    return removeMatchingArrayElements(child, rest, match);
  }

  if (!Array.isArray(child)) return 0;

  if (rest.length > 0) {
    let removed = 0;

    for (const element of child) {
      removed += removeMatchingArrayElements(element, rest, match);
    }

    return removed;
  }

  // Terminal array: splice matching elements in place, back-to-front so
  // earlier indices stay valid. An emptied array stays as `[]` (neither
  // collapsed nor removed); the parent entry is left intact.
  let removed = 0;

  for (let index = child.length - 1; index >= 0; index -= 1) {
    if (elementMatchesSelector(child[index], match)) {
      child.splice(index, 1);
      removed += 1;
    }
  }

  return removed;
};

/**
 * Applies the resolved selectors to one JSON file in place. Returns the count
 * of elements actually removed (0 for a non-object file or when no selector
 * matches); the file is rewritten only when that count is positive.
 */
const stripArrayElementsFromFile = (
  absolutePath: string,
  relativePath: string,
  selectors: readonly ResolvedSelector[]
): number => {
  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(absolutePath, 'utf8'));
  } catch (error) {
    throw new Error(
      `Failed to parse JSON at ${relativePath}: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  const isPlainObject =
    typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed);

  if (!isPlainObject) return 0;

  let removed = 0;

  for (const selector of selectors) {
    removed += removeMatchingArrayElements(
      parsed,
      selector.segments,
      selector.match
    );
  }

  if (removed > 0) {
    atomicWriteFileSync(absolutePath, `${JSON.stringify(parsed, null, 2)}\n`);
  }

  return removed;
};

export const applyJsonStripArrayElement = (
  stagingRoot: string,
  files: readonly string[],
  transform: JsonStripArrayElementTransform
): JsonStripArrayElementResult => {
  const filesTouched: string[] = [];
  let elementsRemoved = 0;
  const selectors: ResolvedSelector[] = transform.selectors.map((selector) => ({
    match: selector.match,
    segments: parseSelectorPath(selector.path),
  }));

  for (const relativePath of files) {
    if (matchesAnyGlob(relativePath, transform.paths)) {
      const absolutePath = path.join(stagingRoot, relativePath);
      const removed = stripArrayElementsFromFile(
        absolutePath,
        relativePath,
        selectors
      );

      if (removed > 0) {
        filesTouched.push(relativePath);
        elementsRemoved += removed;
      }
    }
  }

  return {elementsRemoved, filesTouched};
};
