import {filesOfKinds} from '../context.js';
import {buildLinkGraph, skillDirectoryOf} from '../links.js';
import type {ProjectFile, RuleDefinition} from '../types.js';
import {
  bodyOf,
  descriptionPatternRule,
  firstMatchPerLine,
  lineOfKey,
  linkResolvesCheck,
  MAX_BODY_LINES,
  MIN_DESCRIPTION_WORDS,
  nameOf,
  newlineCount,
  stringField,
  stripQuotedSpans,
  TIME_SENSITIVE,
  tocFinding,
  TRIGGER_WORDS,
  VAGUE_NAMES,
  WINDOWS_PATH,
  withoutDatedSections,
  withoutWindowsFences,
} from './authoring-helpers.js';

const SKILL_SUBTREE_EXCLUDED = /^(?:scripts|assets|eval[^/]*)\//;

const isSkillReference = (file: ProjectFile): boolean => {
  const directory = skillDirectoryOf(file.path);

  if (directory === undefined) return false;

  const rest = file.path.slice(directory.length + 1);

  return rest !== 'SKILL.md' && !SKILL_SUBTREE_EXCLUDED.test(rest);
};

export const AUTHORING_RULES: readonly RuleDefinition[] = [
  {
    appliesTo: ['skill', 'command'],
    category: 'authoring',
    check: (context) =>
      filesOfKinds(context, ['skill', 'command']).flatMap((file) => {
        const body = bodyOf(file);
        const lines = newlineCount(body.text);

        return lines >= MAX_BODY_LINES ?
            [
              {
                file: file.path,
                line: body.startLine,
                message: `The body is ${lines} lines, at or over the ${MAX_BODY_LINES} line limit.`,
                remediation:
                  'Move detail into reference files one level below this one and link them from the body.',
              },
            ]
          : [];
      }),
    detection:
      'Body after the frontmatter of 500 lines or more in a skill or command.',
    ruleId: 'authoring.skill.body.max-lines',
    severity: 'warning',
  },
  {
    appliesTo: ['playbook'],
    category: 'authoring',
    check: (context) =>
      context.filesOfKind('playbook').flatMap((file) => {
        const lines = newlineCount(file.text);

        return lines >= MAX_BODY_LINES ?
            [
              {
                file: file.path,
                line: 1,
                message: `The playbook is ${lines} lines, at or over the ${MAX_BODY_LINES} line limit.`,
                remediation:
                  'Split sections into sub-reference files and route to them with a Read line.',
              },
            ]
          : [];
      }),
    detection: 'A playbook file of 500 lines or more.',
    ruleId: 'authoring.playbook.max-lines',
    severity: 'warning',
  },
  {
    appliesTo: ['skill'],
    category: 'authoring',
    check: (context) =>
      context.filesOfKind('skill').flatMap((file) => {
        const name = nameOf(file);

        return VAGUE_NAMES.has(name.toLowerCase()) ?
            [
              {
                file: file.path,
                line: lineOfKey(file.text, 'name'),
                message: `The skill name "${name}" is too vague to tell it apart from other skills.`,
                remediation:
                  'Name the skill for what it does, for example the verb and object, in lowercase with hyphens.',
              },
            ]
          : [];
      }),
    detection:
      'The whole skill name is a listed vague word such as helper, utils, tools, data or files.',
    ruleId: 'authoring.skill.name.vague',
    severity: 'info',
  },
  descriptionPatternRule({
    detection:
      'After stripping quoted spans, the description has I, we, our, my or me as a word.',
    kinds: ['skill', 'command', 'agent'],
    pattern: /(?<![\w/-])I(?![\w/-])|\b(?:we|our|my|me)\b/i,
    ruleId: 'authoring.skill.description.first-person',
    severity: 'warning',
    what: 'the first person',
  }),
  descriptionPatternRule({
    detection:
      'After stripping quoted spans, the description has you or your as a word.',
    kinds: ['skill', 'command', 'agent'],
    pattern: /\b(?:you|your)\b/i,
    ruleId: 'authoring.skill.description.second-person',
    severity: 'info',
    what: 'the second person',
  }),
  {
    appliesTo: ['skill', 'command'],
    category: 'authoring',
    check: (context) =>
      filesOfKinds(context, ['skill', 'command']).flatMap((file) => {
        const description = stringField(file, 'description');

        if (description === undefined || description.trim() === '') return [];

        const text = stripQuotedSpans(
          `${description} ${stringField(file, 'when_to_use') ?? ''}`
        );

        return TRIGGER_WORDS.test(text) ?
            []
          : [
              {
                file: file.path,
                line: lineOfKey(file.text, 'description'),
                message:
                  'Neither the description nor when_to_use says when to use this.',
                remediation:
                  'Add a trigger to the description, for example "Use when the user asks for ...".',
              },
            ];
      }),
    detection:
      'Neither description nor when_to_use names a trigger: when, whenever, trigger, or use for, if, on, after or before.',
    ruleId: 'authoring.skill.description.no-when',
    severity: 'info',
  },
  {
    appliesTo: ['skill', 'command'],
    category: 'authoring',
    check: (context) =>
      filesOfKinds(context, ['skill', 'command']).flatMap((file) => {
        const description = stringField(file, 'description');

        if (description === undefined || description.trim() === '') return [];

        const words = (description.match(/\S+/g) ?? []).length;

        return words < MIN_DESCRIPTION_WORDS ?
            [
              {
                file: file.path,
                line: lineOfKey(file.text, 'description'),
                message: `The description is ${words} words; fewer than ${MIN_DESCRIPTION_WORDS} cannot say what this does and when to use it.`,
                remediation:
                  'Describe what it does and when to use it in a full sentence or two.',
              },
            ]
          : [];
      }),
    detection: 'A description of fewer than 6 words in a skill or command.',
    ruleId: 'authoring.skill.description.too-short',
    severity: 'info',
  },
  {
    appliesTo: ['reference', 'playbook'],
    category: 'authoring',
    check: (context) =>
      filesOfKinds(context, ['reference', 'playbook']).flatMap((file) =>
        tocFinding(file, bodyOf(file))
      ),
    detection:
      'Body over 100 lines and none of the first 30 non-blank lines outside code fences is a Contents:, ## Contents or Table of contents line.',
    ruleId: 'authoring.reference.toc.required',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'command', 'agent'],
    category: 'authoring',
    check: (context) =>
      filesOfKinds(context, ['skill', 'command', 'agent']).flatMap((file) =>
        tocFinding(file, bodyOf(file))
      ),
    detection:
      'The same Contents matcher applied to a skill, command or agent body over 100 lines.',
    ruleId: 'authoring.skill.body.toc',
    severity: 'info',
  },
  {
    appliesTo: ['skill', 'playbook', 'reference'],
    category: 'authoring',
    check: (context) =>
      buildLinkGraph(context).violations.map((violation) => ({
        file: violation.file,
        line: violation.line,
        message: `${violation.target} is reachable only through another reference, two levels below the entry file.`,
        remediation:
          'Link it from the entry file or a sibling reference so every file is one level from an entry.',
      })),
    detection:
      'A file reachable only through a level 1 reference and not a sibling of the file that links it; entries are each SKILL.md, each command and each playbook a command routes to.',
    ruleId: 'authoring.reference.depth.one-level',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'command', 'agent', 'reference'],
    category: 'authoring',
    check: linkResolvesCheck,
    detection:
      'A markdown link outside inline code, or a backticked relative path whose first folder exists, inside the skill directory (a repo-relative path for commands and agents; a reference qualified by another skill name resolves in that skill) that does not exist.',
    ruleId: 'authoring.reference.link.resolves',
    severity: 'warning',
  },
  {
    appliesTo: ['reference'],
    category: 'authoring',
    check: (context) => {
      const graph = buildLinkGraph(context);

      return context
        .filesOfKind('reference')
        .filter(
          (file) =>
            isSkillReference(file) &&
            !graph.levelZero.has(file.path) &&
            !graph.linked.has(file.path)
        )
        .map((file) => ({
          file: file.path,
          line: 1,
          message: 'No entry file or reference links this file.',
          remediation:
            'Link it from SKILL.md with one line saying when to read it, or delete it.',
        }));
    },
    detection:
      'A markdown file under a skill directory (outside scripts, assets and eval subtrees) that no entry or level 1 file links.',
    ruleId: 'authoring.reference.orphan',
    severity: 'info',
  },
  {
    appliesTo: ['all'],
    category: 'authoring',
    check: (context) =>
      context.files.flatMap((file) =>
        firstMatchPerLine({
          describe: (matched) => ({
            file: file.path,
            line: 1,
            message: `Backslash path "${matched}"; paths use forward slashes.`,
            remediation: 'Write the path with forward slashes.',
          }),
          file,
          pattern: WINDOWS_PATH,
          text: withoutWindowsFences(file.text),
        })
      ),
    detection:
      'A backslash-separated path with an extension outside powershell, ps1, bat and cmd code fences.',
    ruleId: 'authoring.path.windows-separator',
    severity: 'warning',
  },
  {
    appliesTo: ['all'],
    category: 'authoring',
    check: (context) =>
      context.files.flatMap((file) =>
        firstMatchPerLine({
          describe: (matched) => ({
            file: file.path,
            line: 1,
            message: `"${matched}" will go stale.`,
            remediation:
              'State the current behavior, and move the dated history into a collapsed details block or a legacy section.',
          }),
          file,
          pattern: TIME_SENSITIVE,
          text: withoutDatedSections(file.text),
        })
      ),
    detection:
      'before, after, until, by or as of followed by an optional month and a four-digit year, outside details blocks and legacy or deprecated sections.',
    ruleId: 'authoring.content.time-sensitive',
    severity: 'info',
  },
];
