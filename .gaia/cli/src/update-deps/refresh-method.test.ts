/**
 * Maintainer guard for the two refresh methods /update-deps documents for
 * moving a locked transitive dependency: the in-range refresh in
 * `references/security.md` and the Phase 5b refresh in
 * `references/transitive-refresh.md`.
 *
 * Both exit 0 whether or not pnpm re-resolved anything, and the workflow reads
 * "nothing moved" as a clean result. A method that stops re-resolving reports
 * an in-range security patch as not landed, or Phase 5b as `Nothing moved`,
 * with no error anywhere. This test turns that silent no-op red.
 *
 * It runs the pinned pnpm against a registry served in-process, so it needs no
 * network and no real package's release history. A parent whose range admits
 * `^1.0.0` locks its child at 1.0.0, and then 1.1.0 becomes eligible in each of
 * the two ways it does in practice:
 *
 * - It aged past the release-age window: it already existed when the lock was
 *   written, too young to resolve, and the window has since passed. The test
 *   shrinks the window rather than waiting.
 * - It was published after the lock and is admitted by an exact-version
 *   `minimumReleaseAgeExclude` entry. pnpm treats package metadata it cached
 *   within the window as complete, since every mature version must predate it,
 *   so a single-package `update` answers from that cache and never sees the
 *   exempted release, and a whole-tree `update` misses it intermittently. Both
 *   methods delete cached metadata before resolving for this reason.
 *
 * The scripts under test are read from the references, so a reference that
 * changes its method is tested on its new text, and one that loses its block
 * fails at collection.
 *
 * The publish times the registry reports match when it began serving each
 * version, because pnpm's cache rule depends on that: a version stamped older
 * than metadata pnpm already cached without it cannot happen against a real
 * registry, and a fixture that fakes one fails for that reason alone.
 *
 * Fires on the pull request that bumps pnpm: `package.json` (whose
 * `packageManager` pins the version CI installs) is in the `code` paths filter
 * of `cli-tests.yml`. Maintainer-only by construction: `.gaia/cli/src` is
 * release-excluded.
 */
import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  test,
} from 'vitest';
import {execFile, execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {createServer} from 'node:http';
import type {Server} from 'node:http';
import type {AddressInfo} from 'node:net';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {promisify} from 'node:util';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);
const REFERENCES = path.join(
  REPO_ROOT,
  '.claude/skills/update-deps/references'
);

const PARENT = 'refresh-parent';
const CHILD = 'refresh-child';
const PARENT_DEPENDENCIES = {[CHILD]: '^1.0.0'};
const OLD_PUBLISH_TIME = '2020-01-01T00:00:00.000Z';
const HOUR_MILLISECONDS = 3_600_000;

// The repository's own window, so the lock is written under the policy the
// documented commands run under. The aged scenario publishes 1.1.0 two days
// before the lock: inside this three-day window, outside the one-day window
// it shrinks to.
const LOCK_WINDOW_MINUTES = 4320;
const AGED_WINDOW_MINUTES = 1440;
const AGED_PUBLISH_HOURS_AGO = 48;

// Each documented method is the first bash block after its marker in the
// reference, run as written with `<package>` filled in, so the test exercises
// whatever the reference currently tells /update-deps to run.
const DOCUMENTED_METHODS = [
  {
    marker: '**In-range refresh** (`in-range-refresh`)',
    reference: 'security.md',
  },
  {marker: '2. **Refresh:**', reference: 'transitive-refresh.md'},
] as const;

const documentedScript = (reference: string, marker: string): string => {
  const markdown = readFileSync(path.join(REFERENCES, reference), 'utf8');
  const markerAt = markdown.indexOf(marker);
  const opening = '```bash\n';
  const openingAt = markerAt === -1 ? -1 : markdown.indexOf(opening, markerAt);
  const closingAt =
    openingAt === -1 ? -1 : markdown.indexOf('```', openingAt + opening.length);

  if (closingAt === -1) {
    throw new Error(`${reference} has no bash block after ${marker}`);
  }

  return markdown
    .slice(openingAt + opening.length, closingAt)
    .replaceAll(/^ +/gm, '')
    .replaceAll('<package>', CHILD);
};

type Tarball = {bytes: Buffer; integrity: string};

const tarballs = new Map<string, Tarball>();
// The publish time the registry reports for child 1.1.0; unset, it serves only 1.0.0.
let childPublishedAt: string | undefined;
let server: Server;
let registryUrl: string;
let packDir: string;
let fixtureDir: string;

const packTarball = (
  name: string,
  version: string,
  dependencies: Record<string, string>
): void => {
  const sourceDir = path.join(packDir, `${name}-${version}`);
  mkdirSync(path.join(sourceDir, 'package'), {recursive: true});
  writeFileSync(
    path.join(sourceDir, 'package', 'package.json'),
    JSON.stringify({dependencies, name, version})
  );
  const tarPath = path.join(sourceDir, 'package.tgz');
  execFileSync('tar', ['-czf', tarPath, '-C', sourceDir, 'package']);
  const bytes = readFileSync(tarPath);
  tarballs.set(`${name}-${version}.tgz`, {
    bytes,
    integrity: `sha512-${createHash('sha512').update(bytes).digest('base64')}`,
  });
};

const packument = (
  name: string,
  releases: [version: string, publishedAt: string][],
  dependencies: Record<string, string>
) => {
  const [latest, modified] = releases.at(-1) ?? ['', OLD_PUBLISH_TIME];

  return {
    'dist-tags': {latest},
    name,
    time: Object.fromEntries([
      ['created', OLD_PUBLISH_TIME],
      ['modified', modified],
      ...releases,
    ]),
    versions: Object.fromEntries(
      releases.map(([version]) => {
        const file = `${name}-${version}.tgz`;

        return [
          version,
          {
            dependencies,
            dist: {
              integrity: tarballs.get(file)?.integrity,
              tarball: `${registryUrl}/${file}`,
            },
            name,
            version,
          },
        ];
      })
    ),
  };
};

const childReleases = (): [string, string][] => {
  const releases: [string, string][] = [['1.0.0', OLD_PUBLISH_TIME]];

  if (childPublishedAt) {
    releases.push(['1.1.0', childPublishedAt]);
  }

  return releases;
};

// pnpm's own config variables from the outer `pnpm test` would otherwise
// override the fixture's registry, store and lockfile settings.
const PNPM_ENVIRONMENT: NodeJS.ProcessEnv = Object.fromEntries(
  Object.entries(process.env).filter(
    ([key]) => !/^p?npm_config_/i.test(key) && key !== 'npm_execpath'
  )
);

// Every fetch is served from this process, so an install takes well under a
// second even on a cold store; the bound only stops a wedged pnpm holding the
// job.
const PNPM_TIMEOUT_MILLISECONDS = 60_000;

const execFileAsync = promisify(execFile);

// Asynchronous on purpose: the registry answers from this process's event
// loop, so a synchronous spawn would block every request pnpm makes to it.
const pnpm = async (argv: readonly string[]): Promise<string> => {
  const {stdout} = await execFileAsync('pnpm', argv, {
    cwd: fixtureDir,
    encoding: 'utf8',
    env: PNPM_ENVIRONMENT,
    timeout: PNPM_TIMEOUT_MILLISECONDS,
  });

  return stdout;
};

const workspaceYaml = (windowMinutes: number, exclude: string[]): string =>
  [
    'packages:',
    '  - frontend',
    `minimumReleaseAge: ${windowMinutes}`,
    'minimumReleaseAgeStrict: true',
    ...(exclude.length > 0 ?
      ['minimumReleaseAgeExclude:', ...exclude.map((entry) => `  - '${entry}'`)]
    : []),
    `storeDir: ${path.join(fixtureDir, '.store')}`,
    `cacheDir: ${path.join(fixtureDir, '.cache')}`,
    '',
  ].join('\n');

const lockedChildVersions = (): string[] => {
  const lock = readFileSync(path.join(fixtureDir, 'pnpm-lock.yaml'), 'utf8');
  const pattern = new RegExp(`^ {2}${CHILD}@([^:(]+)`, 'gm');

  return [
    ...new Set([...lock.matchAll(pattern)].map((match) => match[1] ?? '')),
  ];
};

const readManifests = (): string[] =>
  ['package.json', 'frontend/package.json', 'pnpm-workspace.yaml'].map((file) =>
    readFileSync(path.join(fixtureDir, file), 'utf8')
  );

// Each scenario takes a fixture locked at child 1.0.0 and makes 1.1.0
// eligible the way it happens in practice.
const SCENARIOS = [
  {
    // The release existed at lock time but was too young; time has since
    // carried it past the window.
    lock: () => {
      childPublishedAt = new Date(
        Date.now() - AGED_PUBLISH_HOURS_AGO * HOUR_MILLISECONDS
      ).toISOString();
    },
    makeEligible: () => {
      writeFileSync(
        path.join(fixtureDir, 'pnpm-workspace.yaml'),
        workspaceYaml(AGED_WINDOW_MINUTES, [])
      );
    },
    name: 'a release that aged past the release-age window',
  },
  {
    // The release appeared after the lock and is exempted by exact version,
    // the way a hand-checked security patch is let in early.
    lock: () => {
      childPublishedAt = undefined;
    },
    makeEligible: () => {
      childPublishedAt = new Date().toISOString();
      writeFileSync(
        path.join(fixtureDir, 'pnpm-workspace.yaml'),
        workspaceYaml(LOCK_WINDOW_MINUTES, [`${CHILD}@1.1.0`])
      );
    },
    name: 'a fresh release exempted by an exact-version exclude',
  },
] as const;

const CASES = DOCUMENTED_METHODS.flatMap(({marker, reference}) =>
  SCENARIOS.map((scenario) => ({
    reference,
    scenario,
    script: documentedScript(reference, marker),
  }))
);

beforeAll(async () => {
  server = createServer((request, response) => {
    const name = decodeURIComponent((request.url ?? '/').slice(1));
    const tarball = tarballs.get(name);

    if (tarball) {
      response.writeHead(200, {'content-type': 'application/octet-stream'});
      response.end(tarball.bytes);

      return;
    }
    const body =
      name === PARENT ?
        packument(PARENT, [['1.0.0', OLD_PUBLISH_TIME]], PARENT_DEPENDENCIES)
      : name === CHILD ? packument(CHILD, childReleases(), {})
      : undefined;

    if (!body) {
      response.writeHead(404).end();

      return;
    }
    response.writeHead(200, {'content-type': 'application/json'});
    response.end(JSON.stringify(body));
  });
  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });
  registryUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

  packDir = mkdtempSync(path.join(tmpdir(), 'refresh-method-pack-'));
  packTarball(PARENT, '1.0.0', PARENT_DEPENDENCIES);
  packTarball(CHILD, '1.0.0', {});
  packTarball(CHILD, '1.1.0', {});
});

afterAll(async () => {
  await new Promise<void>((resolve) => {
    server.close(() => resolve());
  });
  rmSync(packDir, {force: true, recursive: true});
});

beforeEach(() => {
  fixtureDir = mkdtempSync(path.join(tmpdir(), 'refresh-method-'));
  mkdirSync(path.join(fixtureDir, 'frontend'));
  writeFileSync(
    path.join(fixtureDir, 'package.json'),
    JSON.stringify({name: 'refresh-fixture', private: true})
  );
  writeFileSync(
    path.join(fixtureDir, 'frontend', 'package.json'),
    JSON.stringify({
      dependencies: {[PARENT]: '1.0.0'},
      name: 'refresh-frontend',
      private: true,
    })
  );
  writeFileSync(path.join(fixtureDir, '.npmrc'), `registry=${registryUrl}/\n`);
  writeFileSync(
    path.join(fixtureDir, 'pnpm-workspace.yaml'),
    workspaceYaml(LOCK_WINDOW_MINUTES, [])
  );
});

afterEach(() => {
  rmSync(fixtureDir, {force: true, recursive: true});
});

describe('the documented transitive refresh methods', () => {
  test('run the pnpm version the repository pins', async () => {
    const pinned = (
      JSON.parse(
        readFileSync(path.join(REPO_ROOT, 'package.json'), 'utf8')
      ) as {
        packageManager: string;
      }
    ).packageManager
      .replace(/^pnpm@/, '')
      .split('+', 1)[0];
    const installed = await pnpm(['--version']);

    expect(installed.trim()).toBe(pinned);
  });

  test.each(CASES)(
    '$reference moves a locked transitive to $scenario.name',
    async ({scenario, script}) => {
      scenario.lock();
      await pnpm(['install', '--no-frozen-lockfile']);
      expect(lockedChildVersions()).toEqual(['1.0.0']);
      scenario.makeEligible();
      const manifestsBefore = readManifests();

      await execFileAsync('bash', ['-euo', 'pipefail', '-c', script], {
        cwd: fixtureDir,
        env: PNPM_ENVIRONMENT,
        timeout: PNPM_TIMEOUT_MILLISECONDS,
      });

      expect(lockedChildVersions()).toEqual(['1.1.0']);
      expect(readManifests()).toEqual(manifestsBefore);
    },
    PNPM_TIMEOUT_MILLISECONDS
  );
});
