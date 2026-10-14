import {statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {takeNonFlagValue} from '../util/argv.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {
  applySuppressions,
  canonicalRuleIds,
  CONFIG_PARSE_RULE_ID,
  CONFIG_PLACEHOLDER,
  loadSuppressionSource,
} from './config.js';
import type {RuleContext} from './context.js';
import {createRuleContext} from './context.js';
import {discoverFiles, hasPathScopeIn} from './discover.js';
import {gradeFromCounts, overallGrade} from './grade.js';
import {compareBytes, splitFrontmatter} from './markdown.js';
import {projectModelFromSettings, resolveModel} from './model.js';
import {classifyOwnership, effectiveOwnership} from './ownership.js';
import {RULE_CATALOG} from './rules/index.js';
import {redactDeep} from './secrets.js';
import type {
  Category,
  CheckReport,
  FileKind,
  Finding,
  Grade,
  Ownership,
  ProjectFile,
  RuleDefinition,
  Severity,
} from './types.js';
import {CATEGORIES} from './types.js';

export type RunCheckOptions = {
  catalog?: readonly RuleDefinition[];
  configPath?: string;
  /** Tests only: where the ownership classifier seam is read. */
  env?: Readonly<Record<string, string | undefined>>;
  only?: readonly string[];
  root: string;
  scope: 'adopter' | 'all';
};

const SEVERITY_RANK: Readonly<Record<Severity, number>> = {
  error: 3,
  info: 1,
  warning: 2,
};

const UPSTREAM_REMEDIATION =
  'GAIA ships this file; run /update-gaia to take the upstream fix.';

const FIXABLE_CATEGORIES: ReadonlySet<Category> = new Set([
  'claudemd',
  'hooks',
  'rules',
  'settings',
]);

const compareFindings = (a: Finding, b: Finding): number =>
  compareBytes(a.file, b.file) ||
  a.line - b.line ||
  compareBytes(a.rule_id, b.rule_id);

/** True when `selector` names `ruleId` exactly or as a dotted prefix. */
export const matchesSelector = (selector: string, ruleId: string): boolean =>
  ruleId === selector || ruleId.startsWith(`${selector}.`);

const ruleMatches = (rule: RuleDefinition, selector: string): boolean =>
  [rule.ruleId, ...(rule.aliases ?? [])].some((id) =>
    matchesSelector(selector, id)
  );

const hasHookEntry = (parsed: unknown): boolean => {
  if (parsed === null || typeof parsed !== 'object') return false;

  const {hooks} = parsed as {hooks?: unknown};

  if (hooks === null || typeof hooks !== 'object') return false;

  return Object.values(hooks).some(
    (groups: unknown) =>
      Array.isArray(groups) &&
      groups.some((group: unknown) => {
        if (group === null || typeof group !== 'object') return false;

        const inner = (group as {hooks?: unknown}).hooks;

        return Array.isArray(inner) ? inner.length > 0 : 'command' in group;
      })
  );
};

const isDirectory = (target: string): boolean => {
  try {
    return statSync(target).isDirectory();
  } catch {
    return false;
  }
};

const hasAnyKind = (
  context: RuleContext,
  kinds: readonly FileKind[]
): boolean => kinds.some((kind) => context.filesOfKind(kind).length > 0);

/**
 * Whether a category has anything to grade. A category with no input is `n/a`
 * rather than `A+`, so an absent hooks section never reads as a clean one.
 */
const APPLICABILITY: Readonly<
  Record<Category, (context: RuleContext) => boolean>
> = {
  authoring: (context) =>
    hasAnyKind(context, ['skill', 'command', 'agent', 'reference', 'playbook']),
  claudemd: () => true,
  frontmatter: (context) => hasAnyKind(context, ['skill', 'command', 'agent']),
  hooks: (context) =>
    context.settingsFiles.some((file) => hasHookEntry(file.parsed)),
  prompt: (context) => hasAnyKind(context, ['skill', 'command', 'agent']),
  rules: (context) => hasAnyKind(context, ['rule']),
  settings: (context) =>
    hasAnyKind(context, ['settings', 'settings-local', 'fitness-config']),
  wiki: (context) => isDirectory(path.join(context.rootDirectory, 'wiki')),
};

const LINTED_OWNERSHIPS: ReadonlySet<Ownership> = new Set([
  'adopter',
  'gaia-shipped',
  'unknown',
]);

const buildFinding = (
  rule: Pick<RuleDefinition, 'category' | 'ruleId' | 'severity'>,
  raw: {file: string; line: number; message: string; remediation: string},
  ownership: Ownership
): Finding => ({
  /* eslint-disable perfectionist/sort-objects -- the printed key order is part of the report contract */
  rule_id: rule.ruleId,
  category: rule.category,
  severity: rule.severity,
  file: raw.file,
  line: raw.line,
  message: raw.message,
  remediation: raw.remediation,
  ownership,
  fixable:
    FIXABLE_CATEGORIES.has(rule.category) &&
    rule.severity !== 'info' &&
    ownership === 'adopter',
  /* eslint-enable perfectionist/sort-objects */
});

/** Drops third-party and ignored findings; gaia-shipped ones outside `all` scope become upstream notes. */
const partitionFindings = (
  rawFindings: readonly Finding[],
  scope: RunCheckOptions['scope']
): {graded: Finding[]; upstream: Finding[]} => {
  const graded: Finding[] = [];
  const upstream: Finding[] = [];

  for (const finding of rawFindings) {
    if (finding.ownership === 'gaia-shipped' && scope !== 'all') {
      upstream.push({...finding, remediation: UPSTREAM_REMEDIATION});
    } else if (
      finding.ownership !== 'third-party' &&
      finding.ownership !== 'ignored'
    ) {
      graded.push(finding);
    }
  }

  return {graded, upstream};
};

/** Runs the catalog over `root` and returns the report; throws only when the run cannot complete. */
export const runCheck = (options: RunCheckOptions): CheckReport => {
  const root = path.resolve(options.root);

  if (!isDirectory(root)) throw new Error('the root is not a directory');

  const catalog = options.catalog ?? RULE_CATALOG;
  const only = options.only ?? [];
  const selected =
    only.length === 0 ?
      catalog
    : catalog.filter((rule) =>
        only.some((selector) => ruleMatches(rule, selector))
      );
  const parseRuleSelected =
    only.length === 0 ||
    only.some((selector) => matchesSelector(selector, CONFIG_PARSE_RULE_ID));

  const discovery = discoverFiles(root);
  const ownershipByPath = classifyOwnership({
    env: options.env,
    paths: discovery.files.map((file) => file.path),
    root,
  });

  const rootSettings = discovery.files.find(
    (file) => file.path === '.claude/settings.json'
  );
  const projectModel = projectModelFromSettings(rootSettings?.text);

  const projectFiles: ProjectFile[] = discovery.files.map((file) => {
    const ownership = effectiveOwnership(
      ownershipByPath.get(file.path) ?? 'unknown',
      file.kinds
    );
    const frontmatter = splitFrontmatter(file.text);

    return {
      kinds: file.kinds,
      lines: file.text.split('\n').length - 1,
      model: resolveModel(frontmatter.data.model, projectModel),
      ownership,
      path: file.path,
      pathScoped: file.kinds.includes('rule') && hasPathScopeIn(frontmatter),
      text: file.text,
      words: (file.text.match(/\S+/g) ?? []).length,
    };
  });

  const ownershipOf = new Map(
    projectFiles.map((file) => [file.path, file.ownership] as const)
  );
  const linted = projectFiles.filter((file) =>
    LINTED_OWNERSHIPS.has(file.ownership)
  );

  const knownRules =
    catalog === RULE_CATALOG ? catalog : [...RULE_CATALOG, ...catalog];
  const canonical = canonicalRuleIds(knownRules);
  const context = createRuleContext({
    allTrackedPaths: discovery.allTrackedPaths,
    files: linted,
    inGit: discovery.inGit,
    knownRuleIds: new Set(canonical.keys()),
    projectModel,
    root,
  });

  const rawFindings: Finding[] = [];

  for (const rule of selected) {
    for (const raw of rule.check(context)) {
      rawFindings.push(
        buildFinding(rule, raw, ownershipOf.get(raw.file) ?? 'unknown')
      );
    }
  }

  const source = loadSuppressionSource({
    configPath: options.configPath,
    discovered: context.fitnessConfig,
    root,
  });

  if (source.loadError !== undefined && parseRuleSelected) {
    rawFindings.push(
      buildFinding(
        {
          category: 'settings',
          ruleId: CONFIG_PARSE_RULE_ID,
          severity: 'error',
        },
        {
          file: CONFIG_PLACEHOLDER,
          line: 0,
          message: `The --config file cannot be used: ${source.loadError}. None of its suppressions apply.`,
          remediation:
            'Pass a readable JSON object with "version": 1 and an "ignore" list, or drop --config.',
        },
        'unknown'
      )
    );
  }

  const {graded, upstream} = partitionFindings(rawFindings, options.scope);
  const {kept: findings, suppressed} = applySuppressions(
    graded,
    source.entries,
    canonical
  );

  const structuralIds = new Set(
    knownRules
      .filter((rule) => rule.structural === true)
      .map((rule) => rule.ruleId)
  );
  const selectedCategories = new Set<Category>(
    selected.map((rule) => rule.category)
  );

  if (parseRuleSelected) selectedCategories.add('settings');

  const categories = CATEGORIES.map((name) => {
    const ofCategory = findings.filter((finding) => finding.category === name);
    const applicable =
      (only.length === 0 || selectedCategories.has(name)) &&
      (ofCategory.length > 0 || APPLICABILITY[name](context));
    const grade: Grade =
      applicable ?
        gradeFromCounts({
          errors: ofCategory.filter((finding) => finding.severity === 'error')
            .length,
          infos: ofCategory.filter((finding) => finding.severity === 'info')
            .length,
          structural: ofCategory.some((finding) =>
            structuralIds.has(finding.rule_id)
          ),
          warnings: ofCategory.filter(
            (finding) => finding.severity === 'warning'
          ).length,
        })
      : 'n/a';

    // eslint-disable-next-line perfectionist/sort-objects -- the printed key order is part of the report contract
    return {name, grade};
  });

  return {
    /* eslint-disable perfectionist/sort-objects -- the printed key order is part of the report contract */
    scope: options.scope,
    categories,
    overall: overallGrade(categories.map((category) => category.grade)),
    findings: findings.toSorted(compareFindings),
    upstream: upstream.toSorted(compareFindings),
    suppressed: suppressed.toSorted(compareFindings),
    inventory: projectFiles
      .map((file) => ({
        path: file.path,
        kinds: file.kinds,
        words: file.words,
        lines: file.lines,
        model: file.model,
        ownership: file.ownership,
        path_scoped: file.pathScoped,
      }))
      .toSorted((a, b) => compareBytes(a.path, b.path)),
    /* eslint-enable perfectionist/sort-objects */
  };
};

type ParsedArguments = {
  configPath: string | undefined;
  enforce: string[];
  failOn: Severity;
  only: string[];
  root: string | undefined;
  scope: 'adopter' | 'all';
};

type ParseResult =
  {message: string; ok: false} | {ok: true; options: ParsedArguments};

const VALUE_FLAGS: ReadonlySet<string> = new Set([
  '--config',
  '--enforce',
  '--fail-on',
  '--only',
  '--root',
  '--scope',
]);

/** Stores one flag's value; returns the message when the value is not allowed. */
const applyFlag = (
  options: ParsedArguments,
  flag: string,
  value: string
): string | undefined => {
  if (flag === '--config') options.configPath = value;
  else if (flag === '--enforce') options.enforce.push(value);
  else if (flag === '--only') options.only.push(value);
  else if (flag === '--root') options.root = value;
  else if (flag === '--fail-on') {
    if (!['error', 'info', 'warning'].includes(value)) {
      return '--fail-on must be error, warning or info';
    }
    options.failOn = value as Severity;
  } else if (value === 'adopter' || value === 'all') options.scope = value;
  else return '--scope must be adopter or all';

  return undefined;
};

const parseArguments = (args: readonly string[]): ParseResult => {
  const options: ParsedArguments = {
    configPath: undefined,
    enforce: [],
    failOn: 'error',
    only: [],
    root: undefined,
    scope: 'adopter',
  };
  let index = 0;

  while (index < args.length) {
    const flag = args[index] ?? '';

    index += 1;

    // `--json` is accepted for symmetry with the other subcommands; JSON is the
    // only output format.
    if (flag !== '--json') {
      if (!VALUE_FLAGS.has(flag)) {
        return {message: `unknown argument: ${flag}`, ok: false};
      }

      const taken = takeNonFlagValue(args, index, flag);

      if (!taken.ok) return {message: taken.message, ok: false};
      index += 1;

      const problem = applyFlag(options, flag, taken.value);

      if (problem !== undefined) return {message: problem, ok: false};
    }
  }

  return {ok: true, options};
};

const defaultRoot = (): string => {
  try {
    return resolveRepoRoot(process.cwd());
  } catch {
    return process.cwd();
  }
};

/** Exit 1 when a finding reaches `failOn`, or a warning-or-worse matches an `--enforce` selector. */
export const exitCodeFor = (
  report: CheckReport,
  failOn: Severity,
  enforce: readonly string[]
): number => {
  const failing = report.findings.some(
    (finding) =>
      SEVERITY_RANK[finding.severity] >= SEVERITY_RANK[failOn] ||
      (SEVERITY_RANK[finding.severity] >= SEVERITY_RANK.warning &&
        enforce.some((selector) => matchesSelector(selector, finding.rule_id)))
  );

  return failing ? 1 : EXIT_CODES.OK;
};

const usageError = (message: string): number => {
  structuredError({
    code: 'invalid_arguments',
    message,
    subcommand: 'fitness check',
  });

  return EXIT_CODES.INVALID_ARGUMENTS;
};

/** `gaia fitness check`: prints one report and exits per the findings. */
export const run = (args: readonly string[]): number => {
  const parsed = parseArguments(args);

  if (!parsed.ok) return usageError(parsed.message);

  const {configPath, enforce, failOn, only, root, scope} = parsed.options;

  for (const selector of [...enforce, ...only]) {
    if (!RULE_CATALOG.some((rule) => ruleMatches(rule, selector))) {
      return usageError(`${selector} matches no rule id or alias`);
    }
  }

  const resolvedRoot = path.resolve(root ?? defaultRoot());

  try {
    const report = runCheck({configPath, only, root: resolvedRoot, scope});

    process.stdout.write(`${JSON.stringify(redactDeep(report), null, 2)}\n`);

    return exitCodeFor(report, failOn, enforce);
  } catch (error: unknown) {
    structuredError({
      code: 'could_not_run',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'fitness check',
    });

    return EXIT_CODES.COULD_NOT_RUN;
  }
};
