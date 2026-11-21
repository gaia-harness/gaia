/* eslint-disable unicorn/prevent-abbreviations -- the module under test is named dev-ports-vite-plugin */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import type net from 'node:net';
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
  test("a missing port file rejects with the resolution's message", async () => {
    const resolutionMessage = 'opaque-resolution-message-sentinel';
    resolveDevPortsMock.mockReturnValue({
      kind: 'missing-port-file',
      message: resolutionMessage,
      portFilePath: '/package/.gaia-ports',
      treeRoot: '/tree',
    });
    const plugin = await loadPlugin();

    await expect(plugin.configureServer(makeServer())).rejects.toThrow(
      resolutionMessage
    );
  });

  test('a port taken on 127.0.0.1 rejects naming the port', async () => {
    const port = await findFreePort();
    heldServers.push(await listenOn(port, '127.0.0.1'));
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
    const plugin = await loadPlugin();

    const refusal = plugin.configureServer(makeServer());

    await expect(refusal).rejects.toThrow(`port ${port}`);
    await expect(refusal).rejects.toThrow(
      'Never stop a process on a port another live tree owns without asking the user first.'
    );
    await expect(refusal).rejects.toThrow(
      "Run bash .gaia/scripts/ports.sh to see this tree's ports."
    );
  });

  // Runs unconditionally: a host without an IPv6 loopback fails loudly rather
  // than skipping the IPv6-only refusal.
  test('a port taken on ::1 only rejects the same way', async () => {
    const heldServer = await listenOn(0, '::1').catch((error: unknown) => {
      throw new Error(
        `this test needs an IPv6 loopback (::1) on the host: ${String(error)}`
      );
    });
    heldServers.push(heldServer);
    const {port} = heldServer.address() as net.AddressInfo;
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
    const plugin = await loadPlugin();

    await expect(plugin.configureServer(makeServer())).rejects.toThrow(
      `port ${port}`
    );
  });

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
