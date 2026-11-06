// The signal helper emits this as `rowPattern`; the capture hook tests a
// failing row's fullName against it with jq, so it stays within the syntax
// JavaScript and jq's Oniguruma engine read alike (escapes, `[\s\S]`, anchors).

// The tokens vitest's formatTitle substitutes into a `.each`/`.for` title: a
// printf token (`%s`, `%#`, `%$`, `%%`, ...) and an attribute (`$name`,
// `$user.name`, `$0`). A row's value can be any text, truncated or not, so
// each token becomes `[\s\S]*` and the literal text between them is matched
// exactly. Erring wide here only widens which failing row names a template
// accepts; erring narrow would leave a template whose rows never match, a
// RED that can never be recorded.
const ROW_TOKEN = /%[a-zA-Z#$%]|\$[$\p{ID_Continue}.]+/gu;

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const literalPartsOf = ({title, expands}) =>
  expands ? title.split(ROW_TOKEN) : [title];

/**
 * The anchored pattern a row's fullName matches, given the titles from the
 * outermost describe down to the test, each flagged when a `.each`/`.for`
 * expands it. Vitest joins them with one space. Null when the titles from the
 * first expanding one down hold no literal text outside their tokens: that
 * pattern is a static describe prefix plus a wildcard and could claim the
 * failure of any unemitted test under that prefix, so the test stays exempt
 * instead.
 */
export function rowPatternFor(segments) {
  const parts = segments.map(literalPartsOf);
  const firstExpanding = segments.findIndex((segment) => segment.expands);
  if (parts.slice(firstExpanding).flat().join('').trim() === '') {
    return null;
  }
  const segmentPatterns = parts.map((literals) =>
    literals.map(escapeRegExp).join('[\\s\\S]*'),
  );
  return `^${segmentPatterns.join(' ')}$`;
}
