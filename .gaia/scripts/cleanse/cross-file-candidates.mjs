#!/usr/bin/env node
// The deterministic half of /gaia-cleanse --cross-file: finds candidate
// clusters of blocks, in different instruction files, that share distinctive
// literals (commands, flags, paths, numbers), so a model judges short excerpts
// instead of reading the whole set. Matching is by literals, never by titles.
//
// Usage:
//   node .gaia/scripts/cleanse/cross-file-candidates.mjs --root <tree>
//        [--min-shared <n>] [--max-df <n>] [--focus <path>]... [--all]
//   --min-shared  distinct shared literals that pair two blocks (default 3)
//   --max-df      most files a literal may appear in and still count (default 6)
//   --focus       repo-relative file or directory; with one or more, a cluster
//                 is kept only when a member sits at or under a focus path
//   --all         keep clusters with no editable member (default drops them)
//
// File set: tracked `.md` files that are a CLAUDE.md anywhere, sit under a
// `.claude/` directory anywhere, or sit under `wiki/`; minus everything under
// `.gaia/`, `wiki/log.md`, everything under `wiki/meta/`, and every path the
// ownership classifier calls `third-party` or `ignored`. One batched call of
// the classifier (`bash .gaia/scripts/fitness-ownership.sh --root <tree> --
// <paths...>`; CROSS_FILE_OWNERSHIP_CLASSIFIER overrides its path) supplies
// the classes.
//
// Blocks: YAML frontmatter is skipped; a fenced code block is one block; a
// heading is its own block and carries no literals; each top-level list item
// with its continuation lines is one block; each table row is one block;
// otherwise a run of non-blank lines is one block. A line holding only a
// maintainer-only start or end marker comment is not content, and a block
// between the markers carries maintainer_only: true.
//
// Literals: the trimmed, whitespace-collapsed text of each inline code span
// and each non-blank fenced line, kept at 3 or more characters containing a
// digit, a space, or one of / . - _ = $ : ; repo-style paths in prose (a token
// with a slash ending in .sh, .md, .mjs, .json, .yml or .bats); and numbers
// with a unit in prose (500 lines, 72h, 30 days), normalized to number plus
// unit. Document frequency (df) is the number of scanned files carrying it.
//
// Pairing: two blocks in different files pair when they share at least
// --min-shared distinct literals, each with df at most --max-df. Pairs union
// into clusters.
//
// Editable filter: a cluster needs a member of class `adopter`, or of class
// `gaia-shipped` when the tree holds the maintainer marker file (a filesystem
// existence test; the marker need not be tracked).
//
// stdout (exit 0), one JSON object:
//   {"schema": 1, "maintainer_repo": bool, "params": {"min_shared": n,
//    "max_df": n}, "files_scanned": n, "words_scanned": n,
//    "clusters": [{"id": "C001", "literals": [...], "members": [{"path",
//    "start_line", "end_line", "ownership", "maintainer_only", "text"}]}]}
// Clusters sort by first member path then start line, members by path then
// start line, ids are C plus a zero-padded 3-digit number in that order.
//
// Exit codes: 0 ok (zero clusters is ok); 2 usage error; 3 not a git work
// tree, unreadable input, or an ownership classifier that failed or did not
// answer one `<class>\t<path>` line per input path in input order (nothing on
// stdout, one `cross-file-candidates: <reason>` line on stderr).

import {existsSync, readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const MAINTAINER_MARKER_PATH = ".claude/rules/maintainers/harness-triage-threshold.md";
const DEFAULT_MIN_SHARED = 3;
const DEFAULT_MAX_DF = 6;
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DROPPED_CLASSES = new Set(['third-party', 'ignored']);
// One alternation, never the start or end marker spelled whole: the release
// leak check refuses either full marker string in any shipped file.
const MARKER_LINE = /^<!--\s*gaia:maintainer-only:(start|end)\s*-->$/;
const markerKind = (trimmedLine) => MARKER_LINE.exec(trimmedLine)?.[1];
const UNIT_PATTERN =
  '(?:lines?|words?|tokens?|chars?|characters?|days?|hours?|h|minutes?|mins?|seconds?|secs?|ms|s|files?|clusters?|bytes?|kb|mb|rounds?|attempts?|entries|items?|members?|pages?|sentences?|steps?|issues?|times)';

const fail = (code, message) => {
  process.stderr.write(`cross-file-candidates: ${message}\n`);
  process.exit(code);
};
const usage = (message) => fail(2, message);

const parseArgs = (argv) => {
  const opts = {
    all: false,
    focus: [],
    maxDf: DEFAULT_MAX_DF,
    minShared: DEFAULT_MIN_SHARED,
    root: '',
  };
  const positive = (flag, value) => {
    if (!/^[1-9]\d*$/.test(value ?? '')) {
      usage(`${flag} needs a positive integer`);
    }
    return Number(value);
  };
  const required = (flag, value, what) => {
    if (value === undefined || value === '') usage(`${flag} needs ${what}`);
    return value;
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--all') {
      opts.all = true;
    } else if (arg === '--root') {
      i += 1;
      opts.root = required(arg, argv[i], 'a directory');
    } else if (arg === '--min-shared') {
      i += 1;
      opts.minShared = positive(arg, argv[i]);
    } else if (arg === '--max-df') {
      i += 1;
      opts.maxDf = positive(arg, argv[i]);
    } else if (arg === '--focus') {
      i += 1;
      opts.focus.push(required(arg, argv[i], 'a path'));
    } else {
      usage(`unknown argument: ${arg}`);
    }
  }
  if (opts.root === '') usage('usage: --root <tree> [--min-shared <n>] [--max-df <n>] [--focus <path>]... [--all]');
  return opts;
};

const listCandidateFiles = (root) => {
  const result = spawnSync('git', ['-C', root, 'ls-files', '-z'], {
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
  });
  if (result.status !== 0) fail(3, `${root} is not a git work tree`);
  return result.stdout
    .split('\0')
    .filter(Boolean)
    .filter((file) => {
      if (!file.endsWith('.md')) return false;
      if (file.startsWith('.gaia/')) return false;
      if (file === 'wiki/log.md' || file.startsWith('wiki/meta/')) return false;
      return (
        path.posix.basename(file) === 'CLAUDE.md' ||
        file.split('/').includes('.claude') ||
        file.startsWith('wiki/')
      );
    })
    .sort();
};

const classify = (root, files) => {
  if (files.length === 0) return [];
  const classifier =
    process.env.CROSS_FILE_OWNERSHIP_CLASSIFIER ??
    path.join(SCRIPT_DIR, '..', 'fitness-ownership.sh');
  const result = spawnSync('bash', [classifier, '--root', root, '--', ...files], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) {
    fail(3, `the ownership classifier exited ${result.status ?? 'abnormally'}`);
  }
  const lines = result.stdout.split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  const bad = () => fail(3, 'the ownership classifier reply does not match its input');
  if (lines.length !== files.length) bad();
  return lines.map((line, index) => {
    const tab = line.indexOf('\t');
    if (tab < 1 || line.slice(tab + 1) !== files[index]) bad();
    return line.slice(0, tab);
  });
};

const collapse = (text) => text.replace(/\s+/g, ' ').trim();
const DISTINCTIVE = /[\d\s/.\-_=$:]/;
const isLiteral = (text) => text.length >= 3 && DISTINCTIVE.test(text);

const FENCE = /^\s*(```+|~~~+)/;
const fenceChar = (line) => FENCE.exec(line)?.[1][0];
const HEADING = /^\s{0,3}#{1,6}(\s|$)/;
const TOP_LIST_ITEM = /^ {0,1}([-*+]|\d+[.)])\s/;
const TABLE_ROW = /^\s*\|/;
const TABLE_SEPARATOR = /^\s*\|[\s|:-]*\|?\s*$/;
const CODE_SPAN = /(`+)([^`]+?)\1(?!`)/g;
const BARE_PATH = new RegExp(
  '(?:^|[\\s(\\[<"\'*])((?:[\\w.@~$-]+/)+[\\w.@-]+\\.(?:sh|md|mjs|json|yml|bats))(?=$|[\\s)\\]>,;:"\'*.])',
  'g',
);
const NUMBER_UNIT = new RegExp(
  `(?<![\\w.#])(\\d+(?:\\.\\d+)?)\\s?(${UNIT_PATTERN})(?![\\w])`,
  'gi',
);

const normalizeUnit = (unit) => {
  const lower = unit.toLowerCase();
  if (lower === 's' || lower === 'ms') return lower;
  if (lower === 'entries') return 'entry';
  return lower.replace(/s$/, '');
};

const literalsOf = (lines) => {
  const found = new Set();
  const add = (text) => {
    const value = collapse(text);
    if (isLiteral(value)) found.add(value);
  };
  const prose = [];
  let fence = null;
  for (const line of lines) {
    const char = fenceChar(line);
    if (fence === null && char) {
      fence = char;
    } else if (fence !== null && char === fence) {
      fence = null;
    } else if (fence !== null) {
      add(line);
    } else {
      prose.push(line);
    }
  }
  const text = prose.join(' ');
  for (const span of text.matchAll(CODE_SPAN)) add(span[2]);
  const outsideSpans = text.replace(CODE_SPAN, ' ');
  for (const bare of outsideSpans.matchAll(BARE_PATH)) add(bare[1]);
  for (const number of outsideSpans.matchAll(NUMBER_UNIT)) {
    add(`${number[1]} ${normalizeUnit(number[2])}`);
  }
  const percents = outsideSpans.matchAll(/(?<![\w.#])(\d+(?:\.\d+)?)%/g);
  for (const percent of percents) add(`${percent[1]}%`);
  return found;
};

const parseBlocks = (content) => {
  const lines = content.split('\n');
  const blocks = [];
  let maintainerOnly = false;
  let start = 0;
  if (lines[0]?.trim() === '---') {
    const close = lines.findIndex((line, index) => index > 0 && line.trim() === '---');
    if (close > 0) start = close + 1;
  }
  const push = (from, to) => {
    let end = to;
    while (end > from && lines[end].trim() === '') end -= 1;
    const slice = lines.slice(from, end + 1);
    const literals = literalsOf(slice);
    if (literals.size === 0) return;
    blocks.push({
      endLine: end + 1,
      literals,
      maintainerOnly,
      startLine: from + 1,
      text: slice.join('\n'),
    });
  };
  const isBoundary = (line) =>
    line.trim() === '' ||
    HEADING.test(line) ||
    FENCE.test(line) ||
    TABLE_ROW.test(line) ||
    TOP_LIST_ITEM.test(line) ||
    MARKER_LINE.test(line.trim());
  let i = start;
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();
    const kind = trimmed === '' ? undefined : markerKind(trimmed);
    const opener = fenceChar(line);
    if (trimmed === '') {
      i += 1;
    } else if (kind) {
      maintainerOnly = kind === 'start';
      i += 1;
    } else if (HEADING.test(line)) {
      i += 1;
    } else if (opener) {
      let j = i + 1;
      while (j < lines.length) {
        if (fenceChar(lines[j]) === opener) break;
        j += 1;
      }
      push(i, Math.min(j, lines.length - 1));
      i = j + 1;
    } else if (TABLE_ROW.test(line)) {
      if (!TABLE_SEPARATOR.test(line)) push(i, i);
      i += 1;
    } else if (TOP_LIST_ITEM.test(line)) {
      let j = i + 1;
      let fence = null;
      let last = i;
      while (j < lines.length) {
        const next = lines[j];
        const char = fenceChar(next);
        if (fence !== null) {
          if (char === fence) fence = null;
          last = j;
        } else if (next.trim() === '') {
          const following = lines.slice(j + 1).findIndex((x) => x.trim() !== '');
          if (following < 0 || !/^\s+\S/.test(lines[j + 1 + following])) break;
        } else if (/^\s+\S/.test(next)) {
          if (char) fence = char;
          last = j;
        } else if (isBoundary(next)) {
          break;
        } else {
          last = j;
        }
        j += 1;
      }
      push(i, last);
      i = last + 1;
    } else {
      let j = i + 1;
      while (j < lines.length && !isBoundary(lines[j])) j += 1;
      push(i, j - 1);
      i = j;
    }
  }
  return blocks;
};

const find = (parent, x) => {
  let root = x;
  while (parent[root] !== root) root = parent[root];
  let node = x;
  while (parent[node] !== root) {
    const next = parent[node];
    parent[node] = root;
    node = next;
  }
  return root;
};

const compare = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

const main = () => {
  const opts = parseArgs(process.argv.slice(2));
  const root = opts.root.replace(/(.)\/+$/, '$1');
  const candidates = listCandidateFiles(root);
  const classes = classify(root, candidates);
  const files = [];
  candidates.forEach((file, index) => {
    if (!DROPPED_CLASSES.has(classes[index])) {
      files.push({ownership: classes[index], path: file});
    }
  });

  const maintainerRepo = existsSync(path.join(root, MAINTAINER_MARKER_PATH));
  let wordsScanned = 0;
  const blocks = [];
  for (const file of files) {
    let content;
    try {
      content = readFileSync(path.join(root, file.path), 'utf8');
    } catch (error) {
      fail(3, `cannot read ${file.path}: ${error.code ?? error.message}`);
    }
    wordsScanned += content.split(/\s+/).filter(Boolean).length;
    for (const block of parseBlocks(content)) {
      blocks.push({...block, ownership: file.ownership, path: file.path});
    }
  }

  const postings = new Map();
  blocks.forEach((block, index) => {
    for (const literal of block.literals) {
      if (!postings.has(literal)) postings.set(literal, []);
      postings.get(literal).push(index);
    }
  });

  const pairCounts = new Map();
  const qualifying = new Set();
  for (const [literal, members] of postings) {
    const df = new Set(members.map((index) => blocks[index].path)).size;
    if (df < 2 || df > opts.maxDf) continue;
    qualifying.add(literal);
    for (let a = 0; a < members.length; a += 1) {
      for (let b = a + 1; b < members.length; b += 1) {
        if (blocks[members[a]].path === blocks[members[b]].path) continue;
        const key = `${members[a]}:${members[b]}`;
        pairCounts.set(key, (pairCounts.get(key) ?? 0) + 1);
      }
    }
  }

  const parent = blocks.map((_, index) => index);
  for (const [key, count] of pairCounts) {
    if (count < opts.minShared) continue;
    const [a, b] = key.split(':').map(Number);
    parent[find(parent, a)] = find(parent, b);
  }

  const groups = new Map();
  for (let index = 0; index < blocks.length; index += 1) {
    const rootIndex = find(parent, index);
    if (!groups.has(rootIndex)) groups.set(rootIndex, []);
    groups.get(rootIndex).push(index);
  }

  const editable = (ownership) =>
    ownership === 'adopter' || (ownership === 'gaia-shipped' && maintainerRepo);
  const focus = opts.focus.map((entry) =>
    entry.replace(/^\.\//, '').replace(/\/+$/, ''),
  );
  const underFocus = (file) =>
    focus.some((entry) => file === entry || file.startsWith(`${entry}/`));

  const clusters = [];
  for (const indexes of groups.values()) {
    if (indexes.length < 2) continue;
    const members = indexes
      .map((index) => blocks[index])
      .sort((a, b) => compare(a.path, b.path) || a.startLine - b.startLine);
    if (!opts.all && !members.some((member) => editable(member.ownership))) continue;
    if (focus.length > 0 && !members.some((member) => underFocus(member.path))) continue;
    const seen = new Map();
    for (const member of members) {
      for (const literal of member.literals) {
        if (qualifying.has(literal)) seen.set(literal, (seen.get(literal) ?? 0) + 1);
      }
    }
    clusters.push({
      literals: [...seen].filter(([, n]) => n >= 2).map(([literal]) => literal).sort(compare),
      members: members.map((member) => ({
        end_line: member.endLine,
        maintainer_only: member.maintainerOnly,
        ownership: member.ownership,
        path: member.path,
        start_line: member.startLine,
        text: member.text,
      })),
    });
  }
  clusters.sort(
    (a, b) =>
      compare(a.members[0].path, b.members[0].path) ||
      a.members[0].start_line - b.members[0].start_line,
  );

  const output = {
    schema: 1,
    maintainer_repo: maintainerRepo,
    params: {min_shared: opts.minShared, max_df: opts.maxDf},
    files_scanned: files.length,
    words_scanned: wordsScanned,
    clusters: clusters.map((cluster, index) => ({
      id: `C${String(index + 1).padStart(3, '0')}`,
      literals: cluster.literals,
      members: cluster.members,
    })),
  };
  process.stdout.write(`${JSON.stringify(output)}\n`);
};

main();
