import type {Grade} from './types.js';

export type FindingCounts = {
  errors: number;
  infos: number;
  structural: boolean;
  warnings: number;
};

const ERROR_GRADES: readonly Grade[] = ['C+', 'C', 'C-', 'D+', 'D', 'D-'];
const WARNING_GRADES: readonly Grade[] = ['B+', 'B', 'B-'];

/** Worst last; the overall grade is the highest index among graded categories. */
const GRADE_ORDER: readonly Grade[] = [
  'A+',
  'A',
  'A-',
  'B+',
  'B',
  'B-',
  'C+',
  'C',
  'C-',
  'D+',
  'D',
  'D-',
  'F',
];

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
