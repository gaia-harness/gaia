/**
 * `gaia update merge-package --baseline <file> --latest <file> --current <file>`
 * handler.
 *
 * Field-aware verdict oracle for a `package.json`. Only the managed sections
 * are read: `dependencies`, `devDependencies`, `scripts` and `engines` per
 * entry, and `packageManager` as one value. Every other key (identity fields
 * included) belongs to the adopter and is never visited.
 *
 * It is READ-ONLY: it emits a verdict report (JSON with --json) and never
 * writes the file. The verdict table, the deferred-baseline override and the
 * conflict recommendation are shared with the other merge commands: see
 * `field-verdict.ts`.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {parseValueFlags} from '../util/parse-value-flags.js';
import type {ValueFlagMap} from '../util/parse-value-flags.js';
import {
  asRecord,
  classifyTriples,
  extractDeferredBaselines,
  lookup,
  renderHumanReport,
  triplesWithDeferred,
} from './field-verdict.js';
import type {Triple} from './field-verdict.js';

const HELP_TEXT = `Usage: gaia update merge-package --baseline <file> --latest <file> --current <file> [--deferred-baseline <key>=<file>]... [--json]

  Field-aware three-way verdict for a package.json. Reads three JSON files
  (baseline / latest tarball + working-tree current), classifies the
  dependencies, devDependencies, scripts and engines entries and the
  packageManager value, and reports {applied, conflicts, alreadyLatest,
  keptRemoved, removedUpstream} (JSON with --json, a human summary otherwise).

  --deferred-baseline <key>=<file> reads that key's baseline from <file>
  instead of --baseline, so a key deferred at an earlier bundle is merged
  against it. <key> is section.key (or packageManager). Repeatable.

  Read-only: never writes the file.

  Exit codes:
    0  success
    1  user-correctable error (missing flag / file, malformed JSON)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

/** Object sections merged per entry, and whether their values are versions. */
const ENTRY_SECTIONS: readonly {name: string; versionValued: boolean}[] = [
  {name: 'dependencies', versionValued: true},
  {name: 'devDependencies', versionValued: true},
  {name: 'scripts', versionValued: false},
  {name: 'engines', versionValued: true},
];

const WHOLE_VALUE_KEY = 'packageManager';

type Flags = {
  baseline: string;
  current: string;
  deferred: ReadonlyMap<string, string>;
  json: boolean;
  latest: string;
};

type ParsedFlagsResult =
  {flags: Flags; ok: true} | {message: string; ok: false};

const VALUE_FLAGS: ValueFlagMap<'baseline' | 'current' | 'latest'> = {
  '--baseline': 'baseline',
  '--current': 'current',
  '--latest': 'latest',
};

const parseFlags = (argv: readonly string[]): ParsedFlagsResult => {
  const split = extractDeferredBaselines(argv);

  if (!split.ok) return split;

  const parsed = parseValueFlags(split.rest, VALUE_FLAGS);

  if (!parsed.ok) return parsed;

  const {
    collected: {baseline, current, latest},
    json,
  } = parsed.state;

  if (baseline === undefined)
    return {message: '--baseline is required', ok: false};

  if (latest === undefined) return {message: '--latest is required', ok: false};

  if (current === undefined)
    return {message: '--current is required', ok: false};

  return {
    flags: {baseline, current, deferred: split.deferred, json, latest},
    ok: true,
  };
};

const buildTriples =
  (latest: Record<string, unknown>, current: Record<string, unknown>) =>
  (baseline: Record<string, unknown>): Triple[] => [
    {
      a: lookup(current, WHOLE_VALUE_KEY),
      b: lookup(baseline, WHOLE_VALUE_KEY),
      key: WHOLE_VALUE_KEY,
      kind: 'key',
      l: lookup(latest, WHOLE_VALUE_KEY),
      versionValued: true,
    },
    ...ENTRY_SECTIONS.flatMap(({name, versionValued}) => {
      const baseSection = asRecord(baseline[name]);
      const latestSection = asRecord(latest[name]);
      const currentSection = asRecord(current[name]);
      const entryKeys = [
        ...new Set([
          ...Object.keys(baseSection),
          ...Object.keys(latestSection),
        ]),
      ];

      return entryKeys.map((key) => ({
        a: lookup(currentSection, key),
        b: lookup(baseSection, key),
        key,
        kind: 'entry' as const,
        l: lookup(latestSection, key),
        section: name,
        versionValued,
      }));
    }),
  ];

type LoadResult =
  | {
      code: 'package_file_missing' | 'package_parse_failed';
      message: string;
      ok: false;
    }
  | {ok: true; root: Record<string, unknown>};

const loadPackage = (absPath: string, role: string): LoadResult => {
  if (!existsSync(absPath)) {
    return {
      code: 'package_file_missing',
      message: `${role} package.json not found: ${absPath}`,
      ok: false,
    };
  }

  try {
    return {
      ok: true,
      root: asRecord(JSON.parse(readFileSync(absPath, 'utf8'))),
    };
  } catch (error) {
    return {
      code: 'package_parse_failed',
      message: `${role} package.json is not valid JSON (${absPath}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      ok: false,
    };
  }
};

type RunOptions = {
  cwd?: string;
};

const resolvePath = (cwd: string, value: string): string =>
  path.isAbsolute(value) ? value : path.join(cwd, value);

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [firstArgument] = argv;

  if (firstArgument !== undefined && HELP_TOKENS.has(firstArgument)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'update merge-package',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const inputs: [string, string, string][] = [
    ['', 'baseline', resolvePath(cwd, parsed.flags.baseline)],
    ['', 'latest', resolvePath(cwd, parsed.flags.latest)],
    ['', 'current', resolvePath(cwd, parsed.flags.current)],
  ];
  const deferredInputs: [string, string, string][] = [
    ...parsed.flags.deferred,
  ].map(([key, file]) => [
    key,
    `deferred baseline ${key}`,
    resolvePath(cwd, file),
  ]);

  const roots: Record<string, unknown>[] = [];
  const deferredRoots = new Map<string, Record<string, unknown>>();

  for (const [key, role, absPath] of [...inputs, ...deferredInputs]) {
    const result = loadPackage(absPath, role);

    if (!result.ok) {
      structuredError({
        code: result.code,
        message: result.message,
        subcommand: 'update merge-package',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    if (key === '') {
      roots.push(result.root);
    } else {
      deferredRoots.set(key, result.root);
    }
  }

  const [baseline, latest, current] = roots as [
    Record<string, unknown>,
    Record<string, unknown>,
    Record<string, unknown>,
  ];
  const report = classifyTriples(
    triplesWithDeferred(buildTriples(latest, current), baseline, deferredRoots)
  );

  if (parsed.flags.json) {
    process.stdout.write(`${JSON.stringify(report)}\n`);
  } else {
    process.stdout.write(
      renderHumanReport('gaia update merge-package', report)
    );
  }

  return EXIT_CODES.OK;
};
