import {readFileSync} from 'node:fs';
import path from 'node:path';
import {HARNESS_CODE_LINE_BUDGET} from '../budgets.js';
import type {RuleContext} from '../context.js';
import {parseJsonFile} from '../context.js';
import {compareBytes, lineOf} from '../markdown.js';
import type {RawFinding, RuleDefinition} from '../types.js';
import {newlineCount} from './authoring-helpers.js';

/**
 * The file only GAIA's own repository tracks; the release never ships it.
 * Adopters cannot split the harness files GAIA ships them, so the line limit
 * runs only where this marker is tracked.
 */
export const MAINTAINER_MARKER_PATH =
  '.claude/rules/maintainers/harness-triage-threshold.md';

/**
 * The grandfathered files and their ceilings. Read from the checkout, not the
 * base branch the CI lint takes its suppressions from: a pull request that
 * splits or grows a grandfathered file updates its entry in the same diff.
 */
export const CEILINGS_PATH = '.claude/maintainers/line-limit-ceilings.json';

const HARNESS_ROOTS = ['.claude/', '.gaia/', '.github/', 'frontend/.claude/'];

const CODE_FILE = /\.(?:bash|cjs|js|mjs|sh|ts)$/;

const WORKFLOW_FILE = /^\.github\/(?:actions|workflows)\/.+\.ya?ml$/;

const TEST_DIRECTORY =
  /(?:^|\/)(?:__snapshots__|__tests__|fixtures|test|test-fixtures|tests)\//;

const TEST_FILE =
  /(?:\.test\.ts|[.-]fixtures?\.ts|(?:^|\/)(?:fixtures|test-support)\.ts)$/;

const isInScope = (relative: string): boolean =>
  HARNESS_ROOTS.some((root) => relative.startsWith(root)) &&
  (CODE_FILE.test(relative) || WORKFLOW_FILE.test(relative)) &&
  !TEST_DIRECTORY.test(relative) &&
  !TEST_FILE.test(relative);

type Ceilings = {
  entries: ReadonlyMap<string, number>;
  problem: RawFinding | undefined;
  text: string;
};

const ceilingsProblem = (message: string): RawFinding => ({
  file: CEILINGS_PATH,
  line: 1,
  message: `${message}, so it grandfathers no file.`,
  remediation:
    'Make it a JSON object whose "ceilings" maps each grandfathered path to a positive whole line count.',
});

const readCeilings = (context: RuleContext): Ceilings => {
  if (!context.allTrackedPaths.has(CEILINGS_PATH)) {
    return {entries: new Map(), problem: undefined, text: ''};
  }

  const text = readFileSync(
    path.join(context.rootDirectory, CEILINGS_PATH),
    'utf8'
  );
  const {parsed, parseError} = parseJsonFile(CEILINGS_PATH, text);
  const unusable = (message: string): Ceilings => ({
    entries: new Map(),
    problem: ceilingsProblem(message),
    text,
  });

  if (parseError !== undefined) {
    return unusable(`The ceilings file is not JSON (${parseError})`);
  }

  const ceilings = (parsed as null | {ceilings?: unknown})?.ceilings;

  if (
    ceilings === null ||
    typeof ceilings !== 'object' ||
    Array.isArray(ceilings)
  ) {
    return unusable('The ceilings file has no "ceilings" object');
  }

  const entries = new Map<string, number>();

  for (const [file, ceiling] of Object.entries(ceilings)) {
    if (!Number.isInteger(ceiling) || (ceiling as number) <= 0) {
      return unusable(`The ceiling for ${file} is not a positive whole number`);
    }

    entries.set(file, ceiling as number);
  }

  return {entries, problem: undefined, text};
};

const lineCountOf = (context: RuleContext, relative: string): number =>
  newlineCount(
    readFileSync(path.join(context.rootDirectory, relative), 'utf8')
  );

/** In-scope tracked files over the budget, with their line counts. */
const measuredOffenders = (context: RuleContext): Map<string, number> => {
  const offenders = new Map<string, number>();
  const inScope: readonly string[] = [...context.allTrackedPaths].filter(
    isInScope
  );

  for (const relative of inScope.toSorted(compareBytes)) {
    const lines = lineCountOf(context, relative);

    if (lines > HARNESS_CODE_LINE_BUDGET) offenders.set(relative, lines);
  }

  return offenders;
};

const entryLine = (text: string, file: string): number => {
  const index = text.indexOf(JSON.stringify(file));

  return index === -1 ? 1 : lineOf(text, index);
};

/** Runs `check` only where the maintainer marker is tracked. */
const maintainerOnly =
  (check: (context: RuleContext) => RawFinding[]) =>
  (context: RuleContext): RawFinding[] =>
    context.allTrackedPaths.has(MAINTAINER_MARKER_PATH) ? check(context) : [];

const checkMaxLines = (context: RuleContext): RawFinding[] => {
  const ceilings = readCeilings(context);
  const findings: RawFinding[] =
    ceilings.problem === undefined ? [] : [ceilings.problem];

  for (const [file, lines] of measuredOffenders(context)) {
    const ceiling = ceilings.entries.get(file);

    if (ceiling === undefined) {
      findings.push({
        file,
        line: 1,
        message: `The file is ${lines} lines, over the ${HARNESS_CODE_LINE_BUDGET} line limit for harness code, and has no grandfathered ceiling.`,
        remediation: `Split it along its seams to ${HARNESS_CODE_LINE_BUDGET} lines or fewer.`,
      });
    } else if (lines > ceiling) {
      findings.push({
        file,
        line: 1,
        message: `The file is ${lines} lines, past its grandfathered ceiling of ${ceiling}.`,
        remediation: `Split it, or raise its entry in ${CEILINGS_PATH} to "${file}": ${lines} and say why in the pull request.`,
      });
    }
  }

  return findings;
};

const checkStaleCeilings = (context: RuleContext): RawFinding[] => {
  const ceilings = readCeilings(context);
  const findings: RawFinding[] = [];

  const grandfathered: readonly string[] = [...ceilings.entries.keys()];

  for (const file of grandfathered.toSorted(compareBytes)) {
    let reason: string | undefined;

    if (!context.allTrackedPaths.has(file) || !isInScope(file)) {
      reason = `${file} is not a tracked harness code file`;
    } else {
      const lines = lineCountOf(context, file);

      if (lines <= HARNESS_CODE_LINE_BUDGET) {
        reason = `${file} is ${lines} lines, within the ${HARNESS_CODE_LINE_BUDGET} line limit`;
      }
    }

    if (reason !== undefined) {
      findings.push({
        file: CEILINGS_PATH,
        line: entryLine(ceilings.text, file),
        message: `${reason}, so its ceiling is stale.`,
        remediation: `Remove the "${file}" entry so the file is held to the limit again.`,
      });
    }
  }

  return findings;
};

export const LINE_LIMIT_RULES: readonly RuleDefinition[] = [
  {
    appliesTo: ['all'],
    category: 'authoring',
    check: maintainerOnly(checkMaxLines),
    detection: `GAIA's own repository only: a harness code file over ${HARNESS_CODE_LINE_BUDGET} lines with no ceiling in ${CEILINGS_PATH}, or past its ceiling.`,
    ruleId: 'authoring.harness.max-lines',
    severity: 'error',
  },
  {
    appliesTo: ['all'],
    category: 'authoring',
    check: maintainerOnly(checkStaleCeilings),
    detection: `GAIA's own repository only: a ${CEILINGS_PATH} entry whose file is gone or back within ${HARNESS_CODE_LINE_BUDGET} lines.`,
    ruleId: 'authoring.harness.ceiling-stale',
    severity: 'warning',
  },
];
