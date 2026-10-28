import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {listPackageFiles} from './inventory.js';

export type Workspace = {
  /** Never touched after the copy: the pre-run byte record. */
  beforeDir: string;
  /** The files copied, package-relative. */
  files: string[];
  root: string;
  /** Third-party tools run here only. */
  workDir: string;
};

const copyInto = (
  packageDir: string,
  targetDir: string,
  files: readonly string[]
): void => {
  files.forEach((file) => {
    const destination = path.join(targetDir, file);

    mkdirSync(path.dirname(destination), {recursive: true});
    copyFileSync(path.join(packageDir, file), destination);
  });
};

/**
 * Copies what the package holds right now (so an uncommitted update merge is
 * what is copied), and reaches `node_modules` in `work/` only through a symlink
 * to the package's own.
 */
export const createWorkspace = (packageDir: string): Workspace => {
  const files = listPackageFiles(packageDir);
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-migrate-csf4-'));
  const beforeDir = path.join(root, 'before');
  const workDir = path.join(root, 'work');

  mkdirSync(beforeDir);
  mkdirSync(workDir);
  copyInto(packageDir, beforeDir, files);
  copyInto(packageDir, workDir, files);
  const modulesDir = path.join(packageDir, 'node_modules');

  if (existsSync(modulesDir)) {
    symlinkSync(modulesDir, path.join(workDir, 'node_modules'), 'dir');
  }

  return {beforeDir, files, root, workDir};
};

export const removeWorkspace = (workspace: Workspace): void => {
  // The symlink is removed first: a recursive remove must never be able to
  // follow it into the package's real node_modules.
  rmSync(path.join(workspace.workDir, 'node_modules'), {force: true});
  rmSync(workspace.root, {force: true, recursive: true});
};

/**
 * Package files outside `allowed` whose bytes differ from the pre-run copy
 * (including files that vanished or appeared), each restored from that copy.
 * Package-relative paths.
 */
export const restoreUnexpectedChanges = (
  packageDir: string,
  workspace: Workspace,
  allowed: ReadonlySet<string>
): string[] => {
  const restored: string[] = [];

  workspace.files
    .filter((file) => !allowed.has(file))
    .forEach((file) => {
      const target = path.join(packageDir, file);
      const original = readFileSync(path.join(workspace.beforeDir, file));

      if (existsSync(target) && readFileSync(target).equals(original)) return;
      mkdirSync(path.dirname(target), {recursive: true});
      writeFileSync(target, original);
      restored.push(file);
    });

  const known = new Set(workspace.files);

  listPackageFiles(packageDir)
    .filter((file) => !known.has(file) && !allowed.has(file))
    .forEach((file) => {
      rmSync(path.join(packageDir, file), {force: true});
      restored.push(file);
    });

  return restored.toSorted((left, right) => left.localeCompare(right));
};
