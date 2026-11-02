import type {Plugin} from 'vite';
import {spawn} from 'node:child_process';
import fs from 'node:fs';
import type {ListenerOwner} from './dev-ports.ts';
import {
  buildPortInUseMessage,
  findListenerOwner,
  isPortTaken,
  resolveDevPortOverride,
  resolveDevPorts,
  resolveServerProcessScriptPath,
} from './dev-ports.ts';

// A config restart builds the new server (running this hook) before it closes
// the old one, so the old one still holds the port. Vite re-bundles the config
// into a fresh module on restart, so module state does not survive it. The port
// this process is listening on is therefore recorded in a globalThis slot, which
// does survive, so a restart is told from a foreign holder without needing the
// listener-owner probe (which reads unknown without lsof/ss or outside a git
// checkout). The owner probe stays as the fallback for a port the slot does not
// name. The slot also keeps a restart from recording the launch twice.
const LISTENING_PORT_SLOT = Symbol.for('gaia.dev-ports.listening-port');

type ListeningPortHolder = {[LISTENING_PORT_SLOT]?: number};

const getRecordedPort = (): number | undefined =>
  (globalThis as ListeningPortHolder)[LISTENING_PORT_SLOT];

const recordPort = (port: number): void => {
  (globalThis as ListeningPortHolder)[LISTENING_PORT_SLOT] = port;
};

const describePortHolder = ({
  owner,
  treeRoot,
}: {
  owner: ListenerOwner;
  treeRoot: string | undefined;
}): {ownerPath?: string; pid?: number} => {
  if (owner.kind === 'foreign') {
    return {
      ownerPath: owner.ownerPath,
      pid: owner.pid > 0 ? owner.pid : undefined,
    };
  }
  if (owner.kind === 'own') return {ownerPath: treeRoot, pid: owner.pid};

  return {};
};

const recordLaunch = ({
  port,
  treeRoot,
}: {
  port: number;
  treeRoot: string;
}): void => {
  if (!process.env.CLAUDE_CODE_SESSION_ID) return;
  const scriptPath = resolveServerProcessScriptPath(treeRoot);
  if (!fs.existsSync(scriptPath)) return;

  // Fire and forget: the record is bookkeeping and must never slow the server.
  const child = spawn(
    // eslint-disable-next-line sonarjs/no-os-command-from-path -- the script path is absolute; `bash` is the only PATH lookup
    'bash',
    [
      scriptPath,
      '--record-launch',
      '--pid',
      String(process.pid),
      '--port',
      String(port),
      '--kind',
      'dev',
      '--tree',
      treeRoot,
    ],
    {detached: true, stdio: 'ignore'}
  );

  child.on('error', () => {});
  child.unref();
};

/**
 * Pins the dev server to this tree's port (or the named override port)
 * without drifting, refuses a taken
 * port with the ask-first message, and records a Claude-launched server so a
 * dead session's server can be cleaned up.
 */
export const devPortsPlugin = (packageDirectory: string): Plugin => ({
  config: (_, {command}) => {
    if (command !== 'serve') return;
    const resolution = resolveDevPorts(packageDirectory);
    if (resolution.kind !== 'resolved') return;

    return {
      server: {
        port: resolveDevPortOverride(process.env) ?? resolution.ports.devPort,
        strictPort: true,
      },
    };
  },
  configureServer: async (server) => {
    const resolution = resolveDevPorts(packageDirectory);
    if (resolution.kind !== 'resolved') throw new Error(resolution.message);
    const {treeRoot} = resolution.ports;
    const devPort =
      resolveDevPortOverride(process.env) ?? resolution.ports.devPort;

    if ((await isPortTaken(devPort)) && getRecordedPort() !== devPort) {
      const owner = findListenerOwner({port: devPort, treeRoot});

      if (owner.kind !== 'own' || owner.pid !== process.pid) {
        throw new Error(
          buildPortInUseMessage({
            ...describePortHolder({owner, treeRoot}),
            port: devPort,
            service: 'dev server',
          })
        );
      }
    }

    server.httpServer?.once('listening', () => {
      // A restart's port is already recorded, and so is its launch.
      const isRestart = getRecordedPort() === devPort;
      recordPort(devPort);
      if (isRestart) return;
      if (treeRoot !== undefined) recordLaunch({port: devPort, treeRoot});
    });
  },
  name: 'gaia-dev-ports',
});
