import {describe, expect, test} from 'vitest';
import {cpSync, realpathSync} from 'node:fs';
import {homedir} from 'node:os';
import path from 'node:path';
import {
  checkProject,
  cleanProject,
  leakedPieces,
  registerScratchProjects,
  registerTemporaryDirectories,
  reportOf,
} from './check-support.js';
import {runCheck} from './check.js';
import {compareBytes} from './markdown.js';
import {skillFile} from './rules/authoring.fixtures.js';
import type {Finding, FixtureProject} from './types.js';

const scratch = registerScratchProjects();
const temporaryDirectory = registerTemporaryDirectories();

const FINDING_FIELDS = [
  'category',
  'file',
  'fixable',
  'line',
  'message',
  'ownership',
  'remediation',
  'rule_id',
  'severity',
];

const INVENTORY_FIELDS = [
  'kinds',
  'lines',
  'model',
  'ownership',
  'path',
  'path_scoped',
  'words',
];

const REPORT_KEYS = [
  'scope',
  'categories',
  'overall',
  'findings',
  'upstream',
  'suppressed',
  'inventory',
];

/** The clean project plus two info findings in two files, so ordering and fields are observable. */
const projectWithInfoFindings = (): FixtureProject => {
  const base = cleanProject();

  return {
    ...base,
    files: {
      ...base.files,
      '.claude/skills/example/SKILL.md': skillFile('# Example\n\nBody.\n', {
        description:
          'Summarizes the example status when you ask for a status summary.',
      }),
    },
    settingsJson: {permissions: {allow: ['Read', 'Read']}},
  };
};

/** Runs `work` with HOME pointed at `home`, restoring the real value after. */
const withHome = async <TResult>(
  home: string,
  work: () => Promise<TResult>
): Promise<TResult> => {
  const saved = process.env.HOME;

  process.env.HOME = home;

  try {
    return await work();
  } finally {
    if (saved === undefined) delete process.env.HOME;
    else process.env.HOME = saved;
  }
};

describe('gaia fitness check output', () => {
  test('is byte-identical across runs and equal in grades across roots and homes', async () => {
    const first = scratch(projectWithInfoFindings());
    const runA = await checkProject(first);
    const runB = await checkProject(first);

    expect(runA.exitCode).toBe(0);
    expect(runB.exitCode).toBe(0);
    expect(runA.stdout.length).toBeGreaterThan(0);
    expect(runB.stdout).toBe(runA.stdout);

    const copyRoot = path.join(temporaryDirectory(), 'copy');

    cpSync(first.root, copyRoot, {recursive: true});

    const copied = await withHome(temporaryDirectory(), async () =>
      checkProject({...first, root: copyRoot})
    );
    const baseline = reportOf(runA);
    const other = reportOf(copied);

    expect(copied.exitCode).toBe(0);
    expect(other.categories).toEqual(baseline.categories);
    expect(other.overall).toBe(baseline.overall);
    // The whole document matches too, so no message or inventory entry
    // carries the root or the home it ran under.
    expect(copied.stdout).toBe(runA.stdout);
  });

  test('prints the report keys in order with fully formed, sorted findings and in-root inventory', async () => {
    const project = scratch(projectWithInfoFindings());
    const report = reportOf(await checkProject(project));

    expect(Object.keys(report)).toEqual(REPORT_KEYS);
    expect(report.findings.length).toBeGreaterThanOrEqual(2);
    expect(new Set(report.findings.map((finding) => finding.file)).size).toBe(
      report.findings.length
    );

    for (const finding of report.findings) {
      expect(Object.keys(finding).toSorted(compareBytes)).toEqual(
        FINDING_FIELDS
      );
      expect(['error', 'info', 'warning']).toContain(finding.severity);
    }

    expect(report.findings).toEqual(
      report.findings.toSorted(
        (a: Finding, b: Finding) =>
          compareBytes(a.file, b.file) ||
          a.line - b.line ||
          compareBytes(a.rule_id, b.rule_id)
      )
    );
    expect(report.inventory.length).toBeGreaterThan(0);

    for (const entry of report.inventory) {
      expect(Object.keys(entry).toSorted(compareBytes)).toEqual(
        INVENTORY_FIELDS
      );
      expect(path.isAbsolute(entry.path)).toBe(false);
      expect(entry.path.split('/')).not.toContain('..');
      expect(entry.words).toBeGreaterThan(0);
      expect(entry.lines).toBeGreaterThan(0);
      expect(entry.model).toBe('unresolved');
      expect(entry.ownership).toBe('adopter');
    }

    const paths = report.inventory.map((entry) => entry.path);

    expect(paths).toEqual(paths.toSorted(compareBytes));
  });

  test('carries no root, home, timestamp or version string', async () => {
    const otherHome = temporaryDirectory();
    const project = scratch(projectWithInfoFindings());
    const {stdout} = await withHome(otherHome, async () =>
      checkProject(project)
    );

    expect(stdout.length).toBeGreaterThan(0);
    expect(stdout).not.toContain(project.root);
    expect(stdout).not.toContain(realpathSync(project.root));
    expect(stdout).not.toContain(otherHome);
    expect(stdout).not.toContain(homedir());
    expect(stdout).not.toMatch(/\d{4}-\d{2}-\d{2}T\d{2}:/);
    expect(stdout).not.toMatch(/\d{1,6}\.\d{1,6}\.\d{1,6} \(Claude Code\)/);
  });
});

describe('gaia fitness check redaction', () => {
  test('leaves no 8-character piece of a planted credential in any string field', async () => {
    const credential = `sk-ant-${Date.now().toString(16)}${'abcdef0123456789'.repeat(2)}`;
    const base = cleanProject();
    const project = scratch({
      ...base,
      files: {
        ...base.files,
        '.claude/rules/leaky.md': `# Leaky\n\nThe token is ${credential} and see \`docs/${credential}.md\`.\n`,
        'CLAUDE.md': `# Project\n\nSee @${credential}.md and \`${credential}/notes.md\`.\n`,
      },
      settingsJson: {env: {ANTHROPIC_API_KEY: credential}},
    });
    const run = await checkProject(project);
    const report = reportOf(run);

    expect(run.exitCode).toBe(1);

    // The unredacted report quotes the credential, so only the printing pass
    // can be what removes it; the marker shows that pass ran on those fields.
    expect(
      JSON.stringify(
        runCheck({env: project.env, root: project.root, scope: 'adopter'})
      )
    ).toContain(credential);
    expect(
      report.findings.filter((finding) =>
        JSON.stringify(finding).includes('[redacted]')
      ).length
    ).toBeGreaterThan(0);

    expect(leakedPieces(credential, [run.stdout, run.stderr])).toEqual([]);
  });
});
