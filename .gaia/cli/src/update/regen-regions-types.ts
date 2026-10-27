export type ConfinedEntry = {
  action: 'removed' | 'reported' | 'restored';
  path: string;
  regionId: string;
};

export type KilledCause = 'external' | 'maxBuffer' | 'timeout';

export type RegenRegionsReport = {
  backedUp: string[];
  confined: ConfinedEntry[];
  failed: FailedEntry[];
  ran: RanEntry[];
  refused: RefusedEntry[];
  skipped: SkippedEntry[];
};

type FailedEntry = {
  argv: string[];
  /** `killed` only: which bound, or none of them, ended the program. */
  cause?: KilledCause;
  kind: 'exit' | 'killed' | 'spawn';
  message: string;
  regionId: string;
  signal?: string;
  status?: number;
};

type RanEntry = {argv: string[]; regionId: string; rewrote: string[]};

type RefusedEntry = {
  argv?: string[];
  kind: 'declaration' | 'manifest' | 'operand';
  reason: string;
  regionId: string;
};

type SkippedEntry = {argv: string[]; reason: string; regionId: string};
