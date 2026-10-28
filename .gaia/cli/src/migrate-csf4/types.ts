import type {Repairs, Ts} from './repairs/index.js';

export type CommandResult = {exitCode: number; stderr: string; stdout: string};

/**
 * Runs one external tool to completion. Implementations close stdin (a tool
 * that prompts must fail, not hang), and never run in a shell.
 */
export type CommandRunner = (
  command: string,
  args: readonly string[],
  options: {cwd: string}
) => CommandResult;

export type FileOutcome = {
  failures: string[];
  loaded: boolean;
  passed: boolean;
  path: string;
  tests: number;
};

export type MigrateDeps = {
  cwd: string;
  loadTypescript: (packageDir: string) => Ts | undefined;
  repairs: Repairs;
  runCommand: CommandRunner;
  writeErr: (text: string) => void;
  writeOut: (text: string) => void;
};

export type MigrateOptions = {
  json: boolean;
  updateMerge: boolean;
};

export type MigrateReport = {
  converted: string[];
  files: FileOutcome[];
  lint: {files: string[]; result: StepResult};
  package: string;
  refused: null | {paths: string[]; reason: RefusalReason};
  restore: null | string;
  typecheck: {files: string[]; result: StepResult};
  unexpectedChanges: string[];
  unknownAddons: string[];
};

export type RefusalReason =
  | 'codemod-fetch'
  | 'csf2'
  | 'dirty-tree'
  | 'dirty-write-set'
  | 'package-config'
  | 'storybook-version'
  | 'typescript'
  | 'unknown-format';

export type StepResult = 'fail' | 'pass' | 'skipped';
