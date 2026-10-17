/**
 * Shared helpers for the whole-catalog `check` suites. Test-only: it pulls in
 * the test runner, so production code never imports it.
 */
// eslint-disable-next-line import-x/no-extraneous-dependencies -- test-only helper, never bundled
import {afterEach} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {skillFile} from './rules/authoring.fixtures.js';
import type {FitnessRun, ScratchProject} from './test-support.js';
import {createScratchProject, runFitness} from './test-support.js';
import type {CheckReport, Finding, FixtureProject} from './types.js';

export const GOOD_DESCRIPTION =
  'Summarizes the example status. Use when a status summary is requested.';

/**
 * Registers per-test cleanup and returns a creator for scratch projects, so a
 * suite never leaks a temporary directory.
 */
export const registerScratchProjects = (): ((
  project: FixtureProject
) => ScratchProject) => {
  const cleanups: (() => void)[] = [];

  afterEach(() => {
    for (const cleanup of cleanups.splice(0)) cleanup();
  });

  return (project) => {
    const created = createScratchProject(project);

    cleanups.push(created.cleanup);

    return created;
  };
};

/** A temporary directory removed after the test, for files outside any project. */
export const registerTemporaryDirectories = (): (() => string) => {
  const created: string[] = [];

  afterEach(() => {
    for (const directory of created.splice(0)) {
      rmSync(directory, {force: true, recursive: true});
    }
  });

  return () => {
    const directory = mkdtempSync(path.join(tmpdir(), 'gaia-fitness-aux-'));

    created.push(directory);

    return directory;
  };
};

/** Writes an executable-looking stub classifier that always exits 3. */
export const writeFailingClassifier = (directory: string): string => {
  const stub = path.join(directory, 'classifier.sh');

  mkdirSync(directory, {recursive: true});
  writeFileSync(stub, '#!/bin/sh\nexit 3\n', {mode: 0o755});

  return stub;
};

/** A project with every always-linted kind present and no finding at all. */
export const cleanProject = (): FixtureProject => ({
  files: {
    '.claude/rules/example.md': '# Example\n\nKeep the example short.\n',
    '.claude/skills/example/SKILL.md': skillFile('# Example\n\nBody.\n', {
      description: GOOD_DESCRIPTION,
    }),
    'CLAUDE.md': '# Project\n\nA short project note.\n',
  },
  git: true,
  settingsJson: {permissions: {allow: ['Bash(git status)']}},
});

/** `gaia fitness check --json` over a scratch project, with `extra` appended. */
export const checkProject = async (
  project: ScratchProject,
  ...extra: string[]
): Promise<FitnessRun> =>
  runFitness(['check', '--json', '--root', project.root, ...extra], {
    env: project.env,
  });

/** The parsed report of a run; throws when stdout was not a report. */
export const reportOf = (run: FitnessRun): CheckReport => {
  if (typeof run.json !== 'object' || run.json === null) {
    throw new Error(`check did not print a report: ${run.stderr}`);
  }

  return run.json as CheckReport;
};

/** Every 8-character run of `secret` that appears in any of `outputs`. */
export const leakedPieces = (
  secret: string,
  outputs: readonly string[]
): string[] =>
  Array.from({length: secret.length - 7}, (_, start) =>
    secret.slice(start, start + 8)
  ).filter((piece) => outputs.some((output) => output.includes(piece)));

export const gradeOf = (report: CheckReport, category: string): string =>
  report.categories.find((entry) => entry.name === category)?.grade ??
  'missing';

export const findingsOfRule = (
  report: CheckReport,
  ruleId: string
): Finding[] => report.findings.filter((finding) => finding.rule_id === ruleId);

export const findingsOfCategory = (
  report: CheckReport,
  category: string
): Finding[] =>
  report.findings.filter((finding) => finding.category === category);
