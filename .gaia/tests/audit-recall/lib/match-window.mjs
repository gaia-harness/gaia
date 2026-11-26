// A finding within this many lines of a corpus entry's line matches it: the
// scorer's found() test and corpus selection's dedup read the same window.
const LINE_WINDOW = 5;

export const withinLineWindow = (line, otherLine) => Math.abs(line - otherLine) <= LINE_WINDOW;
