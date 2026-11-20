/**
 * Fixtures are built in a temp dir, not against the real repo, so the roster-
 * shape cases are hermetic.
 */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {rosterAgentPaths} from './region-registry.js';

type Sandbox = {cleanup: () => void; root: string};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-region-registry-'));

  return {
    cleanup: () => rmSync(root, {force: true, recursive: true}),
    root,
  };
};

const writeRoster = (root: string, contents: string): void => {
  const rosterPath = path.join(root, '.gaia/audit-ci.yml');
  mkdirSync(path.dirname(rosterPath), {recursive: true});
  writeFileSync(rosterPath, contents, 'utf8');
};

describe('rosterAgentPaths', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('reads each auditors[].name into .claude/agents/<name>.md', () => {
    writeRoster(
      sandbox.root,
      [
        'auditors:',
        '  - name: code-audit-frontend',
        '    globs:',
        '      - "app/**"',
        '    audience: adopter',
        '    default: true',
        '  - name: code-audit-maintainer-node',
        '    globs:',
        '      - ".gaia/cli/src/**/*.ts"',
        '    audience: maintainer',
        '',
      ].join('\n')
    );

    expect(rosterAgentPaths(sandbox.root)).toEqual(
      new Set([
        '.claude/agents/code-audit-frontend.md',
        '.claude/agents/code-audit-maintainer-node.md',
      ])
    );
  });

  test.each<{
    name: string;
    steps: {expected: string[]; roster?: string}[];
  }>([
    {
      name: 'roster file absent → empty set',
      steps: [{expected: []}],
    },
    {
      name: 'auditors key absent or not a list → empty set',
      steps: [
        {expected: [], roster: 'gate_label: null\n'},
        {expected: [], roster: 'auditors: "not-a-list"\n'},
      ],
    },
    {
      name: 'entries with no name, or a non-string name, are skipped rather than crashing',
      steps: [
        {
          expected: ['.claude/agents/real-member.md'],
          roster: [
            'auditors:',
            '  - globs:',
            '      - "app/**"',
            '  - name: 7',
            '  - name: real-member',
            '',
          ].join('\n'),
        },
      ],
    },
  ])('$name', ({steps}) => {
    for (const {expected, roster} of steps) {
      if (roster !== undefined) {
        writeRoster(sandbox.root, roster);
      }
      expect(rosterAgentPaths(sandbox.root)).toEqual(new Set(expected));
    }
  });
});
