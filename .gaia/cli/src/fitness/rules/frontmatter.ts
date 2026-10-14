import {filesOfKinds} from '../context.js';
import type {RuleContext} from '../context.js';
import {splitFrontmatter} from '../markdown.js';
import type {
  FileKind,
  ProjectFile,
  RawFinding,
  RuleDefinition,
} from '../types.js';

/** Anthropic's Agent Skills cap on a skill's `name`. */
const NAME_MAX_CODE_POINTS = 64;
/** Anthropic's Agent Skills cap on a skill's `description`. */
const DESCRIPTION_MAX_CODE_POINTS = 1024;
/** Claude Code cuts a listing entry's description plus `when_to_use` here. */
const LISTING_MAX_CODE_POINTS = 1536;

const NAME_CHARSET = /^[\da-z]+(?:-[\da-z]+)*$/;
const RESERVED_WORDS: ReadonlySet<string> = new Set(['anthropic', 'claude']);
const XML_TAG = /<\/?[A-Z][^>]*>/i;
const TOP_LEVEL_SCALAR = /^([A-Z_][\w-]*)[\t ]*:[\t ]+(\S.*)$/i;

const SKILL_DIRECTORY = /(?:^|\/)\.claude\/skills\/([^/]+)\/SKILL\.md$/;
const COMMAND_STEM = /(?:^|\/)\.claude\/commands\/(.+)\.md$/;
const AGENT_STEM = /(?:^|\/)\.claude\/agents\/(.+)\.md$/;

type Inspection = Omit<RawFinding, 'file'>;

type Parsed = {
  data: Record<string, unknown>;
  error: string | undefined;
  file: ProjectFile;
  ok: boolean;
  raw: string;
};

// eslint-disable-next-line @typescript-eslint/no-misused-spread -- the spread counts code points, which is the unit the Agent Skills limits use
const codePoints = (text: string): number => [...text].length;

const nonEmptyString = (value: unknown): string | undefined =>
  typeof value === 'string' && value.trim() !== '' ? value : undefined;

const parsedFilesOf = (
  context: RuleContext,
  kinds: readonly FileKind[]
): readonly Parsed[] =>
  filesOfKinds(context, kinds).map((file) => {
    const frontmatter = splitFrontmatter(file.text);

    return {
      data: frontmatter.data,
      error: frontmatter.error,
      file,
      ok: frontmatter.ok,
      raw: frontmatter.raw,
    };
  });

/** The 1-indexed file line of top-level `key`, else 1. */
const keyLine = (raw: string, key: string): number => {
  const index = raw
    .split('\n')
    .findIndex((line) => new RegExp(String.raw`^${key}[\t ]*:`).test(line));

  return index === -1 ? 1 : index + 2;
};

/** Top-level `key: value` lines whose plain value changes meaning in YAML. */
const hazardsOf = (raw: string): readonly {key: string; line: number}[] =>
  raw.split('\n').flatMap((text, index) => {
    const match = TOP_LEVEL_SCALAR.exec(text);
    const key = match?.[1];
    const value = match?.[2]?.trim();

    if (key === undefined || value === undefined) return [];
    // Quoted, block and flow values are not plain scalars; a bare `#` starts a comment.
    if (/^["#'>[{|]/.test(value)) return [];

    const hazardous =
      value.startsWith('`') || value.includes(': ') || value.includes(' #');

    return hazardous ? [{key, line: index + 2}] : [];
  });

/** Runs `inspect` on every parsed file of `kinds`; a file that did not parse is left to `frontmatter.parse`. */
const perFile =
  (
    kinds: readonly FileKind[],
    inspect: (parsed: Parsed) => readonly Inspection[]
  ) =>
  (context: RuleContext): readonly RawFinding[] =>
    parsedFilesOf(context, kinds)
      .filter((parsed) => parsed.ok)
      .flatMap((parsed) =>
        inspect(parsed).map((finding) => ({...finding, file: parsed.file.path}))
      );

const effectiveName = (parsed: Parsed): string | undefined => {
  const declared = nonEmptyString(parsed.data.name)?.trim();

  if (declared !== undefined) return declared;

  const {path} = parsed.file;
  const skill = SKILL_DIRECTORY.exec(path)?.[1];

  if (skill !== undefined) return skill;

  const stem = (COMMAND_STEM.exec(path) ?? AGENT_STEM.exec(path))?.[1];

  return stem?.replaceAll('/', ':');
};

const collisionCheck = (context: RuleContext): readonly RawFinding[] => {
  const named = parsedFilesOf(context, ['skill', 'command', 'agent']).flatMap(
    (parsed) => {
      const name = parsed.ok ? effectiveName(parsed) : undefined;

      return name === undefined ? [] : [{name, parsed}];
    }
  );
  const counts = new Map<string, number>();

  for (const {name} of named) counts.set(name, (counts.get(name) ?? 0) + 1);

  return named
    .filter(({name}) => (counts.get(name) ?? 0) > 1)
    .map(({name, parsed}) => ({
      file: parsed.file.path,
      line:
        nonEmptyString(parsed.data.name) === undefined ? 1 : (
          keyLine(parsed.raw, 'name')
        ),
      message: `Another skill, command or agent is also named "${name}", so only one can be invoked by that name.`,
      remediation: 'Give each skill, command and agent a unique name.',
    }));
};

const parseCheck = (context: RuleContext): readonly RawFinding[] =>
  parsedFilesOf(context, ['skill', 'command', 'agent'])
    .filter((parsed) => !parsed.ok && hazardsOf(parsed.raw).length === 0)
    .map((parsed) => ({
      file: parsed.file.path,
      line: 1,
      message: `Frontmatter cannot be read: ${parsed.error ?? 'unknown error'}.`,
      remediation:
        'Start the file with a "---" line, close the block with another "---" line, and keep a YAML mapping between them.',
    }));

const hazardCheck = (context: RuleContext): readonly RawFinding[] =>
  parsedFilesOf(context, ['skill', 'command', 'agent']).flatMap((parsed) =>
    hazardsOf(parsed.raw).map(({key, line}) => ({
      file: parsed.file.path,
      line,
      message: `The unquoted "${key}" value holds ": " or " #", or starts with a backtick, which YAML reads as a mapping or a comment instead of text.`,
      remediation: `Wrap the "${key}" value in double quotes.`,
    }))
  );

const namePresent = perFile(['skill', 'agent'], (parsed) =>
  nonEmptyString(parsed.data.name) === undefined ?
    [
      {
        line: 1,
        message: 'The "name" field is missing or empty.',
        remediation: 'Add a "name" field naming the skill or agent.',
      },
    ]
  : []
);

const nameMaxLength = perFile(['skill', 'agent'], (parsed) => {
  const name = nonEmptyString(parsed.data.name);

  return name !== undefined && codePoints(name) > NAME_MAX_CODE_POINTS ?
      [
        {
          line: keyLine(parsed.raw, 'name'),
          message: `The name is ${codePoints(name)} characters; the limit is ${NAME_MAX_CODE_POINTS}.`,
          remediation: `Shorten the name to ${NAME_MAX_CODE_POINTS} characters or fewer.`,
        },
      ]
    : [];
});

const nameCharset = perFile(['skill', 'agent'], (parsed) => {
  const name = nonEmptyString(parsed.data.name);

  return name !== undefined && !NAME_CHARSET.test(name) ?
      [
        {
          line: keyLine(parsed.raw, 'name'),
          message:
            'The name must be lowercase letters and digits in hyphen-separated groups.',
          remediation:
            'Rename it with only a-z, 0-9 and single hyphens, with no leading or trailing hyphen.',
        },
      ]
    : [];
});

const nameReservedWord = perFile(['skill', 'agent'], (parsed) => {
  const name = nonEmptyString(parsed.data.name);
  const reserved = name?.split('-').find((token) => RESERVED_WORDS.has(token));

  return reserved === undefined ?
      []
    : [
        {
          line: keyLine(parsed.raw, 'name'),
          message: `The name holds the reserved word "${reserved}".`,
          remediation: 'Remove the reserved word from the name.',
        },
      ];
});

const descriptionNonEmpty = perFile(['skill', 'command', 'agent'], (parsed) =>
  nonEmptyString(parsed.data.description) === undefined ?
    [
      {
        line: keyLine(parsed.raw, 'description'),
        message: 'The "description" field is missing, not text, or empty.',
        remediation:
          'Add a description saying what the file does and when to use it.',
      },
    ]
  : []
);

const descriptionMaxLength = perFile(['skill', 'command'], (parsed) => {
  const description = nonEmptyString(parsed.data.description);

  return (
      description !== undefined &&
        codePoints(description) > DESCRIPTION_MAX_CODE_POINTS
    ) ?
      [
        {
          line: keyLine(parsed.raw, 'description'),
          message: `The description is ${codePoints(description)} characters; the limit is ${DESCRIPTION_MAX_CODE_POINTS}.`,
          remediation: `Shorten the description to ${DESCRIPTION_MAX_CODE_POINTS} characters or fewer.`,
        },
      ]
    : [];
});

const listingTruncation = perFile(['skill', 'command'], (parsed) => {
  const description = nonEmptyString(parsed.data.description) ?? '';
  const whenToUse = nonEmptyString(parsed.data.when_to_use) ?? '';
  const total = codePoints(description) + codePoints(whenToUse);

  return total > LISTING_MAX_CODE_POINTS ?
      [
        {
          line: keyLine(parsed.raw, 'description'),
          message: `The description plus when_to_use is ${total} characters; the session listing cuts it at ${LISTING_MAX_CODE_POINTS}.`,
          remediation: `Trim the description and when_to_use to ${LISTING_MAX_CODE_POINTS} characters together, keeping the trigger words first.`,
        },
      ]
    : [];
});

const descriptionXmlTag = perFile(['skill', 'command', 'agent'], (parsed) => {
  const description = nonEmptyString(parsed.data.description);
  const outsideCode = description?.replaceAll(/(`+)[\s\S]*?\1/g, '');

  return outsideCode !== undefined && XML_TAG.test(outsideCode) ?
      [
        {
          line: keyLine(parsed.raw, 'description'),
          message: 'The description holds an XML tag.',
          remediation:
            'Remove the tag, or put it in backticks if it must be shown.',
        },
      ]
    : [];
});

export const FRONTMATTER_RULES: readonly RuleDefinition[] = [
  {
    appliesTo: ['skill', 'command', 'agent'],
    category: 'frontmatter',
    check: collisionCheck,
    detection:
      'Two skills, commands or agents share an effective name (the frontmatter name, else the directory or file stem with its subdirectory namespace).',
    ruleId: 'frontmatter.name-collision',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'command', 'agent'],
    category: 'frontmatter',
    check: parseCheck,
    detection:
      'The first line is not "---", no closing "---" exists, or the block is not a YAML mapping, unless the yaml-hazard rule already fired on the file.',
    ruleId: 'frontmatter.parse',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'command'],
    category: 'frontmatter',
    check: descriptionMaxLength,
    detection: 'The description is over 1024 code points.',
    ruleId: 'frontmatter.skill.description.max-length',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'command'],
    category: 'frontmatter',
    check: listingTruncation,
    detection:
      'The description plus when_to_use is over the 1536-character listing cap.',
    ruleId: 'frontmatter.skill.description.listing-truncation',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'command', 'agent'],
    category: 'frontmatter',
    check: descriptionNonEmpty,
    detection: 'The description is missing, not a string, or empty after trim.',
    ruleId: 'frontmatter.skill.description.non-empty',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'command', 'agent'],
    category: 'frontmatter',
    check: descriptionXmlTag,
    detection: 'The description holds an XML tag outside backtick spans.',
    ruleId: 'frontmatter.skill.description.xml-tag',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'agent'],
    category: 'frontmatter',
    check: nameCharset,
    detection:
      'The name does not match lowercase letters and digits in hyphen-separated groups.',
    ruleId: 'frontmatter.skill.name.charset',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'agent'],
    category: 'frontmatter',
    check: nameMaxLength,
    detection: 'The name is over 64 code points.',
    ruleId: 'frontmatter.skill.name.max-length',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'agent'],
    category: 'frontmatter',
    check: namePresent,
    detection: 'The name is missing or empty after trim.',
    ruleId: 'frontmatter.skill.name.present',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'agent'],
    category: 'frontmatter',
    check: nameReservedWord,
    detection:
      'A hyphen-separated token of the name is "anthropic" or "claude".',
    ruleId: 'frontmatter.skill.name.reserved-word',
    severity: 'warning',
  },
  {
    appliesTo: ['skill', 'command', 'agent'],
    category: 'frontmatter',
    check: hazardCheck,
    detection:
      'A top-level frontmatter value that is not quoted holds ": " or " #", or starts with a backtick.',
    ruleId: 'frontmatter.yaml-hazard',
    severity: 'warning',
  },
];
