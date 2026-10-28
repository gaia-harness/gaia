import semver from 'semver';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {resolvePackageTarget} from '../util/package-target.js';
import {convert} from './convert.js';
import {
  findMainPath,
  findPreviewPath,
  inventoryStoryFiles,
} from './inventory.js';
import {classifyStories, computeWritePlan, writeSetOf} from './plan.js';
import {dirtyTreePaths, dirtyWriteSetPaths} from './preflight.js';
import type {Ts} from './repairs/index.js';
import {
  buildRestoreCommand,
  emptyReport,
  refusedReport,
  renderHumanReport,
  reportPassed,
} from './report.js';
import type {
  MigrateDeps,
  MigrateOptions,
  MigrateReport,
  RefusalReason,
} from './types.js';
import {runLint, runStoryTests, runTypecheck} from './verify.js';

const SUPPORTED_STORYBOOK_RANGE = '~10.6.0';

const CSF2_CODEMOD =
  "Storybook's `csf-2-to-3` codemod (`npx storybook migrate csf-2-to-3`)";

type Refusal = {
  message: string;
  paths: readonly string[];
  reason: RefusalReason;
};

type Resolved = {
  packageDir: string;
  packagePath: string;
  repoRoot: string;
  storybookVersion: string;
  ts: Ts;
};

const toRepoPath = (packagePath: string, relative: string): string =>
  packagePath === '.' ? relative : path.posix.join(packagePath, relative);

const asRepoPaths = (
  packagePath: string,
  relatives: readonly string[]
): string[] => relatives.map((relative) => toRepoPath(packagePath, relative));

const readInstalledStorybookVersion = (
  packageDir: string
): string | undefined => {
  const manifest = path.join(
    packageDir,
    'node_modules',
    'storybook',
    'package.json'
  );

  if (!existsSync(manifest)) return undefined;

  return (JSON.parse(readFileSync(manifest, 'utf8')) as {version?: string})
    .version;
};

const listLines = (paths: readonly string[]): string =>
  paths.map((entry) => `  ${entry}`).join('\n');

const resolveEnvironment = (
  deps: MigrateDeps
): Resolved | {packagePath: string; refusal: Refusal} => {
  const target = resolvePackageTarget(deps.cwd, 'frontend');

  if (!target.ok) {
    return {
      packagePath: '',
      refusal: {message: target.message, paths: [], reason: 'package-config'},
    };
  }
  const {packageDir, packagePath, repoRoot} = target;
  const storybookVersion = readInstalledStorybookVersion(packageDir);

  if (
    storybookVersion === undefined ||
    !semver.satisfies(storybookVersion, SUPPORTED_STORYBOOK_RANGE)
  ) {
    return {
      packagePath,
      refusal: {
        message: `installed storybook is ${storybookVersion ?? 'not found'}; this migration supports ${SUPPORTED_STORYBOOK_RANGE}.`,
        paths: [],
        reason: 'storybook-version',
      },
    };
  }
  const ts = deps.loadTypescript(packageDir);

  if (ts === undefined) {
    return {
      packagePath,
      refusal: {
        message: `typescript is not resolvable from ${packagePath}; install the package's dependencies first.`,
        paths: [],
        reason: 'typescript',
      },
    };
  }

  return {packageDir, packagePath, repoRoot, storybookVersion, ts};
};

const formatRefusals = (
  classified: {csf2: string[]; unknown: string[]},
  packagePath: string
): Refusal | undefined => {
  if (classified.csf2.length > 0) {
    const paths = asRepoPaths(packagePath, classified.csf2);

    return {
      message: `these files are CSF2; convert them to CSF3 first with ${CSF2_CODEMOD}, then re-run:\n${listLines(paths)}`,
      paths,
      reason: 'csf2',
    };
  }

  if (classified.unknown.length > 0) {
    const paths = asRepoPaths(packagePath, classified.unknown);

    return {
      message: `the story format of these files could not be determined:\n${listLines(paths)}`,
      paths,
      reason: 'unknown-format',
    };
  }

  return undefined;
};

const checkCleanTree = (
  options: MigrateOptions,
  repoRoot: string,
  writeSet: readonly string[]
): Refusal | undefined => {
  if (options.updateMerge) {
    const dirty = dirtyWriteSetPaths(repoRoot, writeSet);

    return dirty.length === 0 ?
        undefined
      : {
          message: `these files are untracked or differ from HEAD and the migration would rewrite them; commit them or set them aside:\n${listLines(dirty)}`,
          paths: dirty,
          reason: 'dirty-write-set',
        };
  }
  const dirty = dirtyTreePaths(repoRoot);

  return dirty.length === 0 ?
      undefined
    : {
        message: `the working tree must be clean before the migration writes anything; commit or stash these paths:\n${listLines(dirty)}`,
        paths: dirty,
        reason: 'dirty-tree',
      };
};

/**
 * The command's core. Everything process-adjacent that a test needs to steer
 * arrives through `deps`; git and the filesystem are real.
 */
export const runMigrateCsf4 = (
  options: MigrateOptions,
  deps: MigrateDeps
): number => {
  const {repairs, runCommand} = deps;

  const refuse = (packagePath: string, refusal: Refusal): number => {
    deps.writeErr(
      `migrate-csf4 refused (${refusal.reason}): ${refusal.message}\n`
    );

    if (options.json) {
      deps.writeOut(
        `${JSON.stringify(refusedReport(packagePath, refusal.reason, refusal.paths))}\n`
      );
    }

    return EXIT_CODES.COULD_NOT_RUN;
  };

  const environment = resolveEnvironment(deps);

  if ('refusal' in environment) {
    return refuse(environment.packagePath, environment.refusal);
  }
  const {packageDir, packagePath, repoRoot, storybookVersion, ts} = environment;
  const inventory = inventoryStoryFiles(ts, packageDir);
  const classified = classifyStories({
    packageDir,
    repairs,
    storyFiles: inventory.storyFiles,
    ts,
  });
  const formatRefusal = formatRefusals(classified, packagePath);

  if (formatRefusal !== undefined) return refuse(packagePath, formatRefusal);

  const plan = computeWritePlan({
    csf3Stories: classified.csf3,
    packageDir,
    repairs,
    ts,
  });
  const treeRefusal = checkCleanTree(
    options,
    repoRoot,
    asRepoPaths(packagePath, writeSetOf(plan))
  );

  if (treeRefusal !== undefined) return refuse(packagePath, treeRefusal);

  const report: MigrateReport = emptyReport(packagePath);
  const notes: string[] = [];
  let repairFailures: string[] = [];

  if (inventory.fallbackReason !== undefined) {
    notes.push(
      `Story files were found with the default glob because ${inventory.fallbackReason}.`
    );
  }
  report.unknownAddons = plan.unknownAddons;

  if (writeSetOf(plan).length > 0) {
    const outcome = convert({
      packageDir,
      plan,
      repairs,
      runCommand,
      storybookVersion,
      ts,
    });

    if (outcome.kind === 'codemod-failed') {
      return refuse(packagePath, {
        message: outcome.reason,
        paths: [],
        reason: 'codemod-fetch',
      });
    }
    report.converted = asRepoPaths(packagePath, outcome.changed);
    report.restore = buildRestoreCommand(report.converted);
    report.unexpectedChanges = asRepoPaths(packagePath, outcome.unexpected);
    repairFailures = [...outcome.repairFailures];
    plan.stories.forEach((relative) => {
      const absolute = path.join(packageDir, relative);

      if (repairFailures.includes(relative)) return;

      const format = repairs.classifyStoryFile(
        ts,
        readFileSync(absolute, 'utf8'),
        absolute
      );

      if (format !== 'csf4') {
        repairFailures.push(relative);
        notes.push(
          `${relative}: still ${format.toUpperCase()} after conversion.`
        );
      }
    });
    notes.push(...outcome.notes);
  }

  const context = {packageDir, repoRoot};
  const lintTargets = [
    ...inventory.storyFiles,
    ...[findPreviewPath(packageDir), findMainPath(packageDir)]
      .filter((entry) => entry !== undefined)
      .map((entry) => path.relative(packageDir, entry)),
  ];

  report.typecheck = runTypecheck(runCommand, context);
  report.lint = runLint(runCommand, context, lintTargets);
  report.files = runStoryTests(runCommand, {
    ...context,
    storyFiles: inventory.storyFiles,
  });

  if (repairFailures.length > 0) {
    notes.push(`Conversion failed for: ${repairFailures.join(', ')}`);
  }

  // The JSON object has no field for notes, and stdout carries only that object.
  if (options.json && notes.length > 0) deps.writeErr(`${notes.join('\n')}\n`);
  deps.writeOut(
    options.json ?
      `${JSON.stringify(report)}\n`
    : renderHumanReport(report, notes)
  );

  return reportPassed(report) && repairFailures.length === 0 ?
      EXIT_CODES.OK
    : EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
