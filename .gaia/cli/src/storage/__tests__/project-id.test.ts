/* eslint-disable no-bitwise -- POSIX file modes are bitfields; `& 0o777`
   is the standard idiom for masking off the permission bits. */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import type {StorageRoots} from '../paths.js';
import {readOrCreateProjectId} from '../project-id.js';

const UUID_V4_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

/**
 * The roots for a given repo root, built directly rather than through
 * `resolveStorageRoots`. These tests exercise the id writer — minting,
 * idempotence, mode, legacy rotation, parent creation — not the resolution
 * that decides which checkout owns the file; that is `paths.test.ts`, which
 * needs real git sandboxes. Keeping them separate lets these run against a
 * plain temp dir.
 */
const rootsFor = (repoRoot: string): StorageRoots => ({
  installIdPath: path.join(repoRoot, '.gaia', 'local', '.install-id'),
  legacyProjectIdPath: path.join(repoRoot, '.gaia', 'local', '.project-id'),
});

describe('readOrCreateProjectId', () => {
  let repoRoot: string;

  beforeEach(() => {
    repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-pid-repo-'));
  });

  afterEach(() => {
    rmSync(repoRoot, {force: true, recursive: true});
  });

  test('writes a UUIDv4 id to .install-id with mode 644 on first call', () => {
    const roots = rootsFor(repoRoot);

    const id = readOrCreateProjectId(roots);

    expect(id).toMatch(UUID_V4_RE);
    expect(existsSync(roots.installIdPath)).toBe(true);
    expect(statSync(roots.installIdPath).mode & 0o777).toBe(0o644);
    expect(readFileSync(roots.installIdPath, 'utf8').trim()).toBe(id);
  });

  test('returns the same id on subsequent calls (idempotent)', () => {
    const roots = rootsFor(repoRoot);

    const first = readOrCreateProjectId(roots);
    const second = readOrCreateProjectId(roots);

    expect(second).toBe(first);
  });

  test('mints a fresh random id, not one derived from the path, when the file is gone', () => {
    const roots = rootsFor(repoRoot);

    const first = readOrCreateProjectId(roots);
    rmSync(roots.installIdPath, {force: true});
    const second = readOrCreateProjectId(roots);

    expect(second).toMatch(UUID_V4_RE);
    expect(second).not.toBe(first);
  });

  test('rotates an existing install: deletes the legacy .project-id and never reuses its value', () => {
    const roots = rootsFor(repoRoot);
    const legacyId = '0f1e2d3c-4b5a-4968-8776-655443322110';
    mkdirSync(path.dirname(roots.legacyProjectIdPath), {recursive: true});
    writeFileSync(roots.legacyProjectIdPath, `${legacyId}\n`);

    const id = readOrCreateProjectId(roots);

    expect(id).toMatch(UUID_V4_RE);
    expect(id).not.toBe(legacyId);
    expect(existsSync(roots.legacyProjectIdPath)).toBe(false);
    expect(readFileSync(roots.installIdPath, 'utf8').trim()).toBe(id);
  });

  test('creates the parent .gaia/local/ directory if absent', () => {
    const roots = rootsFor(repoRoot);

    expect(existsSync(path.dirname(roots.installIdPath))).toBe(false);

    const id = readOrCreateProjectId(roots);

    expect(existsSync(path.dirname(roots.installIdPath))).toBe(true);
    expect(id).toMatch(UUID_V4_RE);
  });
});
