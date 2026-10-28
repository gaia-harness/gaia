import {
  existsSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import type {CommandRunner, FileOutcome, StepResult} from './types.js';

type StepOutcome = {files: string[]; result: StepResult};

type VitestAssertion = {fullName?: string; status?: string; title?: string};
type VitestFileResult = {
  assertionResults?: VitestAssertion[];
  name?: string;
  status?: string;
};

const TSC_PARENTHESIZED = /^(.+?)\(\d+,\d+\): error TS\d+/u;
const TSC_PRETTY = /^(.+?):\d+:\d+ - error TS\d+/u;

const canonical = (filePath: string): string => {
  try {
    return realpathSync(filePath);
  } catch {
    return path.resolve(filePath);
  }
};

const toRepoRelative = (
  repoRoot: string,
  packageDir: string,
  filePath: string
): string =>
  path
    .relative(repoRoot, path.resolve(packageDir, filePath))
    .split(path.sep)
    .join('/');

export const parseTscFiles = (
  output: string,
  context: {packageDir: string; repoRoot: string}
): string[] => {
  const found: string[] = [];

  output.split('\n').forEach((line) => {
    const match = TSC_PARENTHESIZED.exec(line) ?? TSC_PRETTY.exec(line);

    if (match?.[1] !== undefined) {
      const entry = toRepoRelative(
        context.repoRoot,
        context.packageDir,
        match[1].trim()
      );

      if (!found.includes(entry)) found.push(entry);
    }
  });

  return found.toSorted((left, right) => left.localeCompare(right));
};

export const parseEslintFiles = (
  json: string,
  context: {packageDir: string; repoRoot: string}
): string[] | undefined => {
  try {
    const parsed = JSON.parse(json) as {
      errorCount?: number;
      filePath?: string;
    }[];

    return parsed
      .filter((entry) => (entry.errorCount ?? 0) > 0 && entry.filePath)
      .map((entry) =>
        toRepoRelative(
          context.repoRoot,
          context.packageDir,
          entry.filePath ?? ''
        )
      )
      .toSorted((left, right) => left.localeCompare(right));
  } catch {
    return undefined;
  }
};

export const runTypecheck = (
  runCommand: CommandRunner,
  context: {packageDir: string; repoRoot: string}
): StepOutcome => {
  const outcome = runCommand('pnpm', ['-C', context.packageDir, 'typecheck'], {
    cwd: context.repoRoot,
  });

  if (outcome.exitCode === 0) return {files: [], result: 'pass'};

  return {
    files: parseTscFiles(`${outcome.stdout}\n${outcome.stderr}`, context),
    result: 'fail',
  };
};

export const runLint = (
  runCommand: CommandRunner,
  context: {packageDir: string; repoRoot: string},
  relativeFiles: readonly string[]
): StepOutcome => {
  const outcome = runCommand(
    'pnpm',
    [
      '-C',
      context.packageDir,
      'exec',
      'eslint',
      '--format',
      'json',
      ...relativeFiles,
    ],
    {cwd: context.repoRoot}
  );
  const files = parseEslintFiles(outcome.stdout, context);

  if (outcome.exitCode === 0 && files !== undefined) {
    return {files, result: files.length > 0 ? 'fail' : 'pass'};
  }

  // A non-zero exit with unparseable output is still a failure: ESLint could
  // not judge the files, which must not read as clean.
  return {files: files ?? [], result: 'fail'};
};

/**
 * A story file is judged by its own suite status in the Storybook Vitest
 * report, never by assertion counts: a file that failed to import has no
 * assertions at all, so every remaining assertion can pass around it.
 */
export const judgeStoryFile = (
  repoRelativePath: string,
  fileResult: undefined | VitestFileResult
): FileOutcome => {
  const assertions = fileResult?.assertionResults ?? [];
  const loaded = assertions.length > 0;
  const failures = assertions
    .filter((assertion) => assertion.status === 'failed')
    .map((assertion) => assertion.fullName ?? assertion.title ?? '(unnamed)');

  return {
    failures,
    loaded,
    passed:
      loaded && assertions.every((assertion) => assertion.status === 'passed'),
    path: repoRelativePath,
    tests: assertions.length,
  };
};

export const runStoryTests = (
  runCommand: CommandRunner,
  context: {
    packageDir: string;
    repoRoot: string;
    storyFiles: readonly string[];
  }
): FileOutcome[] => {
  const outputDir = mkdtempSync(
    path.join(tmpdir(), 'gaia-migrate-csf4-report-')
  );
  const outputFile = path.join(outputDir, 'report.json');

  try {
    runCommand(
      'pnpm',
      [
        '-C',
        context.packageDir,
        'exec',
        'vitest',
        'run',
        '--project',
        'storybook',
        '--reporter=json',
        `--outputFile=${outputFile}`,
      ],
      {cwd: context.repoRoot}
    );
    const results = new Map<string, VitestFileResult>();

    if (existsSync(outputFile)) {
      try {
        const report = JSON.parse(readFileSync(outputFile, 'utf8')) as {
          testResults?: VitestFileResult[];
        };

        (report.testResults ?? []).forEach((entry) => {
          if (entry.name !== undefined)
            results.set(canonical(entry.name), entry);
        });
      } catch {
        // An unreadable report leaves every file unloaded, never passed.
      }
    }

    return context.storyFiles.map((relative) =>
      judgeStoryFile(
        toRepoRelative(context.repoRoot, context.packageDir, relative),
        results.get(canonical(path.join(context.packageDir, relative)))
      )
    );
  } finally {
    rmSync(outputDir, {force: true, recursive: true});
  }
};
