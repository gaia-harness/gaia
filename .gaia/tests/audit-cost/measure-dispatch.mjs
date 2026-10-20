#!/usr/bin/env node
// measure-dispatch.mjs: turn one main session transcript (plus its sub-agent
// transcripts) into the schema-1 measurement JSON for the audit-cost toolkit.
//
//   measure-dispatch.mjs --session <main session jsonl> --rates <token-rates.json> [--out <file>] [--measure-types <comma list>]
//
// --measure-types names agent types to measure wherever they sit in the tree
// (the first-call probe dispatches a single type straight from the main thread).
//
// Cost method: every assistant API call, deduped by message id, is priced from
// one rates file with the rules of .gaia/scripts/token-pricing-lib.sh (the row
// is picked by model and by the call's date against each row's
// effective_through; fresh input at the input rate; 5m cache writes at input x
// write_5m; 1h cache writes at input x write_1h; cache reads at input x the
// row's cache_read_multiplier, else the table's read multiplier; output at the
// output rate). Exit 0 on success, 2 on a usage error, 3 naming each model id
// the rates file cannot price (stderr), with no JSON printed.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { classifyChild, DISPATCH_TOOL_NAMES, firstCallAttachments, listAgents, readCalls, readRecords, roundOneContext } from './lib/transcripts.mjs';

const USAGE = 'usage: measure-dispatch.mjs --session <main session jsonl> --rates <token-rates.json> [--out <file>] [--measure-types <comma list>]';
const REFUTER_REFERENCE_SUFFIX = '.claude/hooks/lib/audit-frontend-refuter.md';
const ORACLE_SCRIPT = 'audit-frontend-oracles.sh';

const fail = (message, code) => {
  process.stderr.write(`${message}\n`);
  process.exit(code);
};

const parseArguments = (argv) => {
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!['--session', '--rates', '--out', '--measure-types'].includes(flag) || value === undefined || value.startsWith('--')) fail(USAGE, 2);
    options[flag.slice(2)] = value;
  }
  if (!options.session || !options.rates) fail(USAGE, 2);
  if (!existsSync(options.session)) fail(`measure-dispatch: no such session transcript: ${options.session}`, 2);
  if (!existsSync(options.rates)) fail(`measure-dispatch: no such rates file: ${options.rates}`, 2);
  return options;
};

const roundTo = (value, places) => Number(value.toFixed(places));

const ratesPathOf = (ratesFile) => {
  const name = ratesFile.slice(ratesFile.lastIndexOf('/') + 1);
  try {
    const prefix = execFileSync('git', ['-C', dirname(ratesFile), 'rev-parse', '--show-prefix'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return `${prefix}${name}`;
  } catch {
    return name;
  }
};

const ratesBlobOf = (ratesFile) => execFileSync('git', ['hash-object', ratesFile], { encoding: 'utf8' }).trim();

// The rate row for a model on a call's date: the first row that has no
// effective_through or whose effective_through is on or after the date.
const rateRow = (rates, model, date) =>
  (rates.models[model] ?? []).find((row) => row.effective_through === undefined || row.effective_through === null || (date !== '' && date <= row.effective_through)) ?? null;

const priceCall = (rates, call, unpriceableModels) => {
  const { usage } = call;
  const model = call.model ?? '';
  if (!model.startsWith('claude-')) return 0;
  const row = rateRow(rates, model, (call.ts ?? '').slice(0, 10));
  if (!row) {
    unpriceableModels.add(model);
    return 0;
  }
  const multipliers = rates.cache_multipliers;
  return (
    (usage.input * row.input +
      usage.cacheWrite5m * row.input * multipliers.write_5m +
      usage.cacheWrite1h * row.input * multipliers.write_1h +
      usage.cacheRead * row.input * (row.cache_read_multiplier ?? multipliers.read) +
      usage.output * row.output) /
    1_000_000
  );
};

const contextOf = (call) => call.usage.input + call.usage.cacheWrite5m + call.usage.cacheWrite1h + call.usage.cacheRead;
const secondsBetween = (from, to) => (Date.parse(to) - Date.parse(from)) / 1000;

const extensionRuleFilesOf = (prompt) => {
  const lines = prompt.split('\n');
  const header = lines.findIndex((line) => line.trim() === 'Extension rule files:');
  if (header === -1) return null;
  const paths = [];
  for (const line of lines.slice(header + 1)) {
    if (line.trim() === '') {
      if (paths.length > 0) break;
      continue;
    }
    const match = /^\s*[-*]\s+`?([^`\s]+)`?\s*$/.exec(line);
    if (!match) break;
    paths.push(match[1]);
  }
  return paths;
};

const options = parseArguments(process.argv.slice(2));
const rates = JSON.parse(readFileSync(options.rates, 'utf8'));
const mainRecords = readRecords(options.session);
const agents = listAgents(options.session);
const byId = new Map(agents.map((agent) => [agent.agentId, agent]));
const alwaysMeasuredTypes = new Set((options['measure-types'] ?? '').split(',').filter(Boolean));
const isMember = (agent) => (agent.agentType ?? '').startsWith('code-audit-');

const { unit: unitAgent, fixerTimes, firstFixerTime } = roundOneContext(agents);

const hasMemberAncestor = (agent) => {
  for (let parent = byId.get(agent.parentAgentId); parent; parent = byId.get(parent.parentAgentId)) {
    if (isMember(parent)) return true;
  }
  return false;
};

const isMeasured = (agent) => {
  if (agent === unitAgent) return false;
  if (alwaysMeasuredTypes.has(agent.agentType)) return true;
  if (isMember(agent) || hasMemberAncestor(agent)) return true;
  return Boolean(unitAgent) && agent.parentAgentId === unitAgent.agentId && (firstFixerTime === null || agent.dispatch.ts < firstFixerTime);
};

const roundOf = (agent) => 1 + fixerTimes.filter((time) => time < agent.dispatch.ts).length;

const unpriceableModels = new Set();
const callsById = new Map(agents.map((agent) => [agent.agentId, readCalls(agent.transcriptPath)]));
const costOf = (calls) => calls.reduce((total, call) => total + priceCall(rates, call, unpriceableModels), 0);

const descendantsOf = (agentId) => {
  const found = [];
  for (const agent of agents) {
    if (agent.parentAgentId === agentId) found.push(agent, ...descendantsOf(agent.agentId));
  }
  return found;
};

const measureAgent = (agent) => {
  const calls = callsById.get(agent.agentId);
  const records = readRecords(agent.transcriptPath).filter((record) => record.timestamp);
  const startTime = records.length > 0 ? records[0].timestamp : agent.dispatch.ts;
  const endTime = records.length > 0 ? records[records.length - 1].timestamp : startTime;
  const resultTimes = new Map();
  for (const call of calls) for (const result of call.toolResults) resultTimes.set(result.toolUseId, result.ts);
  let toolSeconds = 0;
  for (const call of calls) {
    for (const use of call.toolUses) {
      const resultTime = resultTimes.get(use.id);
      if (resultTime && use.ts) toolSeconds += Math.max(0, secondsBetween(use.ts, resultTime));
    }
  }
  const wallSeconds = secondsBetween(startTime, endTime);
  const first = calls[0] ?? null;
  const steadyStateCall = calls.find((call) =>
    call.toolUses.some((use) => DISPATCH_TOOL_NAMES.has(use.name) || (use.name === 'Bash' && String(use.input?.command ?? '').includes(ORACLE_SCRIPT))),
  );
  const parent = byId.get(agent.parentAgentId) ?? null;
  const classification = parent && isMember(parent) ? classifyChild(agent.dispatch) : { kind: null, role: null };
  const directChildren = agents.filter((child) => child.parentAgentId === agent.agentId);
  const childrenByRole = {};
  const specialistCounts = {};
  if (isMember(agent)) {
    for (const child of directChildren) {
      const childClass = classifyChild(child.dispatch);
      const key = childClass.kind === 'refuter' ? 'refuter' : childClass.kind === 'specialist' ? (childClass.role ?? 'unknown') : null;
      if (key === null) continue;
      childrenByRole[key] = (childrenByRole[key] ?? 0) + 1;
      if (childClass.kind === 'specialist') specialistCounts[key] = (specialistCounts[key] ?? 0) + 1;
    }
  }
  const noopRetries = Object.values(specialistCounts).reduce((total, count) => total + Math.max(0, count - 1), 0);
  const cost = costOf(calls);
  const childrenCost = descendantsOf(agent.agentId).reduce((total, child) => total + costOf(callsById.get(child.agentId)), 0);
  return {
    agent_id: agent.agentId,
    agent_type: agent.agentType,
    child_kind: classification.kind,
    role: classification.role,
    parent_agent_id: agent.parentAgentId,
    model: first?.model ?? null,
    round: roundOf(agent),
    first_call: {
      context: first ? contextOf(first) : 0,
      fresh_input: first?.usage.input ?? 0,
      cache_write: first ? first.usage.cacheWrite5m + first.usage.cacheWrite1h : 0,
      cache_read: first?.usage.cacheRead ?? 0,
    },
    first_call_attachments: { skill_listing: 0, deferred_tools_delta: 0, ...firstCallAttachments(agent.transcriptPath) },
    steady_state_context: steadyStateCall ? contextOf(steadyStateCall) : null,
    calls: calls.length,
    per_call: calls.map((call) => ({ cache_write: call.usage.cacheWrite5m + call.usage.cacheWrite1h, cache_read: call.usage.cacheRead })),
    cost_usd: roundTo(cost, 6),
    wall_s: roundTo(wallSeconds, 3),
    tool_s: roundTo(toolSeconds, 3),
    model_s: roundTo(wallSeconds - toolSeconds, 3),
    prompt_chars: agent.dispatch.prompt.length,
    extension_rule_files: classification.kind === 'specialist' ? extensionRuleFilesOf(agent.dispatch.prompt) : null,
    reads_refuter_reference: calls.some((call) => call.toolUses.some((use) => use.name === 'Read' && String(use.input?.file_path ?? '').endsWith(REFUTER_REFERENCE_SUFFIX))),
    children_by_role: childrenByRole,
    noop_retries: noopRetries,
    children_cost_usd: roundTo(childrenCost, 6),
    member_plus_children_cost_usd: roundTo(cost + childrenCost, 6),
  };
};

const measuredAgents = agents.filter(isMeasured);
const dispatches = measuredAgents.map(measureAgent);
const unitCalls = unitAgent ? callsById.get(unitAgent.agentId) : [];
const unitBlock = unitAgent
  ? { agent_id: unitAgent.agentId, cost_usd: roundTo(costOf(unitCalls), 6), first_call_context: unitCalls[0] ? contextOf(unitCalls[0]) : 0, calls: unitCalls.length }
  : null;

if (unpriceableModels.size > 0) {
  for (const model of [...unpriceableModels].sort()) process.stderr.write(`measure-dispatch: cannot price model ${model}: no rate row in ${options.rates}\n`);
  process.exit(3);
}

const measuredTypes = new Set([...measuredAgents, ...(unitAgent ? [unitAgent] : [])].map((agent) => agent.agentType));
const output = {
  schema: 1,
  rates: { path: ratesPathOf(options.rates), git_blob: ratesBlobOf(options.rates) },
  claude_code_version: mainRecords.find((record) => typeof record.version === 'string')?.version ?? null,
  excluded_agent_types: [...new Set(agents.map((agent) => agent.agentType).filter((type) => type && !measuredTypes.has(type)))].sort(),
  unit: unitBlock,
  dispatches,
};
const text = `${JSON.stringify(output, null, 2)}\n`;
if (options.out) writeFileSync(options.out, text);
else process.stdout.write(text);
