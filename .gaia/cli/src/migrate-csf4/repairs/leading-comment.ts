/**
 * Storybook's csf-factories codemod deletes the comment block that opens a
 * file when it rewrites the first import. These helpers find that block in
 * the original and put it back.
 */

const COMMENT_OR_SPACE = /\s+|\/\/[^\n]*|\/\*[\s\S]*?\*\//uy;

/** The comment block opening `source`, from its first comment to its last. */
export const extractLeadingComment = (
  source: string
): undefined | {comment: string; gap: string} => {
  let position = 0;
  let firstStart: number | undefined;
  let lastEnd = 0;

  for (;;) {
    COMMENT_OR_SPACE.lastIndex = position;
    const match = COMMENT_OR_SPACE.exec(source);

    if (!match) break;

    if (!/^\s/u.test(match[0])) {
      firstStart ??= position;
      lastEnd = position + match[0].length;
    }
    position += match[0].length;
  }
  if (firstStart === undefined) return undefined;
  const gap = /^\s*/u.exec(source.slice(lastEnd))?.[0] ?? '';

  return {
    comment: source.slice(firstStart, lastEnd),
    gap: gap.includes('\n') ? gap : '\n\n',
  };
};

/**
 * `after` with the comment block that opened `before` restored at its top,
 * unless `after` still carries that block.
 */
export const restoreLeadingComment = (
  before: string,
  after: string
): string => {
  const leading = extractLeadingComment(before);

  if (!leading || after.includes(leading.comment)) return after;

  return `${leading.comment}${leading.gap}${after.replace(/^\s+/u, '')}`;
};
