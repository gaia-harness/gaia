import {describe, expect, test} from 'vitest';
import {runCheck} from '../check.js';
import {createScratchProject} from '../test-support.js';
import type {Finding} from '../types.js';
import {documentOf} from './frontmatter.fixtures.js';
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
const MAX_LENGTH = 'frontmatter.skill.description.max-length';
const HAZARD = 'frontmatter.yaml-hazard';

describe('frontmatter rules', () => {
  test.each([
    [
      'flags a description of 1025 characters',
      [`description: ${'a'.repeat(1025)}`],
      [MAX_LENGTH],
    ],
    [
      'passes a description of 1024 characters',
      [`description: ${'a'.repeat(1024)}`],
      [],
    ],
    [
      'counts code points, so 1024 emoji pass',
      [`description: ${'😀'.repeat(1024)}`],
      [],
    ],
    [
      'counts code points, so 1025 emoji fail',
      [`description: ${'😀'.repeat(1025)}`],
      [MAX_LENGTH],
    ],
    [
      'flags a description plus when_to_use over the listing cap',
      [`description: ${'a'.repeat(1000)}`, `when_to_use: ${'b'.repeat(600)}`],
      ['frontmatter.skill.description.listing-truncation'],
    ],
  ])('description length: %s', (_name, lines, expected) => {
    const findings = skillFindings('name: example', ...lines);

    expect(idsOf(findings)).toEqual(expected);

    for (const finding of findings) expect(finding.severity).toBe('warning');
  });

  test.each([
    [
      'flags an XML tag in a skill description',
      {
        '.claude/skills/example/SKILL.md': documentOf(
          'name: example',
          'description: Wraps <example>text</example> here.'
        ),
      },
      ['frontmatter.skill.description.xml-tag'],
    ],
    [
      'flags an XML tag in a command description',
      {
        '.claude/commands/example.md': documentOf(
          'description: Wraps <example>text</example> here.'
        ),
      },
      ['frontmatter.skill.description.xml-tag'],
    ],
    [
      'passes a tag inside backticks',
      {
        '.claude/skills/example/SKILL.md': documentOf(
          'name: example',
          'description: Wraps `<tag>` in code.'
        ),
      },
      [],
    ],
  ])('description tags: %s', (_name, files, expected) => {
    const findings = findingsFor(files);

    expect(idsOf(findings)).toEqual(expected);

    for (const finding of findings) expect(finding.severity).toBe('warning');
  });

  test.each([
    [
      'flags a reserved word',
      'name: claude-tdd',
      'frontmatter.skill.name.reserved-word',
    ],
    [
      'flags an over-long name',
      `name: ${'a'.repeat(65)}`,
      'frontmatter.skill.name.max-length',
    ],
    [
      'flags a name outside the lowercase hyphen charset',
      'name: -bad--name',
      'frontmatter.skill.name.charset',
    ],
  ])('skill names: %s', (_name, nameLine, ruleId) => {
    const findings = skillFindings(nameLine, PLAIN);

    expect(idsOf(findings)).toEqual([ruleId]);
    expect(findings[0]?.severity).toBe('warning');
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

    expect(idsOf(unquoted)).toEqual([HAZARD]);
    expect(unquoted[0]).toMatchObject({line: 3, severity: 'warning'});
    expect(skillFindings('name: example', 'description: "Note: here"')).toEqual(
      []
    );
  });

  test.each([
    ['an unquoted " #"', 'description: Fix a #1 bug'],
    ['a leading backtick', 'description: `code` first'],
  ])('flags %s as a YAML hazard', (_name, descriptionLine) => {
    expect(idsOf(skillFindings('name: example', descriptionLine))).toEqual([
      HAZARD,
    ]);
  });

  test('does not report frontmatter.parse on a file the hazard rule already flagged', () => {
    const hazardAndBrokenYaml = findingsFor({
      '.claude/commands/example.md':
        '---\ndescription: Note: here: there\nbad: [unclosed\n---\n',
    });

    expect(idsOf(hazardAndBrokenYaml)).toContain(HAZARD);
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
