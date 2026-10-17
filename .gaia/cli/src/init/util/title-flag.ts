/**
 * The `--title` value check shared by `init rename` and `init strip-branding`.
 *
 * Every sink the title reaches is one line: a quoted JavaScript string
 * literal or a Markdown `# ` heading (`CLAUDE.md`, `README.md`). A line ending would
 * split the literal or the heading, so it is refused here, before any write,
 * rather than escaped at each sink.
 */

/** The usage error for a `--title` value that cannot be written, or `null`. */
export const titleFlagError = (title: string): null | string =>
  /[\n\r]/u.test(title) ? '--title must not contain a line ending' : null;
