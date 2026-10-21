#!/usr/bin/env node
// Transcript questions run-recall.sh asks of a live or finished session, on top
// of the measurement toolkit's transcript library:
//
//   runs.mjs member-done <session jsonl> <member>
//     exit 0 when an agent of type <member> exists and it and every agent
//     under it ended its last turn, else exit 1.
//   runs.mjs specialist-replies <session jsonl> <directory>
//     writes each specialist child's final reply (classifyChild) to
//     <directory>/<agentId>.txt and prints how many it wrote.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { hasReturned } from '../../audit-cost/lib/session-checks.mjs';
import { classifyChild, finalReplyText, listAgents } from '../../audit-cost/lib/transcripts.mjs';

export const memberReturned = (sessionPath, member) => {
  const agents = listAgents(sessionPath);
  const members = agents.filter((agent) => agent.agentType === member);
  if (members.length === 0) return false;
  const memberIds = new Set(members.map((agent) => agent.agentId));
  const underMember = (agent) => {
    for (let parentId = agent.parentAgentId; parentId; parentId = agents.find((candidate) => candidate.agentId === parentId)?.parentAgentId ?? null) {
      if (memberIds.has(parentId)) return true;
    }
    return false;
  };
  return agents.filter((agent) => memberIds.has(agent.agentId) || underMember(agent)).every(hasReturned);
};

export const writeSpecialistReplies = (sessionPath, directory) => {
  mkdirSync(directory, { recursive: true });
  let written = 0;
  for (const agent of listAgents(sessionPath)) {
    if (classifyChild(agent.dispatch).kind !== 'specialist') continue;
    writeFileSync(join(directory, `${agent.agentId}.txt`), finalReplyText(agent.transcriptPath));
    written += 1;
  }
  return written;
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [command, sessionPath, argument] = process.argv.slice(2);
  if (command === 'member-done' && sessionPath && argument) {
    process.exit(memberReturned(sessionPath, argument) ? 0 : 1);
  } else if (command === 'specialist-replies' && sessionPath && argument) {
    process.stdout.write(`${writeSpecialistReplies(sessionPath, argument)}\n`);
  } else {
    process.stderr.write('usage: runs.mjs member-done <session jsonl> <member> | specialist-replies <session jsonl> <directory>\n');
    process.exit(2);
  }
}
