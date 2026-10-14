import {describe, expect, test} from 'vitest';
import {runCheck} from '../check.js';
import {
  createScratchProject,
  expectFixtureParity,
  FIXTURE_PARITY_TIMEOUT_MS,
} from '../test-support.js';
import type {Finding} from '../types.js';
import {documentOf, FRONTMATTER_FIXTURES} from './frontmatter.fixtures.js';
import {FRONTMATTER_RULES} from './frontmatter.js';

const findingsFor = (files: Record<string, string>): readonly Finding[] => {
  const scratch = createScratchProject({files, git: true});

  try {
    return runCheck({
      catalog: FRONTMATTER_RULES,
      env: scratch.env,
      root: scratch.root,
      scope: 'all',
    }).findings;
  } finally {
    scratch.cleanup();
  }
};

const skillFindings = (...lines: readonly string[]): readonly Finding[] =>
  findingsFor({'.claude/skills/example/SKILL.md': documentOf(...lines)});

const idsOf = (findings: readonly Finding[]): readonly string[] =>
  findings.map((finding) => finding.rule_id);

const PLAIN = 'description: Does an example thing.';

describe('frontmatter rules', () => {
  test(
    'has a red and a green fixture for every rule',
    () => {
      expectFixtureParity(FRONTMATTER_RULES, FRONTMATTER_FIXTURES);
    },
    FIXTURE_PARITY_TIMEOUT_MS
  );

  test('flags a description of 1025 characters at warning and passes 1024', () => {
    const over = skillFindings(
      'name: example',
      `description: ${'a'.repeat(1025)}`
    );

    expect(over).toHaveLength(1);
    expect(over[0]).toMatchObject({
      rule_id: 'frontmatter.skill.description.max-length',
      severity: 'warning',
    });
    expect(
      skillFindings('name: example', `description: ${'a'.repeat(1024)}`)
    ).toEqual([]);
  });

  test('counts code points, so 1024 emoji pass and 1025 fail', () => {
    expect(
      skillFindings('name: example', `description: ${'😀'.repeat(1024)}`)
    ).toEqual([]);
    expect(
      idsOf(skillFindings('name: example', `description: ${'😀'.repeat(1025)}`))
    ).toEqual(['frontmatter.skill.description.max-length']);
  });

  test('flags an XML tag in a skill description and in a command description', () => {
    const skill = skillFindings(
      'name: example',
      'description: Wraps <example>text</example> here.'
    );
    const command = findingsFor({
      '.claude/commands/example.md': documentOf(
        'description: Wraps <example>text</example> here.'
      ),
    });

    expect(idsOf(skill)).toEqual(['frontmatter.skill.description.xml-tag']);
    expect(idsOf(command)).toEqual(['frontmatter.skill.description.xml-tag']);
    expect(skill[0]?.severity).toBe('warning');
  });

  test('passes a tag inside backticks', () => {
    expect(
      skillFindings('name: example', 'description: Wraps `<tag>` in code.')
    ).toEqual([]);
  });

  test('flags a reserved word, then an over-long name', () => {
    const reserved = skillFindings('name: claude-tdd', PLAIN);
    const tooLong = skillFindings(`name: ${'a'.repeat(65)}`, PLAIN);

    expect(idsOf(reserved)).toEqual(['frontmatter.skill.name.reserved-word']);
    expect(idsOf(tooLong)).toEqual(['frontmatter.skill.name.max-length']);
    expect(reserved[0]?.severity).toBe('warning');
    expect(tooLong[0]?.severity).toBe('warning');
  });

  test('flags a name outside the lowercase hyphen charset', () => {
    expect(idsOf(skillFindings('name: -bad--name', PLAIN))).toEqual([
      'frontmatter.skill.name.charset',
    ]);
  });

  test('flags an empty description and a missing description', () => {
    const empty = skillFindings('name: example', 'description: ');
    const missing = skillFindings('name: example');

    expect(idsOf(empty)).toEqual(['frontmatter.skill.description.non-empty']);
    expect(idsOf(missing)).toEqual(['frontmatter.skill.description.non-empty']);
    expect(empty[0]?.severity).toBe('warning');
  });

  test('flags an unquoted ": " and passes the quoted form', () => {
    const unquoted = skillFindings('name: example', 'description: Note: here');

    expect(idsOf(unquoted)).toEqual(['frontmatter.yaml-hazard']);
    expect(unquoted[0]).toMatchObject({line: 3, severity: 'warning'});
    expect(skillFindings('name: example', 'description: "Note: here"')).toEqual(
      []
    );
  });

  test('flags an unquoted " #" and a leading backtick', () => {
    expect(
      idsOf(skillFindings('name: example', 'description: Fix a #1 bug'))
    ).toEqual(['frontmatter.yaml-hazard']);
    expect(
      idsOf(skillFindings('name: example', 'description: `code` first'))
    ).toEqual(['frontmatter.yaml-hazard']);
  });

  test('does not report frontmatter.parse on a file the hazard rule already flagged', () => {
    const hazardAndBrokenYaml = findingsFor({
      '.claude/commands/example.md':
        '---\ndescription: Note: here: there\nbad: [unclosed\n---\n',
    });

    expect(idsOf(hazardAndBrokenYaml)).toContain('frontmatter.yaml-hazard');
    expect(idsOf(hazardAndBrokenYaml)).not.toContain('frontmatter.parse');
  });

  test('reports frontmatter.parse at line 1 for a missing or unclosed block', () => {
    const missing = findingsFor({'.claude/commands/example.md': '# Body\n'});
    const unclosed = findingsFor({
      '.claude/commands/example.md': '---\ndescription: ok\n',
    });

    expect(missing).toHaveLength(1);
    expect(missing[0]).toMatchObject({line: 1, rule_id: 'frontmatter.parse'});
    expect(idsOf(unclosed)).toEqual(['frontmatter.parse']);
  });

  test('flags a description plus when_to_use over the listing cap', () => {
    const findings = skillFindings(
      'name: example',
      `description: ${'a'.repeat(1000)}`,
      `when_to_use: ${'b'.repeat(600)}`
    );

    expect(idsOf(findings)).toEqual([
      'frontmatter.skill.description.listing-truncation',
    ]);
  });

  test('flags a name collision once per file, and derives names from paths', () => {
    const declared = findingsFor({
      '.claude/skills/one/SKILL.md': documentOf('name: shared', PLAIN),
      '.claude/skills/two/SKILL.md': documentOf('name: shared', PLAIN),
    });
    const derived = findingsFor({
      '.claude/commands/foo/bar.md': documentOf(PLAIN),
      '.claude/skills/foo:bar/SKILL.md': documentOf(PLAIN),
    });
    const distinct = findingsFor({
      '.claude/commands/bar.md': documentOf(PLAIN),
      '.claude/commands/foo/bar.md': documentOf(PLAIN),
    });

    expect(declared.map((finding) => finding.file)).toEqual([
      '.claude/skills/one/SKILL.md',
      '.claude/skills/two/SKILL.md',
    ]);
    expect(declared[0]).toMatchObject({line: 2});
    expect(
      idsOf(derived).filter((id) => id === 'frontmatter.name-collision')
    ).toEqual(['frontmatter.name-collision', 'frontmatter.name-collision']);
    expect(derived[0]).toMatchObject({line: 1});
    expect(idsOf(distinct)).toEqual([]);
  });

  test('does not require a name on a command', () => {
    expect(
      findingsFor({'.claude/commands/example.md': documentOf(PLAIN)})
    ).toEqual([]);
  });
});
