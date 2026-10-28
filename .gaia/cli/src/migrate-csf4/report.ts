import type {MigrateReport, RefusalReason} from './types.js';

const SAFE_SHELL_WORD = /^[\w./@%+=:,-]+$/u;

const shellQuote = (word: string): string => {
  if (SAFE_SHELL_WORD.test(word)) return word;
  const escaped = word.replaceAll("'", String.raw`'\''`);

  return `'${escaped}'`;
};

/** Restores exactly the write-set files the command changed, from `HEAD`. */
export const buildRestoreCommand = (
  changedFiles: readonly string[]
): null | string =>
  changedFiles.length === 0 ?
    null
  : `git restore --source=HEAD --staged --worktree -- ${changedFiles.map((file) => shellQuote(file)).join(' ')}`;

export const emptyReport = (packagePath: string): MigrateReport => ({
  converted: [],
  files: [],
  lint: {files: [], result: 'skipped'},
  package: packagePath,
  refused: null,
  restore: null,
  typecheck: {files: [], result: 'skipped'},
  unexpectedChanges: [],
  unknownAddons: [],
});

export const refusedReport = (
  packagePath: string,
  reason: RefusalReason,
  paths: readonly string[]
): MigrateReport => ({
  ...emptyReport(packagePath),
  refused: {paths: [...paths], reason},
});

/** Whether the report describes a run that passed every check. */
export const reportPassed = (report: MigrateReport): boolean =>
  report.refused === null &&
  report.typecheck.result === 'pass' &&
  report.lint.result === 'pass' &&
  report.unexpectedChanges.length === 0 &&
  report.files.every((file) => file.loaded && file.passed);

export const renderHumanReport = (
  report: MigrateReport,
  notes: readonly string[]
): string => {
  const lines: string[] = [];
  const convertedSet = new Set(report.converted);

  lines.push(`Package: ${report.package}`);
  report.files.forEach((file) => {
    lines.push(
      `${file.path}: converted=${String(convertedSet.has(file.path))} loaded=${String(file.loaded)} passed=${String(file.passed)} tests=${String(file.tests)}`
    );
    file.failures.forEach((name) => lines.push(`  failing: ${name}`));
  });
  const unloaded = report.files.filter((file) => !file.loaded);

  if (unloaded.length > 0) {
    lines.push(
      'These story files did not load, so their tests did not run:',
      ...unloaded.map((file) => `  ${file.path}`)
    );
  }
  lines.push(
    `Typecheck: ${report.typecheck.result}`,
    ...report.typecheck.files.map((file) => `  ${file}`),
    `Lint: ${report.lint.result}`,
    ...report.lint.files.map((file) => `  ${file}`)
  );

  if (report.unknownAddons.length > 0) {
    lines.push(
      'Addons the preview rewrite did not recognize (likely hand-fixes):',
      ...report.unknownAddons.map((addon) => `  ${addon}`)
    );
  }

  if (report.unexpectedChanges.length > 0) {
    lines.push(
      'Files outside the write set changed during the run and were restored:',
      ...report.unexpectedChanges.map((file) => `  ${file}`)
    );
  }
  lines.push(...notes);

  if (report.restore !== null) {
    lines.push('To undo the conversion:', report.restore);
  }

  return `${lines.join('\n')}\n`;
};
