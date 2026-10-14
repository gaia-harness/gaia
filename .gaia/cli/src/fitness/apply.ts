import {createHash} from 'node:crypto';
import {
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  statSync,
} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {takeNonFlagValue} from '../util/argv.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {runCheck} from './check.js';
import {defaultRoot} from './cli-args.js';
import {isInsideRoot} from './context.js';
import {kindsOfPath} from './discover.js';
import {classifyOwnership, effectiveOwnership} from './ownership.js';
import type {RuleDefinition} from './types.js';

/** Shares the value of the router's unknown-subcommand exit; callers tell them apart by stderr (`refuse:` prefix). */
const EXIT_REFUSED = 1;
/** Keeps the nine permission bits of a mode and drops the file-type bits. */
const PERMISSION_MODULUS = 0o1000;
const ABSENT = 'absent';
const SHA256_HEX = /^[\da-f]{64}$/;
const VENDOR_PIN_DIRECTORY = '.gaia/vendor';

export type ApplyOptions = {
  baseSha256: string;
  /** Tests only: forwarded to the check that recomputes the fixable set. */
  catalog?: readonly RuleDefinition[];
  /** Where the ownership classifier seam is read; defaults to the process environment. */
  env?: Readonly<Record<string, string | undefined>>;
  proposalPath: string;
  root: string;
  /** Tests only: replaces the symlink check, to prove a test depends on it. */
  symlinkCheck?: SymlinkCheck;
  target: string;
};

export type ApplyResult =
  | {kind: 'applied'; target: string}
  | {kind: 'could-not-run'; reason: string}
  | {kind: 'refused'; reason: string}
  | {kind: 'usage'; reason: string};

/** Returns the reason a target path may not be written, or undefined when it may. */
export type SymlinkCheck = (root: string, target: string) => string | undefined;

/** Repo-relative, forward-slash, normalized; undefined for an absolute, empty or climbing path. */
export const normalizeTarget = (target: string): string | undefined => {
  if (target === '' || target.includes('\\') || path.isAbsolute(target)) {
    return undefined;
  }

  const normalized = path.posix.normalize(target);

  if (
    normalized === '.' ||
    normalized === '..' ||
    normalized.startsWith('../') ||
    path.posix.isAbsolute(normalized)
  ) {
    return undefined;
  }

  return normalized.endsWith('/') ? normalized.slice(0, -1) : normalized;
};

/** Each vendor pin's `target`, repo-relative. A pin without a readable target is skipped: the classifier already fails closed on it. */
const vendorTargets = (root: string): string[] => {
  const directory = path.join(root, VENDOR_PIN_DIRECTORY);
  let names: string[];

  try {
    names = readdirSync(directory).filter((name) => name.endsWith('.json'));
  } catch {
    return [];
  }

  const targets: string[] = [];

  for (const name of names) {
    try {
      const parsed: unknown = JSON.parse(
        readFileSync(path.join(directory, name), 'utf8')
      );
      const value =
        parsed !== null && typeof parsed === 'object' ?
          (parsed as {target?: unknown}).target
        : undefined;
      const normalized =
        typeof value === 'string' ? normalizeTarget(value) : undefined;

      if (normalized !== undefined) targets.push(normalized);
    } catch {
      // an unreadable pin is the classifier's failure to report, not this walk's
    }
  }

  return targets;
};

/**
 * Walks every component from the root to the target. A symlink is acceptable
 * only when it resolves inside the project and outside every vendored tree; a
 * path that does not exist yet has no further components to follow. A final
 * component that is itself a symlink is refused, because the write replaces
 * the path rather than writing through it.
 */
export const findSymlinkProblem: SymlinkCheck = (root, target) => {
  const realRoot = realpathSync(root);
  const vendored = vendorTargets(root);

  const problemWith = (resolved: string): string | undefined => {
    if (!isInsideRoot(realRoot, resolved)) {
      return 'target passes through a symlink that leaves the project root';
    }

    const relative = path
      .relative(realRoot, resolved)
      .split(path.sep)
      .join('/');

    return (
        vendored.some(
          (tree) => relative === tree || relative.startsWith(`${tree}/`)
        )
      ) ?
        'target resolves into a vendored tree'
      : undefined;
  };

  let current = root;
  let finalLink: string | undefined;

  for (const part of target.split('/')) {
    finalLink = undefined;
    current = path.join(current, part);

    let isLink: boolean;

    try {
      isLink = lstatSync(current).isSymbolicLink();
    } catch {
      return undefined;
    }

    if (isLink) {
      let resolved: string;

      try {
        resolved = realpathSync(current);
      } catch {
        return 'target passes through a symlink that does not resolve';
      }

      const problem = problemWith(resolved);

      if (problem !== undefined) return problem;

      finalLink = resolved;
    }
  }

  const finalProblem = problemWith(realpathSync(current));

  if (finalProblem !== undefined || finalLink === undefined) {
    return finalProblem;
  }

  // The write renames a temporary file over the path, which would swap the link for a regular file and leave the file it points at unfixed.
  return `target is a symlink to ${path
    .relative(realRoot, finalLink)
    .split(path.sep)
    .join('/')}; fix that file instead`;
};

const sha256Of = (bytes: Buffer): string =>
  createHash('sha256').update(bytes).digest('hex');

const readBase = (
  absolute: string
):
  | {error: string}
  | {exists: false}
  | {exists: true; mode: number; sha256: string} => {
  let stat;

  try {
    stat = lstatSync(absolute);
  } catch {
    return {exists: false};
  }

  try {
    const followed = statSync(absolute);

    if (!followed.isFile()) return {error: 'target is not a regular file'};

    return {
      exists: true,
      mode: followed.mode % PERMISSION_MODULUS,
      sha256: sha256Of(readFileSync(absolute)),
    };
  } catch {
    return {
      error:
        stat.isSymbolicLink() ?
          'target is a symlink that does not resolve'
        : 'target cannot be read',
    };
  }
};

const refused = (reason: string): ApplyResult => ({kind: 'refused', reason});

const couldNotRun = (error: unknown): ApplyResult => ({
  kind: 'could-not-run',
  reason: error instanceof Error ? error.message : String(error),
});

const validateOptions = (
  options: ApplyOptions
): ApplyResult | {root: string; target: string} => {
  const target = normalizeTarget(options.target);

  if (target === undefined) {
    return {
      kind: 'usage',
      reason:
        '--target must be a repo-relative path that stays inside the root',
    };
  }

  if (options.baseSha256 !== ABSENT && !SHA256_HEX.test(options.baseSha256)) {
    return {
      kind: 'usage',
      reason:
        '--base-sha256 must be a 64-character lowercase hex digest or absent',
    };
  }

  const root = path.resolve(options.root);

  try {
    if (statSync(root).isDirectory()) return {root, target};
  } catch {
    // reported below, with a directory that is not one
  }

  return {kind: 'could-not-run', reason: 'the root is not a directory'};
};

/** The refusal for a target that is not a fixable adopter file right now, or undefined. */
const refuseUnlessFixableAdopter = (
  options: ApplyOptions,
  root: string,
  target: string
): ApplyResult | undefined => {
  const env = options.env ?? process.env;
  let report;

  try {
    report = runCheck({
      catalog: options.catalog,
      env,
      root,
      scope: 'adopter',
    });
  } catch (error: unknown) {
    return couldNotRun(error);
  }

  if (
    !report.findings.some(
      (finding) => finding.fixable && finding.file === target
    )
  ) {
    return refused('target is not in the fixable set');
  }

  const classified = classifyOwnership({env, paths: [target], root});
  const ownership = effectiveOwnership(
    classified.get(target) ?? 'unknown',
    kindsOfPath(target)
  );

  return ownership === 'adopter' ? undefined : (
      refused(`target ownership is ${ownership}, not adopter`)
    );
};

const symlinkRefusal = (
  options: ApplyOptions,
  root: string,
  target: string
): ApplyResult | undefined => {
  try {
    const problem = (options.symlinkCheck ?? findSymlinkProblem)(root, target);

    return problem === undefined ? undefined : refused(problem);
  } catch {
    return refused('target path cannot be resolved');
  }
};

/**
 * Decides whether one proposed file may land, and writes it when so. The fixable
 * set comes from a fresh check and the ownership from a fresh classification, so
 * nothing the caller passes decides either.
 */
export const applyProposal = (options: ApplyOptions): ApplyResult => {
  const validated = validateOptions(options);

  if ('kind' in validated) return validated;

  const {root, target} = validated;
  const refusal =
    refuseUnlessFixableAdopter(options, root, target) ??
    symlinkRefusal(options, root, target);

  if (refusal !== undefined) return refusal;

  const absolute = path.join(root, target);
  const base = readBase(absolute);

  if ('error' in base) return refused(base.error);

  if ((base.exists ? base.sha256 : ABSENT) !== options.baseSha256) {
    return refused('file changed since the diff was shown');
  }

  let proposal: Buffer;

  try {
    proposal = readFileSync(options.proposalPath);
  } catch {
    return {kind: 'could-not-run', reason: 'the proposal file cannot be read'};
  }

  try {
    mkdirSync(path.dirname(absolute), {recursive: true});
    atomicWriteFileSync(
      absolute,
      proposal,
      base.exists ? {mode: base.mode} : undefined
    );
  } catch (error: unknown) {
    return couldNotRun(error);
  }

  return {kind: 'applied', target};
};

type ParsedArguments = {
  baseSha256: string | undefined;
  proposal: string | undefined;
  root: string | undefined;
  target: string | undefined;
};

type ParseResult =
  {message: string; ok: false} | {ok: true; options: ParsedArguments};

const parseArguments = (args: readonly string[]): ParseResult => {
  const options: ParsedArguments = {
    baseSha256: undefined,
    proposal: undefined,
    root: undefined,
    target: undefined,
  };
  const setters: Readonly<Record<string, (value: string) => void>> = {
    '--base-sha256': (value) => {
      options.baseSha256 = value;
    },
    '--proposal': (value) => {
      options.proposal = value;
    },
    '--root': (value) => {
      options.root = value;
    },
    '--target': (value) => {
      options.target = value;
    },
  };
  let index = 0;

  while (index < args.length) {
    const flag = args[index] ?? '';
    const setter = Object.hasOwn(setters, flag) ? setters[flag] : undefined;

    index += 1;

    if (setter === undefined) {
      return {message: `unknown argument: ${flag}`, ok: false};
    }

    const taken = takeNonFlagValue(args, index, flag);

    if (!taken.ok) return {message: taken.message, ok: false};
    index += 1;
    setter(taken.value);
  }

  return {ok: true, options};
};

const usageError = (message: string): number => {
  structuredError({
    code: 'invalid_arguments',
    message,
    subcommand: 'fitness apply',
  });

  return EXIT_CODES.INVALID_ARGUMENTS;
};

/** `gaia fitness apply`: the only writer the heal step uses. */
export const run = (args: readonly string[]): number => {
  const parsed = parseArguments(args);

  if (!parsed.ok) return usageError(parsed.message);

  const {baseSha256, proposal, root, target} = parsed.options;

  if (target === undefined) return usageError('--target is required');
  if (proposal === undefined) return usageError('--proposal is required');
  if (baseSha256 === undefined) return usageError('--base-sha256 is required');

  const result = applyProposal({
    baseSha256,
    proposalPath: path.resolve(proposal),
    root: path.resolve(root ?? defaultRoot()),
    target,
  });

  if (result.kind === 'applied') {
    process.stdout.write(`applied: ${result.target}\n`);

    return EXIT_CODES.OK;
  }

  if (result.kind === 'usage') return usageError(result.reason);

  if (result.kind === 'refused') {
    process.stderr.write(`refuse: ${result.reason}\n`);

    return EXIT_REFUSED;
  }

  structuredError({
    code: 'could_not_run',
    message: result.reason,
    subcommand: 'fitness apply',
  });

  return EXIT_CODES.COULD_NOT_RUN;
};
