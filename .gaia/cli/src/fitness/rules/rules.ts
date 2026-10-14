import picomatch from 'picomatch';
import type {RuleContext} from '../context.js';
import {lineOf, splitFrontmatter} from '../markdown.js';
import {deadPathFindings, extractImports, resolveReference} from '../paths.js';
import type {RawFinding, RuleDefinition} from '../types.js';

const SKILLS_DIRECTORY = /(?:^|\/)skills\//;

const noSkillImportCheck = (context: RuleContext): readonly RawFinding[] =>
  context.filesOfKind('rule').flatMap((file) =>
    extractImports(file.text).flatMap(({line, token}) => {
      const status = resolveReference(context, {
        bases: ['file-dir', 'root'],
        fromFile: file.path,
        token,
      });

      return (
          (status.status === 'found' || status.status === 'dead') &&
            SKILLS_DIRECTORY.test(status.relative)
        ) ?
          [
            {
              file: file.path,
              line,
              message: `The rule imports @${token}, which is inside a skills folder, so the whole skill loads on every session.`,
              remediation:
                'Remove the import; a skill loads on demand and a rule should point at it by name instead.',
            },
          ]
        : [];
    })
  );

const globProblem = (entry: unknown): string | undefined => {
  if (typeof entry !== 'string') {
    return 'is not a string';
  }

  if (entry.trim() === '') return 'is empty';

  try {
    picomatch.makeRe(entry, {strictBrackets: true});
  } catch (error: unknown) {
    return `does not compile as a glob (${error instanceof Error ? error.message : String(error)})`;
  }

  return undefined;
};

const describeEntry = (entry: unknown): string =>
  typeof entry === 'string' ? `"${entry}"` : JSON.stringify(entry);

/** The line of `needle` at or after the `paths:` key, else of the key, else 1. */
const pathsLine = (text: string, needle: string | undefined): number => {
  const keyIndex = text.search(/^paths\s*:/m);

  if (keyIndex === -1) return 1;

  const needleIndex =
    needle === undefined || needle === '' ? -1 : text.indexOf(needle, keyIndex);

  return lineOf(text, needleIndex === -1 ? keyIndex : needleIndex);
};

const globSyntaxCheck = (context: RuleContext): readonly RawFinding[] =>
  context.filesOfKind('rule').flatMap((file) => {
    const frontmatter = splitFrontmatter(file.text);

    if (!frontmatter.ok || !Object.hasOwn(frontmatter.data, 'paths')) return [];

    const declared = frontmatter.data.paths;

    if (declared === null || declared === undefined) return [];

    const entries: readonly unknown[] =
      Array.isArray(declared) ? (declared as unknown[]) : [declared];

    return entries.flatMap((entry) => {
      const problem = globProblem(entry);

      return problem === undefined ?
          []
        : [
            {
              file: file.path,
              line: pathsLine(
                file.text,
                typeof entry === 'string' ? entry : undefined
              ),
              message: `The paths entry ${describeEntry(entry)} ${problem}, so the rule may never scope to the files it intends.`,
              remediation:
                'Make every paths entry a non-empty string that is a valid glob, for example "src/**/*.{ts,tsx}".',
            },
          ];
    });
  });

const deadPathCheck = (context: RuleContext): readonly RawFinding[] =>
  deadPathFindings(context, context.filesOfKind('rule'));

export const RULES_RULES: readonly RuleDefinition[] = [
  {
    appliesTo: ['rule'],
    category: 'rules',
    check: deadPathCheck,
    detection:
      'A backticked or linked repo-relative path in a rule file does not exist.',
    ruleId: 'rules.dead-path',
    severity: 'warning',
  },
  {
    appliesTo: ['rule'],
    category: 'rules',
    check: globSyntaxCheck,
    detection:
      'A paths: entry in a rule is not a string or fails to compile with picomatch semantics (empty entry: an addition beyond the catalog).',
    ruleId: 'rules.glob-syntax',
    severity: 'warning',
  },
  {
    appliesTo: ['rule'],
    category: 'rules',
    check: noSkillImportCheck,
    detection: 'A rule @-imports a path that resolves under a skills folder.',
    ruleId: 'rules.no-skill-import',
    severity: 'warning',
  },
];
