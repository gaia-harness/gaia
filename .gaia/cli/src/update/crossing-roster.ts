/**
 * `gaia update crossing roster`: brings `.gaia/audit-ci.yml` to the new
 * layout by line edits, so comments and every untouched line stay as they
 * were. It rewrites old-root entries, drops `unowned` entries that would hide
 * a member's code from review, and has the default member claim each
 * registered member that sits outside the two member directories. Each edit is
 * applied only if still owed, so a second run changes nothing.
 */
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {
  APPS_DIRECTORY,
  AUDIT_ROSTER_FILE,
  done,
  isBlankOrComment,
  LEGACY_PACKAGE_ROOT,
  LEGACY_PREFIX,
  mapLeadingRoot,
  NEW_PREFIX,
  PACKAGES_DIRECTORY,
  parseListItem,
  readRegistry,
  readTextIfPresent,
  reportLine,
  stop,
  topLevelOf,
} from './crossing-shared.js';
import type {Outcome} from './crossing-shared.js';

const TOP_KEY = /^([A-Za-z_][\w-]*):/u;
const ENTRY_START = /^ {2}- name:/u;
const MEMBER_DIRECTORIES = [`${APPS_DIRECTORY}/`, `${PACKAGES_DIRECTORY}/`];
const CLAIM_QUOTE = '"';
const DEEP_INDENT = 5;

type Edit = {lines: string[]; reports: string[]};

type GlobsBlock = {anchor: number; prefix: string; values: Set<string>};

const stripReturn = (line: string): string => line.replace(/\r$/u, '');

const indentOf = (line: string): number =>
  line.length - line.trimStart().length;

const isDefaultLine = (line: string): boolean => {
  const trimmed = line.trim();

  return (
    trimmed.startsWith('default: true') &&
    isBlankOrComment(trimmed.slice('default: true'.length))
  );
};

const isOwnedByMemberDirectories = (value: string): boolean =>
  MEMBER_DIRECTORIES.some((prefix) => value.startsWith(prefix)) &&
  !value.startsWith(NEW_PREFIX);

/** Rewrites old-root items everywhere and drops member-hiding `unowned` items. */
const rewriteAndDrop = (lines: string[]): Edit => {
  const kept: string[] = [];
  const reports: string[] = [];
  let section = '';

  for (const line of lines) {
    const plain = stripReturn(line);
    const top = TOP_KEY.exec(plain);

    if (top !== null) section = top[1] ?? '';
    const item = parseListItem(plain);
    const value = item?.value ?? '';

    if (
      item !== undefined &&
      section === 'unowned' &&
      isOwnedByMemberDirectories(value)
    ) {
      reports.push(reportLine('roster-drop', value));
    } else if (item !== undefined && value.startsWith(LEGACY_PREFIX)) {
      const mapped = mapLeadingRoot(value);
      const carriage = line.endsWith('\r') ? '\r' : '';

      kept.push(
        `${item.head}${item.quote}${mapped}${item.quote}${item.rest}${carriage}`
      );
      reports.push(reportLine('roster-rewrite', `${value} to ${mapped}`));
    } else {
      kept.push(line);
    }
  }

  return {lines: kept, reports};
};

/** The globs list inside one auditor entry, with its last item's index. */
const globsBlockOf = (
  lines: string[],
  start: number,
  end: number
): GlobsBlock | undefined => {
  let globsAt = -1;

  for (let index = start; index < end && globsAt === -1; index += 1) {
    if (stripReturn(lines[index] ?? '').trim() === 'globs:') globsAt = index;
  }
  if (globsAt === -1) return undefined;

  const values = new Set<string>();
  let anchor = -1;
  let prefix = '      - ';

  for (let index = globsAt + 1; index < end; index += 1) {
    const plain = stripReturn(lines[index] ?? '');
    const item = parseListItem(plain);

    if (item !== undefined && indentOf(plain) >= DEEP_INDENT) {
      anchor = index;
      prefix = item.head;
      values.add(item.value);
    } else if (!isBlankOrComment(plain)) {
      break;
    }
  }

  return anchor === -1 ? undefined : {anchor, prefix, values};
};

/** The default member's globs list, or undefined when there is none. */
const defaultGlobs = (lines: string[]): GlobsBlock | undefined => {
  const starts = lines.flatMap((line, index) =>
    ENTRY_START.test(line) ? [index] : []
  );
  const entry = starts.find((start, position) => {
    const end = starts[position + 1] ?? lines.length;

    return lines
      .slice(start, end)
      .some((line) => isDefaultLine(stripReturn(line)));
  });

  if (entry === undefined) return undefined;
  const next = starts.find((start) => start > entry) ?? lines.length;

  return globsBlockOf(lines, entry, next);
};

const outsideMemberGlobs = (root: string): string[] | undefined =>
  readRegistry(root)
    ?.filter(
      (entry) =>
        entry.path !== '.' &&
        entry.path !== LEGACY_PACKAGE_ROOT &&
        !MEMBER_DIRECTORIES.some((prefix) => entry.path.startsWith(prefix))
    )
    .map((entry) => `${entry.path}/**`);

export const runRoster = (workingDirectory: string): Outcome => {
  const root = topLevelOf(workingDirectory);

  if (root === undefined) {
    return stop(
      'not-root-launch',
      'start the session at the repository root and re-run the note'
    );
  }
  const text = readTextIfPresent(path.join(root, AUDIT_ROSTER_FILE));

  if (text === undefined) return done();
  const claims = outsideMemberGlobs(root);

  if (claims === undefined) {
    return stop(
      'registry-path',
      'correct .gaia/packages.json so it is a JSON array of name and path entries, then re-run the note'
    );
  }

  const edit = rewriteAndDrop(text.split('\n'));
  const block = defaultGlobs(edit.lines);
  const owed = claims.filter((glob) => !block?.values.has(glob));

  if (owed.length > 0 && block === undefined) {
    return stop(
      'roster-no-default',
      'mark one auditor in .gaia/audit-ci.yml with default: true and a globs list, then re-run the note'
    );
  }

  if (block !== undefined && owed.length > 0) {
    edit.lines.splice(
      block.anchor + 1,
      0,
      ...owed.map(
        (glob) => `${block.prefix}${CLAIM_QUOTE}${glob}${CLAIM_QUOTE}`
      )
    );
    edit.reports.push(...owed.map((glob) => reportLine('roster-claim', glob)));
  }

  const after = edit.lines.join('\n');

  if (after !== text) {
    atomicWriteFileSync(path.join(root, AUDIT_ROSTER_FILE), after);
  }

  return done(edit.reports);
};
