/**
 * Records one setup decision (`applied`, `declined` or `not-applicable`) for
 * an id in the shipped feature list. This is the only writer of decision
 * records: project-scope ids go to `.gaia/project.json` `setup_decisions`,
 * machine-scope ids to `.gaia/local/setup-state.json` `decisions`.
 *
 * Each write merges the one entry onto what is already there, so every other
 * recorded id (listed or not) survives. Refusals write nothing.
 */
import {EXIT_CODES} from '../exit.js';
import {readProjectConfig} from '../schemas/project-config.js';
import {isSetupDecision, SETUP_DECISIONS} from '../schemas/setup-features.js';
import {structuredError} from '../stderr.js';
import {resolveMainWorktreeRoot} from '../util/main-root.js';
import {
  ProjectConfigError,
  updateProjectConfig,
} from '../util/project-config-write.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {readSetupFeatures, setupFeaturesPath} from './util/setup-features.js';
import {readStateFile, writeStateFile} from './util/state-file.js';
import type {SetupState} from './util/state-file.js';

const SUBCOMMAND = 'setup record';

const HELP_TEXT = `Usage: gaia setup record <id> <${SETUP_DECISIONS.join('|')}>

  Record a setup decision for an id in .gaia/setup-features.json. A project
  scope id lands in .gaia/project.json setup_decisions; a machine scope id
  lands in .gaia/local/setup-state.json decisions. Every other recorded entry
  is kept. Refuses, writing nothing, on an id the list does not hold, a value
  outside the three, or a malformed list or record file.

  Prints {"id", "scope", "decision", "previous"} on success.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
  /** Override "now" for deterministic tests. */
  now?: () => Date;
};

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

type Outcome = {exitCode: number} | {previous: null | string};

const recordProject = (
  repoRoot: string,
  id: string,
  decision: string
): Outcome => {
  const existing = readProjectConfig(repoRoot);

  if (existing.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      message: existing.error,
      subcommand: SUBCOMMAND,
    });

    return {exitCode: EXIT_CODES.CONFIG_INVALID};
  }

  const rawDecisions =
    existing.status === 'ok' ? existing.raw.setup_decisions : undefined;
  const current = isPlainObject(rawDecisions) ? rawDecisions : {};
  const prior = current[id];

  try {
    // updateProjectConfig merges shallowly, so the whole decisions object goes
    // in with the one entry set; passing only the entry would drop the others.
    updateProjectConfig(repoRoot, {
      setup_decisions: {...current, [id]: decision},
    });
  } catch (error) {
    if (error instanceof ProjectConfigError) {
      structuredError({
        code: 'config_malformed',
        message: error.message,
        subcommand: SUBCOMMAND,
      });

      return {exitCode: EXIT_CODES.CONFIG_INVALID};
    }

    structuredError({
      code: 'project_config_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return {exitCode: EXIT_CODES.STORAGE_INACCESSIBLE};
  }

  return {previous: typeof prior === 'string' ? prior : null};
};

const recordMachine = (
  mainRoot: string,
  entry: {decision: string; id: string},
  isoNow: string
): Outcome => {
  const {decision, id} = entry;
  let state: null | SetupState;

  try {
    state = readStateFile(mainRoot);
  } catch (error) {
    structuredError({
      code: 'state_malformed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return {exitCode: EXIT_CODES.CONFIG_INVALID};
  }

  const next: SetupState = state ?? {
    completed_at: null,
    completed_steps: [],
    started_at: isoNow,
    version: 1,
  };
  const decisions = next.decisions ?? {};
  const previous = decisions[id] ?? null;
  next.decisions = {...decisions, [id]: decision};

  try {
    writeStateFile(mainRoot, next);
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return {exitCode: EXIT_CODES.STORAGE_INACCESSIBLE};
  }

  return {previous};
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const first = argv[0];

  if (first === undefined || HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return first === undefined ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  if (argv.length !== 2) {
    structuredError({
      code: 'invalid_arguments',
      message: 'record requires exactly <id> <decision>',
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const id = first;
  const decision = argv[1];

  if (!isSetupDecision(decision)) {
    structuredError({
      code: 'invalid_decision',
      message: `unrecognized decision: ${String(decision)}. Supported: ${SETUP_DECISIONS.join(', ')}`,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  let repoRoot: string;
  let mainRoot: string;

  try {
    repoRoot = resolveRepoRoot(cwd);
    mainRoot = resolveMainWorktreeRoot(cwd);
  } catch (error) {
    structuredError({
      code: 'not_a_git_repo',
      message: `gaia setup record must run inside a git repository: ${error instanceof Error ? error.message : String(error)}`,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let feature;

  try {
    feature = readSetupFeatures(setupFeaturesPath(repoRoot)).features.find(
      (candidate) => candidate.id === id
    );
  } catch (error) {
    structuredError({
      code: 'setup_features_invalid',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (feature === undefined) {
    structuredError({
      code: 'unknown_setup_feature',
      message: `${id} is not in .gaia/setup-features.json`,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const outcome =
    feature.scope === 'project' ?
      recordProject(repoRoot, id, decision)
    : recordMachine(
        mainRoot,
        {decision, id},
        (options.now ?? (() => new Date()))().toISOString()
      );

  if ('exitCode' in outcome) return outcome.exitCode;

  process.stdout.write(
    `${JSON.stringify({decision, id, previous: outcome.previous, scope: feature.scope})}\n`
  );

  return EXIT_CODES.OK;
};
