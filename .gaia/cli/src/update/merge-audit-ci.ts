/**
 * `gaia update merge-audit-ci --baseline <file> --latest <file> --current <file>`
 * handler.
 *
 * Field-aware verdict oracle for `.gaia/audit-ci.yml`, the audit analog of the
 * `pnpm-workspace.yaml` step in `/update-gaia`. The one managed section is the
 * `auditors` roster list, GAIA-authored **and** adopter-extensible at once (a
 * member GAIA ships alongside any member an adopter has added of their own). A
 * whole-file three-way merge produces a full-file conflict patch the moment an
 * adopter adds one roster member, so this command merges at key / per-entry
 * granularity instead. A top-level key an older version of the file carried
 * (the retired scalar knobs among them) is neither applied nor flagged: only
 * the roster is read, so the adopter's copy of any other key is never visited.
 *
 * It is READ-ONLY: it parses the baseline, latest and current YAML files with
 * js-yaml and emits a verdict report (JSON with --json). It never writes the
 * file; the `/update-gaia` skill applies `applied[]` with the Edit tool so
 * comments, key order, and quote style survive.
 *
 * The verdict table, the deferred-baseline override and the conflict
 * recommendation are shared with `merge-package` and `merge-workspace`: see
 * `field-verdict.ts`. The roster is keyed on member `name` exactly (not
 * case-folded: a member name is an agent filename) and iterated keys(B) ∪
 * keys(L), so a member the adopter added of their own is never visited.
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
  absent,
  asRecord,
  classifyTriples,
  extractDeferredBaselines,
  renderHumanReport,
  triplesWithDeferred,
} from './field-verdict.js';
import type {
  FieldMergeReport,
  Presence,
  Triple,
  VerdictItem,
} from './field-verdict.js';

const HELP_TEXT = `Usage: gaia update merge-audit-ci --baseline <file> --latest <file> --current <file> [--deferred-baseline <key>=<file>]... [--json]

  Field-aware three-way verdict for .gaia/audit-ci.yml. Reads three YAML files
  (baseline / latest tarball + working-tree current), classifies the auditors
  roster members, and reports {applied, conflicts, alreadyLatest, keptRemoved,
  removedUpstream} (JSON with --json, a human summary otherwise).

  --deferred-baseline <key>=<file> reads that key's baseline from <file>
  instead of --baseline, so a key deferred at an earlier bundle is merged
  against it. <key> is auditors.<member name>. Repeatable.

  Read-only: never writes the file. The /update-gaia skill applies the 'applied'
  entries with the Edit tool to preserve comments and order.

  Exit codes:
    0  success
    1  user-correctable error (missing flag / file, malformed YAML)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

/** The GAIA-authored-and-adopter-extensible roster list. */
const ROSTER_SECTION = 'auditors';

export type AuditCiMergeReport = FieldMergeReport;

export type AuditCiVerdictItem = VerdictItem;

type Flags = {
  baseline: string;
  current: string;
  deferred: ReadonlyMap<string, string>;
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

/**
 * Parse a YAML `auditors:` list into a name → member-config map. Each
 * member's whole mapping (`globs`, `audience`, `default`, and any other key it
 * carries) is compared and applied as a single unit: `name` is the map key, the
 * rest of the item is the value. A per-glob merge would let an adopter's roster
 * end up with a glob set neither side ever authored, and a per-key merge would
 * let a key upstream dropped survive in the adopter's mapping. Malformed entries (no `name`,
 * or a `name` that is not a string) are skipped; a malformed roster must not crash the update.
 */
type RosterMember = Record<string, unknown>;

const omitName = (item: Record<string, unknown>): RosterMember => {
  const config: RosterMember = {};

  for (const key of Object.keys(item)) {
    if (key !== 'name') config[key] = item[key];
  }

  return config;
};

const parseRoster = (value: unknown): Map<string, RosterMember> => {
  const entries = new Map<string, RosterMember>();

  if (!Array.isArray(value)) return entries;

  for (const item of value) {
    const name =
      typeof item === 'object' && item !== null && !Array.isArray(item) ?
        (item as Record<string, unknown>).name
      : undefined;

    // First occurrence wins.
    if (typeof name === 'string' && !entries.has(name))
      entries.set(name, omitName(item as Record<string, unknown>));
  }

  return entries;
};

const rosterPresence = (
  entries: Map<string, RosterMember>,
  name: string
): Presence => {
  const entry = entries.get(name);

  return entry === undefined ? absent : {has: true, value: entry};
};

const buildTriples =
  (latest: Record<string, unknown>, current: Record<string, unknown>) =>
  (baseline: Record<string, unknown>): Triple[] => {
    const baseRoster = parseRoster(baseline[ROSTER_SECTION]);
    const latestRoster = parseRoster(latest[ROSTER_SECTION]);
    const currentRoster = parseRoster(current[ROSTER_SECTION]);
    const rosterNames = [
      ...new Set([...baseRoster.keys(), ...latestRoster.keys()]),
    ];

    return rosterNames.map((name) => ({
      a: rosterPresence(currentRoster, name),
      b: rosterPresence(baseRoster, name),
      key: name,
      kind: 'entry' as const,
      l: rosterPresence(latestRoster, name),
      section: ROSTER_SECTION,
      versionValued: false,
    }));
  };

type LoadResult =
  | {
      code: 'audit_ci_file_missing' | 'audit_ci_parse_failed';
      message: string;
      ok: false;
    }
  | {ok: true; root: Record<string, unknown>};

const loadAuditCi = (absPath: string, role: string): LoadResult => {
  if (!existsSync(absPath)) {
    return {
      code: 'audit_ci_file_missing',
      message: `${role} audit-ci file not found: ${absPath}`,
      ok: false,
    };
  }

  let parsed: unknown;

  try {
    parsed = parseYaml(readFileSync(absPath, 'utf8'));
  } catch (error) {
    return {
      code: 'audit_ci_parse_failed',
      message: `${role} audit-ci file is not valid YAML (${absPath}): ${
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
      subcommand: 'update merge-audit-ci',
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
    const result = loadAuditCi(absPath, role);

    if (!result.ok) {
      structuredError({
        code: result.code,
        message: result.message,
        subcommand: 'update merge-audit-ci',
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
      renderHumanReport('gaia update merge-audit-ci', report)
    );
  }

  return EXIT_CODES.OK;
};
