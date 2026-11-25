import {readFileSync} from 'node:fs';
import path from 'node:path';
import type {RuleContext} from '../context.js';
import type {ProjectFile, RawFinding, RuleDefinition} from '../types.js';
import {classify, HUMAN_ONLY_HEADERS_PATH} from './ask-user-question-sites.js';
import type {Site} from './ask-user-question-sites.js';

const SCOPE = /(?:^|\/)(?:\.claude|wiki)\//;

const instructionFiles = (context: RuleContext): readonly ProjectFile[] =>
  context.files.filter(
    (file) => file.path.endsWith('.md') && SCOPE.test(file.path)
  );

/** The gate's header list, or undefined when the file is absent or malformed (the gate then fails closed on its own). */
const humanOnlyHeaders = (
  context: RuleContext
): readonly string[] | undefined => {
  try {
    const parsed: unknown = JSON.parse(
      readFileSync(
        path.join(context.rootDirectory, HUMAN_ONLY_HEADERS_PATH),
        'utf8'
      )
    );
    const headers = (parsed as null | {headers?: unknown})?.headers;

    return (
        Array.isArray(headers) &&
          headers.every((header) => typeof header === 'string')
      ) ?
        headers
      : undefined;
  } catch {
    return undefined;
  }
};

const recommendationFindings = (
  file: ProjectFile,
  site: Site
): RawFinding[] => {
  // A bare `(Recommended)` names the mark to apply to a runtime-built option set.
  const marked =
    site.recommendedLabels.size === 0 && site.hasMarker ?
      site.questionCount
    : site.recommendedLabels.size;

  if (site.isNeutral) return [];

  if (marked === site.questionCount) return [];

  return [
    {
      file: file.path,
      line: site.block.line,
      message:
        marked < site.questionCount ?
          `The site asks ${site.questionCount} question(s) but marks ${marked} option(s) \`(Recommended)\`.`
        : `The site marks ${marked} options \`(Recommended)\` for ${site.questionCount} question(s); a question has exactly one.`,
      remediation:
        'Mark exactly one option per question `(Recommended)`, the conservative one, or say in the site that it recommends nothing.',
    },
  ];
};

/** An unheaded block may hold several questions, so only the no-recommendation case binds. */
const unheadedFindings = (file: ProjectFile, site: Site): RawFinding[] =>
  site.isNeutral || site.hasMarker ?
    []
  : [
      {
        file: file.path,
        line: site.block.line,
        message:
          'The block offers options for an AskUserQuestion and marks none `(Recommended)`.',
        remediation:
          'Mark the conservative option `(Recommended)`, or say the question recommends nothing.',
      },
    ];

export const ASK_USER_QUESTION_RULES: readonly RuleDefinition[] = [
  {
    appliesTo: ['all'],
    category: 'authoring',
    check: (context) =>
      instructionFiles(context).flatMap((file) => {
        const {sites, unheaded} = classify(file);

        return [
          ...sites.flatMap((site) => recommendationFindings(file, site)),
          ...unheaded.flatMap((site) => unheadedFindings(file, site)),
        ];
      }),
    detection:
      'An AskUserQuestion site with a header marks no option, or more options than it has headers, (Recommended); an option block with no header marks none.',
    ruleId: 'authoring.ask-user-question.recommendation',
    severity: 'warning',
  },
  {
    appliesTo: ['all'],
    category: 'authoring',
    check: (context) =>
      instructionFiles(context).flatMap((file) =>
        classify(file).freeText.flatMap(({block, hasFallback}) =>
          hasFallback ?
            []
          : [
              {
                file: file.path,
                line: block.line,
                message:
                  'The file asks a free-text question in chat and names no unattended fallback.',
                remediation:
                  'Say what an unattended run does instead of asking, such as taking a stated default or stopping.',
              },
            ]
        )
      ),
    detection:
      'A block asks a plain chat or free-text question and names no unattended or auto-mode fallback.',
    ruleId: 'authoring.ask-user-question.free-text-fallback',
    severity: 'warning',
  },
  {
    appliesTo: ['all'],
    category: 'authoring',
    check: (context) => {
      const listed = humanOnlyHeaders(context);

      if (listed === undefined) return [];

      const sites = instructionFiles(context).flatMap((file) =>
        classify(file).sites.map((site) => ({file, site}))
      );
      const used = new Set(sites.flatMap(({site}) => site.headers));
      const unused: RawFinding[] = listed
        .filter((header) => !used.has(header))
        .map((header) => ({
          file: HUMAN_ONLY_HEADERS_PATH,
          line: 1,
          message: `The human-only header "${header}" matches no AskUserQuestion site, so the gate never recognizes that question.`,
          remediation:
            'Name the header on its site, or remove it from the list when no such question exists.',
        }));
      const unlisted: RawFinding[] = sites.flatMap(({file, site}) =>
        (
          site.isHumanOnly &&
          !site.headers.some((header) => listed.includes(header))
        ) ?
          [
            {
              file: file.path,
              line: site.block.line,
              message:
                'The site says its question is human-only but uses no header on the gate list.',
              remediation: `Use a header listed in ${HUMAN_ONLY_HEADERS_PATH}, or add the header there.`,
            },
          ]
        : []
      );

      return [...unused, ...unlisted];
    },
    detection:
      'A header in the gate human-only list matches no site header, or a site that says human-only uses an unlisted header.',
    ruleId: 'authoring.ask-user-question.human-only-header',
    severity: 'warning',
  },
];
