/* eslint-disable unicorn/prevent-abbreviations -- the module under test is named dev-ports-reuse */
import {describe, expect, test, vi} from 'vitest';
import {ASK_FIRST_SENTENCE} from '../dev-ports';
import type {ListenerOwner} from '../dev-ports';
import {decideServerReuse} from '../dev-ports-reuse';

const decideReuseForOwner = (
  owner: ListenerOwner,
  isContinuousIntegration = false
): {decision: boolean | Error; probe: ReturnType<typeof vi.fn>} => {
  const probe = vi.fn(() => owner);

  try {
    return {
      decision: decideServerReuse({
        isContinuousIntegration,
        port: 5180,
        probe,
        treeRoot: '/trees/mine',
      }),
      probe,
    };
  } catch (error) {
    return {decision: error as Error, probe};
  }
};

describe('decideServerReuse', () => {
  test.each(
    (
      [
        {
          expected: true,
          isContinuousIntegration: false,
          name: 'reuses a server this tree owns',
          owner: {kind: 'own', pid: 10},
          probeCalls: 1,
        },
        {
          expected: false,
          isContinuousIntegration: false,
          name: 'does not reuse a free port',
          owner: {kind: 'free'},
          probeCalls: 1,
        },
        {
          expected: false,
          isContinuousIntegration: false,
          name: 'does not reuse when ownership is unknown',
          owner: {kind: 'unknown'},
          probeCalls: 1,
        },
        {
          expected: false,
          isContinuousIntegration: true,
          name: 'in continuous integration never reuses and never probes',
          owner: {kind: 'own', pid: 10},
          probeCalls: 0,
        },
      ] satisfies readonly {
        expected: boolean;
        isContinuousIntegration: boolean;
        name: string;
        owner: ListenerOwner;
        probeCalls: number;
      }[]
    ).map((row) => [row.name, row] as const)
  )(
    'decideServerReuse decides per listener owner: %s',
    (_name, {expected, isContinuousIntegration, owner, probeCalls}) => {
      const {decision, probe} = decideReuseForOwner(
        owner,
        isContinuousIntegration
      );

      expect(decision).toBe(expected);

      expect(probe).toHaveBeenCalledTimes(probeCalls);
    }
  );

  test.each(
    (
      [
        {
          messageParts: ['5180', '/trees/other', ASK_FIRST_SENTENCE],
          name: 'a foreign server with an owner path throws naming port, path, and the ask-first sentence',
          owner: {
            kind: 'foreign',
            ownerPath: '/trees/other',
            pid: 11,
          },
        },
        {
          messageParts: ['owner unknown'],
          name: 'a foreign server with no owner path throws naming owner unknown',
          owner: {
            kind: 'foreign',
            ownerPath: undefined,
            pid: 0,
          },
        },
      ] satisfies readonly {
        messageParts: string[];
        name: string;
        owner: ListenerOwner;
      }[]
    ).map((row) => [row.name, row] as const)
  )(
    'decideServerReuse refuses a foreign server naming the owner: %s',
    (_name, {messageParts, owner}) => {
      const {decision} = decideReuseForOwner(owner);

      expect(decision).toBeInstanceOf(Error);

      for (const part of messageParts) {
        expect((decision as Error).message).toContain(part);
      }
    }
  );
});
