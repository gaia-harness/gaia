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

  test.each([
    {
      expected: {version: 1},
      input: {},
      name: 'an empty object parses, with version degrading to 1',
    },
    {
      expected: {version: 1},
      input: {
        isolation_policy: 'worktree-ish',
        sandbox_recommended: 'yes',
        version: 9,
      },
      name: 'invalid or wrong-typed values degrade to undefined instead of malforming',
    },
    {
      expected: {setup_decisions: {a: 'applied'}, version: 1},
      input: {setup_decisions: {a: 'applied', b: 'maybe'}},
      name: 'setup_decisions drops an unknown value and keeps the rest',
    },
    ...['applied', 'x', ['applied'], null, 3].map((value) => ({
      expected: {isolation_policy: 'prefer-branch', version: 1},
      input: {isolation_policy: 'prefer-branch', setup_decisions: value},
      name: `a non-object setup_decisions (${JSON.stringify(value)}) reads as absent without malforming`,
    })),
    ...[25, 1].map((value) => ({
      expected: {fitness_commit_threshold: value, version: 1},
      input: {fitness_commit_threshold: value},
      name: `fitness_commit_threshold ${JSON.stringify(value)} reads as itself`,
    })),
    ...[0, -3, 15.5, '25', true, null, {}].map((value) => ({
      expected: {isolation_policy: 'prefer-branch', version: 1},
      input: {
        fitness_commit_threshold: value,
        isolation_policy: 'prefer-branch',
      },
      name: `fitness_commit_threshold ${JSON.stringify(value)} reads as absent without malforming`,
    })),
    ...[true, false].map((value) => ({
      expected: {shellcheck: value, version: 1},
      input: {shellcheck: value},
      name: `${JSON.stringify(value)} reads as itself`,
    })),
    ...['false', 0, null].map((value) => ({
      expected: {isolation_policy: 'prefer-branch', version: 1},
      input: {isolation_policy: 'prefer-branch', shellcheck: value},
      name: `${JSON.stringify(value)} reads as absent without malforming`,
    })),
  ])('ProjectConfigSchema: $name', ({expected, input}) => {
    expect(ProjectConfigSchema.parse(input)).toEqual(expected);
  });

  test.each([
    {expected: true, value: 'always-worktree'},
    {expected: false, value: 'worktree'},
  ])(
    'the guards accept only the known literals: $value',
    ({expected, value}) => {
      expect(isIsolationPolicy(value)).toBe(expected);
    }
  );
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

  const writeIfPresent = (text: string | undefined): void => {
    if (text !== undefined) {
      write(text);
    }
  };

  test('projectConfigPath names .gaia/project.json under the root', () => {
    expect(projectConfigPath(root)).toBe(
      path.join(root, '.gaia', 'project.json')
    );
  });

  test.each([
    {
      content: undefined,
      expected: {status: 'missing'},
      name: 'reports missing when the file is absent',
    },
    {
      content: JSON.stringify({
        isolation_policy: 'prefer-worktree',
        other: 1,
      }),
      expected: {
        config: {isolation_policy: 'prefer-worktree', version: 1},
        raw: {isolation_policy: 'prefer-worktree', other: 1},
        status: 'ok',
      },
      name: 'reports ok with the unstripped raw object',
    },
    {
      content: JSON.stringify({isolation_policy: 'bogus'}),
      expected: {
        config: {isolation_policy: undefined, version: 1},
        raw: {isolation_policy: 'bogus'},
        status: 'ok',
      },
      name: 'narrows an unknown isolation value to undefined while keeping it in raw',
    },
    ...['on', 'off', 'maybe'].map((value) => ({
      content: JSON.stringify({dependabot_security_updates: value, version: 1}),
      expected: {
        config: {version: 1},
        raw: {dependabot_security_updates: value, version: 1},
        status: 'ok',
      },
      name: `a retired dependabot_security_updates value ${JSON.stringify(value)} reads ok and stays in raw`,
    })),
    ...[0, -3, 15.5, '25', true, null, {}].map((value) => ({
      content: JSON.stringify({
        fitness_commit_threshold: value,
        sandbox_recommended: true,
      }),
      expected: {
        config: {sandbox_recommended: true, version: 1},
        raw: {fitness_commit_threshold: value, sandbox_recommended: true},
        status: 'ok',
      },
      name: `readProjectConfig reads an invalid fitness_commit_threshold ${JSON.stringify(value)} as undefined and still ok`,
    })),
    {
      content: JSON.stringify({fitness_commit_threshold: 25}),
      expected: {
        config: {fitness_commit_threshold: 25, version: 1},
        raw: {fitness_commit_threshold: 25},
        status: 'ok',
      },
      name: 'readProjectConfig reads a valid fitness_commit_threshold',
    },
  ])('$name', ({content, expected}) => {
    writeIfPresent(content);

    expect(readProjectConfig(root)).toEqual(expected);
  });

  test.each([
    {
      name: 'reports malformed for invalid JSON, naming the file',
      text: '{not json',
    },
    {name: 'reports malformed when the JSON is not an object', text: '[]'},
  ])('$name', ({text}) => {
    write(text);

    const result = readProjectConfig(root);

    expect(result).toMatchObject({status: 'malformed'});
    expect(JSON.stringify(result)).toContain('project.json');
  });
});

describe('updateProjectConfig at the write boundary', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-project-config-decisions-'));
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  test.each([
    {
      expected: {
        isolation_policy: 'prefer-branch',
        setup_decisions: {x: 'future-value'},
        version: 1,
      },
      initial: {setup_decisions: {x: 'future-value'}, version: 1},
      name: 'a value a newer binary wrote does not make another writer fail',
      patch: {isolation_policy: 'prefer-branch'},
    },
    {
      expected: {shellcheck: false, version: 1},
      initial: {version: 1},
      name: 'the write boundary accepts a boolean',
      patch: {shellcheck: false},
    },
    {
      expected: {
        isolation_policy: 'prefer-branch',
        shellcheck: false,
        version: 1,
      },
      initial: {shellcheck: false, version: 1},
      name: 'another writer keeps the opt-out',
      patch: {isolation_policy: 'prefer-branch'},
    },
  ])('$name', ({expected, initial, patch}) => {
    writeFileSync(projectConfigPath(root), JSON.stringify(initial), 'utf8');

    updateProjectConfig(root, patch);

    expect(JSON.parse(readFileSync(projectConfigPath(root), 'utf8'))).toEqual(
      expected
    );
  });

  test.each([
    {
      name: 'a non-object setup_decisions is refused and nothing is written',
      patch: {setup_decisions: 'applied'},
    },
    {
      name: 'the write boundary refuses a shellcheck value that is not a boolean',
      patch: {shellcheck: 'off'},
    },
  ])('$name', ({patch}) => {
    const before = JSON.stringify({version: 1});
    writeFileSync(projectConfigPath(root), before, 'utf8');

    expect(() => {
      updateProjectConfig(root, patch);
    }).toThrow(ProjectConfigError);
    expect(readFileSync(projectConfigPath(root), 'utf8')).toBe(before);
  });
});
