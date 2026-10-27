import {readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {
  createWorkspace,
  removeWorkspace,
  restoreUnexpectedChanges,
} from './copies.js';
import type {WritePlan} from './plan.js';
import {writeSetOf} from './plan.js';
import type {PreCodemodFacts, Repairs, Ts} from './repairs/index.js';
import {
  exactFilesGlob,
  findMswMigrateBin,
  runCsfFactoriesCodemod,
  runMswMigrate,
} from './tools.js';
import type {CommandRunner} from './types.js';

export type ConversionContext = {
  packageDir: string;
  plan: WritePlan;
  repairs: Repairs;
  runCommand: CommandRunner;
  storybookVersion: string;
  ts: Ts;
};

export type ConversionOutcome =
  | {
      /** Write-set files (package-relative) whose bytes now differ from before. */
      changed: string[];
      kind: 'done';
      notes: string[];
      repairFailures: string[];
      /** Package-relative files outside the write set that were restored. */
      unexpected: string[];
    }
  | {kind: 'codemod-failed'; reason: string};

const readOriginal = (packageDir: string, relative: string): string =>
  readFileSync(path.join(packageDir, relative), 'utf8');

type StoryRepair = {output: string; relative: string};

const repairStories = (
  context: ConversionContext,
  workDir: string,
  facts: ReadonlyMap<string, PreCodemodFacts>
): {failures: string[]; notes: string[]; repaired: StoryRepair[]} => {
  const repaired: StoryRepair[] = [];
  const failures: string[] = [];
  const notes: string[] = [];

  context.plan.stories.forEach((relative) => {
    const absolute = path.join(context.packageDir, relative);
    const fileFacts = facts.get(relative);

    try {
      if (fileFacts === undefined) throw new Error('no pre-codemod facts');
      const result = context.repairs.repairStoryFile(
        context.ts,
        readFileSync(path.join(workDir, relative), 'utf8'),
        readOriginal(context.packageDir, relative),
        fileFacts,
        absolute
      );

      repaired.push({output: result.source, relative});
      result.notes.forEach((note) => notes.push(`${relative}: ${note}`));
    } catch (error: unknown) {
      failures.push(relative);
      notes.push(
        `${relative}: could not be converted (${error instanceof Error ? error.message : String(error)}); it was left unchanged.`
      );
    }
  });

  return {failures, notes, repaired};
};

/**
 * Runs the third-party tools against copies and brings back only the write
 * set. The adopter tree is touched at write-set paths only; anything else a
 * tool changed is restored from the pre-run copy.
 */
export const convert = (context: ConversionContext): ConversionOutcome => {
  const {packageDir, plan, repairs, runCommand, storybookVersion, ts} = context;
  const workspace = createWorkspace(packageDir);

  try {
    const facts = new Map<string, PreCodemodFacts>();

    plan.stories.forEach((relative) => {
      facts.set(
        relative,
        repairs.capturePreCodemodFacts(
          ts,
          readOriginal(packageDir, relative),
          path.join(packageDir, relative)
        )
      );
    });

    const glob = exactFilesGlob(plan.stories);
    const codemod = runCsfFactoriesCodemod(runCommand, {
      glob,
      storybookVersion,
      workDir: workspace.workDir,
    });

    if (!codemod.ok) return {kind: 'codemod-failed', reason: codemod.reason};

    const notes: string[] = [];
    const mswBin = findMswMigrateBin(workspace.workDir);

    if (mswBin !== undefined) {
      notes.push(
        ...runMswMigrate(runCommand, {
          binPath: mswBin,
          glob,
          workDir: workspace.workDir,
        })
      );
    }

    const stories = repairStories(context, workspace.workDir, facts);

    stories.repaired.forEach((entry) => {
      writeFileSync(path.join(packageDir, entry.relative), entry.output);
    });
    plan.configEdits.forEach((edit) => {
      writeFileSync(path.join(packageDir, edit.relative), edit.text);
    });

    const writeSet = writeSetOf(plan);
    const written = [
      ...stories.repaired.map((entry) => entry.relative),
      ...plan.configEdits.map((edit) => edit.relative),
    ];

    // Formatting only ever sees files this run wrote; its exit code is not a
    // verdict (unfixable lint is the verification step's finding).
    // With no file operands ESLint would fix the whole package, so an empty
    // list skips the call.
    if (written.length > 0) {
      runCommand(
        'pnpm',
        ['-C', packageDir, 'exec', 'eslint', '--fix', ...written],
        {cwd: packageDir}
      );
    }

    const unexpected = restoreUnexpectedChanges(
      packageDir,
      workspace,
      new Set(writeSet)
    );
    const changed = writeSet.filter(
      (relative) =>
        !readFileSync(path.join(packageDir, relative)).equals(
          readFileSync(path.join(workspace.beforeDir, relative))
        )
    );

    return {
      changed,
      kind: 'done',
      notes: [...notes, ...stories.notes],
      repairFailures: stories.failures,
      unexpected,
    };
  } finally {
    removeWorkspace(workspace);
  }
};
