/** What a reader returns for one file. */
export type FileReading = {
  sets: readonly ValueSet[];
  strayMarkers: readonly StrayMarker[];
};

/** A comment whose body is a marker, found on a set's own line or the comment-only line directly above it. */
export type MarkerComment = {
  line: number; // 1-based line the comment sits on
  text: string; // comment body: the `#` or `//` leader and surrounding whitespace removed
};

export type SetLanguage = 'shell' | 'typescript';

/** A marker comment that sits above, or on, no value set. */
export type StrayMarker = {line: number; path: string; text: string};

/** One literal value set a reader collected. */
export type ValueSet = {
  language: SetLanguage;
  line: number; // 1-based: the line holding the declaration's name, or the arm's pattern
  markers: readonly MarkerComment[]; // zero, one or more; markers.ts judges conflicts and form
  name: null | string; // the bound identifier; null for a case arm and an unbound set
  origin: SetOrigin;
  path: string; // repo-relative, forward slashes
  values: readonly string[]; // as written, quotes stripped, source order, repeats kept
};

type SetOrigin = 'case-arm' | 'declaration';
