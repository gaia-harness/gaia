import {randomUUID} from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import type {StorageRoots} from './paths.js';

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

/**
 * Read or mint the telemetry install id at `.gaia/local/.install-id`.
 * A random UUIDv4 (`crypto.randomUUID()`), so nothing about the machine,
 * the user or the repo path can be recovered from it. Mode 644.
 * Idempotent: subsequent reads return the existing line.
 *
 * Minting deletes the legacy `.project-id` first. That file held a hash of
 * the repo path, which a guessable path makes reversible, so every install
 * rotates once to a new file name and the old value is never read. Deleting
 * before writing means a failed delete leaves no `.install-id`, and the next
 * run tries the rotation again instead of leaving the old hash behind.
 */
export const readOrCreateProjectId = (roots: StorageRoots): string => {
  const filePath = roots.installIdPath;

  if (existsSync(filePath)) {
    const existing = readFileSync(filePath, 'utf8').trim();

    if (UUID_RE.test(existing)) {
      return existing;
    }
    // Malformed: mint a new one.
  }

  const parent = path.dirname(filePath);

  if (!existsSync(parent)) {
    mkdirSync(parent, {mode: 0o755, recursive: true});
  }

  rmSync(roots.legacyProjectIdPath, {force: true});
  const id = randomUUID();
  writeFileSync(filePath, `${id}\n`, {mode: 0o644});

  return id;
};
