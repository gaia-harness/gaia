import path from 'node:path';

const MARKER_LEAD = /^(?:sanctioned copy of|subset of)(?:\s|$)/;
const MARKER_FORM = /^(sanctioned copy of|subset of)\s+(\S+)\s*$/;

/** True when a comment body is a marker: it starts with `sanctioned copy of` or `subset of`. */
export const isMarkerText = (text: string): boolean =>
  MARKER_LEAD.test(text.trim());

export type ParsedMarker =
  | {kind: 'malformed'}
  | {kind: 'sanctioned-copy' | 'subset'; name: string; path: string};

/**
 * Collapses `.` and `name/..` segments and a leading `./`. A path that is
 * absolute, or escapes the root once collapsed, keeps its leading `/` or
 * `../`, so it matches no collected set; the file is never opened.
 */
const normalizeReferencePath = (referencePath: string): string =>
  path.posix.normalize(referencePath);

/** Parses a marker body; `path` is normalized repo-relative. An absolute or root-escaping path still returns a sanctioned-copy or subset result (its normalized text, starting `/` or `../`), which matches no collected set and fails as source not found, printing that text. */
export const parseMarker = (text: string): ParsedMarker => {
  const match = MARKER_FORM.exec(text.trim());
  if (!match) return {kind: 'malformed'};
  const [, lead, reference = ''] = match;
  const separator = reference.lastIndexOf('#');

  if (separator <= 0 || separator === reference.length - 1) {
    return {kind: 'malformed'};
  }

  return {
    kind: lead === 'subset of' ? 'subset' : 'sanctioned-copy',
    name: reference.slice(separator + 1),
    path: normalizeReferencePath(reference.slice(0, separator)),
  };
};
