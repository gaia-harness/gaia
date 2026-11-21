/**
 * `gaia update-deps global-tools` handler.
 *
 * Reports whether the globally installed playwright-cli binary trails npm
 * latest, and whether the react-doctor pin trails the newest release that has
 * cleared the release-age cooldown. Kept apart from `run.ts` on purpose:
 * neither tool can be cleared through pnpm, so neither may reach the
 * `--emit-updates` payload that `outdatedCount` and the statusline read.
 */
import {spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {resolveTreeRoot} from '../util/package-target.js';
import {applyCooldown, buildCooldownContext} from './run-compute-adjust.js';
import {defaultPnpmRunner} from './run-outdated.js';
import type {PnpmRunner} from './run-types.js';
import {compareSegments, parseSegments} from './version.js';

const HELP_TEXT = `Usage: gaia update-deps global-tools

  Print {"rows":[...]} describing the tools /update-deps keeps current outside
  pnpm (playwright-cli, the react-doctor pin). Always exits 0, even when a
  probe fails.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const INSTALL_COMMAND = 'npm install -g @playwright/cli@latest';

export type GlobalToolProbes = {
  /** Returns the bare semver the binary prints, or `null` when it is absent. */
  probeInstalledVersion: () => null | string;
  /** Returns npm's latest version, or `null` when the lookup failed. */
  probeLatestVersion: () => null | string;
};

export type PlaywrightCliRow = {
  installCommand: typeof INSTALL_COMMAND;
  installed: null | string;
  latest: null | string;
  message: string;
  offerInstall: boolean;
  packageName: '@playwright/cli';
  status: GlobalToolStatus;
  tool: 'playwright-cli';
};

export type PlaywrightCliRowInput = {
  /** `null` means the binary is absent. */
  installedVersion: null | string;
  /** `null` means the npm lookup failed. */
  latestVersion: null | string;
};

type GlobalToolStatus = 'current' | 'not-installed' | 'outdated' | 'unknown';

const STRICT_SEMVER_PATTERN = /^\d+\.\d+\.\d+$/;

const parseStrictSegments = (value: string): null | readonly number[] =>
  STRICT_SEMVER_PATTERN.test(value.trim()) ? parseSegments(value) : null;

export const computePlaywrightCliRow = (
  input: PlaywrightCliRowInput
): PlaywrightCliRow => {
  const {installedVersion, latestVersion} = input;
  const row = (
    status: GlobalToolStatus,
    message: string
  ): PlaywrightCliRow => ({
    installCommand: INSTALL_COMMAND,
    installed: installedVersion,
    latest: latestVersion,
    message,
    offerInstall: status === 'outdated',
    packageName: '@playwright/cli',
    status,
    tool: 'playwright-cli',
  });

  if (installedVersion === null) {
    return row('not-installed', 'not installed, skipped');
  }

  if (latestVersion === null) {
    return row('unknown', 'npm lookup failed, version comparison skipped');
  }

  const installed = parseStrictSegments(installedVersion);
  const latest = parseStrictSegments(latestVersion);

  if (installed === null || latest === null) {
    return row(
      'unknown',
      `cannot compare versions (installed ${installedVersion}, latest ${latestVersion})`
    );
  }

  if (compareSegments(installed, latest) < 0) {
    return row(
      'outdated',
      `installed ${installedVersion}, latest ${latestVersion}`
    );
  }

  return row('current', `up to date at ${installedVersion}`);
};

// ENOENT surfaces as `error`, not as a non-zero status.
const probeCommand = (command: string, args: string[]): null | string => {
  const result = spawnSync(command, args, {encoding: 'utf8'});

  if (result.error !== undefined || result.status !== 0) return null;

  const output = result.stdout.trim();

  return output === '' ? null : output;
};

const defaultProbes: GlobalToolProbes = {
  probeInstalledVersion: () => probeCommand('playwright-cli', ['--version']),
  probeLatestVersion: () =>
    probeCommand('npm', ['view', '@playwright/cli', 'version']),
};

const REACT_DOCTOR_PIN_FILE = '.gaia/react-doctor-version';

export type ReactDoctorRow = {
  latest: null | string;
  message: string;
  offerBump: boolean;
  packageName: 'react-doctor';
  pinFile: typeof REACT_DOCTOR_PIN_FILE;
  pinned: null | string;
  status: Exclude<GlobalToolStatus, 'not-installed'>;
  tool: 'react-doctor';
};

export type ReactDoctorRowInput = {
  now: Date;
  pnpmRunner: PnpmRunner;
  repoRoot: string;
};

type GlobalToolRow = PlaywrightCliRow | ReactDoctorRow;

// The accepted pin format is owned by react_doctor_pinned_version in
// .gaia/scripts/react-doctor-version-lib.sh; a parity test in
// global-tools.test.ts fails when this reader disagrees with it.
const readReactDoctorPin = (repoRoot: string): null | string => {
  try {
    const pinned = readFileSync(
      path.join(repoRoot, REACT_DOCTOR_PIN_FILE),
      'utf8'
    ).replaceAll(/\s/gu, '');

    return STRICT_SEMVER_PATTERN.test(pinned) ? pinned : null;
  } catch {
    return null;
  }
};

/**
 * The react-doctor row: the pin against the newest registry release that has
 * cleared `minimumReleaseAge`, the cooldown `update-deps run` applies to every
 * pnpm dependency.
 */
export const computeReactDoctorRow = (
  input: ReactDoctorRowInput
): ReactDoctorRow => {
  const {now, pnpmRunner, repoRoot} = input;
  const pinned = readReactDoctorPin(repoRoot);
  const row = (
    status: ReactDoctorRow['status'],
    message: string,
    latest: null | string = null
  ): ReactDoctorRow => ({
    latest,
    message,
    offerBump: status === 'outdated',
    packageName: 'react-doctor',
    pinFile: REACT_DOCTOR_PIN_FILE,
    pinned,
    status,
    tool: 'react-doctor',
  });

  if (pinned === null) {
    return row(
      'unknown',
      `${REACT_DOCTOR_PIN_FILE} holds no version such as 0.9.22, comparison skipped`
    );
  }

  const lookup = pnpmRunner(['view', 'react-doctor', 'version'], {
    cwd: repoRoot,
  });
  const registryLatest = lookup.status === 0 ? lookup.stdout.trim() : '';

  if (!STRICT_SEMVER_PATTERN.test(registryLatest)) {
    return row('unknown', 'registry lookup failed, version comparison skipped');
  }

  const decision = applyCooldown({
    context: buildCooldownContext({cwd: repoRoot, now, pnpmRunner, repoRoot}),
    current: pinned,
    latest: registryLatest,
    name: 'react-doctor',
  });

  if (decision.kind === 'unresolved') {
    return row(
      'unknown',
      'release times lookup failed, version comparison skipped'
    );
  }

  if (decision.kind === 'cooldown') {
    return row(
      'current',
      `pinned ${pinned}; ${registryLatest} is still inside the release-age cooldown`,
      registryLatest
    );
  }

  if (
    compareSegments(parseSegments(pinned), parseSegments(decision.latest)) < 0
  ) {
    return row(
      'outdated',
      `pinned ${pinned}, latest ${decision.latest}`,
      decision.latest
    );
  }

  return row('current', `up to date at ${pinned}`, decision.latest);
};

export type RunOptions = {
  now?: () => Date;
  pnpmRunner?: PnpmRunner;
  probes?: GlobalToolProbes;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.some((token) => HELP_TOKENS.has(token))) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const probes = options.probes ?? defaultProbes;
  const rows: GlobalToolRow[] = [
    computePlaywrightCliRow({
      installedVersion: probes.probeInstalledVersion(),
      latestVersion: probes.probeLatestVersion(),
    }),
    computeReactDoctorRow({
      now: options.now?.() ?? new Date(),
      pnpmRunner: options.pnpmRunner ?? defaultPnpmRunner,
      repoRoot: resolveTreeRoot(process.cwd()),
    }),
  ];

  process.stdout.write(`${JSON.stringify({rows})}\n`);

  return EXIT_CODES.OK;
};
