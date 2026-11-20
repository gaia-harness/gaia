/* eslint-disable unicorn/prevent-abbreviations -- the module under test is named dev-ports-vite-plugin */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import type net from 'node:net';
import {ASK_FIRST_SENTENCE, PORTS_HINT} from '../dev-ports';
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

const hasIpv6 = async (): Promise<boolean> => {
  try {
    await closeServer(await listenOn(0, '::1'));

    return true;
  } catch {
    return false;
  }
};

const isIpv6Available = await hasIpv6();

const heldServers: net.Server[] = [];

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
  delete process.env.CLAUDE_CODE_SESSION_ID;
});

describe('config', () => {
  test.each(
    [
      {
        expectedPort: 5199,
        name: 'serve pins the resolved dev port with strictPort',
        override: undefined,
      },
      {
        expectedPort: 5321,
        name: 'a named port override replaces the tree port and keeps strictPort',
        override: '5321',
      },
      {
        expectedPort: 5199,
        name: 'a malformed port override is ignored',
        override: 'abc',
      },
    ].map((row) => [row.name, row] as const)
  )(
    'config pins the resolved or overridden dev port: %s',
    async (_name, {expectedPort, override}) => {
      resolveDevPortsMock.mockReturnValue(buildResolvedResolution(5199));

      vi.stubEnv('GAIA_DEV_PORT_OVERRIDE', override);
      const plugin = await loadPlugin();

      expect(plugin.config({}, {command: 'serve'})).toEqual({
        server: {port: expectedPort, strictPort: true},
      });
    }
  );

  test('build returns nothing port-related and never throws on a missing port file', async () => {
    resolveDevPortsMock.mockReturnValue({
      kind: 'missing-port-file',
      message: 'missing',
      portFilePath: '/package/.gaia-ports',
      treeRoot: '/tree',
    });
    const plugin = await loadPlugin();

    expect(plugin.config({}, {command: 'build'})).toBeUndefined();
    expect(resolveDevPortsMock).not.toHaveBeenCalled();
  });
});

describe('configureServer refusals', () => {
  test('a missing port file rejects with the ask-first sentence and ports hint', async () => {
    resolveDevPortsMock.mockReturnValue({
      kind: 'missing-port-file',
      message: `GAIA: no port file. ${ASK_FIRST_SENTENCE} ${PORTS_HINT}`,
      portFilePath: '/package/.gaia-ports',
      treeRoot: '/tree',
    });
    const plugin = await loadPlugin();

    const failure = plugin.configureServer(makeServer());
    await expect(failure).rejects.toThrow(ASK_FIRST_SENTENCE);
    await expect(failure).rejects.toThrow(PORTS_HINT);
  });

  test('a port taken on 127.0.0.1 rejects naming the port, the ask-first sentence, and the hint', async () => {
    const port = await findFreePort();
    heldServers.push(await listenOn(port, '127.0.0.1'));
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
    const plugin = await loadPlugin();

    const failure = plugin.configureServer(makeServer());
    await expect(failure).rejects.toThrow(`port ${port}`);
    await expect(failure).rejects.toThrow(ASK_FIRST_SENTENCE);
    await expect(failure).rejects.toThrow(PORTS_HINT);
  });

  test.skipIf(!isIpv6Available)(
    'a port taken on ::1 only rejects the same way',
    async () => {
      const port = await findFreePort();
      heldServers.push(await listenOn(port, '::1'));
      resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
      const plugin = await loadPlugin();

      await expect(plugin.configureServer(makeServer())).rejects.toThrow(
        `port ${port}`
      );
    }
  );

  test.each(
    [
      {
        arrange: async (treePort: number): Promise<void> => {
          heldServers.push(await listenOn(treePort, '127.0.0.1'));
          vi.stubEnv('GAIA_DEV_PORT_OVERRIDE', String(await findFreePort()));
        },
        name: 'the override port is probed in place of the tree port',
      },
      {
        arrange: async (): Promise<void> => {},
        name: 'a free port resolves',
      },
    ].map((row) => [row.name, row] as const)
  )(
    'configureServer resolves on a free port and probes the override: %s',
    async (_name, {arrange}) => {
      const treePort = await findFreePort();
      await arrange(treePort);
      resolveDevPortsMock.mockReturnValue(buildResolvedResolution(treePort));
      const plugin = await loadPlugin();

      await expect(
        plugin.configureServer(makeServer())
      ).resolves.toBeUndefined();
    }
  );

  test('a taken override port rejects naming the override port', async () => {
    const overridePort = await findFreePort();
    heldServers.push(await listenOn(overridePort, '127.0.0.1'));
    vi.stubEnv('GAIA_DEV_PORT_OVERRIDE', String(overridePort));
    resolveDevPortsMock.mockReturnValue(
      buildResolvedResolution(await findFreePort())
    );
    const plugin = await loadPlugin();

    await expect(plugin.configureServer(makeServer())).rejects.toThrow(
      `port ${overridePort}`
    );
  });
});
