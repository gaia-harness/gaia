import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {run as bootstrapEnvironment} from '../setup/bootstrap-env.js';
import {computeUpdates} from '../update-deps/run.js';
import type {PnpmRunner} from '../update-deps/run.js';
import {execGaiaGit} from '../util/git-env.js';
import {writeMemberRegistry} from '../util/package-fixture.js';
import type {FixtureMember} from '../util/package-fixture.js';
import {run as renameProject} from './rename.js';
import {run as stripBranding} from './strip-branding.js';

const STOREFRONT: FixtureMember = {name: 'storefront', path: 'apps/storefront'};
const ADMIN: FixtureMember = {name: 'admin', path: 'apps/admin'};
const LIBRARY: FixtureMember = {name: 'lib', path: 'packages/lib', web: false};

const noOutdated: PnpmRunner = () => ({status: 0, stderr: '', stdout: '{}'});

describe('commands acting on the web member, by stack', () => {
  let root: string;
  let errors: string[];

  const listing = (): string[] =>
    readdirSync(root, {recursive: true})
      .map(String)
      .filter((entry) => !entry.startsWith('.git'))
      .toSorted((left, right) => left.localeCompare(right));

  const register = (members: readonly FixtureMember[]): void => {
    writeMemberRegistry(root, members);
    writeFileSync(
      path.join(root, 'package.json'),
      JSON.stringify({dependencies: {}, name: 'workspace'})
    );
    mkdirSync(path.join(root, '.gaia/templates'), {recursive: true});
    writeFileSync(
      path.join(root, '.gaia/templates/README.md'),
      '# {{PROJECT_TITLE}}\n'
    );

    for (const member of members) {
      mkdirSync(path.join(root, member.path, '.storybook'), {recursive: true});
      writeFileSync(
        path.join(root, member.path, 'package.json'),
        JSON.stringify({dependencies: {}, name: member.name})
      );
    }
  };

  beforeEach(() => {
    root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-web-commands-')));
    execGaiaGit(['init', '-q', '-b', 'main'], root);
    errors = [];
    vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
      errors.push(String(chunk));

      return true;
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(root, {force: true, recursive: true});
  });

  test('strip-branding finds a web member named storefront', () => {
    register([LIBRARY, STOREFRONT]);

    expect(stripBranding(['--title', 'Shop'], {cwd: root})).toBe(EXIT_CODES.OK);
  });

  test('strip-branding refuses two web members, naming both', () => {
    register([STOREFRONT, ADMIN]);

    expect(stripBranding(['--title', 'Shop'], {cwd: root})).toBe(
      EXIT_CODES.CONFIG_INVALID
    );
    expect(errors.join('')).toContain('storefront');
    expect(errors.join('')).toContain('admin');
  });

  test('the dependency compute finds a web member named storefront', () => {
    register([LIBRARY, STOREFRONT]);

    expect(() =>
      computeUpdates({cwd: root, pnpmRunner: noOutdated})
    ).not.toThrow();
  });

  test('the dependency compute refuses two web members, naming both', () => {
    register([STOREFRONT, ADMIN]);

    expect(() => computeUpdates({cwd: root, pnpmRunner: noOutdated})).toThrow(
      /storefront.*admin/u
    );
  });

  test('the environment seed copies into the storefront member only', () => {
    register([LIBRARY, STOREFRONT]);
    writeFileSync(path.join(root, 'apps/storefront/.env.example'), 'A=1\n');

    expect(bootstrapEnvironment([], {cwd: root})).toBe(EXIT_CODES.OK);
    expect(readFileSync(path.join(root, 'apps/storefront/.env'), 'utf8')).toBe(
      'A=1\n'
    );
    expect(existsSync(path.join(root, 'packages/lib/.env'))).toBe(false);
  });

  test('the environment seed refuses two web members, naming both', () => {
    register([STOREFRONT, ADMIN]);

    expect(bootstrapEnvironment([], {cwd: root})).toBe(
      EXIT_CODES.CONFIG_INVALID
    );
    expect(errors.join('')).toContain('admin');
  });

  test('rename with --package naming a non-web member refuses and changes no file', () => {
    register([LIBRARY, STOREFRONT]);
    const before = listing();

    expect(
      renameProject(
        ['--title', 'Shop', '--kebab', 'shop', '--package', 'lib'],
        {cwd: root}
      )
    ).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(errors.join('')).toContain('storefront');
    expect(listing()).toEqual(before);
  });

  test('rename refuses two web members with no flag and changes no file', () => {
    register([STOREFRONT, ADMIN]);
    const before = listing();

    expect(
      renameProject(['--title', 'Shop', '--kebab', 'shop'], {cwd: root})
    ).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(errors.join('')).toContain('admin');
    expect(listing()).toEqual(before);
  });
});
