#!/usr/bin/env bats
# Citation check for the three audit-gate pages: the merge runbook
# (`wiki/concepts/PR Merge Workflow.md`), the round procedure
# (`wiki/concepts/Audit Round Procedure.md`) and the gate reference
# (`wiki/concepts/Audit Gate Reference.md`).
#
# Why this suite exists. Rules, skills, commands, agents, hook deny text, script
# error output and wiki pages cite a heading on one of these pages by wikilink
# (`[[Audit Round Procedure#Light routing]]`) or by repo path plus a heading
# (`wiki/concepts/PR Merge Workflow.md` followed by a backticked `#### ...`
# heading, a quoted `"### ..."`, a parenthesized `("...")`, or a bare
# `, #### ...`). Nothing else reads those citations, so a page split or a
# heading rename strands them silently: the citing text still reads fine and
# points at a heading that no longer exists. This suite derives every citation
# from the tracked files that carry them and fails on each one whose heading is
# not on the named page.
#
# What counts as a citation. The heading must follow the page path or the
# wikilink directly, so a path that is merely mentioned in a sentence that
# later quotes some other heading is not read as a citation. A citation split
# over two lines of a comment is not read either. Page-local `[[#Heading]]`
# links are out of scope: a page cannot strand a link to its own heading from
# outside.
#
# Honest limits. This proves each cited heading exists on the cited page, not
# that the page still says what the citing text claims; the doc-pin suites own
# the claims. The derivation reads tracked files only, so a new citing file or
# page must be staged before this suite sees it.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded and out of wiki-style.md's scope.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE_NAMES='PR Merge Workflow|Audit Round Procedure|Audit Gate Reference'
  # The trees that carry citations. `.gaia/scripts/tests/` holds fixtures that
  # name the pages as data, not consumers that cite them.
  CITING_PATHSPEC=(.claude/rules .claude/skills .claude/commands .claude/agents .claude/hooks .gaia/scripts wiki
    ':!wiki/log.md' ':!wiki/meta' ':!.gaia/scripts/tests')
}

# citation_program: the perl program that prints `file TAB line TAB page TAB
# heading` for every citation in the files it is given.
citation_program() {
  cat <<'PERL'
BEGIN { $pages = $ENV{CITATION_PAGES}; exit 0 unless @ARGV; }
while (<>) {
  my $line = $_;
  chomp $line;
  while ($line =~ /\[\[($pages)#([^\]|]+)/g) {
    print "$ARGV\t$.\t$1\t$2\n";
  }
  my @starts;
  while ($line =~ /wiki\/concepts\/($pages)\.md/g) {
    push @starts, [ $1, pos($line), $-[0] ];
  }
  for my $index (0 .. $#starts) {
    my ($page, $after, $begin) = @{ $starts[$index] };
    my $limit = $index < $#starts ? $starts[$index + 1][2] : length($line);
    my $tail = substr($line, $after, $limit - $after);
    my $heading;
    if ($tail =~ /^[`\x27s ,:]{0,8}\(?`#{2,6} ([^`]+)`/) { $heading = $1; }
    elsif ($tail =~ /^[`\x27s ,:]{0,8}\(?"#{2,6} ([^"]+)"/) { $heading = $1; }
    elsif ($tail =~ /^[`\x27s ]{0,4}\("([^"]+)"\)/) { $heading = $1; }
    elsif ($tail =~ /^`?, #{2,6} ([^)]+)/) { $heading = $1; $heading =~ s/[.,;:]+$//; }
    next unless defined $heading;
    $heading =~ s/^\s+|\s+$//g;
    print "$ARGV\t$.\t$page\t$heading\n";
  }
} continue { close ARGV if eof; }
PERL
}

# extract_citations <root>: reads NUL-separated root-relative file paths on
# stdin; prints one `file TAB line TAB page TAB heading` row per citation.
extract_citations() {
  local program root="$1"
  program="$(citation_program)"
  (cd "$root" && xargs -0 env CITATION_PAGES="$PAGE_NAMES" perl -e "$program")
}

# page_headings <root> <page>: every heading text on the page, any level,
# fenced code excluded (a `# comment` inside a fence is not a heading).
page_headings() {
  awk '
    /^```/ { inside_fence = !inside_fence; next }
    !inside_fence && /^#{1,6} / { sub(/^#+ /, ""); sub(/[ \t]+$/, ""); print }
  ' "$1/wiki/concepts/$2.md"
}

# unresolved_citations <root>: reads the citation rows on stdin; prints
# `<file>:<line>: <page>#<heading>` for each whose heading is not on its page
# and exits 1 when any is printed. A missing page leaves every citation of it
# unresolved, so a deleted page is reported rather than skipped.
unresolved_citations() {
  local root="$1" file line page heading headings unresolved_count=0
  while IFS=$'\t' read -r file line page heading; do
    headings=""
    if [ -f "$root/wiki/concepts/$page.md" ]; then
      headings="$(page_headings "$root" "$page")"
    fi
    if ! grep -qxF -- "$heading" <<<"$headings"; then
      printf '%s:%s: %s#%s\n' "$file" "$line" "$page" "$heading"
      unresolved_count=$((unresolved_count + 1))
    fi
  done
  [ "$unresolved_count" -eq 0 ]
}

# tracked_citing_files: NUL-separated tracked files under the citing trees.
tracked_citing_files() {
  # gaia-lint-ignore whole-tree-mark-guard: every test that reaches this listing carries the per-test mark
  git -C "$ROOT" ls-files -z -- "${CITING_PATHSPEC[@]}"
}

# bats test_tags=whole-tree
@test "every citation of a heading on the three pages resolves to a heading on the named page" {
  local citations unresolved
  citations="$(tracked_citing_files | extract_citations "$ROOT")"
  [ -n "$citations" ] || { printf 'the extractor read no citations\n' >&2; return 1; }
  unresolved="$(unresolved_citations "$ROOT" <<<"$citations")" || {
    printf 'unresolved citations:\n%s\n' "$unresolved" >&2
    return 1
  }
  true
}
