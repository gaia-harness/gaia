#!/usr/bin/env node
// Renders SPEC and plan audit lens and refuter briefs from the docs.
//
//   lens-brief.mjs lens --kind spec --lens <ID> --artifact <DRAFT_PATH> --audit-dir <dir> --repo-root <root> --spec-id <id>
//   lens-brief.mjs lens --kind plan --lens <ID> --artifact <PLAN_DIR> --audit-dir <dir> --repo-root <root> [--spec-path <path>]
//   lens-brief.mjs refuter --kind spec|plan --lens <ID> --findings <file> --brief <lens brief> --audit-dir <dir>
//       --artifact <path> --repo-root <root> --shape single|deep|batched|deep-batched --ids <id,...> --verdicts <path,...>
//       [--refuter-lens correctness|security/safety|reproduces-as-described]
//   lens-brief.mjs classify --findings <file> [--brief <lens brief>]
//
// `lens` and `refuter` write the brief to <audit-dir>/briefs/ (the target is
// removed first, so a refused render leaves no file) and print the short prompt
// for the Agent call. A refuter brief exists only when `classify` says the lens
// findings file is real. `classify` runs audit-noop-detect.sh on the file and,
// with --brief, also treats a missing or different top-level brief_token as a
// no-op. Exit 0 ok, 1 refusal or no-op, 2 usage. Every refusal prints one
// `lens-brief: <reason>` line on stderr.

import {spawnSync} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

import {
  DOCS,
  Refusal,
  clauseText,
  directiveRules,
  fill,
  labelledBlockquote,
  lensSource,
  preambleSlots,
  preambleText,
  readLines,
  refuterPrompt,
  section,
  verdictSchema,
} from './lens-brief-sources.mjs';

const NOOP_DETECT = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  'audit-noop-detect.sh',
);
const SHAPES = ['single', 'deep', 'batched', 'deep-batched'];
const REFUTER_LENSES = ['correctness', 'security/safety', 'reproduces-as-described'];
const TOKEN_KEY = /"brief_token":\s*"([0-9a-f]{32})"/;

class Usage extends Error {}

const parseArguments = (argv) => {
  const options = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i].startsWith('--') || argv[i + 1] === undefined) {
      throw new Usage(`bad argument ${argv[i]}`);
    }
    options[argv[i].slice(2)] = argv[i + 1];
  }
  return options;
};

const need = (options, ...names) => {
  for (const name of names) {
    if (!options[name]) throw new Usage(`--${name} is required`);
  }
};

const classify = (findings, briefPath) => {
  const detected = spawnSync(
    'bash',
    [NOOP_DETECT, '--shape', 'agent-report-file', '--path', findings, '--report-key', 'findings'],
    {encoding: 'utf8'},
  );
  if (detected.status !== 0) {
    process.stderr.write(detected.stderr ?? '');
    return detected.status ?? 2;
  }
  if (!briefPath) return 0;
  let briefText;
  try {
    briefText = readFileSync(briefPath, 'utf8');
  } catch {
    throw new Usage(`cannot read brief ${briefPath}`);
  }
  const expected = TOKEN_KEY.exec(briefText)?.[1];
  if (!expected) throw new Usage(`brief ${briefPath} carries no token`);
  const written = JSON.parse(readFileSync(findings, 'utf8')).brief_token;
  if (written === expected) return 0;
  process.stderr.write(`lens-brief: ${findings} has a missing or wrong brief_token\n`);
  return 1;
};

const briefTarget = (auditDir, name) =>
  path.resolve(auditDir, 'briefs', name);

const shortPrompt = (dispatchLines, label, values) =>
  fill(
    labelledBlockquote(section(dispatchLines, '## Shared preamble'), label),
    values,
  );

const writeBrief = (target, text) => {
  if (!text.trim()) throw new Refusal('empty brief');
  mkdirSync(path.dirname(target), {recursive: true});
  writeFileSync(target, `${text.trimEnd()}\n`);
};

const renderLens = (options) => {
  need(options, 'kind', 'lens', 'artifact', 'audit-dir', 'repo-root');
  const {kind, lens: id, artifact, 'repo-root': root} = options;
  if (!['spec', 'plan'].includes(kind)) throw new Usage(`unknown --kind ${kind}`);
  if (kind === 'spec' && !options['spec-id']) {
    throw new Usage('--kind spec requires --spec-id');
  }
  if (kind === 'spec' && options['spec-path']) {
    throw new Usage('--spec-path is only for --kind plan');
  }
  const target = briefTarget(options['audit-dir'], `${kind}-${id}.md`);
  rmSync(target, {force: true});

  const dispatchLines = readLines(root, DOCS.dispatch);
  const token = randomBytes(16).toString('hex');
  const source = lensSource(root, kind, id);
  const preamble = fill(preambleText(dispatchLines), {
    ...preambleSlots(dispatchLines, kind, artifact, options['spec-id']),
    '<LENS>': id,
    '<repo_root>': root,
  });
  const focus =
    kind === 'plan'
      ? fill(source.focus, {
          '<PLAN_DIR>': artifact,
          '<repo_root>': root,
          '<SPEC_PATH>': options['spec-path'],
        })
      : source.focus;
  const clause = fill(clauseText(dispatchLines, kind), {
    '<BRIEF_TOKEN>': token,
    ...(kind === 'spec' ? {'<DIRECTIVE_RULES>': directiveRules(root)} : {}),
  });
  writeBrief(
    target,
    `${preamble}\n\nLENS: ${source.name} (id prefix ${id})\n${focus}\n\n${clause}`,
  );
  return shortPrompt(dispatchLines, 'Lens short prompt:', {
    '<audit>': kind === 'spec' ? 'SPEC' : 'plan',
    '<brief path>': target,
    '<ID>': id,
    '<name>': source.name,
  });
};

const renderRefuter = (options) => {
  need(
    options,
    'kind', 'lens', 'findings', 'brief', 'audit-dir', 'artifact', 'repo-root', 'shape', 'ids', 'verdicts',
  );
  const {kind, shape, artifact, 'repo-root': root} = options;
  if (!['spec', 'plan'].includes(kind)) throw new Usage(`unknown --kind ${kind}`);
  if (!SHAPES.includes(shape)) throw new Usage(`unknown --shape ${shape}`);
  const ids = options.ids.split(',');
  const verdicts = options.verdicts.split(',');
  if (ids.length !== verdicts.length) throw new Usage('--ids and --verdicts differ in length');
  if (['single', 'deep'].includes(shape) && ids.length !== 1) {
    throw new Usage(`--shape ${shape} takes exactly one id`);
  }
  const refuterLens = options['refuter-lens'];
  if (shape === 'deep' && !REFUTER_LENSES.includes(refuterLens)) {
    throw new Usage('--shape deep requires a valid --refuter-lens');
  }
  const slug = shape === 'deep' ? `-${refuterLens.replace('/', '-')}` : '';
  const target = briefTarget(
    options['audit-dir'],
    `refuter-${kind}-${options.lens}-${ids[0]}${slug}.md`,
  );
  rmSync(target, {force: true});

  const code = classify(options.findings, options.brief);
  if (code === 2) throw new Usage('classify reported a usage error');
  if (code !== 0) throw new Refusal(`lens findings ${options.findings} are not real`);

  const dispatchLines = readLines(root, DOCS.dispatch);
  const prompt = fill(refuterPrompt(root, kind), {
    ...(kind === 'spec' ? {'<DRAFT_PATH>': artifact} : {'<PLAN_DIR>': artifact}),
    '<finding_id>': ids.join(', '),
    '<findings_file>': options.findings,
    '<repo_root>': root,
    '<verdict_file>': verdicts.join(', '),
  });
  const lensLines = (shape === 'deep' ? [refuterLens] : shape === 'deep-batched' ? REFUTER_LENSES : []).map(
    (name) => shortPrompt(dispatchLines, 'Verification lens line', {'<verification lens>': name}),
  );
  const parts = [...lensLines, ...(lensLines.length ? [''] : []), prompt, '', verdictSchema(root, kind)];
  if (shape.endsWith('batched')) {
    parts.push('', shortPrompt(dispatchLines, 'Batched refuter instruction', {}));
  }
  writeBrief(target, parts.join('\n'));
  return shortPrompt(dispatchLines, 'Refuter short prompt:', {
    '<audit>': kind === 'spec' ? 'SPEC' : 'plan',
    '<brief path>': target,
  });
};

const main = () => {
  const [command, ...rest] = process.argv.slice(2);
  try {
    const options = parseArguments(rest);
    if (command === 'classify') {
      need(options, 'findings');
      return classify(options.findings, options.brief);
    }
    if (command !== 'lens' && command !== 'refuter') {
      throw new Usage('usage: lens-brief.mjs lens|refuter|classify ...');
    }
    process.stdout.write(`${(command === 'lens' ? renderLens : renderRefuter)(options)}\n`);
    return 0;
  } catch (error) {
    if (error instanceof Usage) {
      process.stderr.write(`lens-brief: ${error.message}\n`);
      return 2;
    }
    if (error instanceof Refusal) {
      process.stderr.write(`lens-brief: ${error.message}\n`);
      return 1;
    }
    throw error;
  }
};

process.exitCode = main();
