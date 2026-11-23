import {existsSync} from 'node:fs';
import {createRequire} from 'node:module';
import path from 'node:path';

/** The TypeScript compiler module a caller parses with. */
// eslint-disable-next-line @typescript-eslint/consistent-type-imports -- a namespace type import of this export= module adds a synthetic `default` the caller's own `typescript` value lacks
export type Ts = typeof import('typescript');

/**
 * The project's own `typescript`, never bundled into this binary. With
 * `isGated`, resolution is gated on the project's own `node_modules`:
 * `createRequire` alone would also walk parent directories, `NODE_PATH` and
 * global folders. Without it, a workspace-root install still resolves.
 */
export const loadTypescript = (
  projectDirectory: string,
  {isGated = false}: {isGated?: boolean} = {}
): Ts | undefined => {
  if (
    isGated &&
    !existsSync(
      path.join(projectDirectory, 'node_modules', 'typescript', 'package.json')
    )
  ) {
    return undefined;
  }

  try {
    return createRequire(path.join(projectDirectory, 'package.json'))(
      'typescript'
    ) as Ts;
  } catch {
    return undefined;
  }
};
