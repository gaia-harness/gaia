/* eslint-disable unicorn/prevent-abbreviations -- the module under test is named dev-ports-vite-plugin */
import net from 'node:net';
import type {DevPortsResolution} from '../dev-ports';

export type PluginHooks = {
  config: (
    configuration: unknown,
    environment: {command: string}
  ) => undefined | {server?: {port?: number; strictPort?: boolean}};
  configureServer: (server: unknown) => Promise<void>;
};

export const loadPlugin = async (): Promise<PluginHooks> => {
  const {devPortsPlugin} = await import('../dev-ports-vite-plugin');

  return devPortsPlugin('/package') as unknown as PluginHooks;
};

export const listenOn = async (
  port: number,
  host: string
): Promise<net.Server> =>
  new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen({exclusive: true, host, port}, () => resolve(server));
  });

export const closeServer = async (server: net.Server): Promise<void> =>
  new Promise((resolve) => {
    server.close(() => resolve());
  });

export const findFreePort = async (): Promise<number> => {
  const server = await listenOn(0, '127.0.0.1');
  const {port} = server.address() as net.AddressInfo;
  await closeServer(server);

  return port;
};

export const buildResolvedResolution = (
  devPort: number,
  treeRoot = '/tree'
): DevPortsResolution => ({
  kind: 'resolved',
  ports: {
    devPort,
    siteUrl: undefined,
    slot: 0,
    source: 'default',
    storybookPort: 6006,
    treeRoot,
  },
});

type FakeServer = {
  httpServer: {
    emit: (event: string) => void;
    once: (event: string, listener: () => void) => void;
  };
};

// The plugin only calls `httpServer.once('listening', ...)`; a handler list is the whole fake.
export const makeServer = (): FakeServer => {
  const handlers: Record<string, (() => void)[]> = {};

  return {
    httpServer: {
      emit: (event) => {
        for (const handler of handlers[event] ?? []) handler();
      },
      once: (event, listener) => {
        handlers[event] = [...(handlers[event] ?? []), listener];
      },
    },
  };
};
