import {afterEach, describe, expect, test, vi} from 'vitest';
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';

type GlobalWithAppDirectory = {__reactRouterAppDirectory?: string};

const appDirectoryGlobal = globalThis as GlobalWithAppDirectory;

// eslint-disable-next-line no-underscore-dangle -- React Router's app-directory global, read by getAppDirectory()
const originalAppDirectory = appDirectoryGlobal.__reactRouterAppDirectory;

const temporaryAppDirectories: string[] = [];

const setAppDirectory = (appDirectory: string | undefined) => {
  // eslint-disable-next-line no-underscore-dangle -- React Router's app-directory global, read by getAppDirectory()
  appDirectoryGlobal.__reactRouterAppDirectory = appDirectory;
  vi.resetModules();
};

const writeTemporaryApp = (routeFile: string) => {
  const appDirectory = realpathSync(
    mkdtempSync(path.join(os.tmpdir(), 'routes-guard-'))
  );
  temporaryAppDirectories.push(appDirectory);

  writeFileSync(
    path.join(appDirectory, 'root.tsx'),
    'export default function Root() { return null; }\n'
  );
  mkdirSync(path.dirname(path.join(appDirectory, 'routes', routeFile)), {
    recursive: true,
  });
  writeFileSync(
    path.join(appDirectory, 'routes', routeFile),
    'export default function Page() { return null; }\n'
  );
  setAppDirectory(appDirectory);
};

afterEach(() => {
  setAppDirectory(originalAppDirectory);

  for (const appDirectory of temporaryAppDirectories.splice(0)) {
    rmSync(appDirectory, {force: true, recursive: true});
  }
});

describe('leftover "+" route folder guard', () => {
  test.each(
    [
      {
        assertOutcome: async (): Promise<void> => {
          await expect(import('~/routes')).rejects.toThrow(/_legacy\+/);
        },
        name: 'throws naming the offending folder when a "+" folder remains',
        routeFile: path.join('_legacy+', 'page.tsx'),
      },
      {
        assertOutcome: async (): Promise<void> => {
          const routesModule = await import('~/routes');

          await expect(routesModule.default).resolves.toEqual(
            expect.arrayContaining([
              expect.objectContaining({id: 'routes/_legacy.page'}),
            ])
          );
        },
        name: 'discovers a flat dot-delimited file when no "+" folder remains',
        routeFile: '_legacy.page.tsx',
      },
    ].map((row) => [row.name, row] as const)
  )(
    'the routes module refuses a leftover plus folder and discovers a flat file: %s',
    async (_name, {assertOutcome, routeFile}) => {
      writeTemporaryApp(routeFile);

      await assertOutcome();
    }
  );
});
