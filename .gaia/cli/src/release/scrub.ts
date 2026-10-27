/**
 * `gaia-maintainer release scrub` handler.
 *
 * Bundle-time discipline for the GAIA release tarball. Runs inside
 * `release.yml` between the staging step (rsync from `git ls-files` minus
 * `.gaia/release-exclude`) and the final `tar -czf`. The transforms run in
 * config order against the staging tree:
 *
 *   - marker-strip: remove maintainer-only blocks delimited by
 *     configured start and end comment markers. Source becomes superset; bundle is subset.
 *
 *   - json-strip: delete maintainer-only keys from structured JSON files
 *     using dot-notation paths (e.g. "scripts.test:forensics"). Dots are
 *     path separators; key names must not contain literal dots.
 *
 *   - json-strip-array-element: remove a single array element by predicate
 *     from a structured JSON file (e.g. a maintainer-only hook registration
 *     inside `.claude/settings.json`), the shape json-strip cannot express.
 *
 *   - pnpm-member-strip: remove a maintainer-only workspace member from the
 *     staged pnpm workspace file and lockfile (`pnpm-member-strip.ts`).
 *     Refuses, writing neither file, when it cannot produce a consistent
 *     pair.
 *
 *   - leak-check: run codified audit patterns from
 *      `.claude/rules/wiki-style.md` Audit section + the distribution-
 *      boundary classes in `.gaia/cli/health/taxonomy.md` against the
 *      post-strip staging tree. Non-empty match = build failure with a
 *      structured leak report.
 *
 * Read-only on the source repo. Writes happen in place inside the
 * staging directory.
 *
 * Exit codes:
 *   0: clean (no leaks; transforms applied successfully)
 *   1: user-correctable (leaks detected, unbalanced markers, a refused
 *       pnpm member strip, missing staging dir, malformed config flags)
 *   2: unexpected (config parse error, filesystem IO failure)
 */
import {statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {takeValue} from '../util/argv.js';
import {collectTreeFiles, EVERY_EXTENSION} from '../util/tree-walk.js';
import {stripPnpmMember} from './pnpm-member-strip.js';
import {loadConfig} from './scrub-config.js';
import type {ScrubConfig} from './scrub-config.js';
import type {AllowlistWarning, Leak} from './scrub-leak-scan.js';
import {tryRunTransformsOrReport} from './scrub-transforms.js';
import type {PnpmMemberStripper} from './scrub-transforms.js';

export {loadConfig} from './scrub-config.js';

export {buildNeverPresentWorkflowSet} from './scrub-derived-checks.js';

export {globToRegex} from './scrub-glob.js';

export {parseKeyPath} from './scrub-json-strip.js';

const HELP_TEXT = `Usage: gaia-maintainer release scrub <staging-dir> [--config <path>] [--json]

  Apply the bundle-time scrub transforms in .gaia/release-scrub.yml (marker,
  JSON and pnpm workspace-member strips, then leak checks) to a staging
  directory produced by release.yml. Writes in place inside <staging-dir>;
  treats the source repo as read-only.

  Flags:
    --config <path>  Override config path (default: .gaia/release-scrub.yml
                     resolved against process.cwd()).
    --json           Emit a structured JSON report on stdout instead of
                     human-readable summary.

  Exit codes:
    0  clean
    1  leaks detected, unbalanced markers, refused pnpm member strip,
       missing staging dir, bad flags
    2  config parse error or filesystem IO failure
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const DEFAULT_CONFIG_PATH = '.gaia/release-scrub.yml';

// Flags

type FlagParseFailure = {message: string; ok: false};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;
type FlagParseSuccess = {flags: Flags; ok: true};
type Flags = {
  configPath: string | undefined;
  json: boolean;
  stagingDir: string | undefined;
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let configPath: string | undefined;
  let json = false;
  let stagingDir: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token !== undefined) {
      if (token === '--config') {
        const taken = takeValue(argv, index + 1, '--config');

        if (!taken.ok) return taken;
        configPath = taken.value;
        index += 1;
      } else if (token === '--json') {
        json = true;
      } else if (token.startsWith('--')) {
        return {message: `unknown flag: ${token}`, ok: false};
      } else if (stagingDir === undefined) {
        stagingDir = token;
      } else {
        return {message: `unexpected positional: ${token}`, ok: false};
      }
    }
  }

  return {flags: {configPath, json, stagingDir}, ok: true};
};

// Run

type Report = {
  json_strip: {
    files_touched: readonly string[];
    keys_removed: number;
  };
  json_strip_array_element: {
    elements_removed: number;
    files_touched: readonly string[];
  };
  leaks: readonly Leak[];
  marker_strip: {
    blocks_stripped: number;
    files_touched: readonly string[];
  };
  pnpm_member_strip: {
    files_touched: readonly string[];
    importers_removed: number;
    packages_removed: number;
    snapshots_removed: number;
  };
  unbalanced_markers: readonly {
    file: string;
    line: number;
    reason: string;
  }[];
  unused_allowlist: readonly AllowlistWarning[];
};

type RunOptions = {
  cwd?: string;
  /** Test seam: replaces the pnpm member stripper the transform calls. */
  stripPnpmMember?: PnpmMemberStripper;
};

const renderHumanReport = (report: Report, jsonMode: boolean): string => {
  if (jsonMode) return `${JSON.stringify(report, null, 2)}\n`;

  const out: string[] = [
    `release scrub: stripped ${report.marker_strip.blocks_stripped} marker block(s) across ${report.marker_strip.files_touched.length} file(s)`,
    `release scrub: removed ${report.json_strip.keys_removed} json key(s) from ${report.json_strip.files_touched.length} file(s)`,
    `release scrub: removed ${report.json_strip_array_element.elements_removed} json array element(s) from ${report.json_strip_array_element.files_touched.length} file(s)`,
    `release scrub: removed ${report.pnpm_member_strip.importers_removed} pnpm importer(s), ${report.pnpm_member_strip.packages_removed} package(s), ${report.pnpm_member_strip.snapshots_removed} snapshot(s)`,
  ];

  if (report.unbalanced_markers.length > 0) {
    out.push('', `unbalanced markers (${report.unbalanced_markers.length}):`);

    for (const issue of report.unbalanced_markers) {
      out.push(`  ${issue.file}:${issue.line}  ${issue.reason}`);
    }
  }

  if (report.leaks.length > 0) {
    out.push('', `leaks (${report.leaks.length}):`);

    for (const leak of report.leaks) {
      out.push(`  [${leak.check}] ${leak.file}:${leak.line}  ${leak.match}`);
    }
  } else {
    out.push('leaks: none');
  }

  if (report.unused_allowlist.length > 0) {
    out.push(
      '',
      `unused allowlist entries (${report.unused_allowlist.length}, warning only):`
    );

    for (const warning of report.unused_allowlist) {
      out.push(`  [${warning.check}] ${warning.kind}: ${warning.entry}`);
    }
  }

  return `${out.join('\n')}\n`;
};

const resolveAbsolute = (cwd: string, value: string): string =>
  path.isAbsolute(value) ? value : path.join(cwd, value);

const tryVerifyExists = (target: string): boolean => {
  try {
    statSync(target);

    return true;
  } catch {
    return false;
  }
};

const tryLoadConfigOrReport = (configPath: string): null | ScrubConfig => {
  try {
    return loadConfig(configPath);
  } catch (error) {
    structuredError({
      code: 'config_load_failed',
      message: error instanceof Error ? error.message : String(error),
      path: configPath,
      subcommand: 'release scrub',
    });

    return null;
  }
};

const tryWalkFilesOrReport = (stagingDir: string): null | readonly string[] => {
  try {
    return collectTreeFiles(stagingDir, EVERY_EXTENSION);
  } catch (error) {
    structuredError({
      code: 'staging_walk_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release scrub',
    });

    return null;
  }
};

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
      subcommand: 'release scrub',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (parsed.flags.stagingDir === undefined) {
    structuredError({
      code: 'missing_staging_dir',
      message: 'staging directory argument required',
      subcommand: 'release scrub',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const stagingDir = resolveAbsolute(cwd, parsed.flags.stagingDir);
  const configPath =
    parsed.flags.configPath === undefined ?
      path.join(cwd, DEFAULT_CONFIG_PATH)
    : resolveAbsolute(cwd, parsed.flags.configPath);

  if (!tryVerifyExists(stagingDir)) {
    structuredError({
      code: 'staging_dir_missing',
      message: `staging directory not found: ${stagingDir}`,
      subcommand: 'release scrub',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const config = tryLoadConfigOrReport(configPath);

  if (config === null) return UNEXPECTED_EXIT;

  const stagedFiles = tryWalkFilesOrReport(stagingDir);

  if (stagedFiles === null) return UNEXPECTED_EXIT;

  const results = tryRunTransformsOrReport(config, {
    cwd,
    stagedFiles,
    stagingDir,
    stripPnpmMember: options.stripPnpmMember ?? stripPnpmMember,
  });

  if (results === null) return UNEXPECTED_EXIT;

  if (results.pnpmRefusal !== null) {
    const {detail, file, token} = results.pnpmRefusal;

    structuredError({
      code: 'pnpm_member_strip_refused',
      detail,
      file,
      message: `pnpm-member-strip refused ${file} (${token}): ${detail}; neither pnpm file was written`,
      subcommand: 'release scrub',
      token,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const report: Report = {
    json_strip: {
      files_touched: results.jsonStripFiles,
      keys_removed: results.jsonStripKeysRemoved,
    },
    json_strip_array_element: {
      elements_removed: results.jsonStripArrayElementsRemoved,
      files_touched: results.jsonStripArrayElementFiles,
    },
    leaks: results.leaks,
    marker_strip: {
      blocks_stripped: results.stripBlocks,
      files_touched: results.stripFiles,
    },
    pnpm_member_strip: {
      files_touched: results.pnpmFiles,
      importers_removed: results.pnpmImportersRemoved,
      packages_removed: results.pnpmPackagesRemoved,
      snapshots_removed: results.pnpmSnapshotsRemoved,
    },
    unbalanced_markers: results.unbalanced,
    unused_allowlist: results.warnings,
  };

  process.stdout.write(renderHumanReport(report, parsed.flags.json));

  if (results.unbalanced.length > 0 || results.leaks.length > 0) {
    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return EXIT_CODES.OK;
};
