/* eslint-disable unicorn/prevent-abbreviations -- the module under test is named dev-ports-vite-plugin */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import fs from 'node:fs';
import type net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {
  buildResolvedResolution,
  closeServer,
  findFreePort,
  listenOn,
  loadPlugin,
  makeServer,
} from './dev-ports-vite-plugin-helpers';

const {findListenerOwnerMock, resolveDevPortsMock, spawnMock} = vi.hoisted(
  () => ({
    findListenerOwnerMock: vi.fn(),
    resolveDevPortsMock: vi.fn(),
    spawnMock: vi.fn(),
  })
);

vi.mock('node:child_process', () => ({
  default: {spawn: spawnMock},
  spawn: spawnMock,
}));

vi.mock('../dev-ports', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  findListenerOwner: findListenerOwnerMock,
  resolveDevPorts: resolveDevPortsMock,
}));

const heldServers: net.Server[] = [];
let sandbox: string | undefined;

const listenWith = async (treeRoot: string): Promise<void> => {
  resolveDevPortsMock.mockReturnValue(buildResolvedResolution(5301, treeRoot));
  const plugin = await loadPlugin();
  const server = makeServer();
  await plugin.configureServer(server);
  server.httpServer.emit('listening');
};

const makeTreeWithScript = (): string => {
  sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'dev-ports-plugin-'));
  fs.mkdirSync(path.join(sandbox, '.gaia', 'scripts'), {recursive: true});
  fs.writeFileSync(
    path.join(sandbox, '.gaia', 'scripts', 'server-process-lib.sh'),
    ''
  );

  return sandbox;
};

beforeEach(() => {
  vi.resetModules();
  spawnMock.mockReset();
  spawnMock.mockReturnValue({on: vi.fn(), unref: vi.fn()});
  resolveDevPortsMock.mockReset();
  findListenerOwnerMock.mockReset();
  findListenerOwnerMock.mockReturnValue({kind: 'unknown'});
  delete process.env.CLAUDE_CODE_SESSION_ID;
  delete (globalThis as Record<symbol, unknown>)[
    Symbol.for('gaia.dev-ports.listening-port')
  ];
});

afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all(
    heldServers.splice(0).map(async (server) => closeServer(server))
  );

  if (sandbox !== undefined) {
    fs.rmSync(sandbox, {force: true, recursive: true});
    sandbox = undefined;
  }
  delete process.env.CLAUDE_CODE_SESSION_ID;
});

describe('config restart', () => {
  test('does not refuse its own port after a module reload and records the launch once', async () => {
    sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'dev-ports-plugin-'));
    fs.mkdirSync(path.join(sandbox, '.gaia', 'scripts'), {recursive: true});
    fs.writeFileSync(
      path.join(sandbox, '.gaia', 'scripts', 'server-process-lib.sh'),
      ''
    );
    process.env.CLAUDE_CODE_SESSION_ID = 'session-one';
    const port = await findFreePort();
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port, sandbox));
    const plugin = await loadPlugin();

    const firstServer = makeServer();
    await plugin.configureServer(firstServer);
    heldServers.push(await listenOn(port, '127.0.0.1'));
    firstServer.httpServer.emit('listening');

    // A real restart re-bundles the config into a fresh module, so the second
    // configureServer runs against a module with no memory of the first.
    vi.resetModules();
    // The owner probe cannot identify the holder (no lsof/ss, or no git
    // checkout): the restart must still pass, on the recorded port alone.
    findListenerOwnerMock.mockReturnValue({kind: 'unknown'});
    const restartedPlugin = await loadPlugin();

    const restartedServer = makeServer();
    await expect(
      restartedPlugin.configureServer(restartedServer)
    ).resolves.toBeUndefined();
    restartedServer.httpServer.emit('listening');

    expect(spawnMock).toHaveBeenCalledTimes(1);
  });

  test('a restart still passes through the owner probe when the slot is empty and the holder is this process', async () => {
    const port = await findFreePort();
    heldServers.push(await listenOn(port, '127.0.0.1'));
    findListenerOwnerMock.mockReturnValue({kind: 'own', pid: process.pid});
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
    const plugin = await loadPlugin();

    await expect(plugin.configureServer(makeServer())).resolves.toBeUndefined();
  });

  test('a held port owned by another process still refuses', async () => {
    const port = await findFreePort();
    heldServers.push(await listenOn(port, '127.0.0.1'));
    findListenerOwnerMock.mockReturnValue({kind: 'own', pid: process.pid + 1});
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
    const plugin = await loadPlugin();

    await expect(plugin.configureServer(makeServer())).rejects.toThrow(
      `port ${port}`
    );
  });

  test('a fresh module with the port held still refuses (control)', async () => {
    const port = await findFreePort();
    heldServers.push(await listenOn(port, '127.0.0.1'));
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
    const plugin = await loadPlugin();

    await expect(plugin.configureServer(makeServer())).rejects.toThrow(
      `port ${port}`
    );
  });
});

const expectNoRecorder = (): void => {
  expect(spawnMock).not.toHaveBeenCalled();
};

const expectOneRecorder = (treeRoot: string): void => {
  expect(spawnMock).toHaveBeenCalledTimes(1);
  expect(spawnMock).toHaveBeenCalledWith(
    'bash',
    [
      path.join(treeRoot, '.gaia', 'scripts', 'server-process-lib.sh'),
      '--record-launch',
      '--pid',
      String(process.pid),
      '--port',
      '5301',
      '--kind',
      'dev',
      '--tree',
      treeRoot,
    ],
    {detached: true, stdio: 'ignore'}
  );
};

const makeTreeWithoutScript = (): string => {
  sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'dev-ports-plugin-'));

  return sandbox;
};

describe('launch recording', () => {
  test.each(
    [
      {
        expectRecorder: expectNoRecorder,
        makeTree: makeTreeWithScript,
        name: 'with no session id nothing is spawned',
        sessionId: undefined,
      },
      {
        expectRecorder: expectOneRecorder,
        makeTree: makeTreeWithScript,
        name: 'with a session id and the script present exactly one detached recorder is spawned',
        sessionId: 'session-two',
      },
      {
        expectRecorder: expectNoRecorder,
        makeTree: makeTreeWithoutScript,
        name: 'with a session id but no script nothing is spawned',
        sessionId: 'session-three',
      },
    ].map((row) => [row.name, row] as const)
  )(
    'launch recording spawns one recorder only with a session id and the script: %s',
    async (_name, {expectRecorder, makeTree, sessionId}) => {
      vi.stubEnv('CLAUDE_CODE_SESSION_ID', sessionId);
      const treeRoot = makeTree();
      await listenWith(treeRoot);

      expectRecorder(treeRoot);
    }
  );
});
