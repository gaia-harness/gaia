/**
 * `gaia update merge-workspace --baseline <file> --latest <file> --current <file>`
 * handler.
 *
 * Field-aware verdict oracle for `pnpm-workspace.yaml`, the YAML analog of
 * the `package.json` step in `/update-gaia`. The file is mixed: GAIA-authored
 * supply-chain / resolution settings plus adopter-extensible `overrides` and
 * `allowBuilds` maps. A whole-file three-way merge produces a full-file
 * conflict patch the moment an adopter adds a single override, so this command
 * merges at key / map-entry granularity instead.
 *
 * It is READ-ONLY: it parses the baseline, latest and current YAML files with
 * js-yaml and emits a verdict report (JSON with --json). It never writes the
 * workspace file; the `/update-gaia` skill applies `applied[]` with the Edit
 * tool so comments, key order, and quote style survive (js-yaml `dump` would
 * strip every comment).
 *
 * The verdict table, the deferred-baseline override and the conflict
 * recommendation are shared with `merge-package` and `merge-audit-ci`: see
 * `field-verdict.ts`.
 *
 * Object-map dispatch and no-switch style per the project's typescript rules.
 */
import {load as parseYaml} from 'js-yaml';
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
import type {FieldMergeReport, Triple, VerdictItem} from './field-verdict.js';

const HELP_TEXT = `Usage: gaia update merge-workspace --baseline <file> --latest <file> --current <file> [--deferred-baseline <key>=<file>]... [--json]

  Field-aware three-way verdict for pnpm-workspace.yaml. Reads three YAML
  files (baseline / latest tarball + working-tree current), classifies the
  GAIA-managed keys and the adopter-shared overrides / allowBuilds maps, and
  reports {applied, conflicts, alreadyLatest, keptRemoved, removedUpstream}
  (JSON with --json, a human summary otherwise).

  --deferred-baseline <key>=<file> reads that key's baseline from <file>
  instead of --baseline, so a key deferred at an earlier bundle is merged
  against it. <key> is section.key (or the bare key). Repeatable.

  Read-only: never writes the workspace file. The /update-gaia skill applies
  the 'applied' entries with the Edit tool to preserve comments and order.

  Exit codes:
    0  success
    1  user-correctable error (missing flag / file, malformed YAML)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

/**
 * GAIA-managed top-level keys, merged whole-value (the adopter's whole value
 * for the key is compared / applied as a unit; lists included).
 */
const MANAGED_WHOLE_VALUE_KEYS: readonly string[] = [
  'minimumReleaseAge',
  'minimumReleaseAgeStrict',
  'trustPolicy',
  'trustPolicyExclude',
  'minimumReleaseAgeExclude',
  'publicHoistPattern',
  'savePrefix',
  'strictPeerDependencies',
  'auditConfig',
];

/**
 * Adopter-shared map sections, merged per entry key. Adopter-only entries are
 * never visited (iteration is over baseline ∪ latest keys), so they are never
 * clobbered.
 */
const SHARED_MAP_SECTIONS: readonly string[] = ['overrides', 'allowBuilds'];

export type WorkspaceMergeReport = FieldMergeReport;

export type WorkspaceVerdictItem = VerdictItem;

type DeferredPaths = ReadonlyMap<string, string>;

type Flags = {
  baseline: string;
  current: string;
  deferred: DeferredPaths;
  json: boolean;
  latest: string;
};

type ParsedFlagsResult =
  {flags: Flags; ok: true} | {message: string; ok: false};

const VALUE_FLAGS: ValueFlagMap<keyof Flags> = {
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

const buildManagedKeyTriples = (
  baseline: Record<string, unknown>,
  latest: Record<string, unknown>,
  current: Record<string, unknown>
): Triple[] =>
  MANAGED_WHOLE_VALUE_KEYS.map((key) => ({
    a: lookup(current, key),
    b: lookup(baseline, key),
    key,
    kind: 'key' as const,
    l: lookup(latest, key),
    versionValued: false,
  }));

type MapEntryTriplesArgs = {
  baseline: Record<string, unknown>;
  current: Record<string, unknown>;
  latest: Record<string, unknown>;
  section: string;
};

const buildMapEntryTriples = ({
  baseline,
  current,
  latest,
  section,
}: MapEntryTriplesArgs): Triple[] => {
  const baseSection = asRecord(baseline[section]);
  const latestSection = asRecord(latest[section]);
  const currentSection = asRecord(current[section]);
  const entryKeys = [
    ...new Set([...Object.keys(baseSection), ...Object.keys(latestSection)]),
  ];

  return entryKeys.map((key) => ({
    a: lookup(currentSection, key),
    b: lookup(baseSection, key),
    key,
    kind: 'entry' as const,
    l: lookup(latestSection, key),
    section,
    versionValued: section === 'overrides',
  }));
};

const buildTriples =
  (latest: Record<string, unknown>, current: Record<string, unknown>) =>
  (baseline: Record<string, unknown>): Triple[] => [
    ...buildManagedKeyTriples(baseline, latest, current),
    ...SHARED_MAP_SECTIONS.flatMap((section) =>
      buildMapEntryTriples({baseline, current, latest, section})
    ),
  ];

type LoadResult =
  | {
      code: 'workspace_file_missing' | 'workspace_parse_failed';
      message: string;
      ok: false;
    }
  | {ok: true; root: Record<string, unknown>};

const loadWorkspace = (absPath: string, role: string): LoadResult => {
  if (!existsSync(absPath)) {
    return {
      code: 'workspace_file_missing',
      message: `${role} workspace file not found: ${absPath}`,
      ok: false,
    };
  }

  let parsed: unknown;

  try {
    parsed = parseYaml(readFileSync(absPath, 'utf8'));
  } catch (error) {
    return {
      code: 'workspace_parse_failed',
      message: `${role} workspace file is not valid YAML (${absPath}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      ok: false,
    };
  }

  return {ok: true, root: asRecord(parsed)};
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
      subcommand: 'update merge-workspace',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const inputs: [string, string][] = [
    ['baseline', resolvePath(cwd, parsed.flags.baseline)],
    ['latest', resolvePath(cwd, parsed.flags.latest)],
    ['current', resolvePath(cwd, parsed.flags.current)],
  ];

  const roots: Record<string, unknown>[] = [];
  const deferredRoots = new Map<string, Record<string, unknown>>();
  const deferredInputs: [string, string, string][] = [
    ...parsed.flags.deferred,
  ].map(([key, file]) => [
    key,
    `deferred baseline ${key}`,
    resolvePath(cwd, file),
  ]);

  for (const [key, role, absPath] of [
    ...inputs.map(([name, file]): [string, string, string] => ['', name, file]),
    ...deferredInputs,
  ]) {
    const result = loadWorkspace(absPath, role);

    if (!result.ok) {
      structuredError({
        code: result.code,
        message: result.message,
        subcommand: 'update merge-workspace',
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
      renderHumanReport('gaia update merge-workspace', report)
    );
  }

  return EXIT_CODES.OK;
};
