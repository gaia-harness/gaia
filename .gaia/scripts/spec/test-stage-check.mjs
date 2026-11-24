#!/usr/bin/env node
// The test stage's coverage check: a script, not a judgment, confirms the test
// lists the stage wrote cover what the SPEC states. Owner of the refusal list
// below; the test stage reference points here instead of restating it.
//
// Usage: node test-stage-check.mjs --plan-dir <dir> [--spec <SPEC.md>]
// Output: one stdout line per refusal, `test-stage-check: <reason>`. Nothing on
// stdout when every list is accepted.
// Exit: 0 accepted, 1 refused, 2 usage error or an unreadable file.
//
// Reads every `task-*.md` of the plan directory. Test lines are read under each
// doc's `## Tests` heading; a Flow test line is read anywhere in the doc, as the plan
// check reads it, since the closing phase's task doc carries it under no named
// heading:
//
//   - Test (<behavior id>, <layer>, <security kind>): <file> › <title>
//   - Flow test (<flow_id>): <repo-relative test path>
//
// The `›` is U+203A with one space each side. `<layer>` is one of LAYERS.
// `<security kind>` is `access`, `forgery` or `secret` when the behavior's kind
// is that kind, else `none`. The record `TEST-STAGE` is not read here, only the
// lines.
//
// Refusals:
//   - a malformed Test or Flow test line (a missing field, a layer outside
//     LAYERS, or a separator other than U+203A);
//   - a behavior id the SPEC lacks;
//   - an access, forgery, secret, refusal or data-loss behavior with no Test
//     line;
//   - a SPEC flow with no Flow test line (spec-derived only);
//   - two Test lines with one behavior id and one layer;
//   - a security kind other than the one the behavior's kind derives.
//
// Spec-less mode (no --spec): the behavior id is `<task stem>:AC<n>`, the n-th
// acceptance-criterion bullet (1-based) under the `## Acceptance criteria`
// heading of that task doc. It checks the form, that the named bullet exists,
// and the same-layer rule; no Flow test line is required.
//
// The same-layer refusal is the deterministic floor only. The stage's own cap,
// at most one test per stated behavior at the cheapest layer that proves it,
// is stated in the test stage reference and checked by its review lens.

import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {parseBehaviors, SECURITY_KINDS} from './behaviors.mjs';
import {LIST_ITEM_MARKER} from './drop-check-lib.mjs';

const LAYERS = ['unit', 'story', 'route', 'real-server', 'browser', 'shell'];
const MUST_BE_TESTED_KINDS = [...SECURITY_KINDS, 'refusal', 'data-loss'];
const USAGE = 'usage: test-stage-check.mjs --plan-dir <dir> [--spec <SPEC.md>]';

const TESTS_HEADING = /^## Tests\s*$/;
const CRITERIA_HEADING = /^## Acceptance criteria\s*$/;
const ANY_HEADING = /^## /;
const TEST_LINE = /^- Test \(([^)]*)\): (.*)$/;
const FLOW_TEST_LINE = /^\s*- Flow test \(([^)]*)\): (.*)$/;
const FILE_TITLE = /^(\S+) › (\S.*)$/;
const CRITERION_ID = /^(.+):AC([1-9][0-9]*)$/;

function usageExit() {
  process.stderr.write(`${USAGE}\n`);
  process.exit(2);
}

function fail(message) {
  process.stderr.write(`test-stage-check: ${message}\n`);
  process.exit(2);
}

function parseArguments(argv) {
  const options = {planDir: null, spec: null};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (value === undefined || !['--plan-dir', '--spec'].includes(flag)) {
      usageExit();
    }
    if (flag === '--plan-dir') options.planDir = value;
    else options.spec = value;
  }
  if (!options.planDir) usageExit();
  return options;
}

function readText(file) {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return fail(`cannot read ${file}`);
  }
}

// The flow ids of a SPEC's frontmatter `flows:` list.
function readFlowIds(specText) {
  const lines = specText.split('\n');
  if (lines[0] !== '---') return [];
  const ids = [];
  let inFlows = false;
  for (const line of lines.slice(1)) {
    if (line === '---') break;
    if (/^flows:\s*$/.test(line)) {
      inFlows = true;
      continue;
    }
    if (inFlows && /^\S/.test(line)) inFlows = false;
    const match =
      inFlows && /^\s*-?\s*flow_id:\s*["']?([^"'\s]+)["']?\s*$/.exec(line);
    if (match) ids.push(match[1]);
  }
  return ids;
}

// The lines of one `##` section, between its heading and the next.
function sectionLines(text, headingPattern) {
  const collected = [];
  let inSection = false;
  for (const line of text.split('\n')) {
    const clean = line.replace(/\r$/, '');
    if (headingPattern.test(clean)) {
      inSection = true;
      continue;
    }
    if (inSection && ANY_HEADING.test(clean)) break;
    if (inSection) collected.push(clean);
  }
  return collected;
}

function countCriteria(taskText) {
  return sectionLines(taskText, CRITERIA_HEADING).filter((line) =>
    LIST_ITEM_MARKER.test(line),
  ).length;
}

// The refusal for one Test line, or null when the line is accepted. Marks the
// behavior tested and the pair seen as it goes.
function checkTestLine(line, context) {
  const testMatch = TEST_LINE.exec(line);
  const fields = testMatch ? testMatch[1].split(', ') : [];
  const fileTitle = testMatch ? FILE_TITLE.exec(testMatch[2]) : null;
  if (
    !testMatch ||
    fields.length !== 3 ||
    fields.some((field) => !field.trim()) ||
    !fileTitle
  ) {
    return `malformed Test line: ${line}`;
  }
  const [behaviorId, layer, kind] = fields;
  if (!LAYERS.includes(layer)) {
    return `malformed Test line, layer "${layer}" is not one of ${LAYERS.join(', ')}: ${line}`;
  }
  if (context.spec) {
    const behavior = context.behaviorsById.get(behaviorId);
    if (!behavior) return `behavior ${behaviorId} is not in the SPEC`;
    const derived = SECURITY_KINDS.includes(behavior.kind)
      ? behavior.kind
      : 'none';
    if (kind !== derived) {
      return `${behaviorId} (${behavior.kind}) must carry security kind ${derived}, not ${kind}`;
    }
  } else {
    const criterion = CRITERION_ID.exec(behaviorId);
    const stemText = criterion ? context.taskTexts.get(criterion[1]) : undefined;
    if (
      !criterion ||
      stemText === undefined ||
      Number(criterion[2]) > countCriteria(stemText)
    ) {
      return `${behaviorId} names no acceptance criterion of a task doc`;
    }
  }
  context.testedBehaviorIds.add(behaviorId);
  const pair = `${behaviorId}\t${layer}`;
  const duplicate = context.seenPairs.has(pair);
  context.seenPairs.add(pair);
  return duplicate ? `two tests of ${behaviorId} at the ${layer} layer` : null;
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  if (!existsSync(options.planDir)) fail(`no such directory ${options.planDir}`);
  const taskFiles = readdirSync(options.planDir)
    .filter((name) => /^task-.*\.md$/.test(name))
    .sort();
  const behaviorsById = new Map();
  let flowIds = [];
  if (options.spec) {
    const specText = readText(options.spec);
    for (const behavior of parseBehaviors(specText).behaviors) {
      if (!behaviorsById.has(behavior.id)) behaviorsById.set(behavior.id, behavior);
    }
    flowIds = readFlowIds(specText);
  }

  const taskTexts = new Map();
  for (const name of taskFiles) {
    taskTexts.set(
      name.replace(/\.md$/, ''),
      readText(path.join(options.planDir, name)),
    );
  }

  const refusals = [];
  const flowsWithTests = new Set();
  const context = {
    spec: Boolean(options.spec),
    behaviorsById,
    taskTexts,
    testedBehaviorIds: new Set(),
    seenPairs: new Set(),
  };
  for (const name of taskFiles) {
    const taskText = taskTexts.get(name.replace(/\.md$/, ''));
    for (const rawLine of taskText.split('\n')) {
      const line = rawLine.replace(/\r$/, '');
      const flowMatch = FLOW_TEST_LINE.exec(line);
      if (!flowMatch) continue;
      if (flowMatch[1].trim() && /^\S+$/.test(flowMatch[2].trim())) {
        flowsWithTests.add(flowMatch[1].trim());
      } else refusals.push(`${name}: malformed Flow test line: ${line}`);
    }
    for (const line of sectionLines(taskText, TESTS_HEADING)) {
      if (FLOW_TEST_LINE.test(line)) continue;
      if (!/^- (Flow )?[Tt]est\b/.test(line)) continue;
      const refusal = checkTestLine(line, context);
      if (refusal) refusals.push(`${name}: ${refusal}`);
    }
  }

  if (options.spec) {
    for (const behavior of behaviorsById.values()) {
      if (
        MUST_BE_TESTED_KINDS.includes(behavior.kind) &&
        !context.testedBehaviorIds.has(behavior.id)
      ) {
        refusals.push(`${behavior.id} (${behavior.kind}) has no Test line`);
      }
    }
    for (const flowId of flowIds) {
      if (!flowsWithTests.has(flowId)) {
        refusals.push(`${flowId} has no Flow test line`);
      }
    }
  }

  for (const refusal of refusals) {
    process.stdout.write(`test-stage-check: ${refusal}\n`);
  }
  process.exit(refusals.length ? 1 : 0);
}

main();
