import {
  NESTED_CLAUDE_MD_WORD_BUDGET,
  ROOT_CLAUDE_MD_WORD_BUDGET,
  RULE_LINE_BUDGET,
} from '../budgets.js';
import type {RuleContext} from '../context.js';
import {filesOfKinds} from '../context.js';
import {
  deadPathFindings,
  extractImports,
  extractPathReferences,
  resolveReference,
} from '../paths.js';
import type {RawFinding, RuleDefinition} from '../types.js';

export type ClaudeMdBudgets = {
  nestedWords: number;
  rootWords: number;
  ruleLines: number;
};

export const DEFAULT_BUDGETS: ClaudeMdBudgets = {
  nestedWords: NESTED_CLAUDE_MD_WORD_BUDGET,
  rootWords: ROOT_CLAUDE_MD_WORD_BUDGET,
  ruleLines: RULE_LINE_BUDGET,
};

const ROOT_CLAUDE_MD = 'CLAUDE.md';

const missingRootCheck = (context: RuleContext): readonly RawFinding[] =>
  context.allTrackedPaths.has(ROOT_CLAUDE_MD) ?
    []
  : [
      {
        file: ROOT_CLAUDE_MD,
        line: 0,
        message:
          'The project has no root CLAUDE.md, so no instructions load automatically.',
        remediation:
          'Create a CLAUDE.md at the project root with the instructions every session needs.',
      },
    ];

const importsResolveCheck = (context: RuleContext): readonly RawFinding[] =>
  filesOfKinds(context, ['claudemd', 'claudemd-local', 'rule']).flatMap(
    (file) =>
      extractImports(file.text).flatMap(({line, token}) => {
        const status = resolveReference(context, {
          bases: ['file-dir', 'root'],
          fromFile: file.path,
          token,
        });

        return status.status === 'dead' ?
            [
              {
                file: file.path,
                line,
                message: `The import @${token} does not resolve to an existing file.`,
                remediation:
                  'Fix the path, or remove the import if the file is gone.',
              },
            ]
          : [];
      })
  );

const deadPathCheck = (context: RuleContext): readonly RawFinding[] =>
  deadPathFindings(context, filesOfKinds(context, ['claudemd']));

const outsideRootCheck = (context: RuleContext): readonly RawFinding[] =>
  filesOfKinds(context, ['claudemd', 'claudemd-local', 'rule']).flatMap(
    (file) => {
      const imports = extractImports(file.text).map(({line, token}) => ({
        bases: ['file-dir', 'root'] as const,
        line,
        shown: `@${token}`,
        token,
      }));
      const paths = extractPathReferences(file.text).map(
        ({line, linked, token}) => ({
          bases: linked ? (['root', 'file-dir'] as const) : (['root'] as const),
          line,
          shown: token,
          token,
        })
      );

      return [...imports, ...paths].flatMap(({bases, line, shown, token}) =>
        (
          resolveReference(context, {bases, fromFile: file.path, token})
            .status === 'outside'
        ) ?
          [
            {
              file: file.path,
              line,
              message: `${shown} points outside the project root, so it is not checked.`,
              remediation:
                'No action needed unless the reference is meant to stay inside the project.',
            },
          ]
        : []
      );
    }
  );

const MACHINE_PATH =
  /\/Users\/[^\s/<>]+\/|\/home\/[^\s/<>]+\/|[A-Za-z]:\\Users\\[^\s\\<>]+\\/;

const machinePathCheck = (context: RuleContext): readonly RawFinding[] =>
  filesOfKinds(context, [
    'claudemd',
    'rule',
    'skill',
    'command',
    'agent',
  ]).flatMap((file) =>
    file.text.split('\n').flatMap((text, index) =>
      MACHINE_PATH.test(text) ?
        [
          {
            file: file.path,
            line: index + 1,
            message:
              'This line holds a machine-specific absolute path that only resolves on one computer.',
            remediation:
              'Use a path relative to the project root, or an environment variable.',
          },
        ]
      : []
    )
  );

const budgetCheck =
  (budgets: ClaudeMdBudgets) =>
  (context: RuleContext): readonly RawFinding[] => {
    const claudeFindings = filesOfKinds(context, ['claudemd']).flatMap(
      (file) => {
        const budget =
          file.path === ROOT_CLAUDE_MD ?
            budgets.rootWords
          : budgets.nestedWords;

        return file.words > budget ?
            [
              {
                file: file.path,
                line: 0,
                message: `${file.path} is ${file.words} words, over its budget of ${budget}.`,
                remediation:
                  'Move detail into a path-scoped rule, a skill or a wiki page that loads on demand.',
              },
            ]
          : [];
      }
    );
    const ruleFindings = filesOfKinds(context, ['rule']).flatMap((file) =>
      file.lines > budgets.ruleLines ?
        [
          {
            file: file.path,
            line: 0,
            message: `${file.path} is ${file.lines} lines, over its budget of ${budgets.ruleLines}.`,
            remediation:
              'Split the rule by topic, or move reference detail into a skill or wiki page.',
          },
        ]
      : []
    );

    return [...claudeFindings, ...ruleFindings];
  };

/** The claudemd rules, with the budgets injectable so a test can move them. */
export const createClaudemdRules = (
  budgets: ClaudeMdBudgets
): readonly RuleDefinition[] => [
  {
    appliesTo: ['claudemd', 'rule'],
    category: 'claudemd',
    check: budgetCheck(budgets),
    detection:
      'The root CLAUDE.md is over its word budget, a nested CLAUDE.md is over its word budget, or a rule file is over its line budget; the numbers come from the budgets module.',
    ruleId: 'claudemd.budget',
    severity: 'warning',
  },
  {
    appliesTo: ['claudemd'],
    category: 'claudemd',
    check: deadPathCheck,
    detection:
      'A backticked or linked repo-relative path in a CLAUDE.md does not exist.',
    ruleId: 'claudemd.dead-path',
    severity: 'warning',
  },
  {
    appliesTo: ['claudemd', 'claudemd-local', 'rule'],
    category: 'claudemd',
    check: importsResolveCheck,
    detection:
      'An @-import in a CLAUDE.md, CLAUDE.local.md or rule does not resolve to an existing file.',
    ruleId: 'claudemd.imports-resolve',
    severity: 'error',
  },
  {
    appliesTo: ['all'],
    category: 'claudemd',
    check: missingRootCheck,
    detection: 'The project has no root CLAUDE.md.',
    ruleId: 'claudemd.missing-root',
    severity: 'error',
    structural: true,
  },
  {
    appliesTo: ['claudemd', 'rule', 'skill', 'command', 'agent'],
    category: 'claudemd',
    check: machinePathCheck,
    detection:
      'A /Users/<name>/, /home/<name>/ or drive-letter user path appears in a CLAUDE.md (not CLAUDE.local.md), rule, skill, command or agent.',
    ruleId: 'claudemd.no-absolute-machine-path',
    severity: 'warning',
  },
  {
    appliesTo: ['claudemd', 'claudemd-local', 'rule'],
    category: 'claudemd',
    check: outsideRootCheck,
    detection:
      'An import or path in a CLAUDE.md, CLAUDE.local.md or rule resolves outside the project root; it is not checked and never read.',
    ruleId: 'claudemd.path-outside-root',
    severity: 'info',
  },
];

export const CLAUDEMD_RULES: readonly RuleDefinition[] =
  createClaudemdRules(DEFAULT_BUDGETS);
