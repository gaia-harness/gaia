import {realpathSync} from 'node:fs';
import path from 'node:path';
import {
  normalizeRepoPath,
  parseDeclaration,
} from './regen-regions-declaration.js';
import type {ParsedDeclaration} from './regen-regions-declaration.js';
import {
  collectScopeDigests,
  isUntouched,
  performBackup,
  scopeDirsFor,
  sweepScope,
} from './regen-regions-scope.js';
import {
  gitStatusPaths,
  reportOutOfScopeWrites,
  trySpawn,
} from './regen-regions-spawn.js';
import type {RegenRegionsReport} from './regen-regions-types.js';

type SkipInputs = {
  absentPaths: ReadonlySet<string>;
  conflicted: ReadonlySet<string>;
  skipRegions: ReadonlySet<string>;
};

/**
 * Step 2: skip conditions, checked before the operand guard. A region reaches
 * here only after well-formedness, so its argv is always buildable.
 */
const computeSkipReason = (
  decl: ParsedDeclaration,
  inputs: SkipInputs
): string | undefined => {
  const {absentPaths, conflicted, skipRegions} = inputs;

  if (skipRegions.has(decl.id)) return 'inputs not reconciled by this run';

  const conflictedPaths = decl.paths.filter((declPath) =>
    conflicted.has(declPath)
  );

  if (conflictedPaths.length > 0)
    return `region is not regenerated until the adopter resolves the conflict patch for: ${conflictedPaths.join(', ')}`;

  const missingPaths = decl.paths.filter((declPath) =>
    absentPaths.has(declPath)
  );

  if (missingPaths.length > 0)
    return `the adopter's tree does not carry: ${missingPaths.join(', ')}`;

  return undefined;
};

type OperandGuardContext = {
  realRoot: string;
  root: string;
  shippedKeys: ReadonlySet<string>;
};

/**
 * Step 3: refuse before anything is spawned. See the module doc's trust-model
 * note: this is a well-formedness guard, not a defense against a hostile
 * manifest.
 */
const checkOperand = (
  decl: ParsedDeclaration,
  context: OperandGuardContext
): string | undefined => {
  const {realRoot, root, shippedKeys} = context;
  const {interpreter, operand} = decl;

  if (path.isAbsolute(operand)) return 'operand is an absolute path';

  if (operand.split('/').includes('..'))
    return 'operand carries a parent-directory segment';

  if (!shippedKeys.has(normalizeRepoPath(operand)))
    return 'operand is not a path this manifest ships';

  let resolvedReal: string | undefined;

  try {
    resolvedReal = realpathSync(path.resolve(root, operand));
  } catch {
    // Target does not exist: not a refusal here, a spawn failure in step 6.
    resolvedReal = undefined;
  }

  if (resolvedReal !== undefined) {
    const insideRoot =
      resolvedReal === realRoot ||
      resolvedReal.startsWith(`${realRoot}${path.sep}`);

    if (!insideRoot)
      return 'operand resolves through a symlink out of the repository';
  }

  if (
    interpreter.trim() === '' ||
    path.isAbsolute(interpreter) ||
    interpreter.includes('/') ||
    interpreter.includes('\\')
  )
    return 'interpreter is not a bare program name';

  return undefined;
};

export type RegionContext = {
  absentPathSet: ReadonlySet<string>;
  backupDir: string | undefined;
  conflictedSet: ReadonlySet<string>;
  realRoot: string;
  /** Resolved once for the run; see `resolveRepoPrefix`. */
  repoPrefix: null | string;
  report: RegenRegionsReport;
  root: string;
  seenIds: Set<string>;
  shippedKeys: ReadonlySet<string>;
  skipRegionSet: ReadonlySet<string>;
};

/** Steps 4-8 for one region that passed well-formedness, skip, and operand checks. */
const runRegeneration = (
  decl: ParsedDeclaration,
  commandArgv: string[],
  context: RegionContext
): void => {
  const {backupDir, repoPrefix, report, root} = context;

  report.backedUp.push(
    ...performBackup({
      backupDir,
      paths: decl.paths,
      regionId: decl.id,
      root,
    })
  );

  const scopeDirs = scopeDirsFor(decl.paths);
  const before = collectScopeDigests(root, scopeDirs);
  const beforeStatus = gitStatusPaths(root, repoPrefix);

  const spawnResult = trySpawn(decl, root);

  const after = collectScopeDigests(root, scopeDirs);

  report.confined.push(
    ...sweepScope({
      after,
      before,
      declaredPaths: decl.paths,
      regionId: decl.id,
      root,
    })
  );

  reportOutOfScopeWrites({
    afterStatus: gitStatusPaths(root, repoPrefix),
    beforeStatus,
    decl,
    report,
    scopeDirs,
  });

  if (spawnResult.ok) {
    // Same question the sweep asks, so it takes the same answer. Comparing
    // digests alone called a declared path that is a link unchanged however
    // the spawn repointed it, because neither side has a digest to differ on.
    const rewrote = decl.paths.filter((declPath) => {
      const beforeEntry = before.get(declPath);

      return beforeEntry === undefined ?
          after.has(declPath)
        : !isUntouched(beforeEntry, after.get(declPath));
    });

    report.ran.push({argv: commandArgv, regionId: decl.id, rewrote});
  } else {
    report.failed.push({
      argv: commandArgv,
      cause: spawnResult.kind === 'killed' ? spawnResult.cause : undefined,
      kind: spawnResult.kind,
      message: spawnResult.message,
      regionId: decl.id,
      signal: spawnResult.kind === 'killed' ? spawnResult.signal : undefined,
      status: spawnResult.kind === 'exit' ? spawnResult.status : undefined,
    });
  }
};

/** Steps 1-3 for one `regions[]` entry: well-formedness, skip, operand guard. */
export const processRegion = (
  raw: unknown,
  index: number,
  context: RegionContext
): void => {
  const {
    absentPathSet,
    conflictedSet,
    realRoot,
    report,
    root,
    seenIds,
    shippedKeys,
    skipRegionSet,
  } = context;

  const parsedDecl = parseDeclaration(raw, index, seenIds);

  if (!parsedDecl.ok) {
    report.refused.push({
      kind: 'declaration',
      reason: parsedDecl.reason,
      regionId: parsedDecl.regionId,
    });

    return;
  }

  const decl = parsedDecl.declaration;
  const commandArgv = [decl.interpreter, decl.operand, ...decl.args];

  const skipReason = computeSkipReason(decl, {
    absentPaths: absentPathSet,
    conflicted: conflictedSet,
    skipRegions: skipRegionSet,
  });

  if (skipReason !== undefined) {
    report.skipped.push({
      argv: commandArgv,
      reason: skipReason,
      regionId: decl.id,
    });

    return;
  }

  const operandRefusal = checkOperand(decl, {realRoot, root, shippedKeys});

  if (operandRefusal !== undefined) {
    report.refused.push({
      argv: commandArgv,
      kind: 'operand',
      reason: operandRefusal,
      regionId: decl.id,
    });

    return;
  }

  runRegeneration(decl, commandArgv, context);
};
