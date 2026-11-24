import {GRADES} from './types.js';
import type {Grade} from './types.js';

export type FindingCounts = {
  errors: number;
  infos: number;
  structural: boolean;
  warnings: number;
};

/** Worst last; the overall grade is the highest index among graded categories. */
export const GRADE_ORDER: readonly Grade[] = GRADES.filter(
  (grade) => grade !== 'n/a'
);
const ERROR_GRADES: readonly Grade[] = GRADE_ORDER.slice(6, 12);
const WARNING_GRADES: readonly Grade[] = GRADE_ORDER.slice(3, 6);

const bandGrade = (bands: readonly Grade[], count: number): Grade =>
  bands[Math.min(count, bands.length) - 1] ?? 'F';

/** Grades one applicable category from its unsuppressed graded finding counts. */
export const gradeFromCounts = (counts: FindingCounts): Grade => {
  if (counts.structural) return 'F';
  if (counts.errors > 0) return bandGrade(ERROR_GRADES, counts.errors);
  if (counts.warnings > 0) return bandGrade(WARNING_GRADES, counts.warnings);
  if (counts.infos >= 3) return 'A-';
  if (counts.infos > 0) return 'A';

  return 'A+';
};

/** The lowest graded category; `n/a` when no category is graded. */
export const overallGrade = (grades: readonly Grade[]): Grade => {
  const indexes = grades
    .map((grade) => GRADE_ORDER.indexOf(grade))
    .filter((index) => index !== -1);

  if (indexes.length === 0) return 'n/a';

  return GRADE_ORDER[Math.max(...indexes)] ?? 'n/a';
};
