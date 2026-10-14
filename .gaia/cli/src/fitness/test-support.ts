/**
 * Test-only helpers for the fitness suites. Production code never imports this
 * file: it pulls in the test runner and writes to the filesystem.
 */
// eslint-disable-next-line import-x/no-extraneous-dependencies -- test-only helper, never bundled
import {expect, vi} from 'vitest';
import {spawnSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {runCheck} from './check.js';
import {OWNERSHIP_CLASSIFIER_ENV} from './ownership.js';
import type {FixtureMap, FixtureProject, RuleDefinition} from './types.js';
import {run as runRouter} from './index.js';

export type ScratchProject = {
  cleanup: () => void;
  env: Record<string, string>;
  root: string;
};

const writeProjectFile = (root: string, relative: string, text: string) => {
  const absolute = path.join(root, relative);

  mkdirSync(path.dirname(absolute), {recursive: true});
  writeFileSync(absolute, text);
};

const git = (root: string, args: readonly string[]): void => {
  const environment = {...process.env};

  delete environment.GIT_DIR;
  delete environment.GIT_WORK_TREE;
  delete environment.GIT_COMMON_DIR;

  const spawned = spawnSync('git', [...args], {
    cwd: root,
    encoding: 'utf8',
    env: environment,
  });

  if (spawned.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${spawned.stderr}`);
  }
};

const repoClassifierPath = (): string =>
  path.join(
    resolveRepoRootFromImportMeta(import.meta.url),
    '.gaia/scripts/fitness-ownership.sh'
  );

/** Writes a fixture project into a fresh temporary directory. */
export const createScratchProject = (
  project: FixtureProject
): ScratchProject => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-fitness-'));
  const mode = project.classifier ?? 'repo';

  for (const [relative, text] of Object.entries(project.files)) {
    writeProjectFile(root, relative, text);
  }

  if (project.settingsJson !== undefined) {
    writeProjectFile(
      root,
      '.claude/settings.json',
      `${JSON.stringify(project.settingsJson, null, 2)}\n`
    );
  }

  if (project.manifest !== undefined) {
    writeProjectFile(
      root,
      '.gaia/manifest.json',
      `${JSON.stringify(project.manifest, null, 2)}\n`
    );
  } else if (mode === 'repo') {
    writeProjectFile(root, '.gaia/manifest.json', '{"files":{}}\n');
  }

  for (const [name, target] of Object.entries(project.vendorPins ?? {})) {
    writeProjectFile(
      root,
      `.gaia/vendor/${name}.json`,
      `${JSON.stringify({target})}\n`
    );
  }

  if (project.git === true) {
    git(root, ['init', '-q']);
    git(root, ['config', 'user.email', 'fitness@example.com']);
    git(root, ['config', 'user.name', 'Fitness Test']);
    git(root, ['config', 'commit.gpgsign', 'false']);
    git(root, ['add', '-A']);
    git(root, ['commit', '-q', '--no-verify', '-m', 'fixture']);
  }

  const classifier =
    mode === 'repo' ? repoClassifierPath()
    : mode === 'none' ? path.join(root, '.gaia/no-such-classifier.sh')
    : mode;

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    env: {[OWNERSHIP_CLASSIFIER_ENV]: classifier},
    root,
  };
};

export type FitnessRun = {
  exitCode: number;
  json: unknown;
  stderr: string;
  stdout: string;
};

/** Runs `gaia fitness <argv>` in process, with `env` applied to `process.env` for the call. */
export const runFitness = async (
  argv: readonly string[],
  options: {env?: Readonly<Record<string, string | undefined>>} = {}
): Promise<FitnessRun> => {
  const saved = new Map<string, string | undefined>();

  for (const [key, value] of Object.entries(options.env ?? {})) {
    saved.set(key, process.env[key]);
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }

  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: string | Uint8Array) => {
      out.push(String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: string | Uint8Array) => {
      err.push(String(chunk));

      return true;
    });

  try {
    const exitCode = await runRouter(argv);
    const stdout = out.join('');
    let json: unknown;

    try {
      json = JSON.parse(stdout) as unknown;
    } catch {
      json = undefined;
    }

    return {exitCode, json, stderr: err.join(''), stdout};
  } finally {
    stdoutSpy.mockRestore();
    stderrSpy.mockRestore();

    for (const [key, value] of saved) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
};

const idsFound = (
  project: FixtureProject,
  catalog: readonly RuleDefinition[]
): Set<string> => {
  const scratch = createScratchProject(project);

  try {
    const report = runCheck({
      catalog,
      env: scratch.env,
      root: scratch.root,
      scope: 'all',
    });

    return new Set(
      [...report.findings, ...report.upstream, ...report.suppressed].map(
        (finding) => finding.rule_id
      )
    );
  } finally {
    scratch.cleanup();
  }
};

/**
 * Asserts every rule has a red fixture that fires it and a green fixture that
 * does not, and that no fixture names a rule outside `rules`.
 */
export const expectFixtureParity = (
  rules: readonly RuleDefinition[],
  fixtures: FixtureMap
): void => {
  const ruleIds = new Set(rules.map((rule) => rule.ruleId));

  expect(
    Object.keys(fixtures).filter((ruleId) => !ruleIds.has(ruleId)),
    'fixtures with no rule'
  ).toEqual([]);

  for (const rule of rules) {
    const pair =
      Object.hasOwn(fixtures, rule.ruleId) ? fixtures[rule.ruleId] : undefined;

    if (pair === undefined) {
      throw new Error(`no fixture pair for ${rule.ruleId}`);
    }

    const red = idsFound(pair.red(), rules);
    const green = idsFound(pair.green(), rules);

    expect(
      red.has(rule.ruleId),
      `${rule.ruleId} fires on its red fixture`
    ).toBe(true);
    expect(
      green.has(rule.ruleId),
      `${rule.ruleId} stays quiet on its green fixture`
    ).toBe(false);
  }
};
