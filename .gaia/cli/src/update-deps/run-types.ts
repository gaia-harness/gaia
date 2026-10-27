import type {SnoozedGroup} from './declines.js';

/**
 * Display bucket for the interactive preview. `nonsemver` collects pre-1.0
 * packages (current major is 0), where semver makes no breaking-change
 * guarantee, mirroring npm-check. It is a display label only; wave routing
 * (`kind`) is unaffected.
 */
export type Bucket = 'major' | 'minor' | 'nonsemver' | 'patch';

export type Kind = 'major' | 'minor' | 'patch';

export type PnpmResult = {
  status: null | number;
  stderr: string;
  stdout: string;
};

export type PnpmRunner = (
  args: readonly string[],
  options: {cwd: string}
) => PnpmResult;

export type SkippedEntry = {
  current: string;
  latest: string;
  name: string;
  reason: string;
};

export type UpdatesPayload = {
  /** Outstanding package count after removing currently-snoozed groups. */
  actionable_count: number;
  generated_at: string;
  schema_version: 1;
  skipped: readonly SkippedEntry[];
  /**
   * Outstanding groups the human snoozed earlier that are still within their
   * snooze window and match the currently-offered targets. The interactive
   * preview marks these and default-skips them; empty with no local ledger.
   */
  snoozed: readonly SnoozedGroup[];
  /** Outstanding package count across both waves, pre-snooze. */
  total_count: number;
  wave_a: readonly WaveAEntry[];
  wave_b: readonly WaveBGroup[];
};

export type WaveAEntry = {
  bucket: Bucket;
  current: string;
  group: string;
  is_pinned: boolean;
  kind: 'minor' | 'patch';
  latest: string;
  name: string;
  wanted: string;
  /** Present only on entries discovered in the CLI workspace member. */
  workspace?: string;
};

export type WaveBGroup = {
  group: string;
  packages: readonly WaveBPackage[];
};

export type WaveBPackage = {
  bucket: Bucket;
  current: string;
  is_pinned: boolean;
  kind: Kind;
  latest: string;
  name: string;
  wanted: string;
  /** Present only on entries discovered in the CLI workspace member. */
  workspace?: string;
};
