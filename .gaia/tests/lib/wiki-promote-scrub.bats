#!/usr/bin/env bats
# A wiki page rendered from the promotion step's own templates passes the
# release scrub and the machine-local reference detector, and its index and
# Related links resolve.
#
#   S      a page assembled from the frontmatter template in wiki-promote.md,
#          filled with a concrete id and this repository's PR URL wherever a
#          template asks for one, goes through the real `release scrub` and
#          the detector; so does the wiki/log.md line template
#   L      the index and Related link templates, rendered for a page whose H1
#          carries a '/', resolve under `gaia wiki broken-links`
#
# The templates are read out of wiki-promote.md rather than copied here, so a
# template edit that reintroduces an id or a PR URL fails S. Tokens the suite
# must not contain (a concrete working-document id, this repository's PR URL)
# are assembled at run time so the suite never matches itself.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.
# Assertion style per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  PROMOTE_DOC="$REPO_ROOT/.claude/skills/gaia/references/spec/wiki-promote.md"
  MAINTAINER_CLI="$REPO_ROOT/.gaia/cli/gaia-maintainer"
  ADOPTER_CLI="$REPO_ROOT/.gaia/cli/gaia"
  SCRUB_CONFIG="$REPO_ROOT/.gaia/release-scrub.yml"
  DETECTOR="$REPO_ROOT/.gaia/scripts/machine-local-ref-lib.sh"
  SPEC_ID="$(printf '%s%s' 'SPEC-' '123')"
  PR_NUMBER='4567'
  PR_URL="$(printf '%s%s%s' 'https://github.com/' 'gaia-react/gaia/pull/' "$PR_NUMBER")"
}

# Print the body of the first fenced block of language $1 that follows the
# line equal to $2 in the promotion doc. List items indent their fences, so
# both comparisons ignore leading spaces.
fenced_block_after() {
  awk -v language="$1" -v anchor="$2" '
    { line = $0; sub(/^ +/, "", line) }
    line == anchor { seen = 1; next }
    seen && !inside && line == "```" language { inside = 1; next }
    inside && line == "```" { exit }
    inside { print }
  ' "$PROMOTE_DOC"
}

# Fill the template placeholders with concrete values.
fill_placeholders() {
  sed \
    -e "s|<relative-path>|../../.notebook/specs/$SPEC_ID/SUMMARY.md|" \
    -e "s|<pr_url>|$PR_URL|g" \
    -e "s|<id>|$SPEC_ID|g" \
    -e "s|NNN|$PR_NUMBER|g" \
    -e "s|<comma-separated paths>|wiki/concepts/example-concept.md|" \
    -e "s|<YYYY-MM-DD>|2026-01-02|g" \
    -e 's|^ *||'
}

# Write a promoted page from the doc's templates to $1.
render_promoted_page() {
  local frontmatter
  frontmatter="$(fenced_block_after yaml '### Frontmatter rendering' | fill_placeholders)"
  [ -n "$frontmatter" ] || return 1
  printf -- '---\n%s\n---\n\n# Example Concept\n\nThe lede.\n' "$frontmatter" > "$1"
}

# Write the wiki/log.md line the doc's template renders to $1.
render_log_line() {
  fenced_block_after '' 'Line format:' | fill_placeholders > "$1"
  [ -s "$1" ]
}

# Run the real scrub over a staging directory holding one promoted page.
scrub_page() {
  local page="$1" staging
  staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging/wiki/concepts"
  cp "$page" "$staging/wiki/concepts/example-concept.md"
  run bash -c 'cd "$1" && "$2" release scrub "$3" --config "$4"' _ "$REPO_ROOT" "$MAINTAINER_CLI" "$staging" "$SCRUB_CONFIG"
  SCRUBBED_PAGE="$staging/wiki/concepts/example-concept.md"
}

@test "S1: the rendered page carries no id, source path or PR URL" {
  page="$BATS_TEST_TMPDIR/page.md"
  render_promoted_page "$page"
  grep -qF -- "$SPEC_ID" "$page" && return 1
  grep -qF -- "$PR_URL" "$page" && return 1
  grep -qF -- '.notebook/' "$page" && return 1
  true
}

@test "S2: a promoted page passes the release scrub with no leak and keeps its pr_number" {
  page="$BATS_TEST_TMPDIR/page.md"
  render_promoted_page "$page"
  scrub_page "$page"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'leaks: none'
  grep -qx -- "pr_number: $PR_NUMBER" "$SCRUBBED_PAGE"
}

@test "S3: the rendered page and the log line pass the machine-local reference detector" {
  page="$BATS_TEST_TMPDIR/page.md"
  log_line="$BATS_TEST_TMPDIR/log-line.md"
  render_promoted_page "$page"
  render_log_line "$log_line"
  grep -qF -- "PR #$PR_NUMBER" "$log_line"
  run bash "$DETECTOR" text "$page"
  [ "$status" -eq 0 ]
  run bash "$DETECTOR" text "$log_line"
  [ "$status" -eq 0 ]
}

# S2 and S3 pass only if the scrub and the detector can refuse: the same page
# with the id the old References block carried fails both.
@test "S4: the page with an id line added fails the scrub and the detector" {
  page="$BATS_TEST_TMPDIR/page.md"
  render_promoted_page "$page"
  printf -- '- Source: %s\n' "$SPEC_ID" >> "$page"
  run bash "$DETECTOR" text "$page"
  [ "$status" -eq 1 ]
  scrub_page "$page"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'spec-concrete-ids'
}

# Print the wikilink a template line renders for slug $2 and title $3; $1 is
# the template text between the backticks or the bullet in the fence.
render_link() {
  printf '%s\n' "$1" | sed -e "s|<slug>|$2|; s|<sibling-slug>|$2|; s|<page-title>|$3|; s|<sibling-page-title>|$3|"
}

# Build a two-page wiki under $1: a page whose H1 carries a '/', and an index
# linking it through the template line $2.
build_wiki() {
  local root="$1" link
  mkdir -p "$root/wiki/concepts"
  printf -- '---\ntype: concept\nstatus: active\n---\n\n# Read/Write Split\n\nBody.\n' > "$root/wiki/concepts/Read Write Split.md"
  link="$(render_link "$2" 'Read Write Split' 'Read/Write Split')"
  printf -- '---\ntype: index\n---\n\n# Index\n\n## Concepts\n\n%s\n' "$link" > "$root/wiki/index.md"
}

@test "L1: the index link template resolves for a page whose H1 carries a '/'" {
  template="$(grep -F 'Compute the wikilink:' "$PROMOTE_DOC" | sed -e 's|^[^`]*`||; s|`.*$||')"
  [ -n "$template" ]
  build_wiki "$BATS_TEST_TMPDIR/index-wiki" "$template"
  run bash -c 'cd "$1" && "$2" wiki broken-links' _ "$BATS_TEST_TMPDIR/index-wiki" "$ADOPTER_CLI"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "L2: the Related link template resolves for a page whose H1 carries a '/'" {
  template="$(fenced_block_after markdown '- **Has siblings**: emit:' | grep -F '[[' | head -n 1 | sed -e 's|^ *||')"
  [ -n "$template" ]
  build_wiki "$BATS_TEST_TMPDIR/related-wiki" "$template"
  run bash -c 'cd "$1" && "$2" wiki broken-links' _ "$BATS_TEST_TMPDIR/related-wiki" "$ADOPTER_CLI"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
