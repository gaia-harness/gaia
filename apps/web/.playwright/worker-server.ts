import {spawn} from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {DEV_PORT_OVERRIDE_ENV, isPortTaken} from '../dev-ports';

/**
 * The one address a worker server binds, and the origin of its readiness
 * probe, `baseURL` and `SITE_URL`. Left to `localhost`, Vite can bind only
 * `::1` while Node's fetch connects to `127.0.0.1` and is refused.
 */
export const WORKER_SERVER_HOST = '127.0.0.1';

/** The start lock's file name inside the Playwright output folder. */
export const START_LOCK_FILE_NAME = 'worker-server-start.lock';

export const SERVER_READY_TIMEOUT_MILLISECONDS = 60_000;

// Starts run one at a time, so the last worker of a full set waits for every
// start ahead of it; a live holder releases within its own ready timeout.
export const START_LOCK_TIMEOUT_MILLISECONDS =
  4 * SERVER_READY_TIMEOUT_MILLISECONDS;

// The lock check is a local file read, so waiters poll it often: every
// handoff between serialized starts waits up to one interval. The readiness
// probe is an HTTP request to a server still booting, so it polls slower.
const LOCK_POLL_INTERVAL_MILLISECONDS = 50;
const READY_POLL_INTERVAL_MILLISECONDS = 250;

// A holder that died mid-start never removes its lock, so a lock whose
// recorded process is gone is taken over. An unreadable lock was released
// between the failed create and this read.
const isHolderAlive = (lockFile: string): boolean => {
  let holder: number;

  try {
    holder = Number(fs.readFileSync(lockFile, 'utf8'));
  } catch {
    return true;
  }

  try {
    process.kill(holder, 0);

    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== 'ESRCH';
  }
};

/**
 * Takes a lock shared by every worker process: resolves once this process
 * holds it, with a release that is safe to call more than once.
 */
export const acquireStartLock = async (
  lockFile: string,
  timeoutMilliseconds = Number.POSITIVE_INFINITY
): Promise<() => void> => {
  const deadline = Date.now() + timeoutMilliseconds;

  for (;;) {
    try {
      fs.writeFileSync(lockFile, String(process.pid), {flag: 'wx'});

      let held = true;

      return () => {
        if (held) fs.rmSync(lockFile, {force: true});
        held = false;
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
    }

    if (!isHolderAlive(lockFile)) fs.rmSync(lockFile, {force: true});

    if (Date.now() > deadline) {
      throw new Error(
        `Timed out waiting for the lock ${lockFile}; delete it if no Playwright run is active.`
      );
    }

    await delay(LOCK_POLL_INTERVAL_MILLISECONDS);
  }
};

const askOperatingSystemForPort = async (): Promise<number> =>
  new Promise((resolve, reject) => {
    const probe = net.createServer();

    probe.once('error', reject);
    probe.listen({exclusive: true, host: '0.0.0.0', port: 0}, () => {
      const {port} = probe.address() as net.AddressInfo;

      probe.close(() => resolve(port));
    });
  });

// Asks the OS for a port, then confirms no listener holds it on any address
// the dev server's own start-up check probes: a loopback-only server (Vite's
// default) coexists with a wildcard bind on macOS, so a wildcard bind alone
// would accept a port another worker's server already answers on.
const findFreePort = async (): Promise<number> => {
  for (;;) {
    const port = await askOperatingSystemForPort();

    if (!(await isPortTaken(port))) return port;
  }
};

const waitForServer = async (origin: string): Promise<void> => {
  const deadline = Date.now() + SERVER_READY_TIMEOUT_MILLISECONDS;

  while (Date.now() < deadline) {
    try {
      const response = await fetch(origin);

      // Any answer means the server is up; the rendered page is not needed.
      await response.body?.cancel();

      return;
    } catch {
      await delay(READY_POLL_INTERVAL_MILLISECONDS);
    }
  }

  throw new Error(`The worker server at ${origin} did not answer in time.`);
};

const stopProcessGroup = (processId: number | undefined): void => {
  if (processId === undefined) return;

  // The group, so the dev server behind `pnpm` stops with it.
  try {
    process.kill(-processId, 'SIGTERM');
  } catch {
    // Already gone.
  }
};

export type WorkerServer = {
  baseURL: string;
  databaseFile: string;
  stop: () => void;
};

/**
 * Starts one worker's dev server on a free port with its own file database,
 * and resolves once it answers.
 *
 * Starts are serialized across worker processes: each `react-router dev`
 * regenerates route types into the package's shared `.react-router/types`
 * folder (delete, then write) as it starts, and two starting together delete
 * each other's files and exit. Typegen begins in Vite's config phase, before
 * the server listens, so holding the lock until the server answers covers it.
 *
 * The server's output is appended to `worker-<parallelIndex>-server.log` in the
 * output folder: appended, because a worker restarted after a failure keeps
 * its index and would otherwise overwrite the log of the start that failed.
 */
export const startWorkerServer = async ({
  command = ['pnpm', 'dev'],
  outputDirectory,
  packageDirectory,
  parallelIndex,
}: {
  command?: string[];
  outputDirectory: string;
  packageDirectory: string;
  parallelIndex: number;
}): Promise<WorkerServer> => {
  const databaseFile = path.join(
    outputDirectory,
    `worker-${parallelIndex}.sqlite`
  );
  const logFile = path.join(
    outputDirectory,
    `worker-${parallelIndex}-server.log`
  );

  fs.mkdirSync(outputDirectory, {recursive: true});
  fs.rmSync(databaseFile, {force: true});

  const log = fs.openSync(logFile, 'a');
  const releaseStartLock = await acquireStartLock(
    path.join(outputDirectory, START_LOCK_FILE_NAME),
    START_LOCK_TIMEOUT_MILLISECONDS
  );
  let serverProcessId: number | undefined;

  const stop = () => {
    releaseStartLock();
    stopProcessGroup(serverProcessId);
  };

  try {
    const port = await findFreePort();
    const baseURL = `http://${WORKER_SERVER_HOST}:${port}`;
    const [executable, ...commandArguments] = command;
    const server = spawn(
      executable,
      [...commandArguments, '--host', WORKER_SERVER_HOST],
      {
        cwd: packageDirectory,
        detached: true,
        env: {
          ...process.env,
          DATABASE_URL: databaseFile,
          [DEV_PORT_OVERRIDE_ENV]: String(port),
          SITE_URL: baseURL,
        },
        stdio: ['ignore', log, log],
      }
    );

    serverProcessId = server.pid;

    const serverStopped = new Promise<never>((_, reject) => {
      server.once('error', reject);
      server.once('exit', (code, signal) => {
        reject(
          new Error(
            `The worker server exited before it answered (code ${code}, signal ${signal}); its output is in ${logFile}.`
          )
        );
      });
    });

    // The exit that `stop` causes rejects too, with no one waiting on it.
    serverStopped.catch(() => undefined);

    await Promise.race([waitForServer(baseURL), serverStopped]);
    releaseStartLock();

    return {baseURL, databaseFile, stop};
  } catch (error) {
    stop();

    throw error;
  } finally {
    // The child holds its own copy of the descriptor.
    fs.closeSync(log);
  }
};
