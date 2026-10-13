/**
 * Compares the setup feature list against the decision records and reports
 * the ids nobody has decided yet. Read-only: `/update-gaia`, `/setup-gaia`
 * and the statusline read this to learn what a project or machine is owed.
 *
 * A record counts only for an id the list holds, in that id's own scope, with
 * a known decision value. Anything else (an unlisted id, a bad value, a
 * machine id recorded in the project file) reads as undecided or is ignored.
 */
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {readProjectConfig} from '../schemas/project-config.js';
import {isSetupDecision} from '../schemas/setup-features.js';
import type {SetupDecision, SetupFeature} from '../schemas/setup-features.js';
import {structuredError} from '../stderr.js';
import {resolveMainWorktreeRoot} from '../util/main-root.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {readSetupFeatures, setupFeaturesPath} from './util/setup-features.js';
import {readStateFile} from './util/state-file.js';

const SUBCOMMAND = 'setup drift';

const HELP_TEXT = `Usage: gaia setup drift [--json] [--features <path>]

  List the setup features in .gaia/setup-features.json (or <path>) that have
  no decision recorded. Project scope ids are read from .gaia/project.json,
  machine scope ids from .gaia/local/setup-state.json.

  Without --json, prints one "<id> <action>" line per undecided feature, or
  "no undecided setup features". With --json, prints one JSON line holding
  the file read, the recorded counts, the decided map and the undecided list.
  Exits 0 whenever it could compare.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type Action = 'apply' | 'ask' | 'setup';

type RunOptions = {
  cwd?: string;
};

const hasOwn = (record: Record<string, unknown>, key: string): boolean =>
  Object.hasOwn(record, key);

const validDecisions = (
  entries: Record<string, unknown> | undefined
): Record<string, SetupDecision> => {
  const valid: Record<string, SetupDecision> = {};

  for (const [id, value] of Object.entries(entries ?? {})) {
    if (isSetupDecision(value)) valid[id] = value;
  }

  return valid;
};

const actionFor = (feature: SetupFeature, hasAnyRecord: boolean): Action => {
  if (!feature.standalone || !hasAnyRecord) return 'setup';

  return feature.required ? 'apply' : 'ask';
};

type ParsedArguments = {
  featuresArgument?: string;
  json: boolean;
};

/** Returns the parsed flags, or an exit code after printing why they are refused. */
const parseArguments = (
  argv: readonly string[]
): {exitCode: number} | {parsed: ParsedArguments} => {
  const parsed: ParsedArguments = {json: false};
  const remaining = [...argv];

  while (remaining.length > 0) {
    const token = remaining.shift() as string;

    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return {exitCode: EXIT_CODES.OK};
    }

    if (token === '--json') {
      parsed.json = true;
    } else if (token === '--features' && remaining.length > 0) {
      parsed.featuresArgument = remaining.shift();
    } else {
      structuredError({
        code: 'invalid_arguments',
        message:
          token === '--features' ?
            '--features requires a path'
          : `unknown argument: ${token}`,
        subcommand: SUBCOMMAND,
      });

      return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
    }
  }

  return {parsed};
};

type Records = {
  machine: Record<string, SetupDecision>;
  project: Record<string, SetupDecision>;
};

/** Returns the valid decision records of both scopes, or an exit code after printing why they cannot be read. */
const readRecords = (
  repoRoot: string,
  mainRoot: string
): {exitCode: number} | {records: Records} => {
  const projectConfig = readProjectConfig(repoRoot);

  if (projectConfig.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      message: projectConfig.error,
      subcommand: SUBCOMMAND,
    });

    return {exitCode: EXIT_CODES.CONFIG_INVALID};
  }

  let machineEntries: Record<string, unknown> | undefined;

  try {
    machineEntries = readStateFile(mainRoot)?.decisions;
  } catch (error) {
    structuredError({
      code: 'state_malformed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return {exitCode: EXIT_CODES.CONFIG_INVALID};
  }

  return {
    records: {
      machine: validDecisions(machineEntries),
      project: validDecisions(
        projectConfig.status === 'ok' ?
          projectConfig.config.setup_decisions
        : undefined
      ),
    },
  };
};

const formatPlain = (
  undecided: readonly {action: Action; id: string}[]
): string => {
  if (undecided.length === 0) return 'no undecided setup features\n';

  const lines = undecided.map((entry) => `${entry.id} ${entry.action}`);

  return `${lines.join('\n')}\n`;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const cwd = options.cwd ?? process.cwd();
  const parsedResult = parseArguments(argv);

  if ('exitCode' in parsedResult) return parsedResult.exitCode;

  const {parsed} = parsedResult;

  let repoRoot: string;
  let mainRoot: string;

  try {
    repoRoot = resolveRepoRoot(cwd);
    mainRoot = resolveMainWorktreeRoot(cwd);
  } catch (error) {
    structuredError({
      code: 'not_a_git_repo',
      message: `gaia setup drift must run inside a git repository: ${error instanceof Error ? error.message : String(error)}`,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const featuresPath =
    parsed.featuresArgument === undefined ?
      setupFeaturesPath(repoRoot)
    : path.resolve(cwd, parsed.featuresArgument);

  let features: readonly SetupFeature[];

  try {
    features = readSetupFeatures(featuresPath).features;
  } catch (error) {
    structuredError({
      code: 'setup_features_invalid',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const recordsResult = readRecords(repoRoot, mainRoot);

  if ('exitCode' in recordsResult) return recordsResult.exitCode;

  const {records} = recordsResult;

  const recorded = {machine: 0, project: 0};
  const decided: Record<string, SetupDecision> = {};

  for (const feature of features) {
    const scoped = records[feature.scope];
    const value = hasOwn(scoped, feature.id) ? scoped[feature.id] : undefined;

    if (value !== undefined) {
      decided[feature.id] = value;
      recorded[feature.scope] += 1;
    }
  }

  const hasAnyRecord = recorded.project + recorded.machine > 0;
  const undecided = features
    .filter((feature) => !hasOwn(decided, feature.id))
    .map((feature) => ({
      action: actionFor(feature, hasAnyRecord),
      admin: feature.admin,
      id: feature.id,
      reference: feature.reference,
      required: feature.required,
      scope: feature.scope,
      standalone: feature.standalone,
    }));

  process.stdout.write(
    parsed.json ?
      `${JSON.stringify({decided, features: featuresPath, recorded, undecided})}\n`
    : formatPlain(undecided)
  );

  return EXIT_CODES.OK;
};
