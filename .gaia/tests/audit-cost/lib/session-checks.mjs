#!/usr/bin/env node
// Two checks over a live or finished session, shared by the probe and replay
// drivers:
//
//   session-checks.mjs wave-done <session jsonl or directory>
//     exit 0 when the round-1 frontend member wave has returned (every frontend
//     member dispatched before the unit's first fixer, and every agent under
//     them, ended its last turn), else exit 1.
//   session-checks.mjs callability <session jsonl or directory> <agent type> <tool,tool,...>
//     prints [{type, tool, called, toolsearch_used, error}] for that agent
//     type's transcript.
import { pathToFileURL } from 'node:url';
import { listAgents, readRecords, roundOneContext } from './transcripts.mjs';

const lastAssistantStopReason = (transcriptPath) => {
  const assistants = readRecords(transcriptPath).filter((record) => record.type === 'assistant' && record.message?.id);
  const last = assistants[assistants.length - 1];
  return last ? (last.message.stop_reason ?? null) : null;
};

export const hasReturned = (agent) => {
  const stopReason = lastAssistantStopReason(agent.transcriptPath);
  return stopReason !== null && stopReason !== 'tool_use';
};

export const roundOneWaveDone = (sessionRoot) => {
  const agents = listAgents(sessionRoot);
  const { unit, firstFixerTime } = roundOneContext(agents);
  if (!unit) return false;
  const members = agents.filter((agent) => agent.agentType === 'code-audit-frontend' && (firstFixerTime === null || agent.dispatch.ts < firstFixerTime));
  if (members.length === 0) return false;
  const underMember = (agent) => {
    for (let parentId = agent.parentAgentId; parentId; parentId = agents.find((candidate) => candidate.agentId === parentId)?.parentAgentId ?? null) {
      if (members.some((member) => member.agentId === parentId)) return true;
    }
    return false;
  };
  return agents.filter((agent) => members.includes(agent) || underMember(agent)).every(hasReturned);
};

export const callabilityEntries = (sessionRoot, agentType, tools) => {
  const agent = listAgents(sessionRoot).find((candidate) => candidate.agentType === agentType);
  const records = agent ? readRecords(agent.transcriptPath) : [];
  const uses = [];
  for (const record of records) {
    if (record.type !== 'assistant') continue;
    for (const block of Array.isArray(record.message?.content) ? record.message.content : []) {
      if (block.type === 'tool_use') uses.push({ id: block.id, name: block.name });
    }
  }
  const erroredIds = new Set();
  for (const record of records) {
    if (record.type !== 'user') continue;
    for (const block of Array.isArray(record.message?.content) ? record.message.content : []) {
      if (block.type === 'tool_result' && block.is_error === true) erroredIds.add(block.tool_use_id);
    }
  }
  const toolSearchUsed = uses.some((use) => use.name === 'ToolSearch');
  return tools.map((tool) => ({
    type: agentType,
    tool,
    called: uses.some((use) => use.name === tool),
    toolsearch_used: toolSearchUsed,
    error: uses.some((use) => use.name === tool && erroredIds.has(use.id)),
  }));
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [command, sessionRoot, agentType, tools] = process.argv.slice(2);
  if (command === 'wave-done' && sessionRoot) {
    process.exit(roundOneWaveDone(sessionRoot) ? 0 : 1);
  } else if (command === 'callability' && sessionRoot && agentType && tools) {
    process.stdout.write(`${JSON.stringify(callabilityEntries(sessionRoot, agentType, tools.split(',')))}\n`);
  } else {
    process.stderr.write('usage: session-checks.mjs wave-done <session> | callability <session> <agent type> <tool,tool,...>\n');
    process.exit(2);
  }
}
