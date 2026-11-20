/* eslint-disable no-bitwise -- POSIX file modes are bitfields; `& 0o777` is
   the standard idiom for masking off the permission bits. */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  readSandboxMarker,
  resolveMarkerPath,
  writeSandboxMarker,
} from '../marker.js';
import type {SandboxMarker} from '../marker.js';

describe('sandbox marker', () => {
  let repoRoot: string;

  beforeEach(() => {
    repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-sandbox-marker-'));
  });

  afterEach(() => {
    rmSync(repoRoot, {force: true, recursive: true});
  });

  const enabledMarker: SandboxMarker = {
    capability: 'ready',
    outcome: 'enabled',
    resolved_at: '2026-01-01T00:00:00.000Z',
    version: 1,
  };

  test.each([
    {
      expected: null,
      name: 'readSandboxMarker returns null when the file is absent',
      writes: [] as SandboxMarker[],
    },
    {
      expected: enabledMarker,
      name: 'writeSandboxMarker then readSandboxMarker round-trips',
      writes: [enabledMarker],
    },
    {
      expected: {
        capability: 'ready',
        outcome: 'enabled',
        resolved_at: '2026-06-01T00:00:00.000Z',
        version: 1,
      },
      name: 'overwrites the previous marker (write-temp-and-rename)',
      writes: [
        {
          capability: 'ready',
          outcome: 'declined',
          resolved_at: '2026-01-01T00:00:00.000Z',
          version: 1,
        },
        {
          capability: 'ready',
          outcome: 'enabled',
          resolved_at: '2026-06-01T00:00:00.000Z',
          version: 1,
        },
      ] as SandboxMarker[],
    },
  ])('$name', ({expected, writes}) => {
    for (const marker of writes) {
      writeSandboxMarker(repoRoot, marker);
    }

    expect(readSandboxMarker(repoRoot)).toEqual(expected);
  });

  test('writes at .gaia/local/sandbox.json with mode 644', () => {
    writeSandboxMarker(repoRoot, {
      capability: 'ready',
      outcome: 'declined',
      resolved_at: '2026-01-01T00:00:00.000Z',
      version: 1,
    });

    const filePath = resolveMarkerPath(repoRoot);
    expect(filePath).toBe(
      path.join(repoRoot, '.gaia', 'local', 'sandbox.json')
    );
    expect(existsSync(filePath)).toBe(true);
    expect(statSync(filePath).mode & 0o777).toBe(0o644);
  });

  test('writes atomically: no leftover temp file beside the target', () => {
    writeSandboxMarker(repoRoot, {
      capability: 'unsupported',
      outcome: 'incapable',
      resolved_at: '2026-01-01T00:00:00.000Z',
      version: 1,
    });

    const parent = path.dirname(resolveMarkerPath(repoRoot));
    const entries = readdirSync(parent);
    expect(entries.some((entry) => entry.includes('.tmp.'))).toBe(false);
  });

  test.each([
    {
      contents: {...enabledMarker, version: 2},
      error: /version/u,
      name: 'throws on an unexpected version (fail loud, not silent default)',
    },
    {
      contents: {version: 1},
      error: /missing required fields/u,
      name: 'throws on a malformed shape missing required fields',
    },
    {
      contents: {...enabledMarker, outcome: 'garbage'},
      error: /unknown outcome or capability/u,
      name: 'throws on a present-but-off-vocabulary outcome/capability',
    },
  ])('$name', ({contents, error}) => {
    // First write ensures the parent dir exists, then corrupt the file.
    writeSandboxMarker(repoRoot, enabledMarker);
    writeFileSync(resolveMarkerPath(repoRoot), JSON.stringify(contents), {
      mode: 0o644,
    });

    expect(() => readSandboxMarker(repoRoot)).toThrow(error);
  });
});
