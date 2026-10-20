#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-quick-classify-lib.sh, the fail-closed
# classifier behind the first-dispatch quick route. Each case builds its own
# scratch repository (a base commit holding the before files, a second commit
# holding the after files), sources the router library and the classifier from
# this checkout, and asserts the exact decision line. Every red case carries a
# green twin that changes only the offending line and prints `quick`, so a
# classifier that printed a constant fails one side of each pair.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-quick-classify-lib.sh"
  # shellcheck source=.claude/hooks/lib/audit-light-route-lib.sh
  . "$REPO_ROOT/.claude/hooks/lib/audit-light-route-lib.sh"
  # shellcheck source=.claude/hooks/lib/audit-quick-classify-lib.sh
  . "$LIBRARY"
  COMPONENT="frontend/app/components/card/index.tsx"
  STORY="frontend/app/components/card/tests/index.stories.tsx"
  CHIP="frontend/app/components/ui/chip.tsx"
  ENGLISH="frontend/app/languages/en/common.ts"
  JAPANESE="frontend/app/languages/ja/common.ts"
  COMPONENT_BASE="$(cat <<'EOF'
import {cn} from 'cn';

const THEME_SCRIPT =
  "(function(){return 1})()";

const Card = () => (
  <div className="flex gap-2">
    <h2 className="text-xl">Title</h2>
    <p>
      Hello world
    </p>
    <span className={cn('px-2', 'py-1')}>Badge</span>
    <section
      className={cn(
        'rounded-md',
        'border'
      )}
    >
      Body
    </section>
    <button className="p-1">Go</button>
    <Button
      className="mt-2 focus-visible:ring-2"
      variant="ghost"
    >
      Save
    </Button>
    <a
      className="underline"
      href={
        '/docs/' +
        'intro'
      }
    >
      Docs
    </a>
  </div>
);

export default Card;
EOF
)"
  CHIP_BASE="$(cat <<'EOF'
import {cva} from 'class-variance-authority';

const chipVariants = cva('inline-flex', {
  variants: {
    tone: {
      plain: 'bg-background',
    },
  },
});

const Chip = () => (
  <span className="bg-background">Chip</span>
);

export {Chip, chipVariants};
EOF
)"
  STORY_BASE="$(cat <<'EOF'
import type {Meta, StoryObj} from '@storybook/react-vite';
import {expect, within} from 'storybook/test';
import Card from '..';

const meta: Meta<typeof Card> = {
  component: Card,
  title: 'Components/Card',
};

export default meta;

type Story = StoryObj<typeof Card>;

export const Default: Story = {
  args: {
    label: 'Save',
  },
};

export const Interactive: Story = {
  args: {label: 'Go'},
  parameters: {
    a11y: {test: 'error'},
  },
  play: async ({canvasElement}) => {
    const canvas = within(canvasElement);
    await expect(canvas.getByText('Go')).toBeVisible();
  },
};
EOF
)"
  ENGLISH_BASE="$(cat <<'EOF'
export default {
  title: 'Hello',
  counters: {
    clicks_one: '{{count}} click',
    clicks_other: '{{count}} clicks',
  },
  long:
    'A long value that prettier wrapped onto its own line for width',
  nested: '$t(common:title) here',
  html: 'Plain text',
};
EOF
)"
  JAPANESE_BASE="$(cat <<'EOF'
export default {
  title: 'こんにちは',
  counters: {
    clicks_one: '{{count}} クリック',
    clicks_other: '{{count}} クリック',
  },
  long:
    '長い値',
  nested: '$t(common:title) ここ',
  html: 'テキスト',
};
EOF
)"
}

qc_git() {
  git -C "$QC_ROOT" -c user.name=quick -c user.email=quick@example.invalid -c commit.gpgsign=false "$@"
}

qc_start() {
  QC_ROOT="$BATS_TEST_TMPDIR/repo"
  rm -rf "$QC_ROOT"
  git init -q "$QC_ROOT"
}

qc_put() {
  mkdir -p "$(dirname "$QC_ROOT/$1")"
  printf '%s\n' "$2" >"$QC_ROOT/$1"
}

qc_base() {
  qc_git add -A && qc_git commit -q -m base && QC_FROM="$(qc_git rev-parse 'HEAD^{tree}')"
}

# qc_edit <path> <replace|insert|delete> <line> [text]: insert puts <text>
# after <line>; <text> may hold newlines.
qc_edit() {
  QC_TEXT="${4:-}" awk -v op="$2" -v target="$3" '
    NR == target && op == "replace" { print ENVIRON["QC_TEXT"]; next }
    NR == target && op == "delete" { next }
    { print }
    NR == target && op == "insert" { print ENVIRON["QC_TEXT"] }
  ' "$QC_ROOT/$1" >"$QC_ROOT/$1.edited" && mv "$QC_ROOT/$1.edited" "$QC_ROOT/$1"
}

qc_head() {
  qc_git add -A && qc_git commit -q --allow-empty -m after && QC_HEAD="$(qc_git rev-parse HEAD)"
}

qc_write_paths() {
  QC_PATHS="$BATS_TEST_TMPDIR/paths"
  printf '%s\n' "$@" >"$QC_PATHS"
}

qc_lines() {
  qc_head
  qc_write_paths "$@"
  run quick_classify_lines "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS"
}

qc_paths() {
  qc_head
  qc_write_paths "$@"
  run quick_classify_paths "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS"
}

qc_expect() {
  if [ "$status" -ne 0 ] || [ "$output" != "$1" ]; then
    printf 'expected: %s\nstatus:   %s\noutput:   %s\n' "$1" "$status" "$output" >&2
    return 1
  fi
}

qc_expect_deep() {
  qc_expect "$(printf 'deep\t%s\t%s\t%s' "$1" "$2" "$3")"
}

qc_expect_quick() {
  qc_expect quick
}

qc_component() {
  qc_start
  qc_put "$COMPONENT" "$COMPONENT_BASE"
  qc_base
}

qc_language() {
  qc_start
  qc_put "$ENGLISH" "$ENGLISH_BASE"
  qc_put "$JAPANESE" "${1:-$JAPANESE_BASE}"
  qc_base
}

qc_story() {
  qc_start
  qc_put "$COMPONENT" "$COMPONENT_BASE"
  qc_put "$STORY" "$STORY_BASE"
  qc_base
  qc_edit "$COMPONENT" replace 10 '      Hello there'
}

# One red line case and its green twin on the component base: the twin applies
# the same operation at the same place with an allowed line.
qc_component_pair() {
  local reason="$1" op="$2" line="$3" red="$4" location="$5" green="$6"
  qc_component
  qc_edit "$COMPONENT" "$op" "$line" "$red"
  qc_lines "$COMPONENT"
  qc_expect_deep "$reason" "$COMPONENT" "$location" || return 1
  qc_component
  qc_edit "$COMPONENT" "$op" "$line" "$green"
  qc_lines "$COMPONENT"
  qc_expect_quick
}

# --- header and library hygiene ---------------------------------------------

# bats test_tags=whole-tree
@test "the classifier header lists exactly the classifier reasons and the router-owned reasons, each reason with a red case" {
  local classifier_reasons=(quick-path quick-file-status quick-codepoint quick-block-comment
    quick-template-literal quick-import quick-hook quick-handler quick-spread quick-conditional
    quick-map quick-cva quick-cn-argument quick-element quick-tag quick-attribute
    quick-hiding-token quick-motion-order-token quick-palette quick-arbitrary-value
    quick-language-shape quick-language-key quick-placeholder quick-nesting quick-html
    quick-empty-value quick-locale-missing quick-text-deleted quick-story-play quick-story-shape
    quick-unclassified)
  local router_owned=(anchor-unresolved refusal-newer unclassifiable-path special-file machinery
    ownerless hard-full no-delta over-cap fence-collision)
  local block unmarked marked expected token
  block="$(awk '/^# quick-signals:start$/ { inside = 1; next } /^# quick-signals:end$/ { inside = 0 } inside' "$LIBRARY")"
  [ -n "$block" ]
  unmarked="$(printf '%s\n' "$block" | awk '$3 != "router-owned:" { print $2 }' | LC_ALL=C sort)"
  marked="$(printf '%s\n' "$block" | awk '$3 == "router-owned:" { print $2 }' | LC_ALL=C sort)"
  [ -n "$unmarked" ]
  expected="$(printf '%s\n' "${classifier_reasons[@]}" | LC_ALL=C sort)"
  [ "$unmarked" = "$expected" ]
  [ "$(printf '%s\n' "$block" | grep -c '^#   [a-z-]*  ')" -eq "$(printf '%s\n' "$block" | grep -c .)" ]
  [ "$marked" = "$(printf '%s\n' "${router_owned[@]}" | LC_ALL=C sort)" ]
  for token in "${classifier_reasons[@]}"; do
    grep -qF "@test \"red $token:" "$BATS_TEST_FILENAME" || { printf 'no red case for %s\n' "$token" >&2; return 1; }
  done
}

# bats test_tags=whole-tree
@test "the classifier header keeps every router-owned row ahead of the classifier rows" {
  local first_classifier last_router
  first_classifier="$(awk '/^# quick-signals:start$/ { inside = 1; next } /^# quick-signals:end$/ { inside = 0 } inside && $3 != "router-owned:" { print NR; exit }' "$LIBRARY")"
  last_router="$(awk '/^# quick-signals:start$/ { inside = 1; next } /^# quick-signals:end$/ { inside = 0 } inside && $3 == "router-owned:" { last = NR } END { print last }' "$LIBRARY")"
  [ -n "$first_classifier" ] && [ -n "$last_router" ]
  [ "$last_router" -lt "$first_classifier" ]
}

# bats test_tags=whole-tree
@test "the library holds no cd, no GAIA or CI variable read, no machine-local path and no working-document id" {
  grep -nE '(^|[;&|[:space:]])cd[[:space:]]' "$LIBRARY" && return 1
  grep -nE '\$\{?(GAIA_[A-Za-z0-9_]*|CI)([^A-Za-z0-9_]|$)' "$LIBRARY" && return 1
  grep -nF '.gaia/local' "$LIBRARY" && return 1
  grep -nE '(SPEC|UAT|PLAN)-[0-9]|(^|[^A-Za-z])[A-Z]{2,5}-[0-9]{3}([^0-9]|$)|#[0-9]{2,}' "$LIBRARY" && return 1
  true
}

# bats test_tags=whole-tree
@test "the library is shellcheck clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not available"
  run shellcheck -x "$LIBRARY"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

# --- path shapes ------------------------------------------------------------

@test "quick_story_component maps an own story to its component and refuses any other shape" {
  run quick_story_component frontend/app/components/x/tests/index.stories.tsx
  [ "$status" -eq 0 ] && [ "$output" = "frontend/app/components/x/index.tsx" ]
  run quick_story_component frontend/app/components/ui/tests/button.stories.tsx
  [ "$status" -eq 0 ] && [ "$output" = "frontend/app/components/ui/button.tsx" ]
  run quick_story_component frontend/app/styles/tests/inline-link.stories.tsx
  [ "$status" -eq 0 ] && [ "$output" = "frontend/app/styles/inline-link.tsx" ]
  run quick_story_component frontend/app/components/x/tests/tests/index.stories.tsx
  [ "$status" -eq 1 ] && [ -z "$output" ]
  run quick_story_component frontend/app/components/x/index.stories.tsx
  [ "$status" -eq 1 ] && [ -z "$output" ]
  run quick_story_component tests/index.stories.tsx
  [ "$status" -eq 1 ] && [ -z "$output" ]
}

@test "quick_path_class prints the class of each allowlisted shape and none for everything else" {
  local pair path expected
  for pair in \
    "frontend/app/components/card/index.tsx component" \
    "frontend/app/components/ui/button.tsx component" \
    "frontend/app/pages/home/page.tsx page" \
    "frontend/app/pages/home/hero/index.tsx page" \
    "frontend/app/languages/en/common.ts language" \
    "frontend/app/languages/ja/pages/_index.ts language" \
    "frontend/app/components/card/tests/index.stories.tsx none" \
    "frontend/app/styles/tailwind.css none" \
    "frontend/app/components/errors/x/index.tsx none" \
    "frontend/app/components/document/index.tsx none" \
    "frontend/app/components/card/hooks/index.tsx none" \
    "frontend/app/languages/en/index.ts none" \
    "frontend/app/languages/index.ts none" \
    "frontend/app/routes/_index.tsx none"; do
    path="${pair% *}"
    expected="${pair##* }"
    run quick_path_class "$path"
    [ "$status" -eq 0 ] && [ "$output" = "$expected" ] || { printf '%s: %s\n' "$path" "$output" >&2; return 1; }
  done
}

# --- path stage ---------------------------------------------------------------

@test "red quick-path: a stylesheet, a route, the document component and a language aggregator each route deep" {
  local path
  for path in frontend/app/styles/tailwind.css frontend/app/routes/_index.tsx \
    frontend/app/components/document/index.tsx frontend/app/languages/en/index.ts; do
    qc_start
    qc_put "$path" 'export default {};'
    qc_base
    qc_put "$path" 'export default {a: 1};'
    qc_paths "$path"
    qc_expect_deep quick-path "$path" - || return 1
  done
  qc_component
  qc_edit "$COMPONENT" replace 10 '      Hello there'
  qc_paths "$COMPONENT"
  qc_expect_quick
}

@test "red quick-path: a component whose post-image carries an always-deep marker, each with a clean twin" {
  local marker
  for marker in 'nonce' 'process.env' 'import.meta.env' 'request'; do
    qc_component
    qc_edit "$COMPONENT" replace 10 "      Hello $marker"
    qc_paths "$COMPONENT"
    qc_expect_deep quick-path "$COMPONENT" - || { printf 'marker %s\n' "$marker" >&2; return 1; }
    qc_component
    qc_edit "$COMPONENT" replace 10 '      Hello there'
    qc_paths "$COMPONENT"
    qc_expect_quick || return 1
  done
}

@test "red quick-path: a story whose component is not in the selected set" {
  qc_story
  qc_edit "$STORY" replace 16 "    label: 'Submit',"
  qc_paths "$STORY"
  qc_expect_deep quick-path "$STORY" -
  qc_story
  qc_edit "$STORY" replace 16 "    label: 'Submit',"
  qc_paths "$COMPONENT" "$STORY"
  qc_expect_quick
}

@test "red quick-path: a story paired with a page, and one paired with a non-component sibling" {
  local page="frontend/app/pages/home/page.tsx" page_story="frontend/app/pages/home/tests/page.stories.tsx"
  local sibling="frontend/app/styles/inline-link.tsx" sibling_story="frontend/app/styles/tests/inline-link.stories.tsx"
  qc_start
  qc_put "$page" '<p>Hi</p>;'
  qc_put "$page_story" "export const A = {args: {label: 'a'}};"
  qc_put "$sibling" '<a>Link</a>;'
  qc_put "$sibling_story" "export const A = {args: {label: 'a'}};"
  qc_base
  qc_put "$page" '<p>Hello</p>;'
  qc_put "$page_story" "export const A = {args: {label: 'b'}};"
  qc_put "$sibling" '<a>Links</a>;'
  qc_put "$sibling_story" "export const A = {args: {label: 'b'}};"
  qc_paths "$page" "$page_story"
  qc_expect_deep quick-path "$page_story" - || return 1
  qc_write_paths "$sibling" "$sibling_story"
  run quick_classify_paths "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS"
  qc_expect_deep quick-path "$sibling" - || return 1
  qc_write_paths "$sibling_story" "$sibling"
  run quick_classify_paths "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS"
  qc_expect_deep quick-path "$sibling_story" -
}

@test "red quick-file-status: an added component file" {
  local added="frontend/app/components/badge/index.tsx"
  qc_component
  qc_put "$added" '<span>New</span>;'
  qc_paths "$added"
  qc_expect_deep quick-file-status "$added" -
}

@test "red quick-file-status: a deleted component file" {
  qc_component
  rm "$QC_ROOT/$COMPONENT"
  qc_paths "$COMPONENT"
  qc_expect_deep quick-file-status "$COMPONENT" -
}

@test "red quick-file-status: a renamed component reads as a delete plus an add, named by the first selected path" {
  local renamed="frontend/app/components/panel/index.tsx"
  qc_component
  mkdir -p "$QC_ROOT/frontend/app/components/panel"
  qc_git mv "$COMPONENT" "$renamed"
  qc_paths "$COMPONENT" "$renamed"
  qc_expect_deep quick-file-status "$COMPONENT" - || return 1
  qc_write_paths "$renamed" "$COMPONENT"
  run quick_classify_paths "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS"
  qc_expect_deep quick-file-status "$renamed" -
}

@test "red quick-file-status: a component turned into a symlink" {
  qc_component
  rm "$QC_ROOT/$COMPONENT"
  ln -s ../layout/index.tsx "$QC_ROOT/$COMPONENT"
  qc_paths "$COMPONENT"
  qc_expect_deep quick-file-status "$COMPONENT" -
}

@test "red quick-file-status: a component whose mode becomes 100755" {
  qc_component
  chmod 755 "$QC_ROOT/$COMPONENT"
  qc_git config core.fileMode true
  qc_paths "$COMPONENT"
  qc_expect_deep quick-file-status "$COMPONENT" -
}

# --- line stage: must-quick shapes --------------------------------------------

@test "must-quick: static JSX text, a div to span swap, intrinsic className tokens and a capitalized element's className line" {
  qc_component
  qc_edit "$COMPONENT" replace 10 '      Hello there'
  qc_lines "$COMPONENT"
  qc_expect_quick || return 1
  qc_component
  qc_edit "$COMPONENT" replace 9 '    <span>'
  qc_edit "$COMPONENT" replace 11 '    </span>'
  qc_lines "$COMPONENT"
  qc_expect_quick || return 1
  qc_component
  qc_edit "$COMPONENT" replace 7 '  <div className="flex gap-4 items-center">'
  qc_lines "$COMPONENT"
  qc_expect_quick || return 1
  qc_component
  qc_edit "$COMPONENT" replace 23 '      className="mt-4 focus-visible:ring-2"'
  qc_lines "$COMPONENT"
  qc_expect_quick
}

@test "must-quick: a token change inside an existing cn() string literal, single-line and multi-line" {
  qc_component
  qc_edit "$COMPONENT" replace 12 "    <span className={cn('px-3', 'py-1')}>Badge</span>"
  qc_lines "$COMPONENT"
  qc_expect_quick || return 1
  qc_component
  qc_edit "$COMPONENT" replace 15 "        'rounded-lg',"
  qc_lines "$COMPONENT"
  qc_expect_quick
}

@test "must-quick: a paired story args literal change alongside its component's change" {
  qc_story
  qc_edit "$STORY" replace 16 "    label: 'Submit',"
  qc_lines "$COMPONENT" "$STORY"
  qc_expect_quick || return 1
  qc_story
  qc_edit "$STORY" replace 21 "  args: {label: 'Run'},"
  qc_lines "$COMPONENT" "$STORY"
  qc_expect_quick
}

@test "must-quick: a value-only change in the en and ja language files, single-line, wrapped and single-line to wrapped" {
  qc_language
  qc_edit "$ENGLISH" replace 2 "  title: 'Hello there',"
  qc_edit "$JAPANESE" replace 2 "  title: 'やあ',"
  qc_lines "$ENGLISH" "$JAPANESE"
  qc_expect_quick || return 1
  qc_language
  qc_edit "$ENGLISH" replace 8 "    'A longer value that prettier wrapped onto its own line for width',"
  qc_edit "$JAPANESE" replace 8 "    'もっと長い値',"
  qc_lines "$ENGLISH" "$JAPANESE"
  qc_expect_quick || return 1
  qc_language
  qc_edit "$ENGLISH" replace 2 "$(printf "  title:\n    'Hello and welcome to a value long enough that prettier wraps it',")"
  qc_lines "$ENGLISH"
  qc_expect_quick
}

# --- line stage: deep signals, each with its green twin ----------------------

@test "red quick-codepoint: a U+202E in a text line, and a non-ASCII byte in a className value" {
  qc_component_pair quick-codepoint replace 10 "$(printf '      Hello \342\200\256world')" post:10 '      Hello world!' || return 1
  qc_component_pair quick-codepoint replace 7 "$(printf '  <div className="flex gap-2 \303\251">')" post:7 '  <div className="flex gap-3">'
}

@test "red quick-block-comment: a /* on a changed text line" {
  qc_component_pair quick-block-comment replace 10 '      Hello /* world' post:10 '      Hello / world'
}

@test "red quick-template-literal: a backtick on a changed text line" {
  qc_component_pair quick-template-literal replace 10 '      Hello `world`' post:10 "      Hello 'world'"
}

@test "red quick-import: an added import line" {
  qc_component_pair quick-import insert 2 "import x from 'y';" post:3 ''
}

@test "red quick-hook: an added hook call in JSX children" {
  qc_component_pair quick-hook insert 10 '      {useThing()}' post:11 '      More text'
}

@test "red quick-handler: an added element carrying an event handler" {
  qc_component_pair quick-handler insert 10 '      <span onClick={go}>x</span>' post:11 '      More text'
}

@test "red quick-spread: an added element carrying a spread" {
  qc_component_pair quick-spread insert 10 '      <span {...rest}>x</span>' post:11 '      More text'
}

@test "red quick-conditional: an added conditional render" {
  qc_component_pair quick-conditional insert 10 "      {ok && 'x'}" post:11 '      More text'
}

@test "red quick-map: an added list render" {
  qc_component_pair quick-map insert 10 '      {items.map(render)}' post:11 '      More text'
}

@test "red quick-cva: a className change inside a cva variant map" {
  qc_start
  qc_put "$CHIP" "$CHIP_BASE"
  qc_base
  qc_edit "$CHIP" replace 6 "      plain: 'bg-muted',"
  qc_lines "$CHIP"
  qc_expect_deep quick-cva "$CHIP" pre:6 || return 1
  qc_start
  qc_put "$CHIP" "$CHIP_BASE"
  qc_base
  qc_edit "$CHIP" replace 12 '  <span className="bg-muted">Chip</span>'
  qc_lines "$CHIP"
  qc_expect_quick
}

@test "red quick-cn-argument: a multi-line cn( continuation line turned into a variable, and a new cn argument" {
  qc_component_pair quick-cn-argument replace 16 '        borderClass' pre:16 "        'border-2'" || return 1
  qc_component_pair quick-cn-argument replace 12 "    <span className={cn('px-2', 'py-1', 'm-1')}>Badge</span>" pre:12 "    <span className={cn('px-2', 'py-2')}>Badge</span>"
}

@test "red quick-element: an added capitalized element, and a changed capitalized element line" {
  qc_component_pair quick-element insert 10 '      <Icon />' post:11 '      More text' || return 1
  qc_component
  qc_edit "$COMPONENT" replace 22 '    <Button size="sm"'
  qc_lines "$COMPONENT"
  qc_expect_deep quick-element "$COMPONENT" pre:22 || return 1
  qc_component
  qc_edit "$COMPONENT" replace 23 '      className="mt-3 focus-visible:ring-2"'
  qc_lines "$COMPONENT"
  qc_expect_quick
}

@test "red quick-tag: h2 to div and button to div" {
  qc_component_pair quick-tag replace 8 '    <div className="text-xl">Title</div>' pre:8 '    <h2 className="text-2xl">Title</h2>' || return 1
  qc_component_pair quick-tag replace 21 '    <div className="p-1">Go</div>' pre:21 '    <button className="p-2">Go</button>'
}

@test "red quick-tag: an added iframe, script, form and meta" {
  local tag count=0
  for tag in iframe script form meta; do
    qc_component_pair quick-tag insert 10 "      <$tag />" post:11 '      More text' || { printf 'tag %s\n' "$tag" >&2; return 1; }
    count=$((count + 1))
  done
  [ "$count" -eq 4 ]
}

@test "red quick-attribute: each non-className attribute added on an intrinsic element" {
  local names=(aria-label role tabIndex alt htmlFor id key href to target src srcDoc action hidden inert disabled placeholder)
  local name count=0
  [ "${#names[@]}" -eq 17 ]
  for name in "${names[@]}"; do
    qc_component_pair quick-attribute replace 7 "  <div className=\"flex gap-2\" $name=\"v\">" pre:7 '  <div className="flex gap-3">' || { printf 'attribute %s\n' "$name" >&2; return 1; }
    count=$((count + 1))
  done
  [ "$count" -eq 17 ]
}

@test "red quick-attribute: a multi-line href continuation line" {
  qc_component
  qc_edit "$COMPONENT" replace 32 "        'evil'"
  qc_lines "$COMPONENT"
  qc_expect_deep quick-attribute "$COMPONENT" pre:32 || return 1
  qc_component
  qc_edit "$COMPONENT" replace 29 '      className="underline-offset-2"'
  qc_lines "$COMPONENT"
  qc_expect_quick
}

@test "red quick-hiding-token: an added hidden, an added-only outline-none, and a removed focus-visible:ring-2" {
  qc_component_pair quick-hiding-token replace 7 '  <div className="flex gap-2 hidden">' post:7 '  <div className="flex gap-2 block">' || return 1
  qc_component_pair quick-hiding-token replace 7 '  <div className="flex gap-2 outline-none">' post:7 '  <div className="flex gap-2 outline-2">' || return 1
  qc_component_pair quick-hiding-token replace 23 '      className="mt-2"' pre:23 '      className="mt-2 focus-visible:ring-2 px-1"'
}

@test "red quick-motion-order-token: an added animate token" {
  qc_component_pair quick-motion-order-token replace 7 '  <div className="flex gap-2 animate-spin">' post:7 '  <div className="flex gap-2 rounded">'
}

@test "red quick-palette: an added raw palette token" {
  qc_component_pair quick-palette replace 7 '  <div className="flex gap-2 bg-red-500">' post:7 '  <div className="flex gap-2 bg-primary">'
}

@test "red quick-arbitrary-value: an added url( arbitrary value" {
  qc_component_pair quick-arbitrary-value replace 7 '  <div className="flex gap-2 bg-[url(x)]">' post:7 '  <div className="flex gap-2 w-3">'
}

@test "red quick-arbitrary-value: an arbitrary property or value spelling of a hiding, motion or palette token" {
  local token
  for token in '[display:none]' '[visibility:hidden]' '[outline:none]' '[pointer-events:none]' '[animation:spin_1s]' '[order:-1]' 'bg-[#ff0000]' 'text-[red]' 'opacity-[0]'; do
    qc_component_pair quick-arbitrary-value replace 7 "  <div className=\"flex gap-2 $token\">" post:7 '  <div className="flex gap-2 rounded">' || { printf 'token %s\n' "$token" >&2; return 1; }
  done
}

@test "red quick-hiding-token: an added size-0" {
  qc_component_pair quick-hiding-token replace 7 '  <div className="flex gap-2 size-0">' post:7 '  <div className="flex gap-2 size-4">'
}

@test "red quick-text-deleted: control text deleted with no replacement" {
  qc_component
  qc_edit "$COMPONENT" delete 26
  qc_lines "$COMPONENT"
  qc_expect_deep quick-text-deleted "$COMPONENT" pre:26 || return 1
  qc_component
  qc_edit "$COMPONENT" replace 26 '      Submit'
  qc_lines "$COMPONENT"
  qc_expect_quick
}

@test "red quick-unclassified: a line inside a multi-line string constant such as an inline theme script" {
  qc_component
  qc_edit "$COMPONENT" replace 4 '  "(function(){return 2})()";'
  qc_lines "$COMPONENT"
  qc_expect_deep quick-unclassified "$COMPONENT" pre:4 || return 1
  qc_component_pair quick-unclassified insert 10 "      {t('extra')}" post:11 '      More text'
}

@test "red quick-unclassified: text inside an existing style element, beside the same edit in a p" {
  local page="frontend/app/pages/home/page.tsx"
  qc_start
  qc_put "$page" "$(printf 'const Home = () => (\n  <div>\n    <style>\n      a\n    </style>\n    <p>\n      Hello\n    </p>\n  </div>\n);\n')"
  qc_base
  qc_edit "$page" replace 4 '      b'
  qc_lines "$page"
  qc_expect_deep quick-unclassified "$page" pre:4 || return 1
  qc_start
  qc_put "$page" "$(printf 'const Home = () => (\n  <div>\n    <style>\n      a\n    </style>\n    <p>\n      Hello\n    </p>\n  </div>\n);\n')"
  qc_base
  qc_edit "$page" replace 7 '      Hi'
  qc_lines "$page"
  qc_expect_quick
}

@test "red quick-language-shape: a process.env and an import.meta.env language value" {
  local value
  for value in 'process.env.TITLE' 'import.meta.env.TITLE'; do
    qc_language
    qc_edit "$ENGLISH" replace 2 "  title: $value,"
    qc_lines "$ENGLISH"
    qc_expect_deep quick-language-shape "$ENGLISH" pre:2 || { printf 'value %s\n' "$value" >&2; return 1; }
  done
  qc_language
  qc_edit "$ENGLISH" replace 2 "  title: 'Env title',"
  qc_lines "$ENGLISH"
  qc_expect_quick
}

@test "red quick-language-key: a plural suffix change" {
  qc_language
  qc_edit "$ENGLISH" replace 4 "    clicks_few: '{{count}} click',"
  qc_lines "$ENGLISH"
  qc_expect_deep quick-language-key "$ENGLISH" pre:4 || return 1
  qc_language
  qc_edit "$ENGLISH" replace 4 "    clicks_one: '{{count}} tap',"
  qc_lines "$ENGLISH"
  qc_expect_quick
}

@test "red quick-placeholder: {{count}} to {{count, number}}" {
  qc_language
  qc_edit "$ENGLISH" replace 4 "    clicks_one: '{{count, number}} click',"
  qc_lines "$ENGLISH"
  qc_expect_deep quick-placeholder "$ENGLISH" post:4 || return 1
  qc_language
  qc_edit "$ENGLISH" replace 4 "    clicks_one: '{{count}} press',"
  qc_lines "$ENGLISH"
  qc_expect_quick
}

@test "red quick-nesting: a changed \$t( reference" {
  qc_language
  qc_edit "$ENGLISH" replace 9 "  nested: '\$t(common:other) here',"
  qc_lines "$ENGLISH"
  qc_expect_deep quick-nesting "$ENGLISH" post:9 || return 1
  qc_language
  qc_edit "$ENGLISH" replace 9 "  nested: '\$t(common:title) there',"
  qc_lines "$ENGLISH"
  qc_expect_quick
}

@test "red quick-html: a tag in a language value" {
  qc_language
  qc_edit "$ENGLISH" replace 10 "  html: 'Plain <b>text</b>',"
  qc_lines "$ENGLISH"
  qc_expect_deep quick-html "$ENGLISH" post:10 || return 1
  qc_language
  qc_edit "$ENGLISH" replace 10 "  html: 'Plain bold text',"
  qc_lines "$ENGLISH"
  qc_expect_quick
}

@test "red quick-empty-value: a value emptied, and one made whitespace-only" {
  local value
  for value in "''" "'   '"; do
    qc_language
    qc_edit "$ENGLISH" replace 2 "  title: $value,"
    qc_lines "$ENGLISH"
    qc_expect_deep quick-empty-value "$ENGLISH" post:2 || { printf 'value %s\n' "$value" >&2; return 1; }
  done
  qc_language
  qc_edit "$ENGLISH" replace 2 "  title: 'Hi',"
  qc_lines "$ENGLISH"
  qc_expect_quick
}

@test "red quick-locale-missing: a key changed in en while ja lacks it" {
  local japanese_without_html
  japanese_without_html="$(printf '%s\n' "$JAPANESE_BASE" | grep -v "^  html:")"
  qc_language "$japanese_without_html"
  qc_edit "$ENGLISH" replace 10 "  html: 'Plain words',"
  qc_lines "$ENGLISH"
  qc_expect_deep quick-locale-missing "$ENGLISH" post:10 || return 1
  qc_language
  qc_edit "$ENGLISH" replace 10 "  html: 'Plain words',"
  qc_lines "$ENGLISH"
  qc_expect_quick
}

@test "red quick-story-shape: a story parameters change that turns a11y off" {
  qc_story
  qc_edit "$STORY" replace 23 "    a11y: {test: 'off'},"
  qc_lines "$COMPONENT" "$STORY"
  qc_expect_deep quick-story-shape "$STORY" pre:23 || return 1
  qc_story
  qc_edit "$STORY" replace 16 "    label: 'Off',"
  qc_lines "$COMPONENT" "$STORY"
  qc_expect_quick
}

@test "red quick-story-play: a story expect change" {
  qc_story
  qc_edit "$STORY" replace 27 "    await expect(canvas.getByText('Run')).toBeVisible();"
  qc_lines "$COMPONENT" "$STORY"
  qc_expect_deep quick-story-play "$STORY" pre:27 || return 1
  qc_story
  qc_edit "$STORY" replace 21 "  args: {label: 'Run'},"
  qc_lines "$COMPONENT" "$STORY"
  qc_expect_quick
}

# --- determinism and failure direction ----------------------------------------

@test "each classifier function prints byte-identical output on the same inputs" {
  local first second
  qc_component
  qc_edit "$COMPONENT" replace 7 '  <div className="flex gap-2 hidden">'
  qc_head
  qc_write_paths "$COMPONENT"
  first="$(quick_classify_lines "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS")"
  second="$(quick_classify_lines "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS")"
  [ -n "$first" ] && [ "$first" = "$second" ]
  first="$(quick_classify_paths "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS")"
  second="$(quick_classify_paths "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS")"
  [ "$first" = "quick" ] && [ "$first" = "$second" ]
  first="$(quick_path_class "$COMPONENT")"
  second="$(quick_path_class "$COMPONENT")"
  [ "$first" = "$second" ]
  first="$(quick_story_component "$STORY")"
  second="$(quick_story_component "$STORY")"
  [ "$first" = "$second" ]
}

@test "an unreadable from-tree exits 2 with no quick on stdout" {
  qc_component
  qc_edit "$COMPONENT" replace 10 '      Hello there'
  qc_head
  qc_write_paths "$COMPONENT"
  run quick_classify_paths "$QC_ROOT" 0123456789abcdef0123456789abcdef01234567 "$QC_HEAD" "$QC_PATHS"
  [ "$status" -eq 2 ]
  grep -q quick <<<"$output" && return 1
  run quick_classify_lines "$QC_ROOT" 0123456789abcdef0123456789abcdef01234567 "$QC_HEAD" "$QC_PATHS"
  [ "$status" -eq 2 ]
  grep -q quick <<<"$output" && return 1
  true
}

@test "a missing light_route_diff exits 2 with no quick on stdout" {
  qc_component
  qc_edit "$COMPONENT" replace 10 '      Hello there'
  qc_head
  qc_write_paths "$COMPONENT"
  unset -f light_route_diff
  run quick_classify_paths "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS"
  [ "$status" -eq 2 ]
  grep -q quick <<<"$output" && return 1
  run quick_classify_lines "$QC_ROOT" "$QC_FROM" "$QC_HEAD" "$QC_PATHS"
  [ "$status" -eq 2 ]
  grep -q quick <<<"$output" && return 1
  true
}
