import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {computePlaywrightCliRow, run} from './global-tools.js';
import type {GlobalToolProbes} from './global-tools.js';
import {run as runEmit} from './run.js';
import type {PnpmRunner} from './run.js';

const emptyOutdated: PnpmRunner = () => ({
  status: 0,
  stderr: '',
  stdout: '{}',
});

const INSTALL_COMMAND = 'npm install -g @playwright/cli@latest';

describe('computePlaywrightCliRow', () => {
  test.each(
    [
      {
        expected: {
          installCommand: INSTALL_COMMAND,
          installed: '0.1.21',
          latest: '0.1.22',
          offerInstall: true,
          status: 'outdated',
        },
        installedVersions: ['0.1.21'],
        latestVersion: '0.1.22',
        name: 'an older installed binary is outdated and offers the install',
      },
      {
        expected: {
          installCommand: INSTALL_COMMAND,
          message: 'not installed, skipped',
          offerInstall: false,
          status: 'not-installed',
        },
        installedVersions: [null],
        latestVersion: '0.1.22',
        name: 'an absent binary is not-installed and never offers the install',
      },
      {
        expected: {
          message: expect.stringContaining('npm lookup failed') as string,
          offerInstall: false,
          status: 'unknown',
        },
        installedVersions: ['0.1.21'],
        latestVersion: null,
        name: 'a failed npm lookup is unknown',
      },
      {
        expected: {offerInstall: false, status: 'unknown'},
        installedVersions: ['not-a-version'],
        latestVersion: '0.1.22',
        name: 'a non-semver installed string is unknown without throwing',
      },
      {
        expected: {offerInstall: false, status: 'current'},
        installedVersions: ['0.1.22', '0.2.0', '1.0.0'],
        latestVersion: '0.1.22',
        name: 'an equal or newer installed binary is current',
      },
      {
        expected: {status: 'outdated'},
        installedVersions: ['0.1.9'],
        latestVersion: '0.1.10',
        name: 'versions compare numerically, not lexically',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {expected, installedVersions, latestVersion}) => {
    for (const installedVersion of installedVersions) {
      expect(() =>
        computePlaywrightCliRow({installedVersion, latestVersion})
      ).not.toThrow();
      expect(
        computePlaywrightCliRow({installedVersion, latestVersion})
      ).toMatchObject(expected);
    }
  });
});

describe('update-deps global-tools handler', () => {
  let written: string[];

  beforeEach(() => {
    written = [];
    vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
      written.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  const parseRows = (): {status: string}[] =>
    (JSON.parse(written.join('')) as {rows: {status: string}[]}).rows;

  test.each(
    [
      {
        expectedStatus: 'not-installed',
        installedVersion: null,
        latestVersion: '0.1.22',
        name: 'prints rows and exits 0 when the binary probe reports it absent',
      },
      {
        expectedStatus: 'unknown',
        installedVersion: '0.1.21',
        latestVersion: null,
        name: 'prints rows and exits 0 when the npm probe fails',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {expectedStatus, installedVersion, latestVersion}) => {
    const probes: GlobalToolProbes = {
      probeInstalledVersion: () => installedVersion,
      probeLatestVersion: () => latestVersion,
    };

    expect(run([], {probes})).toBe(0);
    expect(parseRows()).toHaveLength(1);
    expect(parseRows()[0]?.status).toBe(expectedStatus);
  });
});

describe('update-deps run isolation from global tools', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-global-tools-'));
    writeFrontendRegistry(root);
    execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
    writeFileSync(
      path.join(root, 'package.json'),
      JSON.stringify({dependencies: {foo: '^1.2.3'}}),
      'utf8'
    );
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
    vi.restoreAllMocks();
  });

  test('--emit-updates payload never mentions playwright-cli', () => {
    const outPath = path.join(root, 'updates.json');

    expect(
      runEmit(['--emit-updates', outPath], {
        cwd: root,
        pnpmRunner: emptyOutdated,
      })
    ).toBe(0);

    const payload = readFileSync(outPath, 'utf8');

    expect(payload).not.toContain('playwright-cli');
    expect(payload).not.toContain('@playwright/cli');
  });

  test('run.ts and its run-* modules do not import global-tools', () => {
    const runModules = readdirSync(import.meta.dirname).filter(
      (name) =>
        /^run(?:-[a-z-]+)?\.ts$/u.test(name) && !name.endsWith('.test.ts')
    );

    expect(runModules).toContain('run.ts');

    const importers = runModules.filter((name) =>
      readFileSync(path.join(import.meta.dirname, name), 'utf8').includes(
        'global-tools'
      )
    );

    expect(importers).toEqual([]);
  });
});
