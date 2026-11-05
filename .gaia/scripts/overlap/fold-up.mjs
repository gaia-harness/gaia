// Proposal shapes, the fold-up kind, the unit-cover reason and the fixed point
// for the overlap check. check-proposals.mjs owns the file cache, the layer
// table, the I/O and the main loop; every function here is handed what it
// reads.
//
// A fold-up names two or more subject tests whose property one existing
// integration test, `into` (route, story or real-server), already asserts.
// The fixer deletes the subjects and writes no test, so at --post-fix the
// entry passes only when every subject is gone, `into` still verifies, and no
// file in the check-time `baseline` (every test name each subject file and
// the `into` file held) gained a name. A fold-up that would need a new or
// widened test carries `needsNewTest` in place of `into`; so may a demote that
// names no sibling or target. Either is kept as report-only and never offered.
//
// The unit reason: a drop, merge or demote whose cover is a unit test that is
// not a story file, and whose subject sits on the route layer or higher,
// carries `unitReason: {integrationCost, risk}` with both strings non-empty.
// A demote carrying `needsNewTest` always carries it.
//
// Honest limit: the baseline holds the names the signal extractor reports, so
// a new templated-title test in a baseline file is not seen as a new name.

import {isRendered, locateTests, verifyCitation} from './citations.mjs';

// check-proposals.mjs's layer ranks: 1 unit and story, 2 route, 4 browser.
const UNIT = 1;
const ROUTE = 2;
const BROWSER = 4;

export const KINDS = new Set(['drop', 'merge', 'demote', 'keep-both', 'fold-up']);
// The kinds whose subject the fixer removes, for the fixed point.
export const REMOVING = new Set(['drop', 'merge', 'demote', 'fold-up']);
const REASONED = new Set(['drop', 'merge', 'demote']);

export const nonEmpty = (value) => typeof value === 'string' && value.trim().length > 0;
export const keyOf = (file, fullName) => `${file}\u0000${fullName}`;
export const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
export const isStoryFile = (file) => /\.stories\.tsx$/.test(file);
export const isSafeRelative = (file) =>
  typeof file === 'string' &&
  file.length > 0 &&
  !file.startsWith('/') &&
  !file.includes('\0') &&
  !file.split('/').includes('..');

const isLine = (value) => Number.isInteger(value) && value >= 1;
export const isCitation = (c) => isObject(c) && isSafeRelative(c.file) && isLine(c.line) && nonEmpty(c.fullName) && nonEmpty(c.assertion);
const isTarget = (t) =>
  isObject(t) &&
  nonEmpty(t.layer) &&
  Array.isArray(t.assertions) &&
  t.assertions.length > 0 &&
  t.assertions.every((a) => isObject(a) && isLine(a.line) && nonEmpty(a.assertion));
const isSubject = (s) => isObject(s) && isSafeRelative(s.file) && nonEmpty(s.fullName);

// A fold-up has subjects and no top-level test; into and needsNewTest are
// each optional but never both (neither is fold-up-no-target, not malformed).
function foldUpWellFormed(p) {
  if (p.file !== undefined || p.fullName !== undefined || p.sibling !== undefined || p.target !== undefined) return false;
  if (!Array.isArray(p.subjects) || !p.subjects.every(isSubject)) return false;
  if (p.into !== undefined && p.needsNewTest !== undefined) return false;
  if (p.into !== undefined && !isCitation(p.into)) return false;
  return p.needsNewTest === undefined || nonEmpty(p.needsNewTest);
}

// Otherwise exactly one of sibling and target, a target only on a demote, or
// a demote with neither that carries needsNewTest.
export function wellFormed(p) {
  if (!isObject(p) || !KINDS.has(p.proposal)) return false;
  if (typeof p.seam !== 'boolean' || !nonEmpty(p.property) || !nonEmpty(p.actor) || !nonEmpty(p.action)) return false;
  if (p.proposal === 'fold-up') return foldUpWellFormed(p);
  if (!isSafeRelative(p.file) || !nonEmpty(p.fullName)) return false;
  if (p.needsNewTest !== undefined) {
    return p.proposal === 'demote' && nonEmpty(p.needsNewTest) && p.sibling === undefined && p.target === undefined;
  }
  if ((p.sibling === undefined) === (p.target === undefined)) return false;
  if (p.target !== undefined) return p.proposal === 'demote' && isTarget(p.target);
  return isCitation(p.sibling);
}

/**
 * The unit-reason rule: null when the proposal needs no reason or carries
 * both conditions, else unit-reason-missing or unit-reason-one-condition.
 */
export function unitReasonProblem(p, subjectRank, coverRank, coverIsStory) {
  if (!REASONED.has(p.proposal)) return null;
  const required = p.needsNewTest !== undefined || (coverRank === UNIT && !coverIsStory && subjectRank >= ROUTE);
  if (!required) return null;
  const reason = isObject(p.unitReason) ? p.unitReason : {};
  const held = [reason.integrationCost, reason.risk].filter(nonEmpty).length;
  if (held === 2) return null;
  return held === 1 ? 'unit-reason-one-condition' : 'unit-reason-missing';
}

// Every test name the extractor reports in each file; a file that does not
// exist holds none.
export function buildBaseline(files, loadFile) {
  return [...new Set(files)].map((file) => ({file, names: (loadFile(file)?.tests ?? []).map((test) => test.fullName)}));
}

// The baseline must name every subject file and the into file.
function baselineCovers(p) {
  if (!Array.isArray(p.baseline)) return false;
  const valid = p.baseline.every(
    (row) => isObject(row) && isSafeRelative(row.file) && Array.isArray(row.names) && row.names.every((name) => typeof name === 'string'),
  );
  if (!valid) return false;
  const files = new Set(p.baseline.map((row) => row.file));
  return [...p.subjects.map((s) => s.file), p.into.file].every((file) => files.has(file));
}

// A baseline file whose tests cannot be read cannot prove it gained nothing.
function gainedName(p, loadFile) {
  return p.baseline.some((row) => {
    const entry = loadFile(row.file);
    if (entry === null) return false;
    if (entry.tests === null) return true;
    return entry.tests.some((test) => !row.names.includes(test.fullName));
  });
}

/**
 * Checks one well-formed fold-up. ctx: {postFix, loadFile, rankOf,
 * layerName(rank, isStory), seamOf(flag, file, entry, test), seamCeiling}.
 * Returns {reason} on a refusal, else {reason: null, kept, subjectKeys,
 * coverKey}.
 */
export function checkFoldUp(p, ctx) {
  const keys = new Set(p.subjects.map((s) => keyOf(s.file, s.fullName)));
  if (keys.size < 2) return {reason: 'fold-up-one-subject'};
  if (p.into === undefined && p.needsNewTest === undefined) return {reason: 'fold-up-no-target'};
  // At --post-fix an applied fold-up's subjects are meant to be gone.
  const applied = ctx.postFix && p.into !== undefined;
  const subjects = [];
  for (const [index, s] of p.subjects.entries()) {
    const entry = ctx.loadFile(s.file);
    const test = locateTests(entry, s.fullName)[0] ?? null;
    if (test === null && !applied) return {reason: 'subject-not-found'};
    const rank = ctx.rankOf(s.file);
    if (rank === null) return {reason: 'subject-no-layer'};
    // An applied subject's test is gone, so its own seam flag is the one recorded at check time.
    const recorded = applied && Array.isArray(p.subjectSeams) ? p.subjectSeams[index] : undefined;
    const seam = typeof recorded === 'boolean' ? recorded : ctx.seamOf(p.seam, s.file, entry, test);
    subjects.push({file: s.file, entry, test, rank, seam});
  }
  if (applied) {
    if (!baselineCovers(p)) return {reason: 'fold-up-baseline-missing'};
    if (subjects.some((s) => s.test !== null)) return {reason: 'fold-up-subject-present'};
  }
  let intoLayer = null;
  if (p.into !== undefined) {
    if (keys.has(keyOf(p.into.file, p.into.fullName))) return {reason: 'self-citation'};
    const intoRank = ctx.rankOf(p.into.file);
    const intoIsStory = isStoryFile(p.into.file);
    if (intoRank === null || intoRank === BROWSER || (intoRank === UNIT && !intoIsStory)) return {reason: 'fold-up-target-layer'};
    const {reason} = verifyCitation(ctx.loadFile(p.into.file), p.into, ctx.postFix);
    if (reason !== null) return {reason};
    if (subjects.some((s) => s.seam && intoRank < Math.min(s.rank, ctx.seamCeiling))) return {reason: 'seam-no-sibling-at-or-above'};
    if (applied && gainedName(p, ctx.loadFile)) return {reason: 'fold-up-new-test'};
    intoLayer = ctx.layerName(intoRank, intoIsStory);
  }
  const kept = {
    ...p,
    seam: subjects.some((s) => s.seam),
    subjectSeams: subjects.map((s) => s.seam),
    ...(intoLayer === null ? {} : {intoLayer}),
    ...(intoLayer !== null && !ctx.postFix
      ? {baseline: buildBaseline([...p.subjects.map((s) => s.file), p.into.file], ctx.loadFile)}
      : {}),
    _subjects: subjects.map((s) => ({file: s.file, ranges: s.test === null ? null : s.test.ranges, rendered: isRendered(s.entry)})),
    ...(p.needsNewTest === undefined ? {} : {_needsNewTest: true}),
  };
  return {reason: null, kept, subjectKeys: [...keys], coverKey: p.into === undefined ? null : keyOf(p.into.file, p.into.fullName)};
}

/**
 * The fixed point over survivors ({proposal, subjectKeys, coverKey, kept}):
 * every round judges against the set the round started with, so the outcome
 * does not depend on proposal order. Discards go onto `discarded`; returns
 * the survivors left.
 */
export function settle(survivors, discarded) {
  let left = survivors;
  for (;;) {
    const mutual = new Set();
    const removed = new Set();
    for (const a of left) {
      for (const b of left) {
        if (a !== b && a.coverKey !== null && b.coverKey !== null && b.subjectKeys.includes(a.coverKey) && a.subjectKeys.includes(b.coverKey)) {
          mutual.add(a);
        }
      }
    }
    for (const a of left) {
      if (mutual.has(a) || a.coverKey === null) continue;
      const taken = left.some((b) => b !== a && REMOVING.has(b.proposal.proposal) && b.proposal.needsNewTest === undefined && b.subjectKeys.includes(a.coverKey));
      if (taken) removed.add(a);
    }
    if (mutual.size === 0 && removed.size === 0) return left;
    for (const a of mutual) discarded.push({...a.proposal, reason: 'mutual-citation'});
    for (const a of removed) discarded.push({...a.proposal, reason: 'sibling-removed'});
    left = left.filter((a) => !mutual.has(a) && !removed.has(a));
  }
}
