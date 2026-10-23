/**
 * A `finding_class` is a stable, machine-stable identifier for a kind of Code
 * Audit Team finding. Recurrence (the policy-memory loop) keys on it, so it
 * must reject free-text drift.
 *
 * Per-bucket convention:
 *
 * - Oracle buckets (deterministic tools) carry the tool's own id verbatim
 *   after the prefix; the tool owns that id space, so any slug of the safe id
 *   shape is accepted: `react-doctor/<rule-id>`, `axe/<rule-id>`, `knip/<issue-type>`,
 *   `cve/<advisory-id>`.
 * - Holistic / rule / workflow subagent buckets carry a CLOSED controlled
 *   vocabulary (the `as const` unions below). A holistic, rule, or workflow
 *   finding only becomes a countable class once it has a seeded member; an
 *   unseeded member is rejected so free-text drift never reaches the tally.
 * - A project extends both through `.gaia/finding-classes.json`: extra closed
 *   classes and extra open oracle prefixes, read by
 *   `readProjectFindingClasses` and passed as an optional vocabulary.
 */
import {z} from 'zod';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {structuredError} from '../stderr.js';
import {summarizeZodError} from './zod-error.js';

export const FINDING_CLASS_PREFIXES = [
  'react-doctor',
  'axe',
  'knip',
  'cve',
  'holistic',
  'rule',
  'workflow',
] as const;

export type FindingClassPrefix = (typeof FINDING_CLASS_PREFIXES)[number];

// Open oracle buckets: the deterministic tool owns the id space after the
// prefix, so any slug of the safe id shape below is valid.
const ORACLE_PREFIXES: readonly FindingClassPrefix[] = [
  'react-doctor',
  'axe',
  'knip',
  'cve',
];

// The tally reads classes from pull-request comments anyone can post, and the
// class is displayed verbatim downstream, so an oracle slug is held to an id
// shape: one or more `/`-joined segments of letters, digits, `.`, `_`, and
// `-`, each starting with a letter or digit. That admits every id the oracles
// emit (axe rule ids, knip issue types, numeric, GHSA, and CVE advisory ids,
// plugin-namespaced rule ids) and rejects whitespace, control bytes, and markup.
const ORACLE_SLUG_PATTERN = /^[A-Z0-9][\w.-]*(?:\/[A-Z0-9][\w.-]*)*$/i;
const ORACLE_SLUG_MAX_LENGTH = 128;

const isOracleSlug = (slug: string): boolean =>
  slug.length <= ORACLE_SLUG_MAX_LENGTH && ORACLE_SLUG_PATTERN.test(slug);

/**
 * Closed-vocabulary members for the holistic bucket: one closed set of
 * root-cause names with no scope dimension. Some are seeded from the audit
 * agent's stable cross-cutting dimensions and the project-specific rules it
 * enforces; others are language-neutral root causes derived from the
 * maintainer surface, and an adopter's own audit can legitimately assign one
 * of those too. Deliberately small: seed only classes the agent can reliably
 * and repeatably assign. When in doubt, leave a class out.
 */
export const HOLISTIC_FINDING_CLASSES = [
  'holistic/missing-auth-check',
  'holistic/secret-exposure',
  'holistic/n-plus-one',
  'holistic/unnecessary-rerender',
  'holistic/unhandled-promise-rejection',
  'holistic/swallowed-error',
  'holistic/over-permissive-zod',
  'holistic/business-logic-in-component',
  'holistic/hardcoded-string',
  'holistic/non-null-assertion',
  'holistic/hollow-assertion',
  'holistic/uncoupled-restatement',
  'holistic/stale-figure',
  'holistic/unarmed-guard',
  'holistic/fail-open-discovery',
  'holistic/partial-cause-reporting',
  'holistic/dangling-reference',
  'holistic/drifting-duplicate',
  'holistic/ambient-context-resolution',
  'holistic/shared-state-collision',
  'holistic/unbounded-invocation',
  'holistic/overclaimed-guarantee',
  'holistic/incomplete-enumeration',
  'holistic/repeated-round-trip',
] as const;

export type HolisticFindingClass = (typeof HOLISTIC_FINDING_CLASSES)[number];

/**
 * Dedup-key fallback for an out-of-scope finding that maps to no seeded
 * finding_class.
 *
 * This sits outside the closed finding_class vocabulary on purpose, so
 * `isValidFindingClass` rejects it and it is never a draftable candidate. The
 * tally layer (`compute-tally.ts`) routes it to the distinct `unclassified`
 * recurrence signal instead, never into `candidates[]`. It is **not** a
 * security signal: the filing screen keys on a finding's content and
 * severity, never on this constant, and treating it as a "classless,
 * therefore assume the worst" trigger would divert every out-of-scope
 * finding on a public repo and file none of them. The fail-safe trigger is
 * an absent or malformed `finding_class`, never `holistic/unclassified`. See
 * the file-tech-debt skill (`.claude/skills/file-tech-debt/SKILL.md`).
 */
export const OUT_OF_SCOPE_FALLBACK_FINDING_CLASS = 'holistic/unclassified';

/**
 * Closed-vocabulary members for the rule bucket. Seeded from the line-level
 * rule surfaces the specialist subagents enforce (react-code skill, typescript
 * skill, the thin-route rule). Small and defensible by design.
 */
export const RULE_FINDING_CLASSES = [
  'rule/use-effect-derived-state',
  'rule/use-effect-state-reset',
  'rule/unnecessary-use-callback',
  'rule/missing-effect-cleanup',
  'rule/generic-handler-name',
  'rule/switch-statement',
  'rule/interface-declaration',
  'rule/z-enum',
  'rule/array-generic-syntax',
  'rule/thin-route-violation',
] as const;

export type RuleFindingClass = (typeof RULE_FINDING_CLASSES)[number];

/**
 * Closed-vocabulary members for the workflow bucket. Seeded from the
 * workflow-security surface the `code-audit-github-workflows` member owns
 * (GitHub-Actions supply-chain, injection, and permission defects).
 */
export const WORKFLOW_FINDING_CLASSES = [
  'workflow/script-injection',
  'workflow/unsafe-pull-request-target',
  'workflow/unpinned-action',
  'workflow/broad-permissions',
] as const;

export type WorkflowFindingClass = (typeof WORKFLOW_FINDING_CLASSES)[number];

const CLOSED_VOCABULARY: ReadonlySet<string> = new Set([
  ...HOLISTIC_FINDING_CLASSES,
  ...RULE_FINDING_CLASSES,
  ...WORKFLOW_FINDING_CLASSES,
]);

const splitPrefix = (
  value: string
): undefined | {prefix: string; slug: string} => {
  const separatorIndex = value.indexOf('/');

  if (separatorIndex === -1) return undefined;

  return {
    prefix: value.slice(0, separatorIndex),
    slug: value.slice(separatorIndex + 1),
  };
};

/**
 * A project's own additions to the vocabulary, read from
 * `.gaia/finding-classes.json`: closed classes (`<prefix>/<slug>`, kebab) and
 * open oracle prefixes for the project's own deterministic tools.
 */
export type FindingClassVocabulary = {
  classes: readonly string[];
  oracle_prefixes: readonly string[];
};

export const EMPTY_FINDING_CLASS_VOCABULARY: FindingClassVocabulary = {
  classes: [],
  oracle_prefixes: [],
};

const isOraclePrefix = (
  prefix: string,
  vocabulary: FindingClassVocabulary
): boolean =>
  (ORACLE_PREFIXES as readonly string[]).includes(prefix) ||
  vocabulary.oracle_prefixes.includes(prefix);

/**
 * True when `findingClass` carries a known oracle prefix (`react-doctor/`,
 * `axe/`, `knip/`, `cve/`, or one the project vocabulary adds), the
 * deterministic-tool buckets. Reuses the same membership check as
 * `isValidFindingClass` so callers never need to re-list the prefixes;
 * `codify-tally` uses this to emit `is_oracle` per candidate.
 */
export const isOracleFindingClass = (
  findingClass: string,
  vocabulary: FindingClassVocabulary = EMPTY_FINDING_CLASS_VOCABULARY
): boolean => {
  const parts = splitPrefix(findingClass);

  return parts !== undefined && isOraclePrefix(parts.prefix, vocabulary);
};

/**
 * True when `value` matches the per-bucket convention: a well-formed oracle id
 * (open id space after a known oracle prefix, bounded to the safe id shape) or
 * a seeded closed-vocabulary member (holistic, rule, or workflow), each
 * widened by the project `vocabulary` when one is passed. Everything else
 * (free text, unknown prefix, empty or malformed slug, unseeded
 * closed-vocabulary member) is invalid.
 */
export const isValidFindingClass = (
  value: string,
  vocabulary: FindingClassVocabulary = EMPTY_FINDING_CLASS_VOCABULARY
): boolean => {
  const parts = splitPrefix(value);

  if (parts === undefined) return false;

  if (isOraclePrefix(parts.prefix, vocabulary)) {
    return isOracleSlug(parts.slug);
  }

  return CLOSED_VOCABULARY.has(value) || vocabulary.classes.includes(value);
};

export const FindingClassSchema = z.string().refine(isValidFindingClass, {
  message:
    'finding_class must match the per-bucket convention (oracle id or controlled vocabulary)',
});

const KEBAB_SEGMENT = '[a-z0-9]+(?:-[a-z0-9]+)*';
const PROJECT_PREFIX_PATTERN = new RegExp(`^${KEBAB_SEGMENT}$`);
const PROJECT_CLASS_PATTERN = new RegExp(`^${KEBAB_SEGMENT}/${KEBAB_SEGMENT}$`);

const ProjectClassSchema = z
  .string()
  .regex(PROJECT_CLASS_PATTERN, 'class must be <prefix>/<slug>, kebab-case')
  .refine((value) => value !== OUT_OF_SCOPE_FALLBACK_FINDING_CLASS, {
    message: `${OUT_OF_SCOPE_FALLBACK_FINDING_CLASS} is the classless fallback, never a class`,
  })
  .refine((value) => !isOracleFindingClass(value), {
    message: 'a built-in oracle prefix already accepts any id',
  });

const ProjectOraclePrefixSchema = z
  .string()
  .regex(PROJECT_PREFIX_PATTERN, 'oracle prefix must be kebab-case')
  .refine(
    (value) => !(FINDING_CLASS_PREFIXES as readonly string[]).includes(value),
    {message: 'oracle prefix must not be a built-in prefix'}
  );

// Unknown keys such as `$comment` are stripped, so the parsed data is the
// vocabulary itself.
const ProjectFindingClassesSchema = z.object({
  classes: z.array(ProjectClassSchema),
  oracle_prefixes: z.array(ProjectOraclePrefixSchema),
});

export type ProjectFindingClassesRead = {
  /** True when the file exists but could not be read as a vocabulary. */
  malformed: boolean;
  vocabulary: FindingClassVocabulary;
};

const reportMalformed = (message: string): ProjectFindingClassesRead => {
  structuredError({code: 'malformed_finding_classes', message});

  return {malformed: true, vocabulary: EMPTY_FINDING_CLASS_VOCABULARY};
};

/**
 * Reads the project vocabulary and says whether it was usable. A missing file
 * is the empty vocabulary; an unreadable or malformed one is reported as one
 * structured stderr line, read as empty, and flagged `malformed` so a caller
 * that acts on the vocabulary can fail closed.
 */
export const readProjectFindingClassesChecked = (
  repoRoot: string
): ProjectFindingClassesRead => {
  const filePath = path.join(repoRoot, '.gaia', 'finding-classes.json');

  if (!existsSync(filePath)) {
    return {malformed: false, vocabulary: EMPTY_FINDING_CLASS_VOCABULARY};
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(filePath, 'utf8'));
  } catch (error) {
    return reportMalformed(
      `${filePath}: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  const result = ProjectFindingClassesSchema.safeParse(parsed);

  if (!result.success) {
    return reportMalformed(summarizeZodError(filePath, result.error));
  }

  return {malformed: false, vocabulary: result.data};
};

/**
 * Reads the project vocabulary. A missing, unreadable or malformed file reads
 * as the empty vocabulary, so a bad edit narrows the tally to the built-in
 * vocabulary instead of failing it.
 */
export const readProjectFindingClasses = (
  repoRoot: string
): FindingClassVocabulary =>
  readProjectFindingClassesChecked(repoRoot).vocabulary;
