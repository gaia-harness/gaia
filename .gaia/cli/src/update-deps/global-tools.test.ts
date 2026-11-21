import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync, spawnSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {
  computePlaywrightCliRow,
  computeReactDoctorRow,
  run,
} from './global-tools.js';
import type {GlobalToolProbes} from './global-tools.js';
import {run as runEmit} from './run.js';
import type {PnpmRunner} from './run.js';

const emptyOutdated: PnpmRunner = () => ({
  status: 0,
  stderr: '',
  stdout: '{}',
});

const INSTALL_COMMAND = 'npm install -g @playwright/cli@latest';

const NOW = new Date('2026-11-21T00:00:00Z');
const DAY_MS = 86_400_000;
const daysAgo = (days: number): string =>
  new Date(NOW.getTime() - days * DAY_MS).toISOString();

type RegistryAnswer = {
  latest: null | string;
  times: null | Record<string, string>;
};

const registryReply = (stdout: null | string) =>
  stdout === null ?
    {status: 1, stderr: 'lookup failed', stdout: ''}
  : {status: 0, stderr: '', stdout};

// Answers the two registry reads the react-doctor row makes, so no test
// reaches npm; `null` is a failed lookup. `calls` records every request.
const stubRegistry = (
  answer: RegistryAnswer
): {calls: string[][]; runner: PnpmRunner} => {
  const calls: string[][] = [];

  return {
    calls,
    runner: (args) => {
      calls.push([...args]);

      return args.includes('time') ?
          registryReply(
            answer.times === null ? null : JSON.stringify(answer.times)
          )
        : registryReply(answer.latest);
    },
  };
};

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

describe('computeReactDoctorRow', () => {
  let repoRoot: string;

  beforeEach(() => {
    repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-react-doctor-row-'));
    mkdirSync(path.join(repoRoot, '.gaia'));
    // Three days, the cooldown the repository's own workspace sets.
    writeFileSync(
      path.join(repoRoot, 'pnpm-workspace.yaml'),
      'minimumReleaseAge: 4320\n',
      'utf8'
    );
  });

  afterEach(() => {
    rmSync(repoRoot, {force: true, recursive: true});
  });

  const writePin = (text: string): void => {
    writeFileSync(path.join(repoRoot, '.gaia/react-doctor-version'), text);
  };

  test.each(
    (
      [
        {
          answer: {latest: '0.9.24', times: {'0.9.24': daysAgo(10)}},
          expected: {
            latest: '0.9.24',
            offerBump: true,
            pinned: '0.9.22',
            status: 'outdated',
          },
          name: 'an aged newer release is outdated and offers the bump',
        },
        {
          answer: {
            latest: '0.9.24',
            times: {'0.9.23': daysAgo(10), '0.9.24': daysAgo(1)},
          },
          expected: {latest: '0.9.23', offerBump: true, status: 'outdated'},
          name: 'the cooldown caps the offer at the newest aged release',
        },
        {
          answer: {latest: '0.9.23', times: {'0.9.23': daysAgo(1)}},
          expected: {
            message: expect.stringContaining('cooldown') as string,
            offerBump: false,
            status: 'current',
          },
          name: 'a newer release still inside the cooldown is not offered',
        },
        {
          answer: {latest: '0.9.22', times: null},
          expected: {offerBump: false, status: 'current'},
          name: 'a pin at the registry latest is current',
        },
        {
          answer: {latest: null, times: null},
          expected: {offerBump: false, status: 'unknown'},
          name: 'a failed registry lookup is unknown',
        },
        {
          answer: {latest: '0.9.24', times: null},
          expected: {offerBump: false, status: 'unknown'},
          name: 'a failed release-times lookup is unknown, never a bump',
        },
      ] as {
        answer: RegistryAnswer;
        expected: Record<string, unknown>;
        name: string;
      }[]
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {answer, expected}) => {
    writePin('0.9.22\n');

    expect(
      computeReactDoctorRow({
        now: NOW,
        pnpmRunner: stubRegistry(answer).runner,
        repoRoot,
      })
    ).toMatchObject(expected);
  });

  test.each([
    ['a missing pin file', () => undefined],
    ['a malformed pin', () => writePin('0.9\n')],
  ])('%s is unknown and asks the registry nothing', (_name, preparePin) => {
    preparePin();
    const registry = stubRegistry({latest: '0.9.24', times: null});

    expect(
      computeReactDoctorRow({now: NOW, pnpmRunner: registry.runner, repoRoot})
    ).toMatchObject({offerBump: false, pinned: null, status: 'unknown'});
    expect(registry.calls).toEqual([]);
  });

  // The pin's accepted format is owned by react_doctor_pinned_version in
  // .gaia/scripts/react-doctor-version-lib.sh; this keeps the TS reader from
  // drifting away from it.
  test.each([
    '0.9.22',
    ' 0.9.22 \n',
    '10.0.1',
    '0.9',
    'v0.9.22',
    '0.9.22-beta.1',
    '0.9.22.1',
    '',
  ])(
    'pin %j is accepted by the TS reader only when the shell lib accepts it',
    (pinText) => {
      writePin(pinText);
      const pinFile = path.join(repoRoot, '.gaia/react-doctor-version');
      const library = path.resolve(
        import.meta.dirname,
        '../../../scripts/react-doctor-version-lib.sh'
      );
      const shell = spawnSync(
        'bash',
        [
          '-c',
          '. "$1" && react_doctor_pinned_version "$2"',
          '_',
          library,
          pinFile,
        ],
        {encoding: 'utf8'}
      );
      const row = computeReactDoctorRow({
        now: NOW,
        pnpmRunner: stubRegistry({latest: null, times: null}).runner,
        repoRoot,
      });

      expect(row.pinned).toBe(shell.status === 0 ? shell.stdout.trim() : null);
    }
  );
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

    const {runner} = stubRegistry({latest: null, times: null});

    expect(run([], {pnpmRunner: runner, probes})).toBe(0);
    expect(parseRows().map((row) => row.status)).toEqual([
      expectedStatus,
      'unknown',
    ]);
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
