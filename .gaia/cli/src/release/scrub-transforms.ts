import {existsSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {stripMarkerBlocks} from './marker-strip.js';
import type {MarkerIssueReason} from './marker-strip.js';
import {checkStrippedPair} from './pnpm-member-strip.js';
import type {
  PnpmMemberStripInput,
  PnpmMemberStripOutcome,
  PnpmStripRefusal,
} from './pnpm-member-strip.js';
import type {
  LeakCheckTransform,
  MarkerStripTransform,
  PnpmMemberStripTransform,
  ScrubConfig,
} from './scrub-config.js';
import {
  isDerivedCheck,
  runDerivedRefsCheck,
  runDerivedWikilinkCheck,
  runDerivedWorkflowCheck,
} from './scrub-derived-checks.js';
import {matchesAnyGlob} from './scrub-glob.js';
import {
  applyJsonStrip,
  applyJsonStripArrayElement,
} from './scrub-json-strip.js';
import {runLeakCheck, trackLineAllowlist} from './scrub-leak-scan.js';
import type {AllowlistWarning, Leak} from './scrub-leak-scan.js';
import {runDerivedTitleCheck} from './scrub-title-check.js';

// Marker strip

export type MarkerStripResult = {
  blocksStripped: number;
  filesTouched: readonly string[];
  unbalanced: readonly {
    file: string;
    line: number;
    reason: MarkerIssueReason;
  }[];
};

const applyMarkerStrip = (
  stagingRoot: string,
  files: readonly string[],
  transform: MarkerStripTransform
): MarkerStripResult => {
  const filesTouched: string[] = [];
  const unbalanced: {
    file: string;
    line: number;
    reason: MarkerIssueReason;
  }[] = [];
  let blocksStripped = 0;

  for (const relativePath of files) {
    if (matchesAnyGlob(relativePath, transform.paths)) {
      const absolutePath = path.join(stagingRoot, relativePath);
      const source = readFileSync(absolutePath, 'utf8');
      const hasAnyMarker =
        source.includes(transform.start) || source.includes(transform.end);

      if (hasAnyMarker) {
        const result = stripMarkerBlocks(
          source,
          transform.start,
          transform.end
        );

        for (const issue of result.unbalanced) {
          unbalanced.push({
            file: relativePath,
            line: issue.line,
            reason: issue.reason,
          });
        }

        if (result.blocks > 0) {
          // The atomic write renames a fresh file over the source, so the
          // source's mode is lost unless passed through; a stripped hook or
          // shell script must stay executable in the bundle.
          atomicWriteFileSync(absolutePath, result.output, {
            mode: statSync(absolutePath).mode % 0o1000,
          });
          filesTouched.push(relativePath);
          blocksStripped += result.blocks;
        }
      }
    }
  }

  return {blocksStripped, filesTouched, unbalanced};
};

// pnpm member strip

export type PnpmMemberStripper = (
  input: PnpmMemberStripInput
) => PnpmMemberStripOutcome;

type PnpmMemberStripRefusal = {
  detail: string;
  file: string;
  token: PnpmStripRefusal;
};

type PnpmMemberStripResult = {
  filesTouched: readonly string[];
  importersRemoved: number;
  packagesRemoved: number;
  refusal: null | PnpmMemberStripRefusal;
  snapshotsRemoved: number;
};

const NOTHING_STRIPPED = {
  filesTouched: [],
  importersRemoved: 0,
  packagesRemoved: 0,
  refusal: null,
  snapshotsRemoved: 0,
} as const;

/**
 * Writes the staged pair only after the outcome is `stripped` AND passes
 * `checkStrippedPair`, which runs here as well as inside the stripper so an
 * injected or faulty stripper still cannot write a pair that fails it. A
 * staging tree carrying neither file has nothing to strip.
 */
const applyPnpmMemberStrip = (
  stagingRoot: string,
  transform: PnpmMemberStripTransform,
  strip: PnpmMemberStripper
): PnpmMemberStripResult => {
  const paths = {
    lockfile: path.join(stagingRoot, transform.lockfile),
    workspace: path.join(stagingRoot, transform.workspace),
  };
  const present = {
    lockfile: existsSync(paths.lockfile),
    workspace: existsSync(paths.workspace),
  };

  if (!present.lockfile && !present.workspace) return NOTHING_STRIPPED;

  if (!present.lockfile || !present.workspace) {
    const missing = present.lockfile ? 'workspace' : 'lockfile';

    return {
      ...NOTHING_STRIPPED,
      refusal: {
        detail: 'staged without its pnpm counterpart file',
        file: paths[missing],
        token: 'unparseable',
      },
    };
  }

  const input = {
    lockfile: readFileSync(paths.lockfile, 'utf8'),
    member: transform.member,
    workspace: readFileSync(paths.workspace, 'utf8'),
  };
  const stripped = strip(input);
  const outcome =
    stripped.kind === 'stripped' ?
      (checkStrippedPair(input, stripped) ?? stripped)
    : stripped;

  if (outcome.kind === 'noop') return NOTHING_STRIPPED;

  if (outcome.kind === 'refused') {
    return {
      ...NOTHING_STRIPPED,
      refusal: {
        detail: outcome.detail,
        file: paths[outcome.file],
        token: outcome.token,
      },
    };
  }

  atomicWriteFileSync(paths.workspace, outcome.workspace);
  atomicWriteFileSync(paths.lockfile, outcome.lockfile);

  return {
    filesTouched: [transform.workspace, transform.lockfile],
    importersRemoved: outcome.removed.importers.length,
    packagesRemoved: outcome.removed.packages.length,
    refusal: null,
    snapshotsRemoved: outcome.removed.snapshots.length,
  };
};

type ScrubContext = {
  cwd: string;
  stagedFiles: readonly string[];
  stagingDir: string;
  stripPnpmMember: PnpmMemberStripper;
};

/**
 * Runs every check in one `leak-check` transform: derived checks (which also
 * read source inputs from `ctx.cwd` rather than the staging tree, see
 * `buildExcludedSlugSet`) and static regex checks alike.
 */
const runLeakChecksForTransform = (
  transform: LeakCheckTransform,
  ctx: ScrubContext
): {leaks: Leak[]; warnings: AllowlistWarning[]} => {
  const leaks: Leak[] = [];
  const warnings: AllowlistWarning[] = [];
  const scopeSkip = transform['scope-skip'] ?? [];

  for (const check of transform.checks) {
    const allowlist = trackLineAllowlist(check);

    if (isDerivedCheck(check)) {
      const args = {
        allowlist,
        cwd: ctx.cwd,
        files: ctx.stagedFiles,
        scopeSkip,
        stagingRoot: ctx.stagingDir,
      };

      if (check.derive === 'excluded-titles') {
        leaks.push(...runDerivedTitleCheck({check, ...args}));
      } else if (check.derive === 'excluded-refs') {
        const result = runDerivedRefsCheck({check, ...args});

        leaks.push(...result.leaks);
        warnings.push(...result.warnings);
      } else {
        const runDerived =
          check.derive === 'excluded-workflows' ?
            runDerivedWorkflowCheck
          : runDerivedWikilinkCheck;

        leaks.push(...runDerived({check, ...args}));
      }
    } else {
      leaks.push(
        ...runLeakCheck({
          allowlist,
          check,
          files: ctx.stagedFiles,
          scopeSkip,
          stagingRoot: ctx.stagingDir,
        })
      );
    }

    warnings.push(...allowlist.unused());
  }

  return {leaks, warnings};
};

type TransformResults = {
  jsonStripArrayElementFiles: string[];
  jsonStripArrayElementsRemoved: number;
  jsonStripFiles: string[];
  jsonStripKeysRemoved: number;
  leaks: Leak[];
  pnpmFiles: string[];
  pnpmImportersRemoved: number;
  pnpmPackagesRemoved: number;
  pnpmRefusal: null | PnpmMemberStripRefusal;
  pnpmSnapshotsRemoved: number;
  stripBlocks: number;
  stripFiles: string[];
  unbalanced: {file: string; line: number; reason: string}[];
  warnings: AllowlistWarning[];
};

// After marker-strip and json-strip land, leak-check sees the post-strip
// tree because we re-read each file fresh inside the check. A refused pnpm
// member strip stops the run: the later transforms would only report the
// same unscrubbed member again.
const runTransforms = (
  config: ScrubConfig,
  ctx: ScrubContext
): TransformResults => {
  const results: TransformResults = {
    jsonStripArrayElementFiles: [],
    jsonStripArrayElementsRemoved: 0,
    jsonStripFiles: [],
    jsonStripKeysRemoved: 0,
    leaks: [],
    pnpmFiles: [],
    pnpmImportersRemoved: 0,
    pnpmPackagesRemoved: 0,
    pnpmRefusal: null,
    pnpmSnapshotsRemoved: 0,
    stripBlocks: 0,
    stripFiles: [],
    unbalanced: [],
    warnings: [],
  };

  for (const transform of config.transforms) {
    if (results.pnpmRefusal !== null) break;

    if (transform.type === 'marker-strip') {
      const result = applyMarkerStrip(
        ctx.stagingDir,
        ctx.stagedFiles,
        transform
      );
      results.stripBlocks += result.blocksStripped;
      results.stripFiles.push(...result.filesTouched);
      results.unbalanced.push(...result.unbalanced);
    } else if (transform.type === 'json-strip') {
      const result = applyJsonStrip(ctx.stagingDir, ctx.stagedFiles, transform);
      results.jsonStripKeysRemoved += result.keysRemoved;
      results.jsonStripFiles.push(...result.filesTouched);
    } else if (transform.type === 'json-strip-array-element') {
      const result = applyJsonStripArrayElement(
        ctx.stagingDir,
        ctx.stagedFiles,
        transform
      );
      results.jsonStripArrayElementsRemoved += result.elementsRemoved;
      results.jsonStripArrayElementFiles.push(...result.filesTouched);
    } else if (transform.type === 'pnpm-member-strip') {
      const result = applyPnpmMemberStrip(
        ctx.stagingDir,
        transform,
        ctx.stripPnpmMember
      );
      results.pnpmFiles.push(...result.filesTouched);
      results.pnpmImportersRemoved += result.importersRemoved;
      results.pnpmPackagesRemoved += result.packagesRemoved;
      results.pnpmSnapshotsRemoved += result.snapshotsRemoved;
      results.pnpmRefusal = result.refusal;
    } else {
      const result = runLeakChecksForTransform(transform, ctx);
      results.leaks.push(...result.leaks);
      results.warnings.push(...result.warnings);
    }
  }

  return results;
};

export const tryRunTransformsOrReport = (
  config: ScrubConfig,
  ctx: ScrubContext
): null | TransformResults => {
  try {
    return runTransforms(config, ctx);
  } catch (error) {
    structuredError({
      code: 'transform_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release scrub',
    });

    return null;
  }
};
