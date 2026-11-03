import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {
  acquireStartLock,
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
      databaseUrl: process.env.DATABASE_URL,
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
  test('answers on the origin it bound, with that origin as SITE_URL and its own database', async () => {
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
        databaseUrl: server.databaseFile,
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
    expect(fs.readFileSync(logFile, 'utf8')).toContain(
      'route typegen failed: ENOTEMPTY'
    );
    expect(fs.existsSync(path.join(directory, START_LOCK_FILE_NAME))).toBe(
      false
    );
  });
});
