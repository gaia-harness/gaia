/**
 * `gaia init rename --title <T> --kebab <K>` handler.
 *
 * Codifies Step 3 of `/gaia-init`. Renames the project across the small
 * set of files that carry an identity:
 *
 *   - `package.json` "name" → kebab-case title.
 *   - `CLAUDE.md` first `# ` heading → "# <Title>" (only the first
 *     occurrence, preserves later content). The heading is a required
 *     precondition rather than something this step creates: a `CLAUDE.md`
 *     carrying none fails the step instead of passing silently.
 *   - `app/languages/en/common.ts` `meta.siteName` → `<Title>` (when the
 *     key exists).
 *   - `app/languages/en/pages/_index.ts` `title` and `heroTitle` →
 *     `<Title>` (when the keys exist). Its `meta.title` is left alone: it
 *     nests `$t(common:meta.siteName)`, so the title lives in one place.
 *   - `app/services/gaia/` → `app/services/<kebab>/`, with every specifier
 *     naming it rewritten (`./rename-service-layer.ts`).
 *
 * A language-file key that is absent is tolerated; one that is present is
 * rewritten wherever its value is a quoted string literal.
 *
 * Idempotent: re-running with the same args is a no-op once the rename
 * has been applied.
 *
 * Stdout: nothing on success. Exit codes: see HELP_TEXT.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {
  resolveScaffoldTarget,
  splitPackageFlag,
} from '../scaffold/resolve-target.js';
import {structuredError} from '../stderr.js';
import {takeValue} from '../util/argv.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {renameLanguageFiles} from './rename-language-files.js';
import {
  applyServiceLayerMove,
  planServiceLayerMove,
} from './rename-service-layer.js';
import type {RunnableServiceLayerPlan} from './rename-service-layer.js';
import {markStepCompleted, readState} from './util/state.js';
import {titleFlagError} from './util/title-flag.js';

const HELP_TEXT = `Usage: gaia init rename --title <T> --kebab <K>

  Rename the project across package.json, CLAUDE.md, and seeded language
  files, and move the sample service layer app/services/gaia/ to
  app/services/<K>/ (Step 3 of /gaia-init). --package <name> picks the web
  member.

  Required flags:
    --title <T>     Project title (Title Case, e.g. "Hello World").
    --kebab <K>     Kebab-case slug (e.g. "hello-world").

  Exit codes:
    0  success (no stdout)
    1  user-correctable error (missing flags, invalid kebab, no package.json,
       no CLAUDE.md heading, app/services/<K>/ already exists beside the
       layer to move)
    2  unexpected (filesystem failure)
    30 the package registry (.gaia/packages.json) cannot resolve the web app
       package
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'rename';

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

type FlagParseSuccess = {
  flags: Flags;
  ok: true;
};

type Flags = {
  kebab: string;
  title: string;
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let title: string | undefined;
  let kebab: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--title') {
      const taken = takeValue(argv, index + 1, '--title');

      if (!taken.ok) return taken;
      title = taken.value;
      index += 1;
    } else if (token === '--kebab') {
      const taken = takeValue(argv, index + 1, '--kebab');

      if (!taken.ok) return taken;
      kebab = taken.value;
      index += 1;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
  }

  if (title === undefined) {
    return {message: '--title is required', ok: false};
  }

  const titleError = titleFlagError(title);

  if (titleError !== null) return {message: titleError, ok: false};

  if (kebab === undefined) {
    return {message: '--kebab is required', ok: false};
  }

  if (!/^[a-z][\da-z-]*$/u.test(kebab)) {
    return {message: '--kebab must be a kebab-case identifier', ok: false};
  }

  return {flags: {kebab, title}, ok: true};
};

const PACKAGE_JSON = 'package.json';
const CLAUDE_MD = 'CLAUDE.md';

const renamePackageJson = (cwd: string, kebab: string): void => {
  const target = path.join(cwd, PACKAGE_JSON);

  if (!existsSync(target)) {
    throw new Error('package.json not found at repo root');
  }
  const raw = readFileSync(target, 'utf8');
  const parsed = JSON.parse(raw) as Record<string, unknown>;

  if (parsed.name === kebab) return;
  parsed.name = kebab;
  const trailing = raw.endsWith('\n') ? '\n' : '';
  atomicWriteFileSync(target, `${JSON.stringify(parsed, null, 2)}${trailing}`);
};

const FENCE_LINE = /^\s*(?:```|~~~)/u;
// Tested against one line at a time, which is what keeps `\s` from reaching
// across a line ending: over the whole file it matches the newline after a
// bare `#`, and the rewrite then swallows the blank line below it.
const H1_LINE = /^#\s/u;

/**
 * Index of the document's title heading, or `-1`.
 *
 * The title is the first `# ` line, and it has to sit above the first fenced
 * code block. `# ` opens a shell comment as well as a markdown heading, so a
 * scan that walks into a fence finds one in a shell example, reports a title
 * where there is none, and rewrites a line of the adopter's own code.
 *
 * Stopping at the first fence rather than tracking open and closed ones is
 * deliberate. Whether a later fence *closes* an earlier one is a CommonMark
 * question about delimiter character and run length, and answering it wrong
 * puts the scan back inside a code block; a nested sample, or a `~~~` inside
 * a backtick block, is enough to do it. Nothing has to close for this rule,
 * so no nesting can defeat it.
 */
const findH1Line = (lines: readonly string[]): number => {
  for (const [index, line] of lines.entries()) {
    if (FENCE_LINE.test(line)) return -1;

    if (H1_LINE.test(line)) return index;
  }

  return -1;
};

/**
 * Whether `CLAUDE.md` content carries a heading `rename` can rewrite.
 * Exported so the suite asserting the shipped template through the same
 * predicate the step uses cannot drift from it.
 */
export const claudeMdHasH1 = (source: string): boolean =>
  findH1Line(source.split('\n')) !== -1;

/**
 * True when `CLAUDE.md` is absent, which is tolerated, or carries a heading.
 *
 * The heading is a precondition this step enforces, never one it creates:
 * every rewrite in this module replaces a value the seed already has, and
 * choosing where to insert a heading into a file the user may have
 * restructured is a guess with no right answer. Checked before the first
 * write so a run that cannot finish has not renamed anything.
 */
const claudeMdPreconditionMet = (cwd: string): boolean => {
  const target = path.join(cwd, CLAUDE_MD);

  return !existsSync(target) || claudeMdHasH1(readFileSync(target, 'utf8'));
};

const renameClaudeMd = (cwd: string, title: string): void => {
  const target = path.join(cwd, CLAUDE_MD);

  if (!existsSync(target)) return;
  const lines = readFileSync(target, 'utf8').split('\n');
  const index = findH1Line(lines);

  if (index === -1) return;
  const currentLine = lines[index];

  if (currentLine === undefined) return;
  const heading = `# ${title}`;

  if (currentLine === heading) return;
  lines[index] = heading;
  atomicWriteFileSync(target, lines.join('\n'));
};

/** The slug an earlier `rename` recorded, which is where its layer now sits. */
const recordedKebab = (cwd: string): string | undefined => {
  const args = readState(cwd).step_args[STEP_NAME];

  if (typeof args !== 'object' || args === null || !('kebab' in args)) {
    return undefined;
  }

  return typeof args.kebab === 'string' ? args.kebab : undefined;
};

/**
 * The service-layer plan, or the error that refuses the run. Checked ahead of
 * every write, so a knowable precondition never fails the run with
 * package.json already renamed.
 */
const checkPreconditions = (
  cwd: string,
  packageDir: string,
  kebab: string
): RunnableServiceLayerPlan | {code: string; message: string} => {
  if (!claudeMdPreconditionMet(cwd)) {
    return {
      code: 'claude_md_heading_missing',
      message:
        'CLAUDE.md has no top-level "# " heading to rewrite; add one above any fenced code block and re-run',
    };
  }
  const plan = planServiceLayerMove(packageDir, kebab, recordedKebab(cwd));

  return plan.kind === 'conflict' ?
      {code: 'service_layer_conflict', message: plan.message}
    : plan;
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [first] = argv;

  if (first !== undefined && HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const split = splitPackageFlag(argv, 'init rename');

  if (split === undefined) return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  const parsed = parseFlags(split.argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'init rename',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const target = resolveScaffoldTarget(cwd, 'init rename', split.packageName);

  if (target === undefined) return EXIT_CODES.CONFIG_INVALID;

  try {
    const checked = checkPreconditions(
      cwd,
      target.packageDir,
      parsed.flags.kebab
    );

    if ('code' in checked) {
      structuredError({...checked, subcommand: 'init rename'});

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
    renamePackageJson(cwd, parsed.flags.kebab);
    renameClaudeMd(cwd, parsed.flags.title);

    renameLanguageFiles(target.packageDir, parsed.flags.title);
    applyServiceLayerMove(target.packageDir, checked);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);

    if (message.includes('not found')) {
      structuredError({
        code: 'package_json_missing',
        message,
        subcommand: 'init rename',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
    structuredError({
      code: 'rename_failed',
      message,
      subcommand: 'init rename',
    });

    return UNEXPECTED_EXIT;
  }

  try {
    markStepCompleted(cwd, STEP_NAME, {
      kebab: parsed.flags.kebab,
      title: parsed.flags.title,
    });
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init rename',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
