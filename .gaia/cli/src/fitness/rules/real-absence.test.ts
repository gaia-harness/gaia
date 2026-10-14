import {describe, expect, test} from 'vitest';
import {registerScratchProjects} from '../check-support.js';
import {runCheck} from '../check.js';
import type {Finding, FixtureProject} from '../types.js';

const createProject = registerScratchProjects();

const findingsOf = (project: FixtureProject, ruleId: string): Finding[] => {
  const scratch = createProject(project);

  return runCheck({
    env: scratch.env,
    root: scratch.root,
    scope: 'all',
  }).findings.filter((finding) => finding.rule_id === ruleId);
};

const rule = (
  body: string,
  extra: Record<string, string> = {}
): FixtureProject => ({
  files: {
    '.claude/rules/example.md': body,
    '.gaia/other.json': '{}\n',
    'CLAUDE.md': 'Root.\n',
    'wiki/index.md': '# Wiki\n',
    ...extra,
  },
  git: true,
});

const command = (body: string): FixtureProject => ({
  files: {
    '.claude/commands/example.md': body,
    '.gaia/other.json': '{}\n',
    'CLAUDE.md': 'Root.\n',
  },
  git: true,
});

describe('a path GAIA tooling creates on first use', () => {
  test('is not dead in a rule before the tooling has written it', () => {
    expect(
      findingsOf(
        rule(
          'Reports go to `wiki/meta/`; init resumes from `.gaia/init-state.json`.\n'
        ),
        'rules.dead-path'
      )
    ).toEqual([]);
  });

  test('is not a broken link in a command before the tooling has written it', () => {
    expect(
      findingsOf(
        command('Resume reads `.gaia/init-state.json`.\n'),
        'authoring.reference.link.resolves'
      )
    ).toEqual([]);
  });

  test('does not cover a sibling path that only shares its prefix', () => {
    expect(
      findingsOf(
        rule('See `wiki/metadata/` and `.gaia/init-state.json.bak`.\n'),
        'rules.dead-path'
      )
    ).toHaveLength(2);
  });

  test('does not cover a misspelling of it', () => {
    expect(
      findingsOf(
        rule('Resume reads `.gaia/init_state.json`.\n'),
        'rules.dead-path'
      )
    ).toHaveLength(1);
    expect(
      findingsOf(
        command('Resume reads `.gaia/init_state.json`.\n'),
        'authoring.reference.link.resolves'
      )
    ).toHaveLength(1);
  });

  test('does not cover a named file under the folder it creates', () => {
    expect(
      findingsOf(
        rule('The last report is `wiki/meta/lint-report.md`.\n'),
        'rules.dead-path'
      )
    ).toHaveLength(1);
  });
});

describe('a missing folder a directory-only ignore pattern covers', () => {
  test('is a runtime artifact, not a dead path', () => {
    expect(
      findingsOf(
        rule('Traces land in `build/output/`.\n', {
          '.gitignore': '**/output/\n',
          'build/other.txt': 'x\n',
        }),
        'rules.dead-path'
      )
    ).toEqual([]);
  });

  test('is dead when nothing ignores it', () => {
    expect(
      findingsOf(
        rule('Traces land in `build/output/`.\n', {'build/other.txt': 'x\n'}),
        'rules.dead-path'
      )
    ).toHaveLength(1);
  });
});

describe('a concrete instance of a placeholder template the file declares', () => {
  const pages = {'pages/home/page.tsx': 'export {};\n'};

  test('is an example, not a dead path', () => {
    expect(
      findingsOf(
        rule(
          'Pages live at `pages/<route path>/page.tsx`: `about.tsx` becomes `pages/about/page.tsx` and `account._index.tsx` becomes `pages/account/index/page.tsx`.\n',
          pages
        ),
        'rules.dead-path'
      )
    ).toEqual([]);
  });

  test('is dead when the file declares no template it fits', () => {
    expect(
      findingsOf(
        rule(
          'Pages live at `pages/<route path>/index.tsx`; see `pages/about/page.tsx`.\n',
          pages
        ),
        'rules.dead-path'
      )
    ).toHaveLength(1);
  });

  test('is dead when it only resembles the template', () => {
    expect(
      findingsOf(
        rule(
          'Pages live at `pages/<route path>/page.tsx`; see `pages/page.tsx` and `pages/about/page.ts`.\n',
          pages
        ),
        'rules.dead-path'
      )
    ).toHaveLength(2);
  });

  test('is dead when the template ends in a placeholder, which fits every path in its folder', () => {
    expect(
      findingsOf(
        rule(
          'Shared components are `pages/<name>/`, and reports are `pages/<name>.md`; see `pages/about/page.tsx` and `pages/gone.md`.\n',
          pages
        ),
        'rules.dead-path'
      )
    ).toHaveLength(2);
  });

  test('is dead when the template starts with a placeholder, which fits any folder', () => {
    expect(
      findingsOf(
        rule('Write `<folder>/page.tsx`; see `pages/about/page.tsx`.\n', pages),
        'rules.dead-path'
      )
    ).toHaveLength(1);
  });

  test('is still dead as a markdown link', () => {
    expect(
      findingsOf(
        rule(
          'Pages live at `pages/<route path>/page.tsx`; read [about](pages/about/page.tsx).\n',
          pages
        ),
        'rules.dead-path'
      )
    ).toHaveLength(1);
  });

  test('is an example in a command too, and its look-alike is still a broken link', () => {
    expect(
      findingsOf(
        command(
          'Reports live at `.gaia/reports/<date>/summary.md`, such as `.gaia/reports/2026-01-01/summary.md`.\n'
        ),
        'authoring.reference.link.resolves'
      )
    ).toEqual([]);
    expect(
      findingsOf(
        command(
          'Reports live at `.gaia/reports/<date>/summary.md`; see `.gaia/report/2026-01-01/summary.md`.\n'
        ),
        'authoring.reference.link.resolves'
      )
    ).toHaveLength(1);
  });
});
