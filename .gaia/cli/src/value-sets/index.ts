import {takeNonFlagValue} from '../util/argv.js';
import type {Ts} from '../util/load-typescript.js';
import {loadTypescript} from '../util/load-typescript.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {findCandidates, findStrict} from './compare.js';
import {loadPolicy} from './policy.js';
import {readShellFile} from './read-shell.js';
import {readTypescriptFile} from './read-typescript.js';
import {CANNOT_RUN_PREFIX, CLEAN_LINE, formatCandidates} from './report.js';
import {collectScope} from './scope.js';
import type {ScopeFile} from './scope.js';
import type {FileReading} from './types.js';

const EXIT_CLEAN = 0;
const EXIT_FINDINGS = 1;
const EXIT_CANNOT_RUN = 2;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const HELP_TEXT = `Usage: gaia value-sets [--candidates] [--config <path> | --policy-from <dir>]

  Fail when two value sets in this project's TypeScript or shell hold the same
  three or more values, or one hand-narrows another, unless a marker declares it.

  --candidates         Print the weaker matches (two-value duplicates, two-value
                       subsets, same-file subsets) as a JSON array and exit 0.
  --config <path>      Read exclusions from this file instead of
                       .gaia/value-sets.json.
  --policy-from <dir>  Read .gaia/value-sets.json, .gaia/manifest.json and the
                       maintainer marker file only from <dir>.

  Exit 0 clean, 1 findings, 2 cannot run.
`;

export type ValueSetsDependencies = {
  cwd: string;
  loadTypescript: (projectDirectory: string) => Ts | undefined;
  writeErr: (text: string) => void;
  writeOut: (text: string) => void;
};

type ParsedArguments =
  | {
      candidates: boolean;
      configPath?: string;
      ok: true;
      policyFrom?: string;
    }
  | {message: string; ok: false};

const VALUE_FLAGS = new Set(['--config', '--policy-from']);

const parseArguments = (argv: readonly string[]): ParsedArguments => {
  const seen = new Map<string, string>();

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] ?? '';
    const isValueFlag = VALUE_FLAGS.has(token);

    if (token !== '--candidates' && !isValueFlag)
      return {message: `unknown argument ${token}`, ok: false};
    if (seen.has(token))
      return {message: `${token} given more than once`, ok: false};

    if (isValueFlag) {
      const taken = takeNonFlagValue(argv, index + 1, token);

      if (!taken.ok) return taken;
      index += 1;
      seen.set(token, taken.value);
    } else {
      seen.set(token, '');
    }
  }

  const configPath = seen.get('--config');
  const policyFrom = seen.get('--policy-from');

  if (configPath !== undefined && policyFrom !== undefined) {
    return {
      message: '--config and --policy-from cannot be used together',
      ok: false,
    };
  }

  return {
    candidates: seen.has('--candidates'),
    configPath,
    ok: true,
    policyFrom,
  };
};

const resolveRoot = (cwd: string): string | undefined => {
  try {
    return resolveRepoRoot(cwd) || undefined;
  } catch {
    return undefined;
  }
};

type ReadResult =
  {ok: false; reason: string} | {ok: true; readings: FileReading[]};

const readScope = (
  files: readonly ScopeFile[],
  load: ValueSetsDependencies['loadTypescript'],
  root: string
): ReadResult => {
  const ts =
    files.some((file) => file.language === 'typescript') ?
      load(root)
    : undefined;
  const readings: FileReading[] = [];

  for (const file of files) {
    if (file.language === 'shell') {
      readings.push(readShellFile(file.path, file.text));
    } else {
      if (ts === undefined) {
        return {
          ok: false,
          reason:
            'the typescript package could not be loaded from this project',
        };
      }

      const result = readTypescriptFile(ts, file.path, file.text);

      if (!result.ok) {
        return {
          ok: false,
          reason: `${file.path} has syntax errors at line ${result.syntaxErrorLine}`,
        };
      }
      readings.push(result.reading);
    }
  }

  return {ok: true, readings};
};

/** Testable core: 0 clean, 1 findings, 2 cannot run or bad arguments. */
export const runValueSets = (
  argv: readonly string[],
  dependencies: ValueSetsDependencies
): number => {
  const {cwd, writeErr, writeOut} = dependencies;

  const cannotRun = (reason: string): number => {
    writeErr(`${CANNOT_RUN_PREFIX}${reason}\n`);

    return EXIT_CANNOT_RUN;
  };

  if (argv.some((token) => HELP_TOKENS.has(token))) {
    writeOut(HELP_TEXT);

    return EXIT_CLEAN;
  }

  const parsed = parseArguments(argv);

  if (!parsed.ok) return cannotRun(parsed.message);

  const root = resolveRoot(cwd);

  if (root === undefined) return cannotRun('not inside a git work tree');

  const policyResult = loadPolicy({
    configPath: parsed.configPath,
    cwd,
    policyFrom: parsed.policyFrom,
    root,
  });

  if (!policyResult.ok) return cannotRun(policyResult.reason);

  const {policy} = policyResult;
  const scope = collectScope({exclude: policy.exclude, root});

  if (!scope.ok) return cannotRun(scope.reason);

  const read = readScope(scope.files, dependencies.loadTypescript, root);

  if (!read.ok) return cannotRun(read.reason);

  const {readings} = read;

  if (parsed.candidates) {
    writeOut(formatCandidates(findCandidates(readings, policy.harnessPaths)));

    return EXIT_CLEAN;
  }

  const findings = findStrict(readings, policy.harnessPaths);

  if (findings.length === 0) {
    writeOut(`${CLEAN_LINE}\n`);

    return EXIT_CLEAN;
  }

  writeOut(findings.map((line) => `${line}\n`).join(''));

  return EXIT_FINDINGS;
};

/** `gaia value-sets [--candidates] [--config <path> | --policy-from <dir>]` */
export const run = (argv: string[]): number =>
  runValueSets(argv, {
    cwd: process.cwd(),
    loadTypescript: (directory) => loadTypescript(directory, {isGated: true}),
    writeErr: (text) => process.stderr.write(text),
    writeOut: (text) => process.stdout.write(text),
  });
