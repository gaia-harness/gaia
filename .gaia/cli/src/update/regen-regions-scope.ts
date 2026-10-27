import {createHash} from 'node:crypto';
import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {structuredError} from '../stderr.js';
import type {ConfinedEntry} from './regen-regions-types.js';

/**
 * Step 4: copy each existing declared path aside, unless a copy is already
 * there (the merge walk's own backup, or an earlier region's).
 */
type BackupInputs = {
  backupDir: string | undefined;
  paths: readonly string[];
  regionId: string;
  root: string;
};

export const performBackup = (inputs: BackupInputs): string[] => {
  const {backupDir, paths, regionId, root} = inputs;

  if (backupDir === undefined) return [];

  const backedUp: string[] = [];

  paths.forEach((declPath) => {
    const srcAbs = path.resolve(root, declPath);

    if (!existsSync(srcAbs)) return;

    const destinationAbs = path.resolve(backupDir, declPath);

    if (existsSync(destinationAbs)) return;

    // Contained like every other IO call in the region loop. A throw here
    // would discard the whole report, including the confinement records of
    // every region already swept, and the caller reads an empty report as a
    // CLI that predates this subcommand rather than as a backup failure.
    try {
      mkdirSync(path.dirname(destinationAbs), {recursive: true});
      copyFileSync(srcAbs, destinationAbs);
      backedUp.push(declPath);
    } catch (error) {
      structuredError({
        code: 'region_regen_backup_failed',
        message: `backup skipped for '${declPath}' in region '${regionId}': ${error instanceof Error ? error.message : String(error)}`,
        regionId,
        subcommand: 'update regen-regions',
      });
    }
  });

  return backedUp;
};

export const scopeDirsFor = (paths: readonly string[]): ReadonlySet<string> =>
  new Set(paths.map((declPath) => path.posix.dirname(declPath)));

export type Snapshot = ReadonlyMap<string, SnapshotEntry>;
/**
 * Both kinds carry their whole pre-image, so the sweep's two questions ("did
 * the spawn touch this" and "what do I put back") are answered per kind rather
 * than only for regular files. A file's pre-image is its bytes; a link's is the
 * target it holds, which is all a link is.
 *
 * That target is a `Buffer`, not a string, deliberately. A symlink target is an
 * arbitrary byte string on POSIX, and decoding one as UTF-8 does not fail on an
 * invalid byte, it substitutes U+FFFD. Writing that back would point the link
 * somewhere else while the report claimed it was restored, and the real target
 * is gone by then. Bytes in, bytes out, no decode in between.
 */
type SnapshotEntry =
  | {content: Buffer; digest: string; kind: 'file'; mode: number}
  | {kind: 'symlink'; target: Buffer};

/**
 * Whether the spawn left this path as it found it. A link is compared by the
 * target string it holds, a file by its content hash: the two kinds are never
 * equal to each other, so replacing one with the other always counts as a
 * change.
 */
export const isUntouched = (
  before: SnapshotEntry,
  after: SnapshotEntry | undefined
): boolean => {
  if (after === undefined) return false;

  if (before.kind === 'symlink')
    return after.kind === 'symlink' && after.target.equals(before.target);

  return after.kind === 'file' && after.digest === before.digest;
};

/** Permission bits alone; `lstat` mode also carries the file-type bits. */
const permissionsOf = (mode: number): number => mode % 0o1_0000;

/**
 * Step 5 / re-used for step 7-8: SHA-256 (plus raw content, for restoring)
 * of every existing file under the region's declared paths' parent
 * directories, recursively. Keys are repo-relative, POSIX-separated.
 */
export const collectScopeDigests = (
  root: string,
  scopeDirs: ReadonlySet<string>
): Snapshot => {
  const digests = new Map<string, SnapshotEntry>();

  scopeDirs.forEach((dir) => {
    const absDir = path.resolve(root, dir);

    if (!existsSync(absDir)) return;

    let entries: string[];

    try {
      entries = readdirSync(absDir, {recursive: true}) as string[];
    } catch {
      return;
    }

    entries.forEach((rel) => {
      const abs = path.join(absDir, rel);
      let stat;

      try {
        // `lstat`, not `stat`: a symlink must not be followed here. Followed,
        // it would be buffered as its TARGET's bytes, and the sweep would then
        // restore it as a plain regular file holding a copy of content that may
        // have lived wholly outside the region, or write through the link and
        // rewrite a target outside the snapshot scope entirely.
        stat = lstatSync(abs);
      } catch {
        return;
      }

      const repoRelative = path.relative(root, abs).split(path.sep).join('/');

      // A link's pre-image is the target it holds, which is the whole of it:
      // recording that makes a link restorable in its own right, so the
      // confinement guarantee covers a link the spawn retargets or replaces
      // with a file, not only one it creates. A deleted link is left deleted,
      // like any deleted path. Reading it never follows the link, and a
      // dangling one reads fine.
      // `'buffer'`, never `'utf8'`: see SnapshotEntry.
      if (stat.isSymbolicLink()) {
        try {
          digests.set(repoRelative, {
            kind: 'symlink',
            target: readlinkSync(abs, 'buffer'),
          });
        } catch {
          // Unreadable link: skip it, like the unreadable file below. Recording
          // it with no target would make the sweep think it can put back
          // something it cannot.
        }

        return;
      }

      if (!stat.isFile()) return;

      let content;

      try {
        content = readFileSync(abs);
      } catch {
        // Unreadable file (permissions, a race with the spawn): skip it, the
        // same way an unstattable entry is skipped above. Throwing here would
        // abandon the confinement sweep and the report for every remaining
        // region, which is the one outcome this command promises never to
        // produce.
        return;
      }

      digests.set(repoRelative, {
        content,
        digest: createHash('sha256').update(content).digest('hex'),
        kind: 'file',
        mode: stat.mode,
      });
    });
  });

  return digests;
};

type SweepInputs = {
  after: Snapshot;
  before: Snapshot;
  declaredPaths: readonly string[];
  regionId: string;
  root: string;
};

/**
 * Step 7: revert anything in the snapshot scope that the spawn changed
 * outside the region's declared paths. A changed path with a pre-image is
 * restored to it, whether the spawn rewrote it, retargeted it, or replaced it
 * with the other kind; a path the spawn created has no pre-image, so it is
 * removed instead. A path the spawn deletes is neither restored nor
 * reported.
 */
export const sweepScope = (inputs: SweepInputs): ConfinedEntry[] => {
  const {after, before, declaredPaths, regionId, root} = inputs;
  const declaredSet = new Set(declaredPaths);
  const confined: ConfinedEntry[] = [];

  before.forEach((beforeEntry, relPath) => {
    if (declaredSet.has(relPath)) return;

    const afterEntry = after.get(relPath);

    // Deleted, not rewritten: left as the spawn left it.
    if (afterEntry === undefined) return;

    if (isUntouched(beforeEntry, afterEntry)) return;

    try {
      const abs = path.resolve(root, relPath);

      // Unlink first, never write onto whatever is sitting there. If the spawn
      // replaced this path with a symlink, writing would FOLLOW the link and
      // put the pre-image into its target, which can live anywhere in or
      // outside the tree: the confinement mechanism writing outside the scope
      // it exists to enforce, while the path itself stays a link and the
      // report claims it was restored.
      rmSync(abs, {force: true});

      if (beforeEntry.kind === 'symlink') {
        // Recreating the link writes no content and follows nothing, so
        // whatever it points at is untouched, exactly as when it was made.
        symlinkSync(beforeEntry.target, abs);
      } else {
        const permissions = permissionsOf(beforeEntry.mode);

        // `restored` has to mean restored. Recreating content under the process
        // umask hands back an executable the adopter can no longer run, and
        // creating it at its own permissions keeps a private pre-image from
        // existing world-readable even briefly.
        writeFileSync(abs, beforeEntry.content, {mode: permissions});
        chmodSync(abs, permissions);
      }

      confined.push({action: 'restored', path: relPath, regionId});
    } catch {
      // The revert itself failed. Surface the write rather than throwing:
      // an abandoned sweep would leave every later entry unexamined and
      // unreported, which is exactly the silent out-of-scope write the
      // confinement guarantee rules out. `reported` is the contract's term
      // for a write that is surfaced rather than reverted.
      confined.push({action: 'reported', path: relPath, regionId});
    }
  });

  [...after.keys()].forEach((relPath) => {
    if (declaredSet.has(relPath) || before.has(relPath)) return;

    try {
      // `rmSync` unlinks a symlink rather than following it, so removing one
      // the spawn created never touches what it pointed at.
      rmSync(path.resolve(root, relPath), {force: true});
      confined.push({action: 'removed', path: relPath, regionId});
    } catch {
      confined.push({action: 'reported', path: relPath, regionId});
    }
  });

  return confined;
};

export const isInsideScope = (
  relPath: string,
  scopeDirs: ReadonlySet<string>
): boolean =>
  [...scopeDirs].some(
    (dir) => relPath === dir || relPath.startsWith(`${dir}/`)
  );
