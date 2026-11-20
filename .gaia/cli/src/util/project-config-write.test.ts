import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {projectConfigPath} from '../schemas/project-config.js';
import {updateProjectConfig} from './project-config-write.js';

describe('updateProjectConfig', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-project-config-write-'));
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  const seed = (text: string): void => {
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(projectConfigPath(root), text, 'utf8');
  };

  const read = (): string => readFileSync(projectConfigPath(root), 'utf8');

  test('creates .gaia and the file with version 1 when both are absent', () => {
    updateProjectConfig(root, {isolation_policy: 'prefer-worktree'});

    expect(read()).toBe(
      '{\n  "version": 1,\n  "isolation_policy": "prefer-worktree"\n}\n'
    );
  });

  test('merges onto existing keys and keeps unknown keys', () => {
    seed(
      JSON.stringify({
        future: 'x',
        isolation_policy: 'prefer-branch',
        version: 1,
      })
    );

    updateProjectConfig(root, {sandbox_recommended: true});

    expect(JSON.parse(read())).toEqual({
      future: 'x',
      isolation_policy: 'prefer-branch',
      sandbox_recommended: true,
      version: 1,
    });
  });

  test.each(['on', 'off', 'maybe'])(
    'carries a retired dependabot_security_updates value %j through byte-for-byte',
    (value) => {
      seed(
        `{\n  "version": 1,\n  "dependabot_security_updates": "${value}"\n}\n`
      );

      updateProjectConfig(root, {isolation_policy: 'prefer-branch'});

      expect(read()).toBe(
        `{\n  "version": 1,\n  "dependabot_security_updates": "${value}",\n  "isolation_policy": "prefer-branch"\n}\n`
      );
    }
  );

  test('sets version 1 on an existing file that lacks it', () => {
    seed(JSON.stringify({isolation_policy: 'prefer-branch'}));

    updateProjectConfig(root, {sandbox_recommended: false});

    expect(JSON.parse(read())).toMatchObject({version: 1});
  });

  test('leaves no temporary file beside the target after a write', () => {
    updateProjectConfig(root, {sandbox_recommended: true});

    expect(readdirSync(path.join(root, '.gaia'))).toEqual(['project.json']);
  });

  test.each([{isolation_policy: 'sometimes'}, {sandbox_recommended: 'true'}])(
    'refuses an invalid known key %j and writes nothing',
    (patch) => {
      expect(() => {
        updateProjectConfig(root, patch);
      }).toThrow(expect.objectContaining({kind: 'invalid_value'}));
      expect(existsSync(projectConfigPath(root))).toBe(false);
    }
  );

  test('writes fitness_commit_threshold and keeps unknown keys', () => {
    seed(JSON.stringify({future: 'x', version: 1}));

    updateProjectConfig(root, {fitness_commit_threshold: 20});

    expect(JSON.parse(read())).toEqual({
      fitness_commit_threshold: 20,
      future: 'x',
      version: 1,
    });
  });

  const FUTURE_FILE = '{"version": 1, "future": "x"}\n';

  test.each(
    [
      {
        kind: 'invalid_value',
        message: /isolation_policy/u,
        name: 'an invalid known key leaves an existing file byte-identical',
        patch: {isolation_policy: 'sometimes'},
        seeded: FUTURE_FILE,
      },
      ...[0, 15.5, '25'].map((value) => ({
        kind: 'invalid_value',
        message: /fitness_commit_threshold/u,
        name: `refuses fitness_commit_threshold ${JSON.stringify(value)}, naming the key, and leaves the file byte-identical`,
        patch: {fitness_commit_threshold: value},
        seeded: FUTURE_FILE,
      })),
      {
        kind: 'invalid_value',
        message: /fitness_commit_threshold/u,
        name: 'a file already holding fitness_commit_threshold 0 refuses an unrelated patch',
        patch: {sandbox_recommended: true},
        seeded: '{"version": 1, "fitness_commit_threshold": 0}\n',
      },
      {
        kind: 'malformed',
        message: /project\.json/u,
        name: 'throws a malformed error naming the file and leaves it unchanged',
        patch: {isolation_policy: 'prefer-branch'},
        seeded: '{not json',
      },
      {
        kind: 'malformed',
        message: /project\.json/u,
        name: 'refuses a non-object file as malformed',
        patch: {sandbox_recommended: true},
        seeded: '[]',
      },
    ].map((row) => [row.name, row] as const)
  )('%s', (_name, {kind, message, patch, seeded}) => {
    seed(seeded);

    expect(() => {
      updateProjectConfig(root, patch);
    }).toThrow(expect.objectContaining({kind}));
    expect(() => {
      updateProjectConfig(root, patch);
    }).toThrow(message);
    expect(read()).toBe(seeded);
  });
});
