// The prepare, apply and flag steps of plan-audit-apply.mjs. Library only.
//
// Working folder: `<planDir>/audit/apply/` holding `snapshot/`, `prepared.json`,
// `applied.json` (a JSON array of completed finding ids), `fixup.json` and
// `review.json` (both rewritten as each finding completes; entries of a
// finding a rerun skips are kept).

import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import path from 'node:path';

import {applyReplacements} from './doc-replace.mjs';
import {
  addSecurityWriterRow,
  phaseOfTask,
  renderReadme,
  syncTestLines,
  writeAtomic,
} from './plan-docs.mjs';
import {
  applyPatch,
  checkPatch,
  conflictingPatches,
  lensFindings,
  readJson,
  setCellRegressions,
  takeSnapshot,
} from './row-patch.mjs';
import {isNonEmptyString, isSecurity, readTable} from './table.mjs';

const pretty = (value) => `${JSON.stringify(value, null, 2)}\n`;

// readTable returns only the keys it validates; a write built from it alone
// would drop every other top-level key of tests.json, such as `sets`.
const readWholeTable = (tablePath) => ({...readJson(tablePath, {}), ...readTable(tablePath)});

// A patch two accepted findings both aim at one row field goes to review;
// any other patch is routed by checkPatch against the table as it stands.
// A finding whose applied patches leave the `sets` entries failing the set-cell
// check is held whole: its entry and the cells its rows gain only verify
// together, so each patch the script would have applied goes to fix-up.
const setCellsReason = (problems) => `set cells: ${problems[0]}`;

const routePatch = (conflicts, findingId, index, patch, table, context) =>
  conflicts.has(`${findingId}\u0000${index}`)
    ? {route: 'review', reason: 'two accepted patches set the same field of one row'}
    : checkPatch(patch, table, context);

export const readKeys = (file) =>
  readFileSync(file, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);

const paths = (planDir) => {
  const applyDir = path.join(planDir, 'audit', 'apply');
  return {
    applyDir,
    table: path.join(planDir, 'tests.json'),
    readme: path.join(planDir, 'README.md'),
    orchestrator: path.join(planDir, 'ORCHESTRATOR.md'),
    snapshot: path.join(applyDir, 'snapshot'),
  };
};

const patchesOf = (finding) => (Array.isArray(finding.row_patches) ? finding.row_patches : []);
const replacementsOf = (finding) =>
  Array.isArray(finding.replacements) ? finding.replacements : [];

const asItem = (finding, replacement, index) =>
  replacement !== null && typeof replacement === 'object' && !Array.isArray(replacement)
    ? {...replacement, finding, index}
    : null;

// Writes tests.json and keeps task docs and README in step with `next`.
const commitTable = (planDir, file, before, next) => {
  writeAtomic(file.table, pretty(next));
  syncTestLines(planDir, before.rows, next.rows);
  writeAtomic(file.readme, renderReadme(readFileSync(file.readme, 'utf8'), next));
};

export const prepare = ({planDir, keysFile, exclude = []}) => {
  const file = paths(planDir);
  mkdirSync(file.applyDir, {recursive: true});
  takeSnapshot(planDir, file.applyDir);
  const context = {keys: readKeys(keysFile), ruledWrong: new Set()};
  let scratch = readWholeTable(file.table);
  const findings = lensFindings(planDir).filter((finding) => !exclude.includes(finding.id));
  const conflicts = conflictingPatches(
    findings.flatMap((finding) =>
      patchesOf(finding).map((patch, index) => ({finding: finding.id, index, patch})),
    ),
  );
  const items = findings.flatMap((finding) =>
    replacementsOf(finding).flatMap((replacement, index) => {
      const item = asItem(finding.id, replacement, index);
      return item ? [item] : [];
    }),
  );
  const dry = applyReplacements({planDir, items, dryRun: true});
  const routeOf = new Map();
  for (const {finding, index} of dry.applied) routeOf.set(`${finding}\u0000${index}`, {route: 'script', reason: ''});
  for (const {finding, index, reason} of dry.fixup) routeOf.set(`${finding}\u0000${index}`, {route: 'fixup', reason});
  for (const {finding, index, reason} of dry.refused) routeOf.set(`${finding}\u0000${index}`, {route: 'review', reason});

  const lines = [];
  const prepared = {findings: [], rows_to_judge: []};
  for (const finding of findings) {
    const beforeFinding = scratch;
    const judged = [];
    let patches = patchesOf(finding).map((patch, index) => {
      const outcome = routePatch(conflicts, finding.id, index, patch, scratch, context);
      if (outcome.route === 'script') {
        scratch = applyPatch(scratch, patch);
        if (patch.op !== 'sets') judged.push({finding: finding.id, row: patch.op === 'add' ? patch.row.id : patch.id});
      }
      return {index, ...outcome};
    });
    const regressions = setCellRegressions(beforeFinding, scratch, context.keys);
    if (regressions.length > 0) {
      scratch = beforeFinding;
      patches = patches.map((entry) =>
        entry.route === 'script' ? {...entry, route: 'fixup', reason: setCellsReason(regressions)} : entry,
      );
    } else {
      prepared.rows_to_judge.push(...judged);
    }
    const replacements = replacementsOf(finding).map((_replacement, index) => ({
      index,
      ...(routeOf.get(`${finding.id}\u0000${index}`) ?? {
        route: 'fixup',
        reason: 'malformed item: not an object',
      }),
    }));
    prepared.findings.push({id: finding.id, patches, replacements});
    for (const [kind, list] of [['patch', patches], ['replacement', replacements]]) {
      for (const entry of list) {
        if (entry.route !== 'script') lines.push(`${entry.route} ${finding.id} ${kind} ${entry.index} ${entry.reason}`);
      }
    }
  }
  writeAtomic(path.join(file.applyDir, 'prepared.json'), pretty(prepared));
  return lines;
};

const keep = (entries, completed) => entries.filter((entry) => completed.has(entry.finding));

export const apply = ({planDir, keysFile, decisions}) => {
  const file = paths(planDir);
  if (!existsSync(file.snapshot)) throw new Error('no snapshot: run prepare first');
  const context = {
    keys: readKeys(keysFile),
    ruledWrong: new Set(Array.isArray(decisions.security_ruled_wrong) ? decisions.security_ruled_wrong : []),
  };
  const appliedFile = path.join(file.applyDir, 'applied.json');
  const completedList = readJson(appliedFile, []);
  const completed = new Set(completedList);
  let fixup = keep(readJson(path.join(file.applyDir, 'fixup.json'), []), completed);
  let review = keep(readJson(path.join(file.applyDir, 'review.json'), []), completed);
  const counts = {applied: 0, fixup: 0, review: 0, scriptReplacements: 0, fixupReplacements: 0};
  const byId = new Map(lensFindings(planDir).map((finding) => [finding.id, finding]));
  const decided = (Array.isArray(decisions.findings) ? decisions.findings : []).filter(
    (decision) => decision && typeof decision.id === 'string' && !completed.has(decision.id),
  );
  const accepted = decided.filter((decision) => decision.decision === 'apply');
  const patchList = (decision) =>
    Array.isArray(decision.row_patches) ? decision.row_patches : patchesOf(byId.get(decision.id) ?? {});
  const conflicts = conflictingPatches(
    accepted.flatMap((decision) =>
      patchList(decision).map((patch, index) => ({finding: decision.id, index, patch})),
    ),
  );

  const persist = (id) => {
    completedList.push(id);
    writeAtomic(path.join(file.applyDir, 'fixup.json'), pretty(fixup));
    writeAtomic(path.join(file.applyDir, 'review.json'), pretty(review));
    writeAtomic(appliedFile, pretty(completedList));
  };

  for (const decision of decided) {
    if (decision.decision === 'revise') {
      fixup.push({finding: decision.id, kind: 'revision', index: 0, reason: 'revised', item: {revision: decision.revision ?? ''}});
      counts.fixup += 1;
      persist(decision.id);
      continue;
    }
    if (decision.decision !== 'apply') continue;
    const finding = byId.get(decision.id) ?? {};
    const patches = patchList(decision);
    const replacements = replacementsOf(finding);
    if (patches.length === 0 && replacements.length === 0) {
      fixup.push({finding: decision.id, kind: 'patch', index: 0, reason: 'no fix to apply', item: null});
      counts.fixup += 1;
      persist(decision.id);
      continue;
    }
    const before = readWholeTable(file.table);
    let table = before;
    const scripted = [];
    patches.forEach((patch, index) => {
      const outcome = routePatch(conflicts, decision.id, index, patch, table, context);
      const entry = {finding: decision.id, kind: 'patch', index, reason: outcome.reason, item: patch};
      if (outcome.route === 'script') {
        table = applyPatch(table, patch);
        scripted.push(entry);
      } else if (outcome.route === 'fixup') {
        fixup.push(entry);
        counts.fixup += 1;
      } else {
        review.push(entry);
        counts.review += 1;
      }
    });
    const regressions = setCellRegressions(before, table, context.keys);
    if (regressions.length > 0) {
      table = before;
      fixup.push(...scripted.map((entry) => ({...entry, reason: setCellsReason(regressions)})));
      counts.fixup += scripted.length;
    } else {
      counts.applied += scripted.length;
    }
    if (table !== before) {
      commitTable(planDir, file, before, table);
      // A patch that flags a row never reaches the judge's flag step when the
      // judge agrees with the kind it set, so its phase's Security writer line
      // is written here.
      const priorKinds = new Map(before.rows.map((row) => [row.id, row.security]));
      for (const row of table.rows) {
        if (!isSecurity(row) || priorKinds.get(row.id) === row.security) continue;
        try {
          flagRow({planDir, row: row.id, kind: row.security});
        } catch (error) {
          review.push({finding: decision.id, kind: 'patch', index: 0, reason: `${row.id} is flagged but its Security writer line was not written: ${error.message}`, item: null});
          counts.review += 1;
        }
      }
    }
    const items = replacements.flatMap((replacement, index) => {
      const item = asItem(decision.id, replacement, index);
      if (!item) {
        fixup.push({finding: decision.id, kind: 'replacement', index, reason: 'malformed item: not an object', item: replacement});
        counts.fixup += 1;
        counts.fixupReplacements += 1;
      }
      return item ? [item] : [];
    });
    const result = applyReplacements({planDir, items});
    const original = (index) => replacements[index];
    counts.scriptReplacements += result.applied.length;
    for (const {index, reason} of result.fixup) {
      fixup.push({finding: decision.id, kind: 'replacement', index, reason, item: original(index)});
      counts.fixup += 1;
      counts.fixupReplacements += 1;
    }
    for (const {index, reason} of result.refused) {
      review.push({finding: decision.id, kind: 'replacement', index, reason, item: original(index)});
      counts.review += 1;
    }
    persist(decision.id);
  }
  if (decided.length === 0) {
    writeAtomic(path.join(file.applyDir, 'fixup.json'), pretty(fixup));
    writeAtomic(path.join(file.applyDir, 'review.json'), pretty(review));
  }
  return counts;
};

// The row with `caseKinds` set to its kind when it needs them (flagged, no
// `caseKey`, not `retire`): one entry per given case, else its own entries
// re-kinded. Throws when it needs them and has neither.
const withCaseKinds = (row, cases) => {
  if (row.action === 'retire' || row.caseKey !== undefined) return row;
  if (cases !== undefined) {
    if (!Array.isArray(cases) || cases.length === 0 || !cases.every(isNonEmptyString)) {
      throw new Error('--cases is not a non-empty JSON array of strings');
    }
    return {...row, caseKinds: cases.map((text) => ({case: text, kind: row.security}))};
  }
  if (Array.isArray(row.caseKinds) && row.caseKinds.length > 0) {
    return {...row, caseKinds: row.caseKinds.map((entry) => ({...entry, kind: row.security}))};
  }
  throw new Error(`row ${row.id} has no caseKey and no caseKinds: pass --cases with each case its case names`);
};

// Sets a row's security kind in tests.json and its README row, and lists it on
// its owning phase's Security writer line. Throws before writing anything.
export const flagRow = ({planDir, row: rowId, kind, cases}) => {
  const file = paths(planDir);
  const table = readWholeTable(file.table);
  const row = table.rows.find((candidate) => candidate.id === rowId);
  if (!row) throw new Error(`row ${rowId} is not in the table`);
  const readme = readFileSync(file.readme, 'utf8');
  const phase = phaseOfTask(readme, row.task);
  if (phase === null) throw new Error(`no README Phase row names ${row.task}`);
  const orchestrator = addSecurityWriterRow(readFileSync(file.orchestrator, 'utf8'), phase, rowId);
  if (orchestrator === null) throw new Error(`ORCHESTRATOR.md has no Phase ${phase} entry`);
  const flagged = withCaseKinds({...row, security: kind}, cases);
  const next = {...table, rows: table.rows.map((candidate) => (candidate === row ? flagged : candidate))};
  writeAtomic(file.table, pretty(next));
  writeAtomic(file.readme, renderReadme(readme, next));
  writeAtomic(file.orchestrator, orchestrator);
};
