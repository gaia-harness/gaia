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

/**
 * The anchored pattern a row's fullName matches, or null when the title has
 * no literal text outside its tokens: that pattern is the describe prefix plus
 * a wildcard and could claim the failure of a dynamic-title sibling under
 * that describe, so the test stays exempt instead.
 */
export function rowPatternFor(prefix, title) {
  const literalParts = title.split(ROW_TOKEN);
  if (literalParts.join('').trim() === '') {
    return null;
  }
  return `^${escapeRegExp(prefix)}${literalParts.map(escapeRegExp).join('[\\s\\S]*')}$`;
}
