// Git questions corpus selection asks of a maintainer checkout: which origin/main
// commit carried a mined finding's change, which commit that change was cut
// from, and where a finding's line sits once the change is replayed over a
// bundle. Every call is read-only (`git -C <repo>`, never a checkout).
import { execFileSync } from 'node:child_process';

const MAIN_REFERENCE = 'refs/remotes/origin/main';

export const git = (repo, ...argumentList) =>
  execFileSync('git', ['-C', repo, ...argumentList], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 256 * 1024 * 1024 }).trim();

const succeeds = (repo, ...argumentList) => {
  try {
    git(repo, ...argumentList);
    return true;
  } catch {
    return false;
  }
};

export const isAncestor = (repo, ancestor, descendant) => succeeds(repo, 'merge-base', '--is-ancestor', ancestor, descendant);

export const mainSha = (repo) => git(repo, 'rev-parse', '--verify', `${MAIN_REFERENCE}^{commit}`);

const firstParentCache = new Map();

/** origin/main's first-parent chain, oldest first. */
export const firstParentChain = (repo) => {
  if (!firstParentCache.has(repo)) firstParentCache.set(repo, git(repo, 'rev-list', '--first-parent', '--reverse', MAIN_REFERENCE).split('\n').filter(Boolean));
  return firstParentCache.get(repo);
};

// The oldest first-parent origin/main commit containing `head`. Containment is
// monotonic along the first-parent chain (once a commit contains head, every
// later one does), so a binary search answers in log2(chain) ancestry checks.
const oldestContaining = (repo, head) => {
  const chain = firstParentChain(repo);
  let low = 0;
  let high = chain.length - 1;
  if (high < 0 || !isAncestor(repo, head, chain[high])) return null;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    if (isAncestor(repo, head, chain[middle])) high = middle;
    else low = middle + 1;
  }
  return chain[low];
};

/**
 * The commit a replay of `head` is cut from: with M the oldest first-parent
 * origin/main commit containing head, head^1 when M is head itself (a squash
 * or a direct commit), else the merge base of M^1 and head (a merged branch).
 */
export const baseShaFor = (repo, head) => {
  const merging = oldestContaining(repo, head);
  if (merging === null) return null;
  if (merging === git(repo, 'rev-parse', head)) return git(repo, 'rev-parse', `${head}^1`);
  return git(repo, 'merge-base', `${merging}^1`, head);
};

/**
 * The origin/main commit that carried a mined finding's change. The mining
 * script recorded the audit's base (its first match is AUDIT_KEY, --base or
 * BASE_SHA), never the reviewed head, and on a squash-merged repository the
 * reviewed branch head is not on origin/main at all. When that base sits on
 * the first-parent chain, the change it was cut for is the oldest later
 * first-parent commit that touches the finding's path and, when the audit time
 * is known, was committed after it, within `windowSize` commits of the base.
 * Honest limit: a finding on a file the branch never touched resolves to a
 * later change of that file, or to nothing; the window bounds how far that
 * can drift. A mined sha off the first-parent chain is returned as it is.
 */
export const resolveHead = (repo, mined, path, auditTime, windowSize = 20) => {
  const chain = firstParentChain(repo);
  const minedSha = git(repo, 'rev-parse', mined);
  const position = chain.indexOf(minedSha);
  if (position === -1) return minedSha;
  const auditSeconds = auditTime ? Math.floor(Date.parse(auditTime) / 1000) : null;
  for (let index = position + 1; index < Math.min(chain.length, position + 1 + windowSize); index += 1) {
    const candidate = chain[index];
    if (auditSeconds !== null && Number(git(repo, 'show', '-s', '--format=%ct', candidate)) < auditSeconds) continue;
    const touched = git(repo, 'diff-tree', '--no-commit-id', '--name-only', '-r', '--no-renames', candidate).split('\n');
    if (touched.includes(path)) return candidate;
  }
  return null;
};

/**
 * `line` of `path` at `fromRef`, mapped onto `path` at `toRef` through the
 * zero-context diff between them: null when the line itself was rewritten or
 * either side lacks the file.
 */
export const mapLine = (repo, fromRef, toRef, path, line) => {
  if (!succeeds(repo, 'cat-file', '-e', `${fromRef}:${path}`) || !succeeds(repo, 'cat-file', '-e', `${toRef}:${path}`)) return null;
  const diff = git(repo, 'diff', '-U0', '--no-color', '--no-renames', fromRef, toRef, '--', path);
  let shift = 0;
  for (const match of diff.matchAll(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/gm)) {
    const oldStart = Number(match[1]);
    const oldCount = match[2] === undefined ? 1 : Number(match[2]);
    const newCount = match[4] === undefined ? 1 : Number(match[4]);
    // A pure insertion (oldCount 0) sits after line oldStart.
    const lastOldLine = oldCount === 0 ? oldStart : oldStart + oldCount - 1;
    if (oldCount > 0 && line >= oldStart && line <= lastOldLine) return null;
    if (lastOldLine < line) shift += newCount - oldCount;
    else break;
  }
  return line + shift;
};
