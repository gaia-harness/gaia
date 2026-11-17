#!/usr/bin/env node
// Renders a SPEC audit report (AUDIT.md) from the on-disk audit cache and the
// fold agent's routing record, so no agent hand-writes the report.
//
// Usage:
//   audit-render.mjs --cache <audit cache dir> --routing <routing.json> \
//     --spec-id <id> --out <AUDIT.md path>
//
// Inputs:
//   <cache>/findings/*.json   every lens file plus completeness.json when
//                             present; self-review.json is not read
//   <cache>/verdicts/*.json   counted for the refuted lines' reasons (the first
//                             line of `reasoning`)
//   <cache>/coverage.jsonl    one phase/lens/disposition record per line
//   <routing.json>            the fold agent's record: tier, verdict and one
//                             entry per routed finding
//
// Output: the report template of the SPEC audit's persist step. The output is
// a pure function of the inputs, whatever order files and routing entries
// arrive in.
//
// Exit codes: 0 written; 1 a refusal, nothing written, one
// `audit-render: <reason>` line per problem on stderr (a directive text holding
// a newline, starting with `#` or with `<number>. `, or no text at all; plus
// an unreadable input or a routing record that leaves a finding unplaceable);
// 2 usage. The file is written through a temp file and a rename.

import {
  existsSync,
  readFileSync,
  readdirSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import {basename, dirname, join} from 'node:path';

const NAME = 'audit-render';
const SEVERITY_RANK = {none: 0, minor: 1, major: 2, critical: 3};
const DIRECTIVE_LEAD =
  "These satisfy the SPEC's binding contracts; the plan and implementation must honor them.";

const usage = () => {
  process.stderr.write(
    `usage: ${NAME}.mjs --cache <dir> --routing <routing.json> --spec-id <id> --out <AUDIT.md>\n`
  );
  process.exit(2);
};

const parseArguments = (argv) => {
  const options = {};
  const names = ['cache', 'routing', 'spec-id', 'out'];
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith('--') || !names.includes(flag.slice(2))) usage();
    if (value === undefined || value.startsWith('--')) usage();
    options[flag.slice(2)] = value;
  }
  if (names.some((name) => !options[name])) usage();
  return options;
};

const problems = [];
const refuse = (reason) => problems.push(`${NAME}: ${reason}`);

const readJson = (path, label) => {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    refuse(`${label}: cannot read ${path}: ${error.message}`);
    return null;
  }
};

const listJson = (directory) =>
  existsSync(directory)
    ? readdirSync(directory)
        .filter((name) => name.endsWith('.json'))
        .sort()
    : [];

// "SEC-001" sorts by prefix alphabetically, then by number.
const compareIds = (left, right) => {
  const split = (id) => {
    const match = /^(.*?)-?(\d+)$/.exec(id);
    return match ? [match[1], Number(match[2])] : [id, 0];
  };
  const [leftPrefix, leftNumber] = split(left);
  const [rightPrefix, rightNumber] = split(right);
  if (leftPrefix !== rightPrefix) return leftPrefix < rightPrefix ? -1 : 1;
  if (leftNumber !== rightNumber) return leftNumber - rightNumber;
  return left < right ? -1 : left > right ? 1 : 0;
};

const escapeRegex = (text) => text.replaceAll(/[.*+?^${}()|[\]\\]/g, '\\$&');

const loadFindings = (cache) => {
  const findingsById = new Map();
  let lensCount = 0;
  let raised = 0;
  for (const name of listJson(join(cache, 'findings'))) {
    if (name === 'self-review.json') continue;
    const document = readJson(join(cache, 'findings', name), 'findings');
    if (!document) continue;
    if (name !== 'completeness.json') lensCount += 1;
    const lens = document.dimension ?? basename(name, '.json');
    for (const finding of document.findings ?? []) {
      raised += 1;
      if (findingsById.has(finding.id)) {
        refuse(`${finding.id}: finding id appears in more than one findings file`);
        continue;
      }
      findingsById.set(finding.id, {...finding, lens});
    }
  }
  return {findingsById, lensCount, raised};
};

// The first line of the reasoning of a finding's verdict file. Standard and
// batched runs write <id>.json; Deep writes <id>-<slug>.json, one per refuter,
// and the first in slug order whose verdict matches the routed one is used.
const reasonFor = (cache, id, routedVerdict) => {
  const directory = join(cache, 'verdicts');
  const pattern = new RegExp(`^${escapeRegex(id)}(-[a-z0-9][a-z0-9-]*)?\\.json$`);
  const names = listJson(directory).filter((name) => pattern.test(name));
  const ordered = [
    ...names.filter((name) => name === `${id}.json`),
    ...names.filter((name) => name !== `${id}.json`),
  ];
  for (const name of ordered) {
    const verdict = readJson(join(directory, name), `verdict ${id}`);
    if (!verdict) return null;
    if (name !== `${id}.json` && verdict.verdict !== routedVerdict) continue;
    const firstLine = String(verdict.reasoning ?? '')
      .split(/\r?\n/)
      .find((line) => line.trim() !== '');
    return firstLine?.trim() ?? '(no reasoning recorded)';
  }
  return '(no verdict file)';
};

const directiveTextProblems = (id, text) => {
  if (typeof text !== 'string' || text.trim() === '') {
    return [`${id}: plan-time directive has no text`];
  }
  const found = [];
  if (/[\n\r]/.test(text)) found.push(`${id}: directive text holds a newline`);
  if (text.startsWith('#')) found.push(`${id}: directive text starts with #`);
  if (/^\d+\. /.test(text)) {
    found.push(`${id}: directive text starts with a number prefix`);
  }
  return found;
};

const oneLine = (text) => String(text ?? '').replaceAll(/\r?\n/g, ' ');

const main = () => {
  const options = parseArguments(process.argv.slice(2));
  const cache = options.cache;
  const routing = readJson(options.routing, 'routing');
  const {findingsById, lensCount, raised} = loadFindings(cache);

  const coveragePath = join(cache, 'coverage.jsonl');
  const coverageLines = [];
  if (existsSync(coveragePath)) {
    for (const line of readFileSync(coveragePath, 'utf8').split('\n')) {
      if (line.trim() === '') continue;
      try {
        const record = JSON.parse(line);
        coverageLines.push(
          `- **${record.phase}** (\`${record.lens}\`): \`${record.disposition}\``
        );
      } catch {
        refuse(`coverage: not a JSON record: ${line.slice(0, 60)}`);
      }
    }
  } else {
    refuse(`coverage: cannot read ${coveragePath}`);
  }

  if (!routing || !Array.isArray(routing.findings)) {
    if (routing) refuse('routing: no findings array');
    return finish();
  }
  if (typeof routing.verdict !== 'string' || routing.verdict.trim() === '') {
    refuse('routing: no verdict paragraph');
  }

  const entriesById = new Map();
  for (const entry of routing.findings) {
    if (entriesById.has(entry.id)) {
      refuse(`${entry.id}: routing lists the finding more than once`);
    }
    entriesById.set(entry.id, entry);
    if (!findingsById.has(entry.id)) {
      refuse(`${entry.id}: routing names a finding no findings file holds`);
    }
  }

  const directives = [];
  const fixes = [];
  const refutedLines = [];
  const notRouted = [];
  const survivorSeverity = {critical: 0, major: 0, minor: 0};
  let survived = 0;
  let refuted = 0;

  for (const id of [...findingsById.keys()].sort(compareIds)) {
    const finding = findingsById.get(id);
    const entry = entriesById.get(id) ?? {};
    const isMinor = finding.severity === 'minor';
    const status = entry.status ?? 'unrouted';

    if (status === 'refuted') {
      refuted += 1;
      refutedLines.push({
        id,
        entry,
        finding,
        lowered: true,
      });
      continue;
    }

    let disposition = entry.disposition ?? null;
    if (!disposition && isMinor) disposition = finding.proposed_disposition ?? null;
    if (!disposition) {
      if (isMinor) notRouted.push(id);
      else refuse(`${id}: ${finding.severity} finding has no routing disposition`);
      continue;
    }

    survived += 1;
    const corrected =
      entry.corrected_severity && entry.corrected_severity !== 'none'
        ? entry.corrected_severity
        : finding.severity;
    if (corrected in survivorSeverity) survivorSeverity[corrected] += 1;

    const lowered =
      entry.verdict === 'partial' &&
      entry.corrected_severity != null &&
      (SEVERITY_RANK[entry.corrected_severity] ?? 99) <
        (SEVERITY_RANK[finding.severity] ?? 0);
    if (lowered) refutedLines.push({id, entry, finding, lowered});

    if (disposition === 'plan_directive') {
      const text = entry.directive_text ?? finding.directive;
      const found = directiveTextProblems(id, text);
      if (found.length > 0) {
        for (const line of found) refuse(line);
      } else {
        const evidence = oneLine(finding.evidence);
        directives.push(
          `${text} (${id}${evidence.trim() === '' ? '' : `; ${evidence}`})`
        );
      }
    } else if (disposition === 'spec_defect') {
      const decision = entry.decision ?? null;
      if (decision === 'apply' || decision === 'revise') {
        if (typeof entry.folded_text !== 'string' || entry.folded_text.trim() === '') {
          refuse(`${id}: ${decision} decision has no folded_text`);
        } else {
          fixes.push(`- ${id}: ${oneLine(entry.folded_text)}`);
        }
      } else if (decision === 'keep') {
        fixes.push(`- ${id}: not folded (kept): ${oneLine(finding.title)}`);
      } else if (decision === 'deferred') {
        fixes.push(
          `- ${id}: deferred for human review: ${oneLine(finding.title)}`
        );
      } else {
        refuse(`${id}: spec_defect has no apply, revise, keep or deferred decision`);
      }
    } else {
      refuse(`${id}: unknown disposition ${disposition}`);
    }
  }

  const refutedRendered = refutedLines.map(({id, entry, finding}) => {
    const verdict = entry.verdict ?? 'refuted';
    const reason = reasonFor(cache, id, verdict);
    return `- ${id}: ${verdict} (${entry.corrected_severity ?? 'none'}): ${oneLine(reason ?? '(unreadable verdict)')}`;
  });
  if (notRouted.length > 0) {
    refutedRendered.push(
      `Not routed (minor, no verdict or disposition): ${notRouted.join(', ')}`
    );
  }

  if (problems.length > 0) return finish();

  const tier = routing.tier === 'deep' ? 'Deep' : 'Standard';
  const summary =
    `${lensCount} lenses (${tier} tier), ${raised} findings raised, ` +
    `${survived} survived verification, ${refuted} refuted; ` +
    `survivor severity after verification: ${survivorSeverity.critical} critical / ` +
    `${survivorSeverity.major} major / ${survivorSeverity.minor} minor` +
    (notRouted.length > 0
      ? `; not routed (minor, no verdict or disposition): ${notRouted.length}.`
      : '.');

  const numbered = directives.map((line, index) => `${index + 1}. ${line}`);
  const out = [
    `# ${options['spec-id']} Adversarial Audit`,
    '',
    summary,
    '',
    '## Verdict',
    '',
    routing.verdict,
    '',
    '## Plan-time directives (no SPEC change)',
    '',
    DIRECTIVE_LEAD,
    '',
    ...(numbered.length > 0 ? numbered : ['None.']),
    '',
    '## SPEC contract fixes (folded into the draft pre-save)',
    '',
    ...(fixes.length > 0 ? fixes : ['- None.']),
    '',
    '## Refuted / downgraded (for the record)',
    '',
    ...(refutedRendered.length > 0 ? refutedRendered : ['- None.']),
    '',
    '## Coverage',
    '',
    ...coverageLines,
    '',
  ].join('\n');

  return finish(out, options.out);
};

function finish(content, outPath) {
  if (problems.length > 0 || content === undefined) {
    process.stderr.write(`${problems.join('\n')}\n`);
    process.exit(1);
  }
  const temporary = join(
    dirname(outPath),
    `.${basename(outPath)}.${process.pid}.tmp`
  );
  writeFileSync(temporary, content);
  renameSync(temporary, outPath);
}

main();
