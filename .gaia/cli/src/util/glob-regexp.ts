/**
 * The ERE-grammar body of a glob, without anchors. Sentinels: \u0001 for the
 * zero-or-more-directories form, \u0002 for `**`, \u0003 for `*`, \u0004 for
 * `?`, \u0005 and \u0006 for a brace group's parentheses, \u0007 for its bar.
 */
export const globToBody = (glob: string): string =>
  glob
    .replaceAll(/[\\.+^$()[\]|]/g, String.raw`\$&`)
    .replaceAll('**/', '\u0001')
    .replaceAll('**', '\u0002')
    .replaceAll('*', '\u0003')
    .replaceAll('?', '\u0004')
    .replaceAll(
      /\{([^{}]+)\}/g,
      (_match, inner: string) =>
        `\u0005${inner.replaceAll(',', '\u0007')}\u0006`
    )
    .replaceAll(/[{}]/g, String.raw`\$&`)
    .replaceAll('\u0001', '(.*/)?')
    .replaceAll('\u0002', '.*')
    .replaceAll('\u0003', '[^/]*')
    .replaceAll('\u0004', '[^/]')
    .replaceAll('\u0005', '(')
    .replaceAll('\u0006', ')')
    .replaceAll('\u0007', '|');

export const globToRegExp = (glob: string): RegExp =>
  new RegExp(`^${globToBody(glob)}$`);

export const joinGlob = (packagePath: string, glob: string): string =>
  packagePath === '.' ? glob : `${packagePath}/${glob}`;
