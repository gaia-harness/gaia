/**
 * Pure line-block stripper for `# gaia:maintainer-only` / `<!-- gaia:maintainer-only -->`
 * style marker blocks. Shared by two callers:
 *
 *   - `scrub.ts`'s marker-strip transform, which writes the stripped output
 *     back into the release staging tree ahead of leak-check.
 *   - `runtime-deps.ts`'s bare-mode scan, which strips maintainer-only
 *     blocks from each `.sh` source in-memory before extracting path refs,
 *     so an unstaged bare run agrees with the authoritative post-scrub
 *     `--staging` run instead of false-positiving on maintainer-only
 *     references.
 *
 * Extracted to one shared module so there is a single marker parser rather
 * than two independently-maintained copies.
 */

export type MarkerIssueReason =
  'end_without_start' | 'marker_line_has_text' | 'start_without_end';

export type StripMarkerBlocksResult = {
  blocks: number;
  output: string;
  unbalanced: {
    line: number;
    reason: MarkerIssueReason;
  }[];
};

// The strip drops a delimiting marker's whole line, so any text outside the
// block on that line would vanish from the bundle with no error. A
// single-line block's own content sits between its markers and is dropped
// on purpose; only text before its start or after its end is outside it.
const textBesideMarkers = (
  line: string,
  lineNumber: number,
  bounds: {first: string; last: string}
): StripMarkerBlocksResult['unbalanced'] => {
  const trimmed = line.trim();
  const isBare =
    bounds.first === bounds.last ?
      trimmed === bounds.first
    : trimmed.startsWith(bounds.first) && trimmed.endsWith(bounds.last);

  return isBare ? [] : [{line: lineNumber, reason: 'marker_line_has_text'}];
};

export const stripMarkerBlocks = (
  source: string,
  startMarker: string,
  endMarker: string
): StripMarkerBlocksResult => {
  const lines = source.split('\n');
  const out: string[] = [];
  const unbalanced: {
    line: number;
    reason: MarkerIssueReason;
  }[] = [];
  let inBlock = false;
  let blockStartLine = 0;
  let blocks = 0;

  for (const [index, line] of lines.entries()) {
    const lineNumber = index + 1;
    const hasStart = line.includes(startMarker);
    const hasEnd = line.includes(endMarker);

    if (!inBlock && hasStart && hasEnd) {
      // Single-line block: drop the entire line.
      unbalanced.push(
        ...textBesideMarkers(line, lineNumber, {
          first: startMarker,
          last: endMarker,
        })
      );
      blocks += 1;
    } else if (!inBlock && hasStart) {
      unbalanced.push(
        ...textBesideMarkers(line, lineNumber, {
          first: startMarker,
          last: startMarker,
        })
      );
      inBlock = true;
      blockStartLine = lineNumber;
    } else if (inBlock && hasEnd) {
      unbalanced.push(
        ...textBesideMarkers(line, lineNumber, {
          first: endMarker,
          last: endMarker,
        })
      );
      inBlock = false;
      blocks += 1;
    } else if (!inBlock && hasEnd) {
      unbalanced.push({line: lineNumber, reason: 'end_without_start'});
      out.push(line);
    } else if (!inBlock) {
      out.push(line);
    }
  }

  if (inBlock) {
    unbalanced.push({line: blockStartLine, reason: 'start_without_end'});
  }

  return {blocks, output: out.join('\n'), unbalanced};
};
