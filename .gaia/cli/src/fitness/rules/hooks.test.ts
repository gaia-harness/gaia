/* eslint-disable no-template-curly-in-string -- these literals are shell text, not templates */
import {describe, expect, test} from 'vitest';
import {chmodSync, existsSync} from 'node:fs';
import path from 'node:path';
import {runCheck} from '../check.js';
import {createScratchProject} from '../test-support.js';
import type {FixtureProject} from '../types.js';
import {readScriptReference, splitCommandWords} from './hook-command.js';
import {hookProject, SANCTIONED_ROOT} from './hooks.fixtures.js';
import {HOOKS_RULES} from './hooks.js';

const EXAMPLE_SCRIPT = '.claude/hooks/example.sh';

type Outcome = {ids: string[]; root: string};

const findingIds = (
  project: FixtureProject,
  options: {executable?: string[]} = {}
): Outcome => {
  const scratch = createScratchProject(project);

  try {
    for (const relative of options.executable ?? []) {
      chmodSync(path.join(scratch.root, relative), 0o755);
    }

    const report = runCheck({
      catalog: HOOKS_RULES,
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

describe('hook command reading', () => {
  test.each([
    [
      'keeps a quoted command substitution as one word',
      `bash "${SANCTIONED_ROOT}/.claude/hooks/example.sh" --flag`,
      ['bash', `${SANCTIONED_ROOT}/.claude/hooks/example.sh`, '--flag'],
    ],
    [
      'stops at the first command separator',
      'jq . ; echo $(touch sentinel)',
      ['jq', '.'],
    ],
  ])('splitCommandWords %s', (_name, command, expected) => {
    expect(splitCommandWords(command)).toEqual(expected);
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
      {kind: 'anchored', remainder: EXAMPLE_SCRIPT, viaInterpreter: true},
    ],
  ])('reads %s', (command, expected) => {
    expect(readScriptReference(command)).toEqual(expected);
  });
});

describe('hooks.path-exists-executable', () => {
  const nestedHook = hookProject(`"${SANCTIONED_ROOT}/${EXAMPLE_SCRIPT}"`, {
    files: {[EXAMPLE_SCRIPT]: '#!/usr/bin/env bash\n'},
    path: 'apps/web/.claude/settings.json',
  });

  const executableRows: [string, FixtureProject, string[]][] = [
    [
      'passes an executable script behind the sanctioned prefix',
      withScript(`"${SANCTIONED_ROOT}/${EXAMPLE_SCRIPT}"`),
      [EXAMPLE_SCRIPT],
    ],
    [
      'passes an executable script behind a braced project dir',
      withScript(`\${CLAUDE_PROJECT_DIR}/${EXAMPLE_SCRIPT}`),
      [EXAMPLE_SCRIPT],
    ],
    [
      'passes an executable script behind a bare project dir',
      withScript(`"$CLAUDE_PROJECT_DIR"/${EXAMPLE_SCRIPT}`),
      [EXAMPLE_SCRIPT],
    ],
    [
      'passes an executable script behind the short toplevel form',
      withScript(`$(git rev-parse --show-toplevel)/${EXAMPLE_SCRIPT}`),
      [EXAMPLE_SCRIPT],
    ],
    [
      'passes an executable script behind an interpreter',
      withScript(`bash "${SANCTIONED_ROOT}/${EXAMPLE_SCRIPT}"`),
      [EXAMPLE_SCRIPT],
    ],
    [
      'does not stat a $HOME token whose prefix it does not recognize',
      withScript('$HOME/missing/example.sh'),
      [],
    ],
    [
      'does not stat a ${VAR} token whose prefix it does not recognize',
      withScript('${VAR}/missing/example.sh'),
      [],
    ],
    [
      'does not stat a $(other) token whose prefix it does not recognize',
      withScript('$(other)/missing/example.sh'),
      [],
    ],
    ['does not check a bare executable name', withScript('jq -r .x'), []],
    ['passes a hook in a nested settings file', nestedHook, [EXAMPLE_SCRIPT]],
    [
      'passes a non-executable script run through an interpreter',
      withScript(`bash "${SANCTIONED_ROOT}/${EXAMPLE_SCRIPT}"`),
      [],
    ],
  ];

  test.each(executableRows)('%s', (_name, project, executable) => {
    expect(findingIds(project, {executable}).ids).toEqual([]);
  });

  test.each([
    [
      'reports a missing script once',
      hookProject('"$CLAUDE_PROJECT_DIR"/.claude/hooks/missing.sh'),
    ],
    [
      'reports a script that exists without the executable bit',
      withScript(`"$CLAUDE_PROJECT_DIR"/${EXAMPLE_SCRIPT}`),
    ],
    [
      'reports a missing script run through an interpreter',
      hookProject(`bash "${SANCTIONED_ROOT}/.claude/hooks/missing.sh"`),
    ],
    [
      'reports a script that resolves outside the project',
      hookProject('"$CLAUDE_PROJECT_DIR"/../outside/example.sh'),
    ],
  ])('%s', (_name, project) => {
    expect(findingIds(project).ids).toEqual(['hooks.path-exists-executable']);
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
});

describe('hooks.rooted-command', () => {
  test.each([
    [
      'reports a dot-claude path once',
      '.claude/hooks/example.sh',
      ['hooks.rooted-command'],
    ],
    ['reports a dot-slash path once', './example.sh', ['hooks.rooted-command']],
    [
      'reports a directory path once',
      'scripts/example.sh',
      ['hooks.rooted-command'],
    ],
    [
      'reports a path behind an interpreter once',
      'bash scripts/example.sh',
      ['hooks.rooted-command'],
    ],
    ['passes an absolute path', '/opt/hooks/example.sh', []],
    ['passes a home-anchored path', '$HOME/hooks/example.sh', []],
    ['passes a braced expansion', '${VAR}/hooks/example.sh', []],
    ['passes a command substitution', '$(other)/hooks/example.sh', []],
    ['passes a bare executable', 'jq', []],
  ])('%s', (_name, command, expectedIds) => {
    expect(findingIds(withScript(command)).ids).toEqual(expectedIds);
  });
});

describe('hooks.event-name', () => {
  test.each([
    ['reports an unknown event once', 'PreToolRun', ['hooks.event-name']],
    ['passes PreToolUse', 'PreToolUse', []],
    ['passes PostToolUse', 'PostToolUse', []],
    ['passes PostToolUseFailure', 'PostToolUseFailure', []],
    ['passes SessionStart', 'SessionStart', []],
    ['passes Stop', 'Stop', []],
    ['passes UserPromptSubmit', 'UserPromptSubmit', []],
  ])('%s', (_name, event, expected) => {
    expect(findingIds(withScript('jq', event)).ids).toEqual(expected);
  });
});
