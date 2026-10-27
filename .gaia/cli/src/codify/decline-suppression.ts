import {readDeclineLedger} from '../schemas/decline-ledger.js';
import {
  governingDeclines,
  isLapsed,
  readDeclineStore,
} from './decline-store.js';
import {isMaterialRise, TALLY_SCHEMA_VERSION} from './material-rise.js';

export type DeclineLoadReport =
  | {code: 'malformed_decline_ledger'; message: string; path: string}
  | {code: 'skipped_decline_file'; path: string; reason: string};

export type DeclineSource = 'committed' | 'legacy';

export type DeclineSources = {
  check: (
    findingClass: string,
    currentPrCount: number,
    currentAuditedPrCount: number
  ) => DeclineVerdict;
  reports: readonly DeclineLoadReport[];
};

export type DeclineVerdict =
  | {
      reason:
        'lapsed' | 'material_rise' | 'no_decline' | 'schema_version_mismatch';
      status: 'resurface';
    }
  | {source: DeclineSource; status: 'suppressed'};

type Decline = {
  declined_at: string;
  declined_at_audited_pr_count: number;
  declined_at_pr_count: number;
  tally_schema_version: number;
};

type ResurfaceReason = Extract<DeclineVerdict, {status: 'resurface'}>['reason'];

const LEGACY_LEDGER_RELATIVE_PATH = '.gaia/local/codify/declines.json';

const judge = ({
  currentAuditedPrCount,
  currentPrCount,
  decline,
  now,
  windowDays,
}: {
  currentAuditedPrCount: number;
  currentPrCount: number;
  decline: Decline;
  now: Date;
  windowDays: number;
}): 'suppressed' | ResurfaceReason => {
  if (isLapsed(decline.declined_at, now, windowDays)) return 'lapsed';

  // A decline measured under other counting semantics has a base count that
  // is not comparable to the live one.
  if (decline.tally_schema_version !== TALLY_SCHEMA_VERSION) {
    return 'schema_version_mismatch';
  }

  const materialRise = isMaterialRise({
    baseAuditedPrCount: decline.declined_at_audited_pr_count,
    baseCount: decline.declined_at_pr_count,
    liveAuditedPrCount: currentAuditedPrCount,
    liveCount: currentPrCount,
  });

  return materialRise ? 'material_rise' : 'suppressed';
};

/**
 * Reads the committed declines and the legacy ledger once and returns a pure
 * `check` over them; it writes and prints nothing.
 */
export const loadDeclineSources = ({
  now,
  repoRoot,
  windowDays,
}: {
  now: Date;
  repoRoot: string;
  windowDays: number;
}): DeclineSources => {
  const reports: DeclineLoadReport[] = [];
  const store = readDeclineStore(repoRoot);

  for (const skip of store.skipped) {
    reports.push({
      code: 'skipped_decline_file',
      path: skip.relativePath,
      reason: skip.reason,
    });
  }

  const committed = new Map<string, Decline>();

  for (const [findingClass, file] of governingDeclines(store.files, now)) {
    committed.set(findingClass, file.entry);
  }

  const legacy = new Map<string, Decline>();
  const ledger = readDeclineLedger(repoRoot);

  // The legacy ledger fails open: failing closed would suppress every class,
  // and an unparseable file can never age out, so one bad file would silence
  // a clone indefinitely.
  if (ledger.status === 'malformed') {
    reports.push({
      code: 'malformed_decline_ledger',
      message: ledger.error,
      path: LEGACY_LEDGER_RELATIVE_PATH,
    });
  } else if (ledger.status === 'ok') {
    for (const decline of ledger.ledger.declines) {
      const existing = legacy.get(decline.finding_class);

      if (
        existing === undefined ||
        Date.parse(decline.declined_at) >= Date.parse(existing.declined_at)
      ) {
        legacy.set(decline.finding_class, decline);
      }
    }
  }

  const check: DeclineSources['check'] = (
    findingClass,
    currentPrCount,
    currentAuditedPrCount
  ) => {
    const verdictFor = (
      decline: Decline | undefined
    ): 'suppressed' | ResurfaceReason =>
      decline === undefined ? 'no_decline' : (
        judge({
          currentAuditedPrCount,
          currentPrCount,
          decline,
          now,
          windowDays,
        })
      );

    const committedVerdict = verdictFor(committed.get(findingClass));

    if (committedVerdict === 'suppressed') {
      return {source: 'committed', status: 'suppressed'};
    }

    const legacyVerdict = verdictFor(legacy.get(findingClass));

    if (legacyVerdict === 'suppressed') {
      return {source: 'legacy', status: 'suppressed'};
    }

    return {
      reason:
        committedVerdict === 'no_decline' ? legacyVerdict : committedVerdict,
      status: 'resurface',
    };
  };

  return {check, reports};
};
