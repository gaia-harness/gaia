import {afterEach, describe, expect, test} from 'vitest';
import {rmSync} from 'node:fs';
import {
  git,
  makeLegacyRepo,
  read,
  ROSTER,
  write,
} from './__tests__/crossing-fixture.js';
import {runRoster} from './crossing-roster.js';

const roots: string[] = [];

const withRegistry = (registry: string): string => {
  const root = makeLegacyRepo();

  roots.push(root);
  write(root, '.gaia/packages.json', registry);
  git(root, ['add', '-A']);

  return root;
};

const WEB_AND_CLI =
  '[{"name":"web","path":"apps/web"},{"name":"cli","path":".gaia/cli"}]\n';

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, {force: true, recursive: true});
  }
});

const EXPECTED = `# roster header comment
auditors:
  - name: code-audit-frontend
    globs:
      - "apps/web/app/**"
      # a comment inside the list
      - "package.json"
      - 'apps/web/package.json'
      - ".gaia/cli/**"
    light_hard_full:
      - "apps/web/package.json"
    audience: adopter
    default: true
  - name: code-audit-shell
    globs:
      - "**/*.sh"
    audience: adopter
unowned:
  - "*.md"
  - "apps/web/public/**"
`;

describe('runRoster', () => {
  test('rewrites old-root entries, drops member-owned unowned entries and claims outside members', () => {
    const root = withRegistry(WEB_AND_CLI);
    const outcome = runRoster(root);

    expect(outcome.exit).toBe(0);
    expect(read(root, '.gaia/audit-ci.yml')).toBe(EXPECTED);
    expect(outcome.lines).toContain('REPORT\troster-drop\tapps/legacy/docs/**');
    expect(outcome.lines).toContain('REPORT\troster-drop\tpackages/shared/**');
    expect(outcome.lines).toContain('REPORT\troster-claim\t.gaia/cli/**');
    expect(
      outcome.lines.filter((line) => line.startsWith('REPORT\troster-rewrite'))
    ).toHaveLength(4);
  });

  test('a second run changes nothing and reports nothing', () => {
    const root = withRegistry(WEB_AND_CLI);

    runRoster(root);
    const outcome = runRoster(root);

    expect(outcome).toEqual({exit: 0, lines: []});
    expect(read(root, '.gaia/audit-ci.yml')).toBe(EXPECTED);
  });

  test('a registry with only the app adds no claim', () => {
    const root = withRegistry('[{"name":"web","path":"apps/web"}]\n');

    runRoster(root);

    expect(read(root, '.gaia/audit-ci.yml')).not.toContain('.gaia/cli');
  });

  test('a member under packages is not claimed by the default member', () => {
    const root = withRegistry(
      '[{"name":"web","path":"apps/web"},{"name":"lib","path":"packages/lib"}]\n'
    );

    runRoster(root);

    expect(read(root, '.gaia/audit-ci.yml')).not.toContain('packages/lib');
  });

  test('an absent roster file is left absent', () => {
    const root = withRegistry(WEB_AND_CLI);

    rmSync(`${root}/.gaia/audit-ci.yml`);

    expect(runRoster(root)).toEqual({exit: 0, lines: []});
  });

  test('a roster without a default member stops', () => {
    const root = withRegistry(WEB_AND_CLI);

    write(
      root,
      '.gaia/audit-ci.yml',
      ROSTER.replace('    default: true\n', '')
    );
    const outcome = runRoster(root);

    expect(outcome.exit).toBe(3);
    expect(outcome.lines[0]).toBe('CROSSING_STOP roster-no-default');
  });
});
