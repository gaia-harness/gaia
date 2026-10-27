import {spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import type {Bucket, Kind, PnpmRunner} from './run-types.js';
import {parseSegments} from './version.js';

// ---------- pnpm runner indirection ----------

export const defaultPnpmRunner: PnpmRunner = (args, options) => {
  const result = spawnSync('pnpm', args as string[], {
    cwd: options.cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  // With `stdio: ['ignore', 'pipe', 'pipe']` and `encoding: 'utf8'`,
  // `SpawnSyncReturns<string>.stdout`/`.stderr` are always strings (never
  // null); the type declares them as such too, so no `?? ''` fallback is
  // needed.
  return {
    status: result.status,
    stderr: result.stderr,
    stdout: result.stdout,
  };
};

/**
 * Compare current/latest by leading segments. Major if `[0]` differs,
 * else minor if `[1]` differs, else patch.
 */
export const classifyKind = (current: string, latest: string): Kind => {
  const a = parseSegments(current);
  const b = parseSegments(latest);

  if ((a[0] ?? 0) !== (b[0] ?? 0)) return 'major';
  if ((a[1] ?? 0) !== (b[1] ?? 0)) return 'minor';

  return 'patch';
};

/**
 * Preview display bucket. A pre-1.0 `current` (major segment 0) is `nonsemver`
 * regardless of which segment moved; otherwise defer to `classifyKind`. Display
 * only, it does not influence Wave A/B routing.
 */
export const classifyBucket = (current: string, latest: string): Bucket => {
  if ((parseSegments(current)[0] ?? 0) === 0) return 'nonsemver';

  return classifyKind(current, latest);
};

/** Plain ascending string comparator, shared by every stable-sort call in
 * this module so sort callsites stay a one-line delegation instead of a
 * repeated ternary chain. */
export const compareStrings = (a: string, b: string): number => {
  if (a < b) return -1;

  return a > b ? 1 : 0;
};

// ---------- pinning detection ----------

export type PackageJsonShape = {
  dependencies?: Readonly<Record<string, string>>;
  devDependencies?: Readonly<Record<string, string>>;
  gaia?: {updateDepsHold?: Readonly<Record<string, unknown>>};
  optionalDependencies?: Readonly<Record<string, string>>;
  peerDependencies?: Readonly<Record<string, string>>;
};

export const readPackageJson = (cwd: string): PackageJsonShape => {
  const raw = readFileSync(path.join(cwd, 'package.json'), 'utf8');

  return JSON.parse(raw) as PackageJsonShape;
};

/**
 * The committed `gaia.updateDepsHold` map (`name -> version ceiling`) from
 * package.json. A ceiling is a version prefix: `"8.0"` caps the package to the
 * highest `8.0.x`, `"8.0.16"` freezes it exactly. Unlike the local snooze
 * ledger this is committed, so it holds a package on every machine, until the
 * maintainer lifts it. Non-string values are dropped;
 * a missing map yields no holds.
 */
export const readUpdateDepsHolds = (
  pkg: PackageJsonShape
): ReadonlyMap<string, string> => {
  // `pkg` came through an unchecked `JSON.parse(...) as PackageJsonShape`, so
  // `updateDepsHold` could genuinely be anything at runtime (including
  // `null`) despite its declared type; widen back to `unknown` so the checks
  // below are not dead code.
  const raw = pkg.gaia?.updateDepsHold as unknown;

  if (raw === null || typeof raw !== 'object') return new Map();

  const out = new Map<string, string>();

  for (const [name, ceiling] of Object.entries(
    raw as Record<string, unknown>
  )) {
    if (typeof ceiling === 'string' && ceiling.trim().length > 0) {
      out.set(name, ceiling.trim());
    }
  }

  return out;
};

/**
 * The version actually installed in `node_modules`. The package.json range
 * spec does not reveal it; a `^1.2.3` spec can resolve to any 1.x, and
 * `workspace:*` / tag / url specs carry no version at all. Returns
 * `undefined` when the package is not installed.
 */
export const readInstalledVersion = (
  cwd: string,
  name: string
): string | undefined => {
  try {
    const raw = readFileSync(
      path.join(cwd, 'node_modules', name, 'package.json'),
      'utf8'
    );
    const parsed = JSON.parse(raw) as {version?: unknown};

    return typeof parsed.version === 'string' ? parsed.version : undefined;
  } catch {
    return undefined;
  }
};

export const lookupSpec = (
  pkg: PackageJsonShape,
  name: string
): string | undefined =>
  pkg.dependencies?.[name] ??
  pkg.devDependencies?.[name] ??
  pkg.optionalDependencies?.[name] ??
  pkg.peerDependencies?.[name];

/**
 * Pinning rule: no `^` or `~` prefix in the spec. Anything else
 * (exact `1.2.3`, `>=`, tag refs, etc.) counts as pinned.
 */
export const isPinnedSpec = (spec: string | undefined): boolean => {
  if (spec === undefined) return false;

  const trimmed = spec.trim();

  if (trimmed.length === 0) return false;
  if (trimmed.startsWith('^')) return false;
  if (trimmed.startsWith('~')) return false;

  return true;
};

// ---------- pnpm outdated parsing ----------

export type OutdatedEntry = {
  current: string;
  latest: string;
  name: string;
  wanted: string;
};

type OutdatedRaw = {
  current: string;
  dependencyType?: string;
  latest: string;
  wanted: string;
};

const parseOutdatedEntry = (
  name: string,
  raw: unknown
): null | OutdatedEntry => {
  if (raw === null || typeof raw !== 'object') return null;

  const obj = raw as Partial<OutdatedRaw>;

  if (typeof obj.current !== 'string' || typeof obj.latest !== 'string') {
    return null;
  }

  return {
    current: obj.current,
    latest: obj.latest,
    name,
    wanted: typeof obj.wanted === 'string' ? obj.wanted : obj.current,
  };
};

export const parseOutdated = (stdout: string): readonly OutdatedEntry[] => {
  const trimmed = stdout.trim();

  if (trimmed.length === 0) return [];

  let parsed: unknown;

  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return [];
  }

  if (parsed === null || typeof parsed !== 'object') return [];

  const out: OutdatedEntry[] = [];

  for (const [name, raw] of Object.entries(parsed as Record<string, unknown>)) {
    const entry = parseOutdatedEntry(name, raw);

    if (entry !== null) out.push(entry);
  }

  // Stable order: alphabetical by name. Makes the emitted JSON
  // deterministic across runs regardless of pnpm's output ordering.
  return out.toSorted((a, b) => compareStrings(a.name, b.name));
};
