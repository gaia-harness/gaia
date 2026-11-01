import path from 'node:path';
import {loadPackages, webMembers} from './packages.js';
import {resolveRepoRoot} from './repo-root.js';

export type PackageTarget =
  | {message: string; ok: false}
  | {ok: true; packageDir: string; packagePath: string; repoRoot: string};

/**
 * The tree a CLI command acts on: the calling working tree's root, so a
 * command run from `frontend/` and from the repo root name the same tree.
 * Falls back to `cwd` when git cannot answer, because scaffolding must not
 * require a repository (an adopter may scaffold before `git init`).
 */
const resolveTreeRoot = (cwd: string): string => {
  try {
    return resolveRepoRoot(cwd);
  } catch {
    return cwd;
  }
};

/**
 * Resolve the web-stack member a command acts on from the working tree root
 * and the registry, never from `cwd` itself. With no `packageName` the single
 * web member is the target; a name must be a web member. A registry or
 * descriptor failure comes back as its `gaia-packages:` message so the caller
 * can refuse before it writes anything.
 */
export const resolveWebTarget = (
  cwd: string,
  packageName?: string
): PackageTarget => {
  const repoRoot = resolveTreeRoot(cwd);
  const loaded = loadPackages(repoRoot);

  if (!loaded.ok) {
    return {message: loaded.message, ok: false};
  }
  const candidates = webMembers(loaded.packages);
  const listed = candidates.map((entry) => `"${entry.name}"`).join(', ');

  if (candidates.length === 0) {
    return {
      message:
        'gaia-packages: no registered package declares "stack": "web". Next step: add "stack": "web" to the app package\'s gaia.package.json, which .gaia/packages.json registers.',
      ok: false,
    };
  }

  if (packageName === undefined && candidates.length > 1) {
    return {
      message: `gaia-packages: several packages declare the web stack (${listed}). Next step: pass --package <name> to choose one.`,
      ok: false,
    };
  }
  const found =
    packageName === undefined ?
      candidates[0]
    : candidates.find((entry) => entry.name === packageName);

  if (found === undefined) {
    return {
      message: `gaia-packages: "${packageName}" is not a web-stack package. Next step: pass --package with a web package (${listed}).`,
      ok: false,
    };
  }

  return {
    ok: true,
    packageDir: path.resolve(repoRoot, found.path),
    packagePath: found.path,
    repoRoot,
  };
};

/**
 * Normalize a user-supplied path to package-relative: a repo-relative value
 * that begins with the package path (`frontend/app/components/form`) loses
 * that prefix, a package-relative one passes through.
 */
export const toPackageRelative = (
  value: string,
  packagePath: string
): string => {
  if (packagePath === '.') {
    return value;
  }

  return value.startsWith(`${packagePath}/`) ?
      value.slice(packagePath.length + 1)
    : value;
};
