import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import type {CommandResult, CommandRunner} from './types.js';

const GLOB_SPECIAL = /[$()*?[\\\]{}!,]/gu;

/**
 * A glob naming exactly these package-relative files. One file is the plain
 * path: a one-member brace group is not expanded by every glob engine.
 */
export const exactFilesGlob = (files: readonly string[]): string => {
  const escaped = files.map((file) =>
    file.replaceAll(GLOB_SPECIAL, String.raw`\$&`)
  );

  return escaped.length === 1 ? (escaped[0] ?? '') : `{${escaped.join(',')}}`;
};

export type CodemodOutcome =
  {ok: false; reason: string} | {ok: true; result: CommandResult};

/**
 * Storybook's `csf-factories` migration, run with `work/` as its working
 * directory. The package manager's remote runner fetches `@storybook/cli` at
 * the installed `storybook` version, which is the exact thing the installed
 * `storybook` dispatcher does for `automigrate` (its `@storybook/cli` is not
 * installed); naming the version here makes the pin explicit and testable.
 *
 * Behavior the design depends on: under `--yes` outside Storybook's sandbox the
 * codemod writes relative preview imports and never edits `package.json`
 * `imports` (the repairs replace those imports); it first runs
 * `storybook migrate csf-2-to-3 --glob=...` through the package manager; after
 * the stories it always rewrites main and preview and syncs the preview's
 * addons. It installs no package (confirmed against the 10.6 source;
 * `--skip-install` and `--skip-doctor` keep the automigrate wrapper from
 * installing or running its doctor check either). Every write lands in `work/` and the
 * main, preview and `package.json` edits are discarded.
 */
export const runCsfFactoriesCodemod = (
  runCommand: CommandRunner,
  options: {glob: string; storybookVersion: string; workDir: string}
): CodemodOutcome => {
  const result = runCommand(
    'pnpm',
    [
      'dlx',
      `@storybook/cli@${options.storybookVersion}`,
      'automigrate',
      'csf-factories',
      '--yes',
      '--skip-install',
      '--skip-doctor',
      `--glob=${options.glob}`,
    ],
    {cwd: options.workDir}
  );

  if (result.exitCode !== 0) {
    const tail = `${result.stderr}\n${result.stdout}`
      .trim()
      .split('\n')
      .slice(-8);

    return {
      ok: false,
      reason: `The Storybook codemod did not complete (it is fetched from the npm registry, so this command needs network access):\n${tail.join('\n')}`,
    };
  }

  return {ok: true, result};
};

/** The installed `msw-storybook-addon` migrate bin inside `work/`, if the addon is installed. */
export const findMswMigrateBin = (workDir: string): string | undefined => {
  const packageJsonPath = path.join(
    workDir,
    'node_modules',
    'msw-storybook-addon',
    'package.json'
  );

  if (!existsSync(packageJsonPath)) return undefined;
  const parsed = JSON.parse(readFileSync(packageJsonPath, 'utf8')) as {
    bin?: Record<string, string> | string;
  };
  const bin =
    typeof parsed.bin === 'string' ?
      parsed.bin
    : parsed.bin?.['msw-storybook-addon'];

  return bin === undefined ? undefined : (
      path.join(path.dirname(packageJsonPath), bin)
    );
};

/**
 * The addon's own migrate bin, run with `work/` as its working directory. It
 * takes only a glob (no file list) and rewrites `work/`'s preview and main on
 * every non-dry run; those edits are discarded with the rest of `work/`.
 * Returns the lines it reports as skipped, for the report to carry.
 */
export const runMswMigrate = (
  runCommand: CommandRunner,
  options: {binPath: string; glob: string; workDir: string}
): string[] => {
  const result = runCommand(
    'node',
    [options.binPath, 'migrate', '--glob', options.glob],
    {cwd: options.workDir}
  );
  const output = `${result.stdout}\n${result.stderr}`;
  const notes: string[] = [];

  if (result.exitCode !== 0) {
    notes.push(
      `msw-storybook-addon migrate exited ${String(result.exitCode)}; any parameters.msw story it skipped needs a hand migration.`
    );
  }
  output.split('\n').forEach((line) => {
    if (
      /migrate (?:them )?manually|could not (?:migrate|recognize)|^\s*•\s/iu.test(
        line
      )
    ) {
      notes.push(`msw-storybook-addon migrate: ${line.trim()}`);
    }
  });

  return notes;
};
