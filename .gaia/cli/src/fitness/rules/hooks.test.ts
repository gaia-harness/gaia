/* eslint-disable no-template-curly-in-string -- these literals are shell text, not templates */
import {describe, expect, test} from 'vitest';
import {chmodSync, existsSync} from 'node:fs';
import path from 'node:path';
import {runCheck} from '../check.js';
import {
  createScratchProject,
  expectFixtureParity,
  FIXTURE_PARITY_TIMEOUT_MS,
} from '../test-support.js';
import type {FixtureProject, RuleDefinition} from '../types.js';
import {readScriptReference, splitCommandWords} from './hook-command.js';
import {
  hookProject,
  HOOKS_FIXTURES,
  SANCTIONED_ROOT,
} from './hooks.fixtures.js';
import {createHookRules, HOOKS_RULES} from './hooks.js';

const EXAMPLE_SCRIPT = '.claude/hooks/example.sh';

type Outcome = {ids: string[]; root: string};

const findingIds = (
  project: FixtureProject,
  options: {catalog?: readonly RuleDefinition[]; executable?: string[]} = {}
): Outcome => {
  const scratch = createScratchProject(project);

  try {
    for (const relative of options.executable ?? []) {
      chmodSync(path.join(scratch.root, relative), 0o755);
    }

    const report = runCheck({
      catalog: options.catalog ?? HOOKS_RULES,
      env: scratch.env,
      root: scratch.root,
      scope: 'all',
    });

    return {
      ids: report.findings
        .filter((finding) => finding.category === 'hooks')
        .map((finding) => finding.rule_id),
      root: scratch.root,
    };
  } finally {
    scratch.cleanup();
  }
};

const withScript = (command: string, event = 'PreToolUse') =>
  hookProject(command, {
    event,
    files: {[EXAMPLE_SCRIPT]: '#!/usr/bin/env bash\nexit 0\n'},
  });

describe('hook rules fixtures', () => {
  test(
    'fires on every red fixture and stays quiet on every green one',
    () => {
      expectFixtureParity(HOOKS_RULES, HOOKS_FIXTURES);
    },
    FIXTURE_PARITY_TIMEOUT_MS
  );
});

describe('hook command reading', () => {
  test('keeps a quoted command substitution as one word', () => {
    const words = splitCommandWords(
      `bash "${SANCTIONED_ROOT}/.claude/hooks/example.sh" --flag`
    );

    expect(words).toEqual([
      'bash',
      `${SANCTIONED_ROOT}/.claude/hooks/example.sh`,
      '--flag',
    ]);
  });

  test('stops at the first command separator', () => {
    expect(splitCommandWords('jq . ; echo $(touch sentinel)')).toEqual([
      'jq',
      '.',
    ]);
  });

  test.each([
    ['/opt/hooks/example.sh', {kind: 'anchored-unrecognized'}],
    ['$HOME/hooks/example.sh', {kind: 'anchored-unrecognized'}],
    ['${VAR}/hooks/example.sh', {kind: 'anchored-unrecognized'}],
    ['$(other)/hooks/example.sh', {kind: 'anchored-unrecognized'}],
    ['jq -r .x', {kind: 'none'}],
    ['hook.sh', {kind: 'none'}],
    ['node -e "console.log(1/2)"', {kind: 'none'}],
    [
      '.claude/hooks/example.sh',
      {kind: 'relative', token: '.claude/hooks/example.sh'},
    ],
    ['./example.sh', {kind: 'relative', token: './example.sh'}],
    ['scripts/example.sh', {kind: 'relative', token: 'scripts/example.sh'}],
    [
      'bash scripts/example.sh',
      {kind: 'relative', token: 'scripts/example.sh'},
    ],
    [
      '"$CLAUDE_PROJECT_DIR"/.claude/hooks/example.sh',
      {kind: 'anchored', remainder: EXAMPLE_SCRIPT},
    ],
    [
      '${CLAUDE_PROJECT_DIR}/.claude/hooks/example.sh',
      {kind: 'anchored', remainder: EXAMPLE_SCRIPT},
    ],
    [
      '$(git rev-parse --show-toplevel)/.claude/hooks/example.sh',
      {kind: 'anchored', remainder: EXAMPLE_SCRIPT},
    ],
    [
      `bash "${SANCTIONED_ROOT}/.claude/hooks/example.sh"`,
      {kind: 'anchored', remainder: EXAMPLE_SCRIPT},
    ],
  ])('reads %s', (command, expected) => {
    expect(readScriptReference(command)).toEqual(expected);
  });
});

describe('hooks.path-exists-executable', () => {
  test.each([
    ['the sanctioned prefix', `"${SANCTIONED_ROOT}/${EXAMPLE_SCRIPT}"`],
    ['a braced project dir', `\${CLAUDE_PROJECT_DIR}/${EXAMPLE_SCRIPT}`],
    ['a bare project dir', `"$CLAUDE_PROJECT_DIR"/${EXAMPLE_SCRIPT}`],
    [
      'the short toplevel form',
      `$(git rev-parse --show-toplevel)/${EXAMPLE_SCRIPT}`,
    ],
    ['an interpreter', `bash "${SANCTIONED_ROOT}/${EXAMPLE_SCRIPT}"`],
  ])('passes an executable script behind %s', (_label, command) => {
    expect(
      findingIds(withScript(command), {executable: [EXAMPLE_SCRIPT]}).ids
    ).toEqual([]);
  });

  test('does not stat a token whose prefix it does not recognize', () => {
    expect(findingIds(withScript('$HOME/missing/example.sh')).ids).toEqual([]);
    expect(findingIds(withScript('${VAR}/missing/example.sh')).ids).toEqual([]);
    expect(findingIds(withScript('$(other)/missing/example.sh')).ids).toEqual(
      []
    );
  });

  test('does not check a bare executable name', () => {
    expect(findingIds(withScript('jq -r .x')).ids).toEqual([]);
  });

  test('passes a hook in a nested settings file', () => {
    const project = hookProject(`"${SANCTIONED_ROOT}/${EXAMPLE_SCRIPT}"`, {
      files: {[EXAMPLE_SCRIPT]: '#!/usr/bin/env bash\n'},
      path: 'frontend/.claude/settings.json',
    });

    expect(findingIds(project, {executable: [EXAMPLE_SCRIPT]}).ids).toEqual([]);
  });

  test('reports a missing script once', () => {
    expect(
      findingIds(hookProject('"$CLAUDE_PROJECT_DIR"/.claude/hooks/missing.sh'))
        .ids
    ).toEqual(['hooks.path-exists-executable']);
  });

  test('reports a script that exists without the executable bit', () => {
    expect(
      findingIds(withScript(`"$CLAUDE_PROJECT_DIR"/${EXAMPLE_SCRIPT}`)).ids
    ).toEqual(['hooks.path-exists-executable']);
  });

  test('reports a script that resolves outside the project', () => {
    expect(
      findingIds(hookProject('"$CLAUDE_PROJECT_DIR"/../outside/example.sh')).ids
    ).toEqual(['hooks.path-exists-executable']);
  });

  test('never runs a substitution inside the command', () => {
    const project = hookProject(
      '"$CLAUDE_PROJECT_DIR"/.claude/hooks/missing.sh $(touch sentinel)'
    );
    const outcome = findingIds(project);

    expect(outcome.ids).toEqual(['hooks.path-exists-executable']);
    expect(existsSync(path.join(outcome.root, 'sentinel'))).toBe(false);
    expect(existsSync(path.join(process.cwd(), 'sentinel'))).toBe(false);
  });

  test('goes undetected when the check is replaced by an always-pass stand-in', () => {
    const alwaysPass = createHookRules({findScriptProblem: () => undefined});

    expect(
      findingIds(
        hookProject('"$CLAUDE_PROJECT_DIR"/.claude/hooks/missing.sh'),
        {
          catalog: alwaysPass,
        }
      ).ids
    ).toEqual([]);
  });
});

describe('hooks.rooted-command', () => {
  test.each([
    ['a dot-claude path', '.claude/hooks/example.sh'],
    ['a dot-slash path', './example.sh'],
    ['a directory path', 'scripts/example.sh'],
    ['a path behind an interpreter', 'bash scripts/example.sh'],
  ])('reports %s once', (_label, command) => {
    expect(findingIds(withScript(command)).ids).toEqual([
      'hooks.rooted-command',
    ]);
  });

  test.each([
    ['an absolute path', '/opt/hooks/example.sh'],
    ['a home-anchored path', '$HOME/hooks/example.sh'],
    ['a braced expansion', '${VAR}/hooks/example.sh'],
    ['a command substitution', '$(other)/hooks/example.sh'],
    ['a bare executable', 'jq'],
  ])('passes %s', (_label, command) => {
    expect(findingIds(withScript(command)).ids).toEqual([]);
  });

  test('goes undetected when the check is replaced by an always-pass stand-in', () => {
    const alwaysPass = createHookRules({isUnanchored: () => false});

    expect(
      findingIds(withScript('scripts/example.sh'), {catalog: alwaysPass}).ids
    ).toEqual([]);
  });
});

describe('hooks.event-name', () => {
  test('reports an unknown event once', () => {
    expect(findingIds(withScript('jq', 'PreToolRun')).ids).toEqual([
      'hooks.event-name',
    ]);
  });

  test('passes the events a repository registers', () => {
    for (const event of [
      'PreToolUse',
      'PostToolUse',
      'PostToolUseFailure',
      'SessionStart',
      'Stop',
      'UserPromptSubmit',
    ]) {
      expect(findingIds(withScript('jq', event)).ids).toEqual([]);
    }
  });
});
