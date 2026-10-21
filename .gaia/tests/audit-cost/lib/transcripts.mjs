// Claude Code transcript reader for the audit-cost measurement and the recall
// harness. A main session is `<id>.jsonl` plus a directory `<id>/` holding
// `subagents/agent-<agentId>.jsonl` and a sibling `agent-<agentId>.meta.json`
// (agent type, description, the parent's tool_use id and parent agent id).
//
// Reads are lenient like claude-probe's observe.mjs: a malformed line is
// skipped, because Claude Code wrote the transcript, not this tool.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export const DISPATCH_TOOL_NAMES = new Set(['Agent', 'Task']);

export const readRecords = (path) => {
  if (!existsSync(path)) return [];
  const records = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (line.trim() === '') continue;
    try {
      const value = JSON.parse(line);
      if (value !== null && typeof value === 'object' && !Array.isArray(value)) records.push(value);
    } catch {
      // skipped: a truncated or foreign line must not void the transcript
    }
  }
  return records;
};

const blocksOf = (record) => (Array.isArray(record?.message?.content) ? record.message.content : []);

// One usage block as the priced buckets plus output. A block that reports the
// 5m/1h split uses it; one that reports only the total counts all of it as 5m,
// the default bucket.
const usageOf = (raw) => {
  const usage = raw ?? {};
  const split = usage.cache_creation ?? null;
  const written = usage.cache_creation_input_tokens ?? ((split?.ephemeral_5m_input_tokens ?? 0) + (split?.ephemeral_1h_input_tokens ?? 0));
  const cacheWrite1h = split?.ephemeral_1h_input_tokens ?? 0;
  return {
    input: usage.input_tokens ?? 0,
    cacheWrite5m: Math.max(0, written - cacheWrite1h),
    cacheWrite1h,
    cacheRead: usage.cache_read_input_tokens ?? 0,
    output: usage.output_tokens ?? 0,
  };
};

// Assistant API calls, deduped by message id. Claude Code writes one record per
// content block of a streamed message, each carrying the usage seen so far, so
// the last usage block per id is the call's real usage.
export const readCalls = (transcriptPath) => {
  const calls = [];
  const byKey = new Map();
  let lastCall = null;
  for (const record of readRecords(transcriptPath)) {
    if (record.type === 'assistant' && record.message?.id) {
      const message = record.message;
      const dedupeKey = message.id;
      let call = byKey.get(dedupeKey);
      if (!call) {
        call = { messageId: message.id, ts: record.timestamp ?? null, model: message.model ?? null, usage: usageOf(message.usage), toolUses: [], toolResults: [] };
        byKey.set(dedupeKey, call);
        calls.push(call);
      }
      call.usage = usageOf(message.usage);
      call.model = message.model ?? call.model;
      for (const block of blocksOf(record)) {
        if (block.type === 'tool_use' && !call.toolUses.some((use) => use.id === block.id)) {
          call.toolUses.push({ id: block.id, name: block.name, input: block.input ?? {}, ts: record.timestamp ?? null });
        }
      }
      lastCall = call;
    } else if (record.type === 'user' && lastCall) {
      for (const block of blocksOf(record)) {
        if (block.type === 'tool_result') lastCall.toolResults.push({ toolUseId: block.tool_use_id, ts: record.timestamp ?? null });
      }
    }
  }
  return calls;
};

export const finalReplyText = (transcriptPath) => {
  const textByMessage = new Map();
  for (const record of readRecords(transcriptPath)) {
    if (record.type !== 'assistant' || !record.message?.id) continue;
    for (const block of blocksOf(record)) {
      if (block.type === 'text' && typeof block.text === 'string' && block.text !== '') {
        const texts = textByMessage.get(record.message.id) ?? [];
        texts.push(block.text);
        textByMessage.set(record.message.id, texts);
      }
    }
  }
  const last = [...textByMessage.values()].pop();
  return last ? last.join('\n') : '';
};

const renderedChars = (record) => {
  if (!Array.isArray(record.rendered)) return 0;
  let chars = 0;
  for (const entry of record.rendered) {
    const content = entry?.content;
    chars += typeof content === 'string' ? content.length : JSON.stringify(content ?? '').length;
  }
  return chars;
};

// Attachment records written before the first API call, as characters of
// rendered text per attachment type.
export const firstCallAttachments = (transcriptPath) => {
  const chars = {};
  for (const record of readRecords(transcriptPath)) {
    if (record.type === 'assistant' && record.message?.id) break;
    if (record.type !== 'attachment') continue;
    const size = renderedChars(record);
    const type = record.attachment?.type ?? 'unknown';
    if (size > 0) chars[type] = (chars[type] ?? 0) + size;
  }
  return chars;
};

const dispatchesIn = (transcriptPath) => {
  const found = new Map();
  for (const record of readRecords(transcriptPath)) {
    if (record.type !== 'assistant') continue;
    for (const block of blocksOf(record)) {
      if (block.type === 'tool_use' && DISPATCH_TOOL_NAMES.has(block.name)) found.set(block.id, { input: block.input ?? {}, ts: record.timestamp ?? null });
    }
  }
  return found;
};

const agentFiles = (directory, found = []) => {
  if (!existsSync(directory)) return found;
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      if (entry.name !== 'tool-results') agentFiles(path, found);
    } else if (/^agent-.+\.jsonl$/.test(entry.name)) {
      found.push(path);
    }
  }
  return found;
};

const readMeta = (transcriptPath) => {
  const metaPath = transcriptPath.replace(/\.jsonl$/, '.meta.json');
  if (!existsSync(metaPath)) return null;
  try {
    return JSON.parse(readFileSync(metaPath, 'utf8'));
  } catch {
    return null;
  }
};

// Every sub-agent transcript under a main session, at any depth. sessionRoot
// is the session directory or the main session's `.jsonl` path.
export const listAgents = (sessionRoot) => {
  const directory = sessionRoot.replace(/\.jsonl$/, '');
  const mainPath = `${directory}.jsonl`;
  const transcripts = new Map();
  for (const path of agentFiles(directory)) {
    const name = path.slice(path.lastIndexOf('/') + 1);
    transcripts.set(name.slice('agent-'.length, -'.jsonl'.length), path);
  }
  const dispatchCache = new Map();
  const dispatchesOf = (parentAgentId) => {
    if (!dispatchCache.has(parentAgentId)) {
      const parentPath = parentAgentId === null ? mainPath : transcripts.get(parentAgentId);
      dispatchCache.set(parentAgentId, parentPath ? dispatchesIn(parentPath) : new Map());
    }
    return dispatchCache.get(parentAgentId);
  };
  const agents = [];
  for (const [agentId, transcriptPath] of transcripts) {
    const meta = readMeta(transcriptPath);
    if (!meta) continue;
    const parentAgentId = meta.parentAgentId ?? null;
    const sent = dispatchesOf(parentAgentId).get(meta.toolUseId);
    const firstRecord = readRecords(transcriptPath).find((record) => record.timestamp);
    agents.push({
      agentId,
      agentType: meta.agentType ?? null,
      parentAgentId,
      transcriptPath,
      finished: meta.finished === true,
      dispatch: {
        toolUseId: meta.toolUseId ?? null,
        subagentType: sent?.input.subagent_type ?? meta.agentType ?? null,
        description: sent?.input.description ?? meta.description ?? '',
        prompt: sent?.input.prompt ?? '',
        ts: sent?.ts ?? firstRecord?.timestamp ?? null,
      },
    });
  }
  return agents.sort((left, right) => String(left.dispatch.ts).localeCompare(String(right.dispatch.ts)) || left.agentId.localeCompare(right.agentId));
};

// The audit-loop unit, the dispatch times of the fixers it launched, and the
// earliest of them (null when none): the cutoff that ends round one.
export const roundOneContext = (agents) => {
  const unit = agents.find((agent) => agent.agentType === 'audit-loop-unit') ?? null;
  const fixerTimes = unit ? agents.filter((agent) => agent.parentAgentId === unit.agentId && /fix/i.test(agent.dispatch.description)).map((agent) => agent.dispatch.ts) : [];
  const firstFixerTime = fixerTimes.length > 0 ? fixerTimes.reduce((earliest, time) => (time < earliest ? time : earliest)) : null;
  return { unit, fixerTimes, firstFixerTime };
};

// Before-bundle specialists are free-form `general-purpose` children. The
// pinned rule: the description is tried against every rule in this order, then
// the prompt is. One rule per line so a guard can drop one.
const FREE_FORM_ROLE_RULES = [
  { pattern: /\breact\b/i, role: 'react-patterns' },
  { pattern: /translation|i18n/i, role: 'translation' },
  { pattern: /typescript/i, role: 'typescript' },
];

const freeFormRole = (text) => FREE_FORM_ROLE_RULES.find((rule) => rule.pattern.test(text))?.role ?? null;

// The one role classifier the measurement and the recall scorer share.
export const classifyChild = (dispatch) => {
  const subagentType = dispatch?.subagentType ?? '';
  const description = dispatch?.description ?? '';
  const prompt = dispatch?.prompt ?? '';
  if (subagentType === 'audit-refuter') return { kind: 'refuter', role: null };
  if (subagentType === 'audit-rule-specialist') {
    const role = /^\s*([\w-]+)\s+specialist/i.exec(description)?.[1] ?? /^\s*Role:\s*([\w-]+)/m.exec(prompt)?.[1] ?? null;
    return { kind: 'specialist', role: role === null ? null : role.toLowerCase() };
  }
  if (subagentType !== 'general-purpose') return { kind: 'other', role: null };
  if (prompt.includes('You are an adversarial reviewer')) return { kind: 'refuter', role: null };
  const role = freeFormRole(description) ?? freeFormRole(prompt);
  return role === null ? { kind: 'other', role: null } : { kind: 'specialist', role };
};
