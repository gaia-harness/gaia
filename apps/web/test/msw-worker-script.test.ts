import {describe, expect, test} from 'vitest';
// Runs in the node project.
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const WORKER_CONSTANT_NAMES = [
  'PACKAGE_VERSION',
  'INTEGRITY_CHECKSUM',
] as const;

type WorkerConstantName = (typeof WORKER_CONSTANT_NAMES)[number];

const REGENERATE_INSTRUCTION =
  'Regenerate it with `pnpm -C apps/web msw:init`, or with `pnpm -C apps/web exec msw init` if package.json has no msw:init script.';

const extractConstant = (
  source: string,
  name: WorkerConstantName
): string | undefined =>
  new RegExp(`const ${name} = ['"]([^'"]+)['"]`).exec(source)?.[1];

/**
 * Compares the committed worker script against the one the installed msw ships.
 * Returns one message per mismatch, empty when they agree.
 */
const compareWorkerScripts = (
  committedSource: string,
  installedSource: string,
  installedPackageVersion?: string
): string[] => {
  const mismatches: string[] = [];

  for (const name of WORKER_CONSTANT_NAMES) {
    const committed = extractConstant(committedSource, name);
    const installed = extractConstant(installedSource, name);

    if (committed === undefined || installed === undefined) {
      const missingFrom = [
        committed === undefined ? 'the committed worker script' : undefined,
        installed === undefined ? 'the installed worker script' : undefined,
      ]
        .filter(Boolean)
        .join(' and ');

      mismatches.push(`${name} was not found in ${missingFrom}.`);
    } else if (committed !== installed) {
      mismatches.push(
        `${name} differs: committed ${committed}, installed ${installed}. ${REGENERATE_INSTRUCTION}`
      );
    }
  }

  const committedVersion = extractConstant(committedSource, 'PACKAGE_VERSION');

  if (
    installedPackageVersion !== undefined &&
    committedVersion !== undefined &&
    committedVersion !== installedPackageVersion
  ) {
    mismatches.push(
      `The committed worker script is for msw ${committedVersion} but msw ${installedPackageVersion} is installed. ${REGENERATE_INSTRUCTION}`
    );
  }

  return mismatches;
};

const committedWorkerPath = path.resolve(
  import.meta.dirname,
  '../public/mockServiceWorker.js'
);
const installedWorkerPath = fileURLToPath(
  import.meta.resolve('msw/mockServiceWorker.js')
);
const installedPackagePath = fileURLToPath(
  import.meta.resolve('msw/package.json')
);

const committedSource = readFileSync(committedWorkerPath, 'utf-8');
const installedSource = readFileSync(installedWorkerPath, 'utf-8');
const installedPackageVersion = (
  JSON.parse(readFileSync(installedPackagePath, 'utf-8')) as {version: string}
).version;

describe('committed msw worker script', () => {
  test('matches the worker the installed msw ships', () => {
    expect(
      compareWorkerScripts(
        committedSource,
        installedSource,
        installedPackageVersion
      )
    ).toEqual([]);
  });
});
