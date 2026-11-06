import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {spawn, spawnSync} from 'node:child_process';
import {once} from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import {
  acquireStartLock,
  isProcessAlive,
  START_LOCK_FILE_NAME,
  startWorkerServer,
  WORKER_SERVER_HOST,
} from '../.playwright/worker-server';
import {DEV_PORT_OVERRIDE_ENV} from '../dev-ports';

let directory: string;
let lockFile: string;

beforeEach(() => {
  directory = fs.mkdtempSync(path.join(os.tmpdir(), 'worker-server-'));
  lockFile = path.join(directory, 'start.lock');
});

afterEach(() => {
  fs.rmSync(directory, {force: true, recursive: true});
});

describe('acquireStartLock', () => {
  test('a second holder waits until the first releases', async () => {
    const events: string[] = [];
    const releaseFirst = await acquireStartLock(lockFile);
    const second = acquireStartLock(lockFile).then((release) => {
      events.push('second acquired');

      return release;
    });

    // Several lock polls, so a waiter that ignored the lock would have run.
    await delay(200);
    events.push('first released');
    releaseFirst();
    (await second)();

    expect(events).toEqual(['first released', 'second acquired']);
    expect(fs.existsSync(lockFile)).toBe(false);
  });

  test('takes over a lock whose holder process is gone', async () => {
    const exited = spawnSync(process.execPath, ['-e', '']);

    fs.writeFileSync(lockFile, String(exited.pid));

    const release = await acquireStartLock(lockFile);

    expect(fs.readFileSync(lockFile, 'utf8')).toBe(String(process.pid));
    release();
  });

  // A parent that never reaps (a container whose PID 1 is node, here a shell
  // that execs `sleep`) leaves an exited holder as a zombie, which a signal
  // probe still finds.
  test('takes over a lock whose holder is a zombie', async () => {
    const parent = spawn(
      '/bin/sh',
      ['-c', 'sleep 0 & echo $!; exec sleep 30'],
      {
        stdio: ['ignore', 'pipe', 'ignore'],
      }
    );

    try {
      const [output] = (await once(parent.stdout, 'data')) as [Buffer];
      const zombieProcessId = Number(String(output).trim());

      // Lets `sleep 0` exit, so the holder is a zombie at the first lock read.
      await delay(200);
      fs.writeFileSync(lockFile, String(zombieProcessId));

      const release = await acquireStartLock(lockFile, 1000);

      expect(fs.readFileSync(lockFile, 'utf8')).toBe(String(process.pid));
      release();
    } finally {
      parent.kill('SIGKILL');
    }
  });

  test('a second release leaves a later holder lock in place', async () => {
    const release = await acquireStartLock(lockFile);

    release();
    fs.writeFileSync(lockFile, 'another holder');
    release();

    expect(fs.readFileSync(lockFile, 'utf8')).toBe('another holder');
  });
});

// Stands in for `pnpm dev`: listens only on the host it is told to bind, so a
// launch that leaves the bind to the server's own `localhost` resolution
// cannot pass, and answers with the environment it was started with.
const STAND_IN_SERVER = `
import http from 'node:http';
const hostIndex = process.argv.indexOf('--host');
if (hostIndex === -1) {
  console.error('no --host given');
  process.exit(2);
}
http
  .createServer((_request, response) => {
    response.end(JSON.stringify({
      mswEnabled: process.env.MSW_ENABLED,
      mswSeed: process.env.MSW_SEED,
      pid: process.pid,
      siteUrl: process.env.SITE_URL,
    }));
  })
  .listen(Number(process.env.${DEV_PORT_OVERRIDE_ENV}), process.argv[hostIndex + 1]);
`;

const FAILING_SERVER = `
console.error('route typegen failed: ENOTEMPTY');
process.exit(1);
`;

const writeScript = (name: string, source: string): string => {
  const file = path.join(directory, name);

  fs.writeFileSync(file, source);

  return file;
};

describe('startWorkerServer', () => {
  test('answers on the origin it bound, with that origin as SITE_URL and MSW and its seed surface on', async () => {
    const server = await startWorkerServer({
      command: [process.execPath, writeScript('server.mjs', STAND_IN_SERVER)],
      outputDirectory: directory,
      packageDirectory: directory,
      parallelIndex: 0,
    });

    try {
      const response = await fetch(server.baseURL);

      expect(new URL(server.baseURL).hostname).toBe(WORKER_SERVER_HOST);
      expect(await response.json()).toEqual({
        mswEnabled: 'true',
        mswSeed: 'true',
        pid: expect.any(Number),
        siteUrl: server.baseURL,
      });
    } finally {
      server.stop();
    }
  });

  test('a server that exits names its log, which holds the server output', async () => {
    const start = startWorkerServer({
      command: [process.execPath, writeScript('server.mjs', FAILING_SERVER)],
      outputDirectory: directory,
      packageDirectory: directory,
      parallelIndex: 3,
    });
    const logFile = path.join(directory, 'worker-3-server.log');

    await expect(start).rejects.toThrow(logFile);
    await expect(start).rejects.toThrow('(code 1, signal null)');
    expect(fs.readFileSync(logFile, 'utf8')).toContain(
      'route typegen failed: ENOTEMPTY'
    );
    expect(fs.existsSync(path.join(directory, START_LOCK_FILE_NAME))).toBe(
      false
    );
  });
});

// A process that starts a worker server and prints the server's pid, then ends
// the way its mode names without calling `stop`: `exit` exits at once without
// running any teardown, `wait` stays up until the test signals it, and `drain`
// leaves nothing scheduled, so it ends when its event loop empties.
const OWNER = String.raw`
import {startWorkerServer} from ${JSON.stringify(
  new URL('../.playwright/worker-server.ts', import.meta.url).href
)};
const [mode, serverScript, directory] = process.argv.slice(2);
const server = await startWorkerServer({
  command: [process.execPath, serverScript],
  outputDirectory: directory,
  packageDirectory: directory,
  parallelIndex: 0,
});
const {pid} = await (await fetch(server.baseURL)).json();
process.stdout.write(pid + '\n');
if (mode === 'exit') process.exit(0);
if (mode === 'wait') setInterval(() => undefined, 1000);
`;

const OWNER_DEADLINE_MILLISECONDS = 10_000;

const waitUntil = async (condition: () => boolean): Promise<boolean> => {
  const deadline = Date.now() + OWNER_DEADLINE_MILLISECONDS;

  while (Date.now() < deadline) {
    if (condition()) return true;
    await delay(50);
  }

  return condition();
};

describe('a worker server whose owner ends without stopping it', () => {
  test.each([
    {ending: 'exits', mode: 'exit'},
    {ending: 'is sent SIGTERM', mode: 'wait', signal: 'SIGTERM'},
    {ending: 'is killed', mode: 'wait', signal: 'SIGKILL'},
    {ending: 'lets its event loop drain', mode: 'drain'},
  ] as {ending: string; mode: string; signal?: NodeJS.Signals}[])(
    'stops when the owner $ending, and never holds the owner open',
    async ({mode, signal}) => {
      const owner = spawn(
        process.execPath,
        [
          '--import',
          'tsx',
          writeScript('owner.mts', OWNER),
          mode,
          writeScript('server.mjs', STAND_IN_SERVER),
          directory,
        ],
        {cwd: fileURLToPath(new URL('..', import.meta.url))}
      );
      let hasOwnerExited = false;
      let ownerErrorOutput = '';
      let serverProcessId: number | undefined;

      owner.stderr.on('data', (chunk: Buffer) => {
        ownerErrorOutput += chunk.toString();
      });
      owner.once('exit', () => {
        hasOwnerExited = true;
      });

      try {
        const line = await Promise.race([
          once(owner.stdout, 'data').then(([chunk]) => String(chunk)),
          once(owner, 'exit').then(() => {
            throw new Error(
              `The owner exited before printing the server pid:\n${ownerErrorOutput}`
            );
          }),
        ]);

        serverProcessId = Number(line.trim());

        if (signal !== undefined) owner.kill(signal);

        expect(await waitUntil(() => hasOwnerExited)).toBe(true);
        expect(await waitUntil(() => !isProcessAlive(serverProcessId!))).toBe(
          true
        );
      } finally {
        owner.kill('SIGKILL');

        if (serverProcessId !== undefined && isProcessAlive(serverProcessId)) {
          process.kill(serverProcessId, 'SIGKILL');
        }
      }
    }
  );
});
