// Cell coverage of a set-stated rule's case table (`tests.json` `sets`).
//
// A rule stated as sets (the roles that take each action, the statuses each
// action leaves from) owes one case per member of every axis against every
// member of the others, inside the set or out (`.claude/doctrine/testing.md`,
// `## What to test`). The plan records each such rule as a `sets` entry,
// {source, rows: [ids], axes: {<axis>: [members]}}, and each listed row names
// the combinations it tests in `cells`, [{<axis>: <member>, ...}]. A table
// that samples the set leaves a combination with no cell, which a scan of the
// `case` text alone cannot see. A status entry beside a role or relationship
// entry also carries `actors`, and its cells name who acts (see actorsShape).

import {readFileSync} from 'node:fs';

import {isNonEmptyString} from './table.mjs';

const isPlainObject = (value) =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

// The `sets` value of the table file, undefined when it has none. readTable
// has already refused an unreadable or unparseable file.
export const readSets = (path) => JSON.parse(readFileSync(path, 'utf8')).sets;

const combinations = (axes) =>
  Object.entries(axes).reduce(
    (partial, [axis, members]) =>
      partial.flatMap((cell) => members.map((member) => ({...cell, [axis]: member}))),
    [{}],
  );

// Labelled in the axes' order, so a cell written in any key order matches its
// combination.
const cellLabel = (names, cell) =>
  names.map((name) => `${name} ${cell[name]}`).join(', ');

// Whether the case text holds the member bounded by neither a word character
// nor `-`, so `view` is not found inside `viewer` or `view-only`.
const namesMember = (caseText, member) =>
  new RegExp(
    String.raw`(?<![\w-])${member.toLowerCase().replaceAll(/[$()*+.?[\\\]^{|}]/g, String.raw`\$&`)}(?![\w-])`,
  ).test(caseText);

const isMemberList = (members) =>
  Array.isArray(members) && members.length > 0 && members.every(isNonEmptyString);

const hasDuplicate = (members) => new Set(members).size !== members.length;

const axesProblems = (label, axes) => {
  if (!isPlainObject(axes)) {
    return [`${label} has no axes object`];
  }
  const names = Object.keys(axes);
  if (names.length < 2) return [`${label} names fewer than two axes`];
  const problems = [];
  for (const name of names) {
    const members = axes[name];
    if (!isMemberList(members)) {
      problems.push(`${label} axis ${name} is not a non-empty list of members`);
    } else if (hasDuplicate(members)) {
      problems.push(`${label} axis ${name} lists a member twice`);
    }
  }
  return problems;
};

const isActionPair = (axes) => {
  const names = Object.keys(axes);
  return names.length === 2 && names.includes('action');
};

const actionKey = (axes) => [...axes.action].sort().join('\n');

// A status entry's `actors`, {<axis>: {<action>: [members]}}: the roles or
// relationships inside each action's set. Without it a status table run by
// one role passes, so a status guard on that role's path alone passes every
// test. On no problems, also returns the actor {axis, map}.
const actorsShape = (label, {actors, axes}) => {
  if (actors === undefined) return {problems: []};
  if (!isActionPair(axes)) {
    return {problems: [`${label} has actors but its axes are not action and one other`]};
  }
  if (!isPlainObject(actors) || Object.keys(actors).length !== 1) {
    return {problems: [`${label} actors does not name exactly one axis`]};
  }
  const [axis] = Object.keys(actors);
  const map = actors[axis];
  if (Object.hasOwn(axes, axis)) {
    return {problems: [`${label} actors names ${axis}, which is already one of its axes`]};
  }
  if (!isPlainObject(map)) return {problems: [`${label} actors ${axis} is not an object`]};
  const problems = [];
  for (const action of axes.action) {
    if (!isMemberList(map[action])) {
      problems.push(`${label} actors ${axis} gives action ${action} no non-empty list of members`);
    } else if (hasDuplicate(map[action])) {
      problems.push(`${label} actors ${axis} lists a member twice for action ${action}`);
    }
  }
  for (const action of Object.keys(map)) {
    if (!axes.action.includes(action)) {
      problems.push(`${label} actors ${axis} names action ${action}, which its axes do not list`);
    }
  }
  return problems.length > 0 ? {problems} : {problems, actor: {axis, map}};
};

// The other entries pairing the same actions with a role or relationship. They
// are read before their own shape check runs, so each is guarded here.
const partnersOf = (entry, sets) =>
  sets.filter(
    (other) =>
      other !== entry &&
      isPlainObject(other?.axes) &&
      Array.isArray(other.axes.action) &&
      isActionPair(other.axes) &&
      !Object.hasOwn(other.axes, 'status') &&
      actionKey(other.axes) === actionKey(entry.axes),
  );

// A status entry beside a partner covers a rule over both, so it owes actors.
const missingActorsProblems = (label, entry, partners) => {
  if (!Object.hasOwn(entry.axes, 'status') || partners.length === 0) return [];
  const partnerAxis = Object.keys(partners[0].axes).find((name) => name !== 'action');
  return [
    `${label} pairs the actions with status while another entry pairs them with ${partnerAxis}, but has no actors naming the ${partnerAxis} inside each action's set`,
  ];
};

const actorMembershipProblems = (label, actor, partners) => {
  const listed = partners.find((other) => Object.hasOwn(other.axes, actor.axis))?.axes[actor.axis];
  if (!Array.isArray(listed)) return [];
  return Object.entries(actor.map).flatMap(([action, members]) =>
    members
      .filter((member) => !listed.includes(member))
      .map((member) => `${label} actors ${actor.axis} names ${member} for action ${action}, which no entry's ${actor.axis} axis lists`),
  );
};

// Each problem with one row's cells against its entry's axes and, for a
// status entry with actors, the actor each cell names.
const rowCellProblems = (label, row, axes, actor) => {
  if (!Array.isArray(row.cells) || row.cells.length === 0) {
    return [`${label} lists row ${row.id}, which has no cells`];
  }
  const caseText = typeof row.case === 'string' ? row.case.toLowerCase() : '';
  const names = actor ? [...Object.keys(axes), actor.axis] : Object.keys(axes);
  const kind = actor ? 'axes and actor' : 'axes';
  // The actor's allowed members depend on the cell's action; an unknown
  // action is refused on its own axis, so its actor is not judged again.
  const allowed = (name, cell) =>
    name === actor?.axis ? actor.map[cell.action] : axes[name];
  const problems = [];
  row.cells.forEach((cell, index) => {
    const where = `row ${row.id} cell #${index + 1}`;
    if (!isPlainObject(cell)) {
      problems.push(`${where} is not an object`);
      return;
    }
    const keys = Object.keys(cell);
    if (keys.length !== names.length || !names.every((name) => keys.includes(name))) {
      problems.push(`${where} does not name exactly the ${kind} ${names.join(', ')} of ${label}`);
      return;
    }
    for (const name of names) {
      const members = allowed(name, cell);
      if (members === undefined) continue;
      if (!members.includes(cell[name])) {
        problems.push(
          name === actor?.axis
            ? `${where} names ${name} ${cell[name]}, which ${label} actors does not list for action ${cell.action}`
            : `${where} names ${name} ${cell[name]}, which ${label} does not list`,
        );
      } else if (!namesMember(caseText, cell[name])) {
        problems.push(`${where} names ${name} ${cell[name]}, which the row's case does not`);
      }
    }
  });
  return problems;
};

// Every problem the table's `sets` entries have against its rows and keys: a
// malformed entry, a listed row the table lacks, retires or holds, a cell its
// entry does not allow or its row's case does not name, and each combination
// of an entry's axes no listed row holds. Without a keySet the source check is
// skipped, for a caller that holds no keys file.
export const setCellProblems = ({rows, sets}, keySet) => {
  if (sets === undefined) return [];
  if (!Array.isArray(sets)) return ['sets is not an array'];
  const rowsById = new Map(
    rows.filter((row) => row && typeof row === 'object').map((row) => [row.id, row]),
  );
  const problems = [];
  sets.forEach((entry, index) => {
    if (!isPlainObject(entry)) {
      problems.push(`sets entry #${index + 1} is not an object`);
      return;
    }
    const hasSource = isNonEmptyString(entry.source);
    const label = hasSource ? `sets entry ${entry.source}` : `sets entry #${index + 1}`;
    if (!hasSource) {
      problems.push(`${label} has no source`);
    } else if (keySet && !keySet.has(entry.source)) {
      problems.push(`${label} cites unknown source ${entry.source}`);
    }
    const shape = axesProblems(label, entry.axes);
    if (!Array.isArray(entry.rows) || entry.rows.length === 0) {
      shape.push(`${label} names no rows`);
    }
    if (shape.length > 0) {
      problems.push(...shape);
      return;
    }
    const {problems: actorProblems, actor} = actorsShape(label, entry);
    if (actorProblems.length > 0) {
      problems.push(...actorProblems);
      return;
    }
    const partners = isActionPair(entry.axes) ? partnersOf(entry, sets) : [];
    problems.push(
      ...(actor
        ? actorMembershipProblems(label, actor, partners)
        : missingActorsProblems(label, entry, partners)),
    );
    // Every combination of each projection needs a cell. With actors, the
    // second asks for each actor at least once at each status: the cheapest
    // table that sends every role or relationship past the status guard. It
    // cannot see a guard that differs per (actor, action) pair; that needs
    // every actor of every action at every status, which multiplies the rows.
    const projections = [entry.axes];
    if (actor) {
      const otherAxis = Object.keys(entry.axes).find((name) => name !== 'action');
      projections.push({
        [otherAxis]: entry.axes[otherAxis],
        [actor.axis]: [...new Set(Object.values(actor.map).flat())],
      });
    }
    const held = new Set();
    for (const id of entry.rows) {
      const row = rowsById.get(id);
      if (!row) {
        problems.push(`${label} names row ${id}, which the table lacks`);
      } else if (row.action === 'retire' || row.held !== undefined) {
        problems.push(`${label} names row ${id}, which is ${row.action === 'retire' ? 'retired' : 'held'} and so runs no test`);
      } else {
        const rowProblems = rowCellProblems(label, row, entry.axes, actor);
        problems.push(...rowProblems);
        if (rowProblems.length === 0) {
          for (const cell of row.cells) {
            for (const projection of projections) held.add(cellLabel(Object.keys(projection), cell));
          }
        }
      }
    }
    for (const projection of projections) {
      const names = Object.keys(projection);
      for (const cell of combinations(projection)) {
        if (!held.has(cellLabel(names, cell))) {
          problems.push(`${label} has no row for ${cellLabel(names, cell)}`);
        }
      }
    }
  });
  return problems;
};
