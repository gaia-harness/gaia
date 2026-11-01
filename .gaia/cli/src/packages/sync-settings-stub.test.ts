/**
 * Strategy: a member that is neither web-stack nor opted in gets a one-hook
 * warning stub instead of the full generated file. The stub shape is asserted
 * on the pure generator and by running its hook command; the run wrapper is
 * driven over a temp tree for who gets which file, restoring a deleted or
 * edited stub, leaving a hand-written file byte-unchanged, and keeping a
 * missing or edited stub out of the --check exit status.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {committedFrontendDescriptor} from '../util/package-fixture.js';
import {
  generateStubSettings,
  serializeSettings,
  STUB_MARKER,
} from './settings-transform.js';
import {run} from './sync-settings.js';

const ROOT_SETTINGS = {
  hooks: {PreToolUse: []},
  permissions: {deny: ['Edit(.env)']},
};
const HAND_WRITTEN = '{"permissions":{"allow":["Bash(ls)"]}}\n';

const writeMember = (
  root: string,
  name: string,
  memberPath: string,
  extra: Record<string, unknown>
): void => {
  const base: Record<string, unknown> = {...committedFrontendDescriptor()};

  delete base.stack;
  mkdirSync(path.join(root, memberPath), {recursive: true});
  writeFileSync(
    path.join(root, memberPath, 'gaia.package.json'),
    JSON.stringify({...base, ...extra, name})
  );
};

const stdoutText = () =>
  vi
    .mocked(process.stdout.write)
    .mock.calls.map(([chunk]) => String(chunk))
    .join('');

describe('generateStubSettings', () => {
  test('holds one SessionStart handler carrying the marker', () => {
    const stub = generateStubSettings() as Record<string, any>;

    expect(Object.keys(stub)).toEqual(['hooks']);
    expect(Object.keys(stub.hooks)).toEqual(['SessionStart']);
    expect(stub.hooks.SessionStart).toHaveLength(1);
    expect(stub.hooks.SessionStart[0].matcher).toBe('startup|resume');
    expect(stub.hooks.SessionStart[0].hooks).toHaveLength(1);
    expect(stub.hooks.SessionStart[0].hooks[0].type).toBe('command');
    expect(stub.hooks.SessionStart[0].hooks[0].command).toContain(STUB_MARKER);
  });

  test('its command runs alone and prints the warning for the user and the session', () => {
    const stub = generateStubSettings() as Record<string, any>;
    const command = stub.hooks.SessionStart[0].hooks[0].command as string;
    const printed = JSON.parse(
      execFileSync('/bin/sh', ['-c', command], {
        encoding: 'utf8',
        env: {PATH: ''},
      })
    ) as Record<string, any>;
    const warning =
      'GAIA guards are off in this session. Launch from the repo root.';

    expect(printed.systemMessage).toBe(warning);
    expect(printed.hookSpecificOutput.additionalContext).toBe(warning);
  });
});

describe('run with non-web members', () => {
  let root: string;
  const file = (memberPath: string) =>
    path.join(root, memberPath, '.claude/settings.json');

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'sync-settings-stub-'));
    mkdirSync(path.join(root, '.claude'), {recursive: true});
    writeFileSync(
      path.join(root, '.claude/settings.json'),
      JSON.stringify(ROOT_SETTINGS)
    );
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(
      path.join(root, '.gaia/packages.json'),
      JSON.stringify([
        {name: 'web', path: 'apps/web'},
        {name: 'optin', path: 'libs/optin'},
        {name: 'api', path: 'apps/api'},
        {name: 'tool', path: 'tools/tool'},
      ])
    );
    writeMember(root, 'web', 'apps/web', {stack: 'web'});
    writeMember(root, 'optin', 'libs/optin', {generatedSettings: true});
    writeMember(root, 'api', 'apps/api', {});
    writeMember(root, 'tool', 'tools/tool', {});
    mkdirSync(path.join(root, 'tools/tool/.claude'), {recursive: true});
    writeFileSync(file('tools/tool'), HAND_WRITTEN);
    vi.spyOn(process.stderr, 'write').mockReturnValue(true);
    vi.spyOn(process.stdout, 'write').mockReturnValue(true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(root, {force: true, recursive: true});
  });

  test('writes full settings for web and opted-in members and a stub for the rest', () => {
    expect(run(['--repo-root', root])).toBe(0);

    expect(readFileSync(file('apps/api'), 'utf8')).toBe(
      serializeSettings(generateStubSettings())
    );
    expect(readFileSync(file('tools/tool'), 'utf8')).toBe(HAND_WRITTEN);
    const webSettings = JSON.parse(
      readFileSync(file('apps/web'), 'utf8')
    ) as Record<string, any>;
    const optInSettings = JSON.parse(
      readFileSync(file('libs/optin'), 'utf8')
    ) as Record<string, any>;

    expect(webSettings.permissions.deny).toContain('Edit(../../.env)');
    expect(webSettings.permissions.additionalDirectories).toContain('../..');
    expect(optInSettings.permissions.deny).toContain('Edit(../../.env)');
    expect(optInSettings.permissions.additionalDirectories).toContain('../..');
  });

  test('--check passes with a missing or edited stub and names it on stdout', () => {
    run(['--repo-root', root]);
    rmSync(file('apps/api'));

    expect(run(['--check', '--repo-root', root])).toBe(0);
    expect(stdoutText()).toContain(
      'stub-stale\tapi\tapps/api/.claude/settings.json'
    );

    writeFileSync(file('apps/api'), `${STUB_MARKER} edited\n`);
    vi.mocked(process.stdout.write).mockClear();

    expect(run(['--check', '--repo-root', root])).toBe(0);
    expect(stdoutText()).toContain('stub-stale\tapi\t');
  });

  test('--check is silent about a current stub and a hand-written file', () => {
    run(['--repo-root', root]);
    vi.mocked(process.stdout.write).mockClear();

    expect(run(['--check', '--repo-root', root])).toBe(0);
    expect(stdoutText()).not.toContain('stub-stale');
  });

  test('a stale full file on an opted-in member is drift', () => {
    run(['--repo-root', root]);
    writeFileSync(file('libs/optin'), '{}\n');

    expect(run(['--check', '--repo-root', root])).toBe(1);
  });

  test('sync restores a deleted or edited stub and leaves the hand-written file alone', () => {
    run(['--repo-root', root]);
    const expected = serializeSettings(generateStubSettings());

    rmSync(file('apps/api'));
    run(['--repo-root', root]);
    expect(readFileSync(file('apps/api'), 'utf8')).toBe(expected);

    writeFileSync(file('apps/api'), expected.replace('startup', 'other'));
    run(['--repo-root', root]);
    expect(readFileSync(file('apps/api'), 'utf8')).toBe(expected);
    expect(readFileSync(file('tools/tool'), 'utf8')).toBe(HAND_WRITTEN);
  });

  test('a stub-free member file with the marker removed becomes hand-written', () => {
    run(['--repo-root', root]);
    writeFileSync(file('apps/api'), HAND_WRITTEN);
    run(['--repo-root', root]);

    expect(readFileSync(file('apps/api'), 'utf8')).toBe(HAND_WRITTEN);
  });
});
