import type {RuleContext} from './context.js';

export type Severity = 'error' | 'info' | 'warning';

export const CATEGORIES = [
  'authoring',
  'claudemd',
  'frontmatter',
  'hooks',
  'prompt',
  'rules',
  'settings',
  'wiki',
] as const;

export type Category = (typeof CATEGORIES)[number];

export type CheckReport = {
  categories: readonly {grade: Grade; name: Category}[];
  findings: readonly Finding[];
  inventory: readonly InventoryEntry[];
  overall: Grade;
  scope: 'adopter' | 'all';
  suppressed: readonly SuppressedFinding[];
  upstream: readonly Finding[];
};

export type FileKind =
  | 'agent'
  | 'claudemd'
  | 'claudemd-local'
  | 'command'
  | 'fitness-config'
  | 'playbook'
  | 'reference'
  | 'rule'
  | 'settings'
  | 'settings-local'
  | 'skill'
  | 'wiki';

export type Finding = {
  category: Category;
  file: string;
  fixable: boolean;
  line: number;
  message: string;
  ownership: Ownership;
  remediation: string;
  rule_id: string;
  severity: Severity;
};

export type FixtureFactory = () => FixtureProject;

export type FixtureMap = Readonly<Record<string, FixturePair>>;

export type FixturePair = {green: FixtureFactory; red: FixtureFactory};

/**
 * A fixture project written to a scratch directory by `createScratchProject`.
 * It lives here, not in `test-support.ts`, so a fixture module can name the
 * type without importing the test runner.
 */
export type FixtureProject = {
  /** `'repo'` (default), `'none'`, or the path of a stub classifier script. */
  classifier?: string;
  files: Record<string, string>;
  /** True: `git init`, add everything and commit, so every file is tracked. */
  git?: boolean;
  manifest?: unknown;
  /** Serialized to `.claude/settings.json`; wins over a `files` entry. */
  settingsJson?: unknown;
  /** Pin name to target path; written as `.gaia/vendor/<name>.json`. */
  vendorPins?: Record<string, string>;
};

export type Grade =
  | 'A'
  | 'A+'
  | 'A-'
  | 'B'
  | 'B+'
  | 'B-'
  | 'C'
  | 'C+'
  | 'C-'
  | 'D'
  | 'D+'
  | 'D-'
  | 'F'
  | 'n/a';

export type InventoryEntry = {
  kinds: readonly FileKind[];
  lines: number;
  model: ModelFamily;
  ownership: Ownership;
  path: string;
  path_scoped: boolean;
  words: number;
};

export type ModelFamily = 'fable' | 'haiku' | 'opus' | 'sonnet' | 'unresolved';

export type Ownership =
  'adopter' | 'gaia-shipped' | 'ignored' | 'third-party' | 'unknown';

export type ProjectFile = {
  /** Sorted, deduped; `playbook` and `reference` may co-occur. */
  kinds: readonly FileKind[];
  /** Lines, as `wc -l`: the count of `\n`. */
  lines: number;
  /** Frontmatter model, else the project settings model, else `unresolved`. */
  model: ModelFamily;
  ownership: Ownership;
  /** Repo-relative, forward slashes. */
  path: string;
  /** True only for a `rule` file whose frontmatter holds a non-empty `paths:`. */
  pathScoped: boolean;
  /** File content. Never emitted. */
  text: string;
  /** Whitespace-separated tokens, as `wc -w`. */
  words: number;
};

export type PromptModel = 'any' | 'fable' | 'opus' | 'sonnet';

export type RawFinding = {
  file: string;
  line: number;
  message: string;
  remediation: string;
};

export type RuleDefinition = {
  /** Retired ids this rule answers to in suppressions. */
  aliases?: readonly string[];
  appliesTo: readonly ('all' | FileKind)[];
  category: Category;
  check: (context: RuleContext) => readonly RawFinding[];
  /** One line, printed by `rules --json`. */
  detection: string;
  /** Prompt rules only. */
  models?: readonly PromptModel[];
  /** Dotted; the first segment equals the category. */
  ruleId: string;
  severity: Severity;
  /** A finding makes the category F. */
  structural?: true;
};

export type SuppressedFinding = Finding & {reason: string};
