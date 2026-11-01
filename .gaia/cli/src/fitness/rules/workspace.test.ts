import {describe, expect, test} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {FITNESS_CONFIG_PATH} from '../config.js';
import {
  createScratchProject,
  expectFixtureParity,
  FIXTURE_PARITY_TIMEOUT_MS,
  runFitness,
} from '../test-support.js';
import type {CheckReport, FixtureProject} from '../types.js';
import {WORKSPACE_FIXTURES, workspaceProject} from './workspace.fixtures.js';
import {WORKSPACE_RULES} from './workspace.js';

const UNREGISTERED = 'settings.workspace-member-unregistered';
const UNREGISTRABLE = 'settings.workspace-member-unregistrable';

const withFolderWithoutPackageJson = (
  project: FixtureProject
): FixtureProject => ({
  ...project,
  files: {...project.files, 'apps/empty/README.md': '# empty\n'},
});

const withSuppression = (
  project: FixtureProject,
  file: string
): FixtureProject => ({
  ...project,
  files: {
    ...project.files,
    [FITNESS_CONFIG_PATH]: JSON.stringify({
      ignore: [{path: file, reason: 'kept on purpose', rule_id: UNREGISTERED}],
      version: 1,
    }),
  },
});

const checkProject = async (
  project: FixtureProject,
  extra: readonly string[] = []
) => {
  const scratch = createScratchProject(project);

  try {
    const run = await runFitness(
      ['check', '--json', '--root', scratch.root, ...extra],
      {env: scratch.env}
    );

    return {exitCode: run.exitCode, report: run.json as CheckReport};
  } finally {
    scratch.cleanup();
  }
};

const messages = (report: CheckReport): string[] =>
  report.findings
    .filter((finding) => finding.rule_id.startsWith('settings.workspace-'))
    .map(
      (finding) => `${finding.file}: ${finding.message} ${finding.remediation}`
    );

describe('workspace rules fixtures', () => {
  test(
    'fires on every red fixture and stays quiet on every green one',
    () => {
      expectFixtureParity(WORKSPACE_RULES, WORKSPACE_FIXTURES);
    },
    FIXTURE_PARITY_TIMEOUT_MS
  );
});

describe('unregistered workspace members', () => {
  const project = withFolderWithoutPackageJson(
    workspaceProject(['apps/extra', 'apps/Legacy'], [])
  );

  test('warns naming the member and each pointer, and exits 0', async () => {
    const {exitCode, report} = await checkProject(project);
    const unregistered = report.findings.find(
      (finding) => finding.rule_id === UNREGISTERED
    );

    expect(exitCode).toBe(0);
    expect(unregistered?.file).toBe('apps/extra/package.json');
    expect(unregistered?.severity).toBe('warning');
    expect(unregistered?.message).toContain('apps/extra');
    expect(unregistered?.message).toContain('.gaia/packages.json');
    expect(unregistered?.remediation).toContain('apps/extra/gaia.package.json');
    expect(unregistered?.remediation).toContain('Package Descriptor.md');
  });

  test('names a refused path as unregistrable and not the folder without a package.json', async () => {
    const {report} = await checkProject(project);
    const unregistrable = report.findings.find(
      (finding) => finding.rule_id === UNREGISTRABLE
    );

    expect(unregistrable?.file).toBe('apps/Legacy/package.json');
    expect(unregistrable?.remediation).toContain('apps/legacy');
    expect(messages(report).join('\n')).not.toContain('apps/empty');
  });

  test('exits 1 under --fail-on warning', async () => {
    const {exitCode} = await checkProject(project, ['--fail-on', 'warning']);

    expect(exitCode).toBe(1);
  });

  test('a suppression for the finding clears it, and one for another member leaves it', async () => {
    const suppressed = await checkProject(
      withSuppression(project, 'apps/extra/package.json')
    );
    const other = await checkProject(
      withSuppression(project, 'apps/Legacy/package.json')
    );

    expect(
      suppressed.report.findings.some(
        (finding) => finding.rule_id === UNREGISTERED
      )
    ).toBe(false);
    expect(
      suppressed.report.findings.some(
        (finding) => finding.rule_id === 'settings.fitness-config.stale'
      )
    ).toBe(false);
    expect(
      other.report.findings.some((finding) => finding.rule_id === UNREGISTERED)
    ).toBe(true);
  });

  test('prints no such warning when every member is registered', async () => {
    const {report} = await checkProject(
      workspaceProject(['apps/extra'], ['apps/extra'])
    );

    expect(messages(report)).toEqual([]);
  });

  test('an absent workspace file produces no finding and no error', async () => {
    const {exitCode, report} = await checkProject({
      files: {'apps/extra/package.json': '{}', 'CLAUDE.md': '# Project\n'},
      git: true,
    });

    expect(exitCode).toBe(0);
    expect(messages(report)).toEqual([]);
  });
});

describe('this repository', () => {
  const root = resolveRepoRootFromImportMeta(import.meta.url);

  const repoWarnings = async (configPath?: string): Promise<string[]> => {
    const run = await runFitness([
      'check',
      '--json',
      '--root',
      root,
      ...(configPath === undefined ? [] : ['--config', configPath]),
    ]);

    return (run.json as CheckReport).findings
      .filter(
        (finding) =>
          finding.rule_id.startsWith('settings.workspace-') ||
          finding.rule_id === 'settings.fitness-config.stale'
      )
      .map((finding) => `${finding.rule_id} ${finding.file}`);
  };

  test(
    'prints no warning for the command-line tool and no stale suppression',
    async () => {
      expect(await repoWarnings()).toEqual([]);
    },
    FIXTURE_PARITY_TIMEOUT_MS
  );

  test(
    'prints the warning once the suppression is removed',
    async () => {
      const scratch = mkdtempSync(path.join(tmpdir(), 'gaia-fitness-config-'));

      try {
        const configPath = path.join(scratch, 'gaia-fitness.json');

        writeFileSync(configPath, JSON.stringify({ignore: [], version: 1}));

        expect(await repoWarnings(configPath)).toContain(
          `${UNREGISTRABLE} .gaia/cli/package.json`
        );
      } finally {
        rmSync(scratch, {force: true, recursive: true});
      }
    },
    FIXTURE_PARITY_TIMEOUT_MS
  );
});
