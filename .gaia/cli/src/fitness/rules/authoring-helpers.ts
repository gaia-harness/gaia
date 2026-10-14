import type {RuleContext} from '../context.js';
import {filesOfKinds} from '../context.js';
import {
  extractLinks,
  linkPlaces,
  resolveLink,
  skillDirectoryOf,
} from '../links.js';
import {lineOf, splitFrontmatter, stripFencedCode} from '../markdown.js';
import {isProjectFolder, templateExamples} from '../paths.js';
import type {
  FileKind,
  ProjectFile,
  RawFinding,
  RuleDefinition,
} from '../types.js';

/** A body at or past this many lines is over the Agent Skills "under 500 lines" guidance. */
export const MAX_BODY_LINES = 500;

/** A body longer than this wants a table of contents so a partial read still finds the sections. */
const TOC_THRESHOLD_LINES = 100;

/** How far into a file the contents line may sit and still count as a lead-in. */
const TOC_SEARCH_LINES = 30;

/** Fewer words than this cannot say what a skill does and when to use it. */
export const MIN_DESCRIPTION_WORDS = 6;

export const VAGUE_NAMES: ReadonlySet<string> = new Set([
  'common',
  'data',
  'document',
  'documents',
  'file',
  'files',
  'general',
  'helper',
  'helpers',
  'misc',
  'stuff',
  'thing',
  'things',
  'tool',
  'tools',
  'util',
  'utilities',
  'utility',
  'utils',
]);

export type Body = {startLine: number; text: string};

export const bodyOf = (file: ProjectFile): Body => {
  const {bodyStartLine} = splitFrontmatter(file.text);

  return {
    startLine: bodyStartLine,
    text: file.text
      .split('\n')
      .slice(bodyStartLine - 1)
      .join('\n'),
  };
};

export const newlineCount = (text: string): number =>
  text.split('\n').length - 1;

/** The 1-indexed line of a top-level frontmatter key, else 1. */
export const lineOfKey = (text: string, key: string): number => {
  const match = new RegExp(String.raw`^${key}\s*:`, 'm').exec(text);

  return match === null ? 1 : lineOf(text, match.index);
};

export const stringField = (
  file: ProjectFile,
  key: string
): string | undefined => {
  const value = splitFrontmatter(file.text).data[key];

  return typeof value === 'string' ? value : undefined;
};

const QUOTED_SPANS = [/"[^"\n]*"/g, /\B'[^'\n]*'\B/g, /`[^`\n]*`/g] as const;

export const stripQuotedSpans = (text: string): string =>
  QUOTED_SPANS.reduce((value, pattern) => value.replaceAll(pattern, ' '), text);

const hasContentsLine = (bodyText: string): boolean =>
  stripFencedCode(bodyText)
    .split('\n')
    .filter((line) => line.trim() !== '')
    .slice(0, TOC_SEARCH_LINES)
    .some(
      (line) =>
        /^\s*Contents:/.test(line) ||
        /^#{1,6}\s+Contents\s*$/i.test(line.trim()) ||
        /table of contents/i.test(line)
    );

export const tocFinding = (file: ProjectFile, body: Body): RawFinding[] =>
  newlineCount(body.text) > TOC_THRESHOLD_LINES && !hasContentsLine(body.text) ?
    [
      {
        file: file.path,
        line: body.startLine,
        message: `${file.path} has more than ${TOC_THRESHOLD_LINES} lines and no Contents line near the top.`,
        remediation:
          'Add a "Contents:" line naming the sections, or a "## Contents" heading, within the first 30 lines.',
      },
    ]
  : [];

type DescriptionRuleOptions = {
  detection: string;
  kinds: readonly FileKind[];
  pattern: RegExp;
  ruleId: string;
  severity: 'info' | 'warning';
  what: string;
};

export const descriptionPatternRule = ({
  detection,
  kinds,
  pattern,
  ruleId,
  severity,
  what,
}: DescriptionRuleOptions): RuleDefinition => ({
  appliesTo: kinds,
  category: 'authoring',
  check: (context) =>
    filesOfKinds(context, kinds).flatMap((file) => {
      const description = stringField(file, 'description');

      if (description === undefined) return [];

      const hit = pattern.exec(stripQuotedSpans(description));

      return hit === null ?
          []
        : [
            {
              file: file.path,
              line: lineOfKey(file.text, 'description'),
              message: `The description uses ${what} ("${hit[0]}").`,
              remediation:
                'Write the description in the third person, as what the file does and when to use it.',
            },
          ];
    }),
  detection,
  ruleId,
  severity,
});

export const TRIGGER_WORDS =
  /\b(?:when|whenever|triggers?|triggered|triggering)\b|\buse\s+(?:for|if|on|after|before)\b/i;

const MONTHS =
  '(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec)';

export const TIME_SENSITIVE = new RegExp(
  String.raw`\b(?:before|after|until|by|as of)\s+(?:${MONTHS}\.?\s+)?(?:\d{1,2},?\s+)?(?:19|20)\d{2}(?![\w-])`,
  'i'
);

export const WINDOWS_PATH = /\b[\w.-]+(?:\\[\w-]+)*\\[\w-]+\.[A-Z0-9]{1,6}\b/i;

const WINDOWS_FENCE_TAGS: ReadonlySet<string> = new Set([
  'bat',
  'cmd',
  'powershell',
  'ps1',
]);

/** Blanks lines inside fences tagged for Windows shells, keeping every other line. */
export const withoutWindowsFences = (text: string): string => {
  let fence: undefined | {marker: string; skip: boolean};

  return text
    .split('\n')
    .map((line) => {
      const match = /^ {0,3}(`{3,}|~{3,})\s*(\S*)/.exec(line);

      if (fence === undefined) {
        if (match === null) return line;

        fence = {
          marker: match[1] ?? '```',
          skip: WINDOWS_FENCE_TAGS.has((match[2] ?? '').toLowerCase()),
        };

        return fence.skip ? '' : line;
      }

      const skipped = fence.skip;
      const closes =
        match !== null &&
        (match[1] ?? '').startsWith(fence.marker[0] ?? '`') &&
        (match[1] ?? '').length >= fence.marker.length &&
        line.trim() === match[1];

      if (closes) fence = undefined;

      return skipped ? '' : line;
    })
    .join('\n');
};

const SECTION_SKIP_HEADING = /legacy|deprecated/i;

/** Blanks `<details>` blocks and sections whose heading says legacy or deprecated. */
export const withoutDatedSections = (text: string): string => {
  let detailsDepth = 0;
  let skippedLevel: number | undefined;

  return stripFencedCode(text)
    .split('\n')
    .map((line) => {
      const heading = /^(#{1,6})\s(.*)/.exec(line);

      if (heading !== null) {
        const level = (heading[1] ?? '').length;

        if (skippedLevel !== undefined && level <= skippedLevel) {
          skippedLevel = undefined;
        }

        if (
          skippedLevel === undefined &&
          SECTION_SKIP_HEADING.test(heading[2] ?? '')
        ) {
          skippedLevel = level;
        }
      }

      const opens = (line.match(/<details[\s>]/gi) ?? []).length;
      const closes = (line.match(/<\/details>/gi) ?? []).length;
      const inside = detailsDepth > 0 || opens > 0;

      detailsDepth = Math.max(0, detailsDepth + opens - closes);

      return inside || skippedLevel !== undefined ? '' : line;
    })
    .join('\n');
};

export const firstMatchPerLine = ({
  describe,
  file,
  pattern,
  text,
}: {
  describe: (matched: string) => RawFinding;
  file: ProjectFile;
  pattern: RegExp;
  text: string;
}): RawFinding[] =>
  text.split('\n').flatMap((line, index) => {
    const hit = pattern.exec(line);

    return hit === null ?
        []
      : [{...describe(hit[0]), file: file.path, line: index + 1}];
  });

export const nameOf = (file: ProjectFile): string => {
  const declared = stringField(file, 'name');

  if (declared !== undefined && declared.trim() !== '') return declared.trim();

  const directory = skillDirectoryOf(file.path);

  return directory?.split('/').at(-1) ?? '';
};

const BACKTICK_SKILL_PREFIX = /^(?:\.{1,2}\/|references\/|scripts\/|assets\/)/;
const REPO_ROOT_PREFIX = /^(?:\.claude\/|\.gaia\/|wiki\/)/;

export const linkResolvesCheck = (
  context: RuleContext
): readonly RawFinding[] =>
  filesOfKinds(context, [
    'skill',
    'command',
    'agent',
    'reference',
    'playbook',
  ]).flatMap((file) => {
    const inSkillTree = skillDirectoryOf(file.path) !== undefined;
    const isExample = templateExamples(file.text);

    return extractLinks(file.text).flatMap((reference) => {
      const checked =
        reference.kind === 'markdown' ||
        ((inSkillTree ?
          BACKTICK_SKILL_PREFIX.test(reference.target)
        : REPO_ROOT_PREFIX.test(reference.target)) &&
          !isExample(reference.target));

      if (!checked) return [];

      // An ignored target is no broken link, and one that leaves the root is
      // reported by its own rule, never read.
      if (resolveLink(context, file.path, reference).status !== 'dead') {
        return [];
      }

      // A backticked token whose first folder exists nowhere it is tried
      // names something outside this tree, such as another project's script.
      const firstFolder = reference.target.split('/', 1)[0] ?? '';

      if (
        reference.kind === 'backtick' &&
        !linkPlaces(context, file.path, {
          ...reference,
          target: firstFolder,
        }).some((resolved) => isProjectFolder(context, resolved))
      ) {
        return [];
      }

      return [
        {
          file: file.path,
          line: reference.line,
          message: `${reference.target} does not exist.`,
          remediation: 'Fix the path, or remove the link if the file is gone.',
        },
      ];
    });
  });
