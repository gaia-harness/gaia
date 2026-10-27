/**
 * `gaia update regen-regions --manifest <path> --root <dir> [--backup-dir <dir>]
 *   [--conflicted <repo-relative-path>]... [--absent-path <repo-relative-path>]...
 *   [--skip-region <id>]... [--json]` handler.
 *
 * Regeneration runner for declared generated regions. `merge-region.ts`
 * only classifies a region's divergence; this command is what makes a declared
 * region correct again after an update, by running its shipped regeneration
 * command against the adopter's OWN post-merge tree. Unlike the oracle, this
 * command is not pure: it spawns a process and writes files.
 *
 * Reads the `regions` declaration array straight off `--manifest` as raw JSON.
 * The adopter side does no schema validation of the manifest, so every field
 * here is treated as untrusted shape: a malformed declaration is refused, never
 * thrown.
 *
 * **Trust model.** The shipped-path / symlink / parent-segment checks in
 * `checkOperand` are a well-formedness guard against a stale, corrupt, or
 * hand-edited declaration. The update flow already extracts and runs the
 * release tarball's bundled tool, and the tarball is transport-authenticated
 * only, so these checks are not, and must not be described as, a defense
 * against an adversary who controls the manifest.
 *
 * **Write confinement.** A region's regeneration command legitimately rewrites
 * every path it owns, but nothing else. Before the spawn, this command hashes
 * every file and reads every symlink under the union of the declared paths'
 * parent directories (the "snapshot scope"); after the spawn, any other path
 * in that scope which was rewritten, retargeted, or replaced with the other
 * kind is put back to its pre-image, and any other path in scope the spawn
 * newly created is removed. A path in scope the spawn deletes is neither
 * restored nor reported. A `git status --porcelain -z`
 * before/after pair also catches a write anywhere else in the tree; that has
 * no pre-image to restore from, so it is only reported, never reverted. The
 * spawn never runs through a shell and never takes a shell-interpreted
 * string: it is always a fixed argv array, and it is bounded in output and
 * runtime.
 *
 * Exit codes: 0 for every refusal, skip, spawn failure, or non-zero program
 * exit; 1 only when the flags or `--manifest` itself are unusable.
 */
import {existsSync, readFileSync, realpathSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {describeJsonShape, isPlainObject} from './regen-regions-declaration.js';
import type {Flags} from './regen-regions-flags.js';
import {parseFlags} from './regen-regions-flags.js';
import {processRegion} from './regen-regions-region.js';
import type {RegionContext} from './regen-regions-region.js';
import {resolveRepoPrefix} from './regen-regions-spawn.js';
import type {RegenRegionsReport} from './regen-regions-types.js';

export {spawnFailureCause} from './regen-regions-spawn.js';

export type {RegenRegionsReport} from './regen-regions-types.js';

const HELP_TEXT = `Usage: gaia update regen-regions --manifest <path> --root <dir> [--backup-dir <dir>]
                                  [--conflicted <repo-relative-path>]...
                                  [--absent-path <repo-relative-path>]...
                                  [--skip-region <id>]... [--json]

  Runs each declared region's regeneration command against <root>, one region
  at a time. A region named by --skip-region, or one of whose declared paths
  appears in --conflicted or --absent-path, is left alone. A declaration that
  fails well-formedness, or an operand that fails the shipped-path / symlink /
  parent-segment guard, is refused before anything is spawned. Writes outside
  a region's declared paths are reverted when changed (inside the region's
  own directories) or reported (anywhere else); a deletion inside the
  region's own directories is neither restored nor reported.

  Read the manifest's regions from a RELEASE copy, never the adopter's stale
  working-tree copy: pass $LATEST_DIR/.gaia/manifest.json as --manifest.

  Each regeneration program gets 5 minutes and 32 MiB of output before it is
  killed. A program stopped by either bound is reported as killed with the
  bound named, so a command that legitimately needs more is told what stopped
  it rather than left looking like one that never started.

  Exit codes:
    0  success, including every refusal, skip, spawn failure, or non-zero
       program exit
    1  user-correctable error (missing flag / unreadable or unparseable
       --manifest / missing --root)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const resolvePath = (cwd: string, value: string): string =>
  path.isAbsolute(value) ? value : path.join(cwd, value);

type LoadedInputs = {
  backupDir: string | undefined;
  manifestRecord: Record<string, unknown>;
  /** `null` when the manifest is a plain object; else its shape name. */
  manifestShape: null | string;
  realRoot: string;
  root: string;
};

type LoadResult = {ok: false} | {ok: true; value: LoadedInputs};

type RunOptions = {
  cwd?: string;
};

/**
 * Reads and validates `--manifest` and `--root` before any region is
 * processed. Every failure here already wrote its own `structuredError`;
 * the caller only needs to know whether to keep going.
 */
const loadRunInputs = (cwd: string, flags: Flags): LoadResult => {
  const manifestPath = resolvePath(cwd, flags.manifest);
  const root = resolvePath(cwd, flags.root);
  const backupDir =
    flags.backupDir === undefined ?
      undefined
    : resolvePath(cwd, flags.backupDir);

  if (!existsSync(manifestPath)) {
    structuredError({
      code: 'manifest_not_found',
      message: `manifest not found: ${manifestPath}`,
      subcommand: 'update regen-regions',
    });

    return {ok: false};
  }

  let manifestRaw: string;

  try {
    manifestRaw = readFileSync(manifestPath, 'utf8');
  } catch (error) {
    structuredError({
      code: 'manifest_read_failed',
      message: `manifest could not be read (${manifestPath}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      subcommand: 'update regen-regions',
    });

    return {ok: false};
  }

  let manifestParsed: unknown;

  try {
    manifestParsed = JSON.parse(manifestRaw);
  } catch (error) {
    structuredError({
      code: 'manifest_parse_failed',
      message: `manifest is not valid JSON (${manifestPath}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      subcommand: 'update regen-regions',
    });

    return {ok: false};
  }

  if (!existsSync(root)) {
    structuredError({
      code: 'root_not_found',
      message: `root directory not found: ${root}`,
      subcommand: 'update regen-regions',
    });

    return {ok: false};
  }

  let realRoot: string;

  try {
    realRoot = realpathSync(root);
  } catch (error) {
    structuredError({
      code: 'root_unreadable',
      message: `root directory could not be resolved (${root}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      subcommand: 'update regen-regions',
    });

    return {ok: false};
  }

  // Two returns rather than one, so the type guard narrows `manifestParsed`
  // for `manifestRecord` on the arm that keeps it.
  if (isPlainObject(manifestParsed))
    return {
      ok: true,
      value: {
        backupDir,
        manifestRecord: manifestParsed,
        manifestShape: null,
        realRoot,
        root,
      },
    };

  // A manifest that parsed but is not an object has no `regions` key to be
  // wrong-typed, so without a shape name it would reach the caller as an
  // empty record and read exactly like a release predating the mechanism.
  return {
    ok: true,
    value: {
      backupDir,
      manifestRecord: {},
      manifestShape: describeJsonShape(manifestParsed),
      realRoot,
      root,
    },
  };
};

const printHuman = (report: RegenRegionsReport): void => {
  const lines = [
    'gaia update regen-regions',
    `  Ran:       ${report.ran.length}`,
    `  Refused:   ${report.refused.length}`,
    `  Skipped:   ${report.skipped.length}`,
    `  Failed:    ${report.failed.length}`,
    `  Backed up: ${report.backedUp.length}`,
    `  Confined:  ${report.confined.length}`,
  ];

  process.stdout.write(`${lines.join('\n')}\n`);
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [firstArgument] = argv;

  if (firstArgument !== undefined && HELP_TOKENS.has(firstArgument)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'update regen-regions',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const loaded = loadRunInputs(cwd, parsed.flags);

  if (!loaded.ok) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const {backupDir, manifestRecord, manifestShape, realRoot, root} =
    loaded.value;
  const regionsValue = manifestRecord.regions;
  const regionsAreArray = Array.isArray(regionsValue);
  const rawRegions = regionsAreArray ? regionsValue : [];
  const filesMap =
    isPlainObject(manifestRecord.files) ? manifestRecord.files : {};
  const shippedKeys = new Set(Object.keys(filesMap));

  const context: RegionContext = {
    absentPathSet: new Set(parsed.flags.absentPaths),
    backupDir,
    conflictedSet: new Set(parsed.flags.conflicted),
    realRoot,
    // Not resolved at all when there is no region to process, which is the
    // ordinary shape of a release predating the region mechanism, and the
    // value is then unreachable.
    repoPrefix: rawRegions.length > 0 ? resolveRepoPrefix(root) : null,
    report: {
      backedUp: [],
      confined: [],
      failed: [],
      ran: [],
      refused: [],
      skipped: [],
    },
    root,
    seenIds: new Set<string>(),
    shippedKeys,
    skipRegionSet: new Set(parsed.flags.skipRegions),
  };

  // An absent `regions` key is the legitimate "this release predates the
  // region mechanism" case, and produces an empty report. A present key of
  // the wrong type is a manifest this command could not read; collapsing it
  // into the same empty report would tell the adopter the release carries no
  // regions, with every downstream region guarantee silently not applying.
  //
  // `(manifest)` names the manifest itself rather than a region: the refusal
  // is run-level, and the parentheses keep it clear of a real declared id,
  // which `parseDeclaration` requires to be a non-empty string.
  if (manifestShape !== null)
    context.report.refused.push({
      kind: 'manifest',
      reason: `manifest top level is not an object: ${manifestShape}`,
      regionId: '(manifest)',
    });
  else if (regionsValue !== undefined && !regionsAreArray)
    context.report.refused.push({
      kind: 'manifest',
      reason: `regions is present but is not an array: ${describeJsonShape(regionsValue)}`,
      regionId: '(manifest)',
    });

  rawRegions.forEach((raw, index) => {
    processRegion(raw, index, context);
  });

  if (parsed.flags.json) {
    process.stdout.write(`${JSON.stringify(context.report)}\n`);
  } else {
    printHuman(context.report);
  }

  return EXIT_CODES.OK;
};
