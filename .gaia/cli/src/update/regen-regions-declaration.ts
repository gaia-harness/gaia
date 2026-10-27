import path from 'node:path';

export type ParsedDeclaration = {
  args: string[];
  endMarker: string;
  id: string;
  interpreter: string;
  operand: string;
  paths: string[];
  startMarker: string;
};

type DeclarationParseResult =
  | {declaration: ParsedDeclaration; ok: true}
  | {ok: false; reason: string; regionId: string};

const isNonEmptyString = (value: unknown): value is string =>
  typeof value === 'string' && value.trim() !== '';

const isStringArray = (value: unknown): value is string[] =>
  Array.isArray(value) && value.every((item) => typeof item === 'string');

export const isPlainObject = (
  value: unknown
): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

/**
 * Names a parsed-JSON value's shape for a refusal reason. `null` and arrays
 * are spelled out because `typeof` calls both `'object'`, which would report
 * them identically to the plain object this exists to tell them apart from.
 */
export const describeJsonShape = (value: unknown): string => {
  if (value === null) return 'null';

  return Array.isArray(value) ? 'array' : typeof value;
};

/** Strips a leading `./`, collapses separators, converts to POSIX. */
export const normalizeRepoPath = (value: string): string => {
  const posix = value.replaceAll('\\', '/').replaceAll(/\/{2,}/gu, '/');

  return posix.startsWith('./') ? posix.slice(2) : posix;
};

/**
 * Well-formedness guard for `paths[]`, the counterpart to `checkOperand`'s
 * guard on the operand. Both are downstream of the same untrusted manifest,
 * and every consumer of a declared path resolves it against `--root`: the
 * backup copies it, the snapshot walks its parent directory, and the sweep
 * writes and deletes inside that directory. An entry that is absolute or
 * carries a parent segment therefore reaches outside `--root` on all three.
 *
 * Normalizing here rather than at each use site is what makes `declaredSet`
 * and the snapshot keys agree by construction. The snapshot canonicalizes its
 * keys through `path.relative`, so a declared `./a/b.md` would otherwise never
 * match its own snapshot entry, and the sweep would revert the very file the
 * regeneration just wrote while reporting the run a success.
 */
const normalizeDeclaredPaths = (
  paths: readonly string[]
): {ok: false; reason: string} | {ok: true; paths: string[]} => {
  const normalized: string[] = [];

  for (const declPath of paths) {
    const candidate = normalizeRepoPath(declPath);

    if (candidate.trim() === '')
      return {ok: false, reason: 'paths carries an empty entry'};

    if (path.isAbsolute(candidate))
      return {
        ok: false,
        reason: `paths carries an absolute path: ${candidate}`,
      };

    if (candidate.split('/').includes('..'))
      return {
        ok: false,
        reason: `paths carries a parent-directory segment: ${candidate}`,
      };

    // The snapshot scope is the union of the declared paths' parent
    // directories, so a path whose parent is the repository root scopes the
    // snapshot to the entire tree: every file under it read and buffered
    // twice per region, `node_modules` and `.git` included. A literal '.'
    // is worse than slow, because it is never equal to any snapshot key, so
    // the sweep reverts the region's own freshly written output while still
    // reporting the region as run.
    if (path.posix.dirname(candidate) === '.')
      return {
        ok: false,
        reason: `paths carries a path whose parent is the repository root: ${candidate}`,
      };

    normalized.push(candidate);
  }

  return {ok: true, paths: normalized};
};

/**
 * Defensive shape parse of one `regions[]` entry (untrusted JSON). Never
 * throws: every defect resolves to a `refused[]`-shaped result, never a crash.
 *
 * `seenIds` is mutated as soon as a candidate id is confirmed non-empty and
 * unique, before the rest of the declaration is validated. That way a
 * duplicate id is always caught on its second occurrence, even when the
 * FIRST declaration bearing that id is itself malformed for an unrelated
 * reason (and so never reaches `ok: true`).
 */
export const parseDeclaration = (
  raw: unknown,
  index: number,
  seenIds: Set<string>
): DeclarationParseResult => {
  const fallbackId = `region-at-index-${index}`;

  if (!isPlainObject(raw))
    return {
      ok: false,
      reason: 'declaration is not an object',
      regionId: fallbackId,
    };

  const {endMarker, id, paths, regenerate, startMarker} = raw;

  if (!isNonEmptyString(id))
    return {
      ok: false,
      reason: 'declaration is missing a non-empty id',
      regionId: fallbackId,
    };

  if (seenIds.has(id))
    return {ok: false, reason: `duplicate region id: ${id}`, regionId: id};

  seenIds.add(id);

  if (!isNonEmptyString(startMarker))
    return {ok: false, reason: 'startMarker is missing or empty', regionId: id};

  if (!isNonEmptyString(endMarker))
    return {ok: false, reason: 'endMarker is missing or empty', regionId: id};

  if (!isStringArray(paths))
    return {
      ok: false,
      reason: 'paths is missing or not an array of strings',
      regionId: id,
    };

  const declaredPaths = normalizeDeclaredPaths(paths);

  if (!declaredPaths.ok)
    return {ok: false, reason: declaredPaths.reason, regionId: id};

  if (!isPlainObject(regenerate))
    return {
      ok: false,
      reason: 'regenerate is missing or not an object',
      regionId: id,
    };

  const {args, interpreter, operand} = regenerate;

  if (!isNonEmptyString(interpreter))
    return {
      ok: false,
      reason: 'regenerate.interpreter is missing or empty',
      regionId: id,
    };

  if (!isNonEmptyString(operand))
    return {
      ok: false,
      reason: 'regenerate.operand is missing or empty',
      regionId: id,
    };

  if (!isStringArray(args))
    return {
      ok: false,
      reason: 'regenerate.args is missing or not an array of strings',
      regionId: id,
    };

  return {
    declaration: {
      args,
      endMarker,
      id,
      interpreter,
      operand,
      paths: declaredPaths.paths,
      startMarker,
    },
    ok: true,
  };
};
