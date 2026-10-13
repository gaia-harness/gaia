import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  ProjectConfigError,
  updateProjectConfig,
} from '../../util/project-config-write.js';
import {
  isIsolationPolicy,
  projectConfigPath,
  ProjectConfigSchema,
  readProjectConfig,
} from '../project-config.js';

describe('ProjectConfigSchema', () => {
  test('parses a config with every key', () => {
    expect(
      ProjectConfigSchema.parse({
        isolation_policy: 'prefer-branch',
        sandbox_recommended: true,
        version: 1,
      })
    ).toEqual({
      isolation_policy: 'prefer-branch',
      sandbox_recommended: true,
      version: 1,
    });
  });

  test('an empty object parses, with version degrading to 1', () => {
    expect(ProjectConfigSchema.parse({})).toEqual({version: 1});
  });

  test('invalid or wrong-typed values degrade to undefined instead of malforming', () => {
    const parsed = ProjectConfigSchema.parse({
      isolation_policy: 'worktree-ish',
      sandbox_recommended: 'yes',
      version: 9,
    });

    expect(parsed.isolation_policy).toBeUndefined();
    expect(parsed.sandbox_recommended).toBeUndefined();
    expect(parsed.version).toBe(1);
  });

  test('setup_decisions drops an unknown value and keeps the rest', () => {
    expect(
      ProjectConfigSchema.parse({setup_decisions: {a: 'applied', b: 'maybe'}})
        .setup_decisions
    ).toEqual({a: 'applied'});
  });

  test.each([['applied'], ['x'], [['applied']], [null], [3]])(
    'a non-object setup_decisions (%j) reads as absent without malforming',
    (value) => {
      const parsed = ProjectConfigSchema.parse({
        isolation_policy: 'prefer-branch',
        setup_decisions: value,
      });

      expect(parsed.setup_decisions).toBeUndefined();
      expect(parsed.isolation_policy).toBe('prefer-branch');
    }
  );

  test('the guards accept only the known literals', () => {
    expect(isIsolationPolicy('always-worktree')).toBe(true);
    expect(isIsolationPolicy('worktree')).toBe(false);
  });
});

describe('readProjectConfig', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-project-config-'));
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  const write = (text: string): void => {
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(projectConfigPath(root), text, 'utf8');
  };

  test('projectConfigPath names .gaia/project.json under the root', () => {
    expect(projectConfigPath(root)).toBe(
      path.join(root, '.gaia', 'project.json')
    );
  });

  test('reports missing when the file is absent', () => {
    expect(readProjectConfig(root)).toEqual({status: 'missing'});
  });

  test('reports ok with the unstripped raw object', () => {
    write(JSON.stringify({isolation_policy: 'prefer-worktree', other: 1}));

    expect(readProjectConfig(root)).toEqual({
      config: {isolation_policy: 'prefer-worktree', version: 1},
      raw: {isolation_policy: 'prefer-worktree', other: 1},
      status: 'ok',
    });
  });

  test('narrows an unknown isolation value to undefined while keeping it in raw', () => {
    write(JSON.stringify({isolation_policy: 'bogus'}));

    const result = readProjectConfig(root);

    expect(result.status).toBe('ok');
    expect(result).toMatchObject({
      config: {isolation_policy: undefined},
      raw: {isolation_policy: 'bogus'},
    });
  });

  test.each(['on', 'off', 'maybe'])(
    'a retired dependabot_security_updates value %j reads ok and stays in raw',
    (value) => {
      write(JSON.stringify({dependabot_security_updates: value, version: 1}));

      const result = readProjectConfig(root);

      expect(result.status).toBe('ok');
      expect(result).toMatchObject({
        config: {version: 1},
        raw: {dependabot_security_updates: value},
      });
      expect(result).not.toHaveProperty('config.dependabot_security_updates');
    }
  );

  test('reports malformed for invalid JSON, naming the file', () => {
    write('{not json');

    const result = readProjectConfig(root);

    expect(result).toMatchObject({status: 'malformed'});
    expect(JSON.stringify(result)).toContain('project.json');
  });

  test('reports malformed when the JSON is not an object', () => {
    write('[]');

    expect(readProjectConfig(root).status).toBe('malformed');
  });
});

describe('setup_decisions at the write boundary', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-project-config-decisions-'));
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  test('a value a newer binary wrote does not make another writer fail', () => {
    writeFileSync(
      projectConfigPath(root),
      JSON.stringify({setup_decisions: {x: 'future-value'}, version: 1}),
      'utf8'
    );

    updateProjectConfig(root, {isolation_policy: 'prefer-branch'});

    const written = JSON.parse(
      readFileSync(projectConfigPath(root), 'utf8')
    ) as Record<string, unknown>;

    expect(written.setup_decisions).toEqual({x: 'future-value'});
    expect(written.isolation_policy).toBe('prefer-branch');
  });

  test('a non-object setup_decisions is refused and nothing is written', () => {
    const before = JSON.stringify({version: 1});
    writeFileSync(projectConfigPath(root), before, 'utf8');

    expect(() => {
      updateProjectConfig(root, {setup_decisions: 'applied'});
    }).toThrow(ProjectConfigError);
    expect(readFileSync(projectConfigPath(root), 'utf8')).toBe(before);
  });
});
