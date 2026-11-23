import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {HOLISTIC_FINDING_CLASSES} from '../finding-class.js';

/**
 * The shared member protocol lists the holistic classes every Code Audit Team
 * member assigns from; the schema is what the sidecar writer and the tally
 * accept. Two lists with no shared source drift silently, so this suite holds
 * them equal as sets. `PROTOCOL_PARITY_PATH` points the live comparison at a
 * scratch copy, which is how a mutated protocol is proven to fail it.
 */
const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const protocolPath =
  process.env.PROTOCOL_PARITY_PATH ??
  path.join(repoRoot, '.claude/hooks/lib/audit-member-protocol.md');

const SECTION_HEADING = '## Holistic class assignment';
const CLASS_BULLET = /^- `(holistic\/[a-z0-9-]+)`:/;

/** The class each bullet of the protocol's holistic section opens with. */
const extractProtocolClasses = (markdown: string): string[] => {
  const lines = markdown.split('\n');
  const start = lines.indexOf(SECTION_HEADING);

  if (start === -1) return [];
  const classes: string[] = [];

  for (const line of lines.slice(start + 1)) {
    if (line.startsWith('## ')) break;
    const match = CLASS_BULLET.exec(line);

    if (match?.[1] !== undefined) classes.push(match[1]);
  }

  return classes;
};

/** Members present in one list and absent from the other, in both directions. */
const setDifference = (
  protocolClasses: readonly string[],
  schemaClasses: readonly string[]
): {missingFromProtocol: string[]; missingFromSchema: string[]} => ({
  missingFromProtocol: schemaClasses.filter(
    (entry) => !protocolClasses.includes(entry)
  ),
  missingFromSchema: protocolClasses.filter(
    (entry) => !schemaClasses.includes(entry)
  ),
});

describe('holistic class list parity: protocol and schema', () => {
  const protocolClasses = extractProtocolClasses(
    readFileSync(protocolPath, 'utf8')
  );

  test('the protocol section lists classes at all', () => {
    expect(protocolClasses.length).toBeGreaterThan(0);
  });

  test('the protocol lists no class twice', () => {
    expect(new Set(protocolClasses).size).toBe(protocolClasses.length);
  });

  test('the protocol list equals HOLISTIC_FINDING_CLASSES as a set', () => {
    expect(setDifference(protocolClasses, HOLISTIC_FINDING_CLASSES)).toEqual({
      missingFromProtocol: [],
      missingFromSchema: [],
    });
  });
});
