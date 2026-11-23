import {describe, expect, test} from 'vitest';
import {gradeFromCounts, overallGrade} from './grade.js';
import type {Grade} from './types.js';

const counts = (
  overrides: Partial<Parameters<typeof gradeFromCounts>[0]> = {}
): Parameters<typeof gradeFromCounts>[0] => ({
  errors: 0,
  infos: 0,
  structural: false,
  warnings: 0,
  ...overrides,
});

describe('gradeFromCounts', () => {
  test.each<[string, Parameters<typeof gradeFromCounts>[0], Grade]>([
    ['no findings', counts(), 'A+'],
    ['1 info', counts({infos: 1}), 'A'],
    ['2 infos', counts({infos: 2}), 'A'],
    ['3 infos', counts({infos: 3}), 'A-'],
    ['40 infos never drop below A-', counts({infos: 40}), 'A-'],
    ['1 warning', counts({warnings: 1}), 'B+'],
    ['2 warnings', counts({warnings: 2}), 'B'],
    ['3 warnings', counts({warnings: 3}), 'B-'],
    ['4 warnings', counts({warnings: 4}), 'B-'],
    ['1 error', counts({errors: 1}), 'C+'],
    ['2 errors', counts({errors: 2}), 'C'],
    ['3 errors', counts({errors: 3}), 'C-'],
    ['4 errors', counts({errors: 4}), 'D+'],
    ['5 errors', counts({errors: 5}), 'D'],
    ['6 errors', counts({errors: 6}), 'D-'],
    ['7 errors', counts({errors: 7}), 'D-'],
    [
      'errors outrank warnings and infos',
      counts({errors: 1, infos: 9, warnings: 9}),
      'C+',
    ],
    ['warnings outrank infos', counts({infos: 9, warnings: 1}), 'B+'],
    ['a structural finding alone', counts({structural: true}), 'F'],
    [
      'a structural finding regardless of counts',
      counts({errors: 1, structural: true}),
      'F',
    ],
  ])('%s grades %s', (_name, input, expected) => {
    expect(gradeFromCounts(input)).toBe(expected);
  });
});

describe('overallGrade', () => {
  test.each<[string, Grade[], Grade]>([
    ['is the lowest graded category', ['A+', 'B', 'C-', 'A'], 'C-'],
    ['is the lowest graded category, F included', ['A+', 'F', 'D'], 'F'],
    ['ignores n/a categories', ['n/a', 'A', 'n/a', 'B+'], 'B+'],
    ['is n/a when every category is n/a', ['n/a', 'n/a'], 'n/a'],
    ['is n/a when none is given', [], 'n/a'],
  ])('%s', (_name, input, expected) => {
    expect(overallGrade(input)).toBe(expected);
  });
});
