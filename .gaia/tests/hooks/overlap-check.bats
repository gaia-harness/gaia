#!/usr/bin/env bats
#
# Suite for .gaia/scripts/overlap-check.sh: whether the overlap pass runs, the
# changed tests with their layers, and the check that stands between the
# evaluator's proposals and the human.
#
# Every case builds a fixture repo with a real merge base: the harness is linked
# in, a base commit holds the pre-existing legacy tests, and a feature commit
# adds the fixture tree under fixtures/overlap. A proposal is built by `cite`,
# which finds the cited line in the sibling file, so no case hard-codes a line.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/overlap-check.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

bats_require_minimum_version 1.5.0

EMERGENT_GLOBS='["app/components/**/*.test.tsx",".playwright/**/*.spec.ts","app/**/*.stories.tsx"]'
SIBLING='apps/web/.playwright/e2e/sibling.spec.ts'
SUBJECTS='apps/web/.playwright/e2e/subjects.spec.ts'
DROPPABLE='apps/web/.playwright/e2e/droppable.spec.ts'
RENDERED='apps/web/.playwright/e2e/rendered.spec.ts'
LEGACY='apps/web/.playwright/e2e/legacy.spec.ts'
LEGACY_EDITED='apps/web/.playwright/e2e/legacy-edited.spec.ts'
ROUTE_SIBLING='apps/web/app/route-tests/records.test.ts'
UNIT_SIBLING='apps/web/app/utils/format.test.ts'
SERVER_SIBLING='apps/web/test/x.server.test.ts'
PLAIN_UNIT_SIBLING='apps/web/test/x.test.ts'
OFF_LAYER='apps/web/lib/other.test.ts'
REFUSE_UNIT='apps/web/app/utils/refuse.test.ts'
SESSION_UNIT='apps/web/app/sessions.server/plain.test.ts'
DEMOTE='apps/web/.playwright/e2e/demote.spec.ts'
SESSION_NAME='adds two numbers'
SERVED='apps/web/.playwright/e2e/served.spec.ts'
LOOPED='apps/web/.playwright/e2e/route-status.spec.ts'
HELPERS='apps/web/.playwright/e2e/helpers.spec.ts'
RENDERED_HELPERS='apps/web/.playwright/e2e/rendered-helpers.spec.ts'
REPLACEMENT='apps/web/.playwright/e2e/demote-served.spec.ts'
MIXED='apps/web/.playwright/e2e/mixed.spec.ts'
TABLES='apps/web/app/route-tests/tables.server.test.ts'
SLUG_UNIT='apps/web/app/utils/slug.test.ts'
TRIM_UNIT='apps/web/app/utils/trim.test.ts'
SLUG_ROUTE='apps/web/app/route-tests/slugs.test.ts'
TROPHY_ROUTE='apps/web/app/route-tests/trophy.test.ts'
STORY='apps/web/app/components/card/tests/card.stories.tsx'

setup() {
  HOME_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$HOME_ROOT/.gaia/tests/hooks/helpers/package-fixture.sh"
  . "$HOME_ROOT/.gaia/tests/hooks/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  CHECK_SOURCE="${OVERLAP_CHECK_SOURCE:-$HOME_ROOT/.gaia/scripts/overlap-check.sh}"
  FIXTURES="$HOME_ROOT/.gaia/tests/hooks/fixtures/overlap"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  unset GIT_DIR GIT_WORK_TREE

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  write_builtin_descriptor "$REPO" '' '' "$EMERGENT_GLOBS"
  install_harness
  mkdir -p "$REPO/apps/web/.playwright/e2e"
  printf '# readme\n' >"$REPO/README.md"
  legacy_source 'legacy stays put' >"$REPO/$LEGACY"
  legacy_source 'blocks legacy access' >"$REPO/$LEGACY_EDITED"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  git -C "$REPO" checkout -q -b feature

  cp -R "$FIXTURES/." "$REPO/"
  legacy_source 'stops legacy access' >"$REPO/$LEGACY_EDITED"
  write_layer_fixtures
  write_trophy_fixtures
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m feature
  CHECK="$REPO/.gaia/scripts/overlap-check.sh"
  PROPOSALS="$BATS_TEST_TMPDIR/proposals.json"
}

install_harness() {
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  local library
  for library in gaia-packages.sh audit-base-provenance.sh; do
    ln -sfn "$HOME_ROOT/.claude/hooks/lib/$library" "$REPO/.claude/hooks/lib/$library"
  done
  for library in branch-authorship-lib.sh main-root-lib.sh red-ledger overlap spec; do
    ln -sfn "$HOME_ROOT/.gaia/scripts/$library" "$REPO/.gaia/scripts/$library"
  done
  cp "$CHECK_SOURCE" "$REPO/.gaia/scripts/overlap-check.sh"
}

legacy_source() {
  printf '%s\n' \
    "import {expect, test} from '@playwright/test';" \
    "" \
    "test('$1', async ({page}) => {" \
    "  await page.goto('/legacy');" \
    "  expect(await page.title()).toBe('Legacy');" \
    "});"
}

# The fixtures for the real-server and browser layers, the sibling-less demote,
# the looped templated title, the table-driven titles and the helper-call
# citations. Each opens a page only where its name says it does.
write_layer_fixtures() {
  mkdir -p "$REPO/apps/web/app/route-tests"
  cat >"$REPO/$TABLES" <<'EOF'
import {describe, expect, test} from 'vitest';

const ROLE_ROWS = [
  ['dashboard', 'rita', 'rita@example.com'],
  ['settings', 'sam', 'sam@example.com'],
];

const PAGE_ROWS = [
  {page: 'dashboard', status: 200},
  {page: 'settings', status: 403},
];

describe('per-role page status', () => {
  test.each(ROLE_ROWS)('%s as %s', async (pageKey, userKey, email) => {
    const outcome = await visit(pageKey, email);
    expect(outcome).toEqual(expectedOutcome(pageKey, userKey));
  });

  test.for(PAGE_ROWS)('$page answers $status', ({page, status}) => {
    expect(statusOf(page)).toBe(status);
  });

  test.each(['rita'])('%#: %s takes 100%% of the quota', (userKey) => {
    expect(quotaOf(userKey)).toBe(1);
  });

  test.each([['']])('pays 1%% now', (fee) => {
    expect(feeOf(fee)).toBe(1);
  });
});

describe.each(['admin', 'guest'])('as %s', (role) => {
  test('opens the records list', () => {
    expect(canOpen(role, 'records')).toBe(true);
  });
});
EOF

  cat >"$REPO/$DEMOTE" <<'EOF'
import {expect, test} from '@playwright/test';

test('shows the archive heading', async ({page}) => {
  const response = await page.goto('/archive');
  expect(response?.status()).toBe(200);
  await expect(page.locator('h1')).toHaveText('Archive');
});

test('refuses the forbidden admin page', async ({page}) => {
  const response = await page.goto('/admin');
  expect(response?.status()).toBe(403);
});
EOF
  cat >"$REPO/$SERVED" <<'EOF'
import {expect, test} from '@playwright/test';

test('serves the records list', async ({request}) => {
  const response = await request.get('/records');
  expect(response.status()).toBe(200);
});
EOF
  cat >"$REPO/$LOOPED" <<'EOF'
import {expect, test} from '@playwright/test';

const PAGES = [
  {heading: 'Home', path: '/'},
  {heading: 'About', path: '/about'},
];

for (const {heading, path} of PAGES) {
  test(`${path} responds 200 and renders its own page`, async ({request}) => {
    const response = await request.get(path);
    expect(response.status()).toBe(200);
    expect(await response.text()).toContain(heading);
  });
}
EOF
  cat >"$REPO/$HELPERS" <<'EOF'
import {expect, test} from '@playwright/test';
import {expectHeading} from '../support/assertions';

const assertNothing = async (page) => {
  await page.waitForLoadState();
};

async function assertTitle(page) {
  expect(await page.title()).toBe('Records');
}

test('calls a helper that asserts nothing', async ({page}) => {
  await page.goto('/records');
  await assertNothing(page);
});

test('calls a helper that asserts', async ({page}) => {
  await page.goto('/records');
  await assertTitle(page);
});

test('calls an imported helper', async ({page}) => {
  await page.goto('/records');
  await expectHeading(page, 'Records');
});

test('answers a missing record over several lines', async ({request}) => {
  const response = await request.get('/records/missing');
  expect(
    response.status(),
  ).toBe(404);
});
EOF
  cat >"$REPO/$RENDERED_HELPERS" <<'EOF'
// gaia-uat-contract sha256:0000000000000000000000000000000000000000000000000000000000000000
import {expect, test} from '@playwright/test';

async function assertTitle(page) {
  expect(await page.title()).toBe('Records');
}

test('a rendered test that calls a helper', async ({page}) => {
  await page.goto('/records');
  await assertTitle(page);
});
EOF
}

# The fold-up and unit-reason fixtures: two unit subjects in two files, the
# route tests that already assert their property, route subjects for the
# reason rule, and a story whose attached test is a cover.
write_trophy_fixtures() {
  mkdir -p "$REPO/apps/web/app/utils" "$REPO/apps/web/app/route-tests" "$REPO/$(dirname "$STORY")"
  write_slug_unit 'slugs a title' 'keeps digits'
  write_trim_unit 'trims spaces'
  write_slug_route
  cat >"$REPO/$TROPHY_ROUTE" <<'EOF'
import {expect, test} from 'vitest';

test('demote with both conditions', () => {
  expect(1).toBe(1);
});

test('demote with no reason', () => {
  expect(1).toBe(1);
});

test('demote with one condition', () => {
  expect(1).toBe(1);
});

test('demote onto a story', () => {
  expect(1).toBe(1);
});

test('drops a route check', () => {
  expect(1).toBe(1);
});

test('drop onto a folded subject', () => {
  expect(1).toBe(1);
});
EOF
  cat >"$REPO/$STORY" <<'EOF'
import {expect} from 'storybook/test';
import preview from '#.storybook/preview';
import {Card} from '../index';

const meta = preview.meta({
  component: Card,
  title: 'Card',
});

export const Default = meta.story({
  args: {title: 'Title'},
});

Default.test('shows the title', async ({canvas}) => {
  await expect(canvas.getByText('Title')).toBeVisible();
});
EOF
}

# write_slug_route [extra test name]: the route tests a fold-up folds into,
# plus one more test when named, the way a fixer that wrote a test leaves it.
write_slug_route() {
  {
    printf "import {expect, test} from 'vitest';\n"
    printf "\ntest('the slug route answers the slug', async () => {\n  expect(await slugRoute(' A b ')).toBe('a-b');\n});\n"
    printf "\ntest('the trim route answers the trimmed text', async () => {\n  expect(await trimRoute(' a ')).toBe('a');\n});\n"
    [ -z "${1:-}" ] || printf "\ntest('%s', async () => {\n  expect(await slugRoute('x')).toBe('x');\n});\n" "$1"
  } >"$REPO/$SLUG_ROUTE"
}

# write_slug_unit <name>... and write_trim_unit <name>...: each unit file
# holding only the named tests, the way a fixer leaves it after a deletion.
write_slug_unit() {
  local name
  {
    printf "import {expect, test} from 'vitest';\n"
    for name in "$@"; do
      case "$name" in
        'slugs a title') printf "\ntest('slugs a title', () => {\n  expect(slugOf('A b')).toBe('a-b');\n});\n" ;;
        *) printf "\ntest('%s', () => {\n  expect(slugOf('a1')).toBe('a1');\n});\n" "$name" ;;
      esac
    done
  } >"$REPO/$SLUG_UNIT"
}

write_trim_unit() {
  local name
  {
    printf "import {expect, test} from 'vitest';\n"
    for name in "$@"; do
      printf "\ntest('%s', () => {\n  expect(trim(' a ')).toBe('a');\n});\n" "$name"
    done
  } >"$REPO/$TRIM_UNIT"
}

line_of() { grep -n -F -m1 -- "$2" "$REPO/$1" | cut -d: -f1; }

# cite attaches this unit reason unless UNIT_REASON says otherwise: `null`
# leaves it out, any other value is the JSON attached. A proposal that needs
# no reason is judged the same with or without it.
DEFAULT_UNIT_REASON='{"integrationCost":"the route layer cannot reach every case cheaply","risk":"the logic is likely to fail"}'

# cite <kind> <file> <fullName> <seam> <sibling-file> <sibling-fullName> <assertion> [bug]
# The cited line is CITE_LINE when set, else where the assertion sits.
cite() {
  local line="${CITE_LINE:-$(line_of "$5" "$7")}"
  jq -n --arg kind "$1" --arg file "$2" --arg name "$3" --argjson seam "$4" \
    --arg sf "$5" --argjson sl "${line:-0}" --arg sn "$6" --arg sa "$7" --arg bug "${8:-}" \
    --argjson reason "${UNIT_REASON:-$DEFAULT_UNIT_REASON}" '{
      proposal: $kind, file: $file, fullName: $name, seam: $seam,
      property: "the property", actor: "the actor", action: "the action",
      sibling: {file: $sf, line: $sl, fullName: $sn, assertion: $sa}
    } + (if $bug == "" then {} else {bug: $bug} end)
      + (if $reason == null then {} else {unitReason: $reason} end)'
}

# fold_up <property> <into-file> <into-fullName> <assertion> <file> <fullName> [<file> <fullName>]...
# An <into-file> of - leaves out `into`; NEEDS sets needsNewTest. A fold-up has
# no top-level fullName, so fold_reason and fold_field find it by property.
fold_up() {
  local property="$1" into_file="$2" into_name="$3" assertion="$4" subjects='[]' line=''
  shift 4
  while [ "$#" -ge 2 ]; do
    subjects="$(jq -c --arg f "$1" --arg n "$2" '. + [{file: $f, fullName: $n}]' <<<"$subjects")"
    shift 2
  done
  [ "$into_file" = - ] || line="${CITE_LINE:-$(line_of "$into_file" "$assertion")}"
  jq -n --arg property "$property" --arg f "$into_file" --arg n "$into_name" --arg a "$assertion" \
    --argjson l "${line:-0}" --argjson subjects "$subjects" --arg needs "${NEEDS:-}" '{
      proposal: "fold-up", subjects: $subjects, seam: false,
      property: $property, actor: "the actor", action: "the action"
    } + (if $f == "-" then {} else {into: {file: $f, line: $l, fullName: $n, assertion: $a}} end)
      + (if $needs == "" then {} else {needsNewTest: $needs} end)'
}

# target_cite <file> <fullName> <seam> <assertion>...: a sibling-less demote
# whose target cites each assertion where it sits in <file>. CITE_LINE pins
# every cited line, TARGET_LAYER the target layer, KIND the proposal kind.
target_cite() {
  local file="$1" name="$2" seam="$3" assertion line assertions='[]'
  shift 3
  for assertion in "$@"; do
    line="${CITE_LINE:-$(line_of "$file" "$assertion")}"
    assertions="$(jq -c --argjson l "${line:-0}" --arg a "$assertion" '. + [{line: $l, assertion: $a}]' <<<"$assertions")"
  done
  jq -n --arg kind "${KIND:-demote}" --arg file "$file" --arg name "$name" --argjson seam "$seam" \
    --arg layer "${TARGET_LAYER:-real-server}" --argjson assertions "$assertions" '{
      proposal: $kind, file: $file, fullName: $name, seam: $seam,
      property: "the property", actor: "the actor", action: "the action",
      target: {layer: $layer, assertions: $assertions}
    }'
}

# kept_with_replacement <fullName> <file> <test name> <assertion>: the last
# check's kept list, the named entry carrying the fixer's replacement citation,
# the way the orchestrator merges it before --post-fix.
kept_with_replacement() {
  local line
  line="$(line_of "$2" "$4")"
  jq --arg n "$1" --arg f "$2" --argjson l "${line:-1}" --arg t "$3" --arg a "$4" \
    '[.kept[] | if .fullName == $n then . + {replacement: {file: $f, line: $l, fullName: $t, assertion: $a}} else . end]' <<<"$output"
}

# write_served_replacement: the fixer's request-only tests for both demotes.
write_served_replacement() {
  cat >"$REPO/$REPLACEMENT" <<'EOF'
import {expect, test} from '@playwright/test';

test('serves the archive heading', async ({request}) => {
  const response = await request.get('/archive');
  expect(response.status()).toBe(200);
});

test('refuses the admin page', async ({request}) => {
  const response = await request.get('/admin');
  expect(response.status()).toBe(403);
});
EOF
}

# mutate <from> <to> <in> <out>: a copy with the first occurrence replaced,
# failing when <from> is absent so a red twin never runs the unmutated file.
mutate() {
  awk -v from="$1" -v to="$2" '{ if (!done && (i = index($0, from)) > 0) { $0 = substr($0, 1, i - 1) to substr($0, i + length(from)); done = 1 } print }' "$3" >"$4"
  ! cmp -s "$3" "$4" || { printf '"%s" is not in %s\n' "$1" "$3" >&2; return 1; }
}

# install_mutated_module <module> <from> <to>: the fixture's overlap directory
# becomes real, every entry a link to the checkout's file except <module>, a
# mutated copy. node_modules links to the checkout's so the copy resolves
# typescript; red-ledger and spec stay linked whole.
install_mutated_module() {
  local overlap="$REPO/.gaia/scripts/overlap" entry
  rm -f "$overlap"
  mkdir -p "$overlap"
  # gaia-lint-ignore whole-tree-mark-guard: every test that reaches this link farm carries the per-test mark
  for entry in "$HOME_ROOT/.gaia/scripts/overlap/"*; do
    ln -sfn "$entry" "$overlap/$(basename "$entry")"
  done
  rm -f "$overlap/$1"
  mutate "$2" "$3" "$HOME_ROOT/.gaia/scripts/overlap/$1" "$overlap/$1" || return 1
  ln -sfn "$HOME_ROOT/node_modules" "$REPO/node_modules"
}

run_check() {
  run --separate-stderr bash "$CHECK" check --root "$REPO" --proposals "$PROPOSALS" "$@"
}

# check_all: the proposals on stdin, as separate objects, run through check.
check_all() {
  jq -s . >"$PROPOSALS"
  run_check
  [ "$status" -eq 0 ]
}

reason_of() { jq -r --arg n "$1" '[.discarded[] | select(.fullName == $n) | .reason] | join(",")' <<<"$output"; }
kept_field() { jq -r --arg n "$1" --arg f "$2" '[.kept[] | select(.fullName == $n) | .[$f]] | map(tostring) | join(",")' <<<"$output"; }
is_kept() { [ "$(jq -r --arg n "$1" '[.kept[] | select(.fullName == $n)] | length' <<<"$output")" = 1 ]; }
fold_reason() { jq -r --arg p "$1" '[.discarded[] | select(.property == $p) | .reason] | join(",")' <<<"$output"; }
fold_field() { jq -r --arg p "$1" --arg f "$2" '[.kept[] | select(.property == $p) | .[$f]] | map(tostring) | join(",")' <<<"$output"; }

LIVE_ASSERTION="expect(await page.title()).toBe('Records')"
UNIT_ASSERTION="expect(formatTitle('a')).toBe('A')"

# --- citations ---------------------------------------------------------------

@test "a real assertion in a live body is kept" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION")
  is_kept 'repeats the records title'
  [ "$(kept_field 'repeats the records title' disposition)" = offer ]
}

@test "citation text absent from the cited line is citation-unverified" {
  check_all < <(CITE_LINE=5 cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "toBe('Nowhere')")
  [ "$(reason_of 'repeats the records title')" = citation-unverified ]
}

@test "a cited line outside the named test's body is citation-unverified" {
  check_all < <(CITE_LINE=1 cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "import {expect, test}")
  [ "$(reason_of 'repeats the records title')" = citation-unverified ]
}

@test "citation text inside a comment is citation-not-live" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'commented assertion' "toBe('Hidden gem')")
  [ "$(reason_of 'repeats the records title')" = citation-not-live ]
}

@test "citation text in a test.skip is citation-not-live" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'skipped assertion' "toBe('Skipped title')")
  [ "$(reason_of 'repeats the records title')" = citation-not-live ]
}

@test "citation text under a skipped describe is citation-not-live" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'skipped group inside skipped group' "expect(2).toBe(2)")
  [ "$(reason_of 'repeats the records title')" = citation-not-live ]
}

# --- the kept set ------------------------------------------------------------

@test "a citation of the test itself is a self-citation" {
  check_all < <(cite drop "$SIBLING" 'shows the records page' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION")
  [ "$(reason_of 'shows the records page')" = self-citation ]
}

@test "two proposals citing each other are both discarded as mutual-citation" {
  check_all < <(
    cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION"
    cite drop "$SIBLING" 'shows the records page' false "$DROPPABLE" 'repeats the records title' "$LIVE_ASSERTION"
  )
  [ "$(reason_of 'repeats the records title')" = mutual-citation ]
  [ "$(reason_of 'shows the records page')" = mutual-citation ]
  [ "$(jq '.kept | length' <<<"$output")" -eq 0 ]
}

@test "a citation of a test another kept drop removes is sibling-removed" {
  check_all < <(
    cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION"
    cite drop "$SIBLING" 'shows the records page' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
  )
  [ "$(reason_of 'repeats the records title')" = sibling-removed ]
  is_kept 'shows the records page'
}

@test "a merge and a demote remove their subject for the citations that name it" {
  check_all < <(
    cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION"
    cite merge "$SIBLING" 'shows the records page' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
  )
  [ "$(reason_of 'repeats the records title')" = sibling-removed ]
  check_all < <(
    cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION"
    cite demote "$SIBLING" 'shows the records page' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
  )
  [ "$(reason_of 'repeats the records title')" = sibling-removed ]
}

@test "a keep-both does not remove the test it names, so a citation of it stands" {
  check_all < <(
    cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION"
    cite keep-both "$SIBLING" 'shows the records page' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION" 'the unit test cannot see the page title'
  )
  is_kept 'repeats the records title'
  is_kept 'shows the records page'
}

@test "the fixed point holds on a three-proposal chain" {
  check_all < <(
    cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION"
    cite drop "$SIBLING" 'shows the records page' false "$ROUTE_SIBLING" 'the records route answers 200' "expect(200).toBe(200)"
    cite drop "$ROUTE_SIBLING" 'the records route answers 200' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
  )
  [ "$(reason_of 'repeats the records title')" = sibling-removed ]
  [ "$(reason_of 'shows the records page')" = sibling-removed ]
  is_kept 'the records route answers 200'
  [ "$(jq '.kept | length' <<<"$output")" -eq 1 ]
}

# --- the seam rule -----------------------------------------------------------

@test "seam titles and bodies with the flag false are seams: drop, demote and merge citing a lower layer are discarded" {
  local names=(
    'refuses an edit to another account'
    'hides records of another user'
    'ignores forged fields on submit'
    'answers for a missing page'
    'hiding the banner'
    'denies entry to guests'
    'escaping markup in names'
    'unauthorized visitors see the form'
    'creates a user'
  )
  local kinds=(drop demote merge drop drop drop drop drop drop)
  local index=0 name
  check_all < <(
  for name in "${names[@]}"; do
    cite "${kinds[$index]}" "$SUBJECTS" "$name" false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
    index=$((index + 1))
  done
  )
  [ "$(jq '.discarded | length' <<<"$output")" -eq "${#names[@]}" ]
  for name in "${names[@]}"; do
    [ "$(reason_of "$name")" = seam-no-sibling-at-or-above ] || { echo "$name: $(reason_of "$name")"; return 1; }
  done
}

@test "a getByRole call alone does not make a test a seam" {
  check_all < <(
    cite drop "$SUBJECTS" 'opens the settings page' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
    cite drop "$SUBJECTS" 'walks the first step' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
  )
  is_kept 'opens the settings page'
  [ "$(kept_field 'opens the settings page' seam)" = false ]
  [ "$(kept_field 'walks the first step' seam)" = false ]
}

@test "the project word list adds a seam word and cannot remove a built-in one" {
  check_all < <(cite drop "$SUBJECTS" 'reads the invoice' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION")
  is_kept 'reads the invoice'
  printf 'invoice\n' >"$REPO/.gaia/overlap-seams.txt"
  check_all < <(
    cite drop "$SUBJECTS" 'reads the invoice' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
    cite drop "$SUBJECTS" 'unauthorized visitors see the form' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
  )
  [ "$(reason_of 'reads the invoice')" = seam-no-sibling-at-or-above ]
  [ "$(reason_of 'unauthorized visitors see the form')" = seam-no-sibling-at-or-above ]
}

@test "a test under a path holding session is a seam" {
  check_all < <(cite drop "$SESSION_UNIT" 'adds two numbers' false "$ROUTE_SIBLING" 'the records route answers 200' "expect(200).toBe(200)")
  [ "$(kept_field 'adds two numbers' seam)" = true ]
}

@test "a seam with a verified sibling at the same layer or one above is kept" {
  check_all < <(
    cite drop "$SUBJECTS" 'refuses an edit to another account' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION"
    cite drop "$REFUSE_UNIT" 'refuses blank input' false "$ROUTE_SIBLING" 'the records route answers 200' "expect(200).toBe(200)"
    cite merge "$REFUSE_UNIT" 'refuses blank input' true "$SIBLING" 'shows the records page' "$LIVE_ASSERTION"
  )
  [ "$(kept_field 'refuses an edit to another account' seam)" = true ]
  [ "$(kept_field 'refuses an edit to another account' layer)" = browser ]
  [ "$(kept_field 'refuses an edit to another account' siblingLayer)" = browser ]
  [ "$(jq '[.kept[] | select(.fullName == "refuses blank input")] | length' <<<"$output")" -eq 2 ]
  [ "$(jq -r '[.kept[] | select(.fullName == "refuses blank input") | .siblingLayer] | join(",")' <<<"$output")" = route,browser ]
}

@test "a keep-both naming the bug is kept even for a seam citing a lower layer" {
  check_all < <(cite keep-both "$SUBJECTS" 'refuses an edit to another account' true "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION" 'the unit test never reaches the route guard')
  is_kept 'refuses an edit to another account'
}

@test "a test/ server test ranks as route and a plain test/ test ranks as unit" {
  check_all < <(
    cite drop "$SUBJECTS" 'refuses an edit to another account' false "$SERVER_SIBLING" 'answers the loader' "expect(loaded).toBe(true)"
    cite drop "$SUBJECTS" 'hides records of another user' false "$PLAIN_UNIT_SIBLING" 'counts items' "expect(count([1])).toBe(1)"
    cite drop "$REFUSE_UNIT" 'refuses blank input' false "$SERVER_SIBLING" 'answers the loader' "expect(loaded).toBe(true)"
  )
  [ "$(reason_of 'refuses an edit to another account')" = seam-no-sibling-at-or-above ]
  [ "$(reason_of 'hides records of another user')" = seam-no-sibling-at-or-above ]
  [ "$(kept_field 'refuses blank input' siblingLayer)" = route ]
  [ "$(kept_field 'refuses blank input' layer)" = unit ]
}

@test "a sibling at a path mapping to no layer is sibling-no-layer for every kind" {
  check_all < <(
    cite drop "$DROPPABLE" 'repeats the records title' false "$OFF_LAYER" 'lives off every layer' "expect(1).toBe(1)"
    cite keep-both "$SUBJECTS" 'walks the first step' false "$OFF_LAYER" 'lives off every layer' "expect(1).toBe(1)" 'a real bug'
  )
  [ "$(reason_of 'repeats the records title')" = sibling-no-layer ]
  [ "$(reason_of 'walks the first step')" = sibling-no-layer ]
}

@test "a keep-both with no bug is no-distinguishing-bug" {
  check_all < <(cite keep-both "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION")
  [ "$(reason_of 'repeats the records title')" = no-distinguishing-bug ]
}

@test "a proposal missing a required field is malformed" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION" | jq 'del(.actor)')
  [ "$(reason_of 'repeats the records title')" = malformed ]
}

@test "a subject whose name resolves to no test is subject-not-found, whatever its flag or title" {
  check_all < <(
    cite drop "$SUBJECTS" 'a name that is not in the file' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION"
    cite drop "$SUBJECTS" 'refuses a name that is not in the file' true "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
  )
  [ "$(reason_of 'a name that is not in the file')" = subject-not-found ]
  [ "$(reason_of 'refuses a name that is not in the file')" = subject-not-found ]
}

@test "a subject at a path on no layer is subject-no-layer" {
  check_all < <(cite drop "$OFF_LAYER" 'lives off every layer' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION")
  [ "$(reason_of 'lives off every layer')" = subject-no-layer ]
}

# --- disposition -------------------------------------------------------------

@test "a test the branch wrote is offered" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION")
  [ "$(kept_field 'repeats the records title' disposition)" = offer ]
}

@test "a rendered spec is report-only with reason rendered" {
  check_all < <(cite drop "$RENDERED" 'shows the rendered page' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION")
  [ "$(kept_field 'shows the rendered page' disposition)" = report-only ]
  [ "$(kept_field 'shows the rendered page' reportReason)" = rendered ]
}

@test "a test the branch did not touch is report-only with reason not-authored" {
  check_all < <(cite drop "$LEGACY" 'legacy stays put' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION")
  [ "$(kept_field 'legacy stays put' disposition)" = report-only ]
  [ "$(kept_field 'legacy stays put' reportReason)" = not-authored ]
}

@test "a pre-existing test with only its title line edited stays report-only" {
  check_all < <(cite drop "$LEGACY_EDITED" 'stops legacy access' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION")
  [ "$(kept_field 'stops legacy access' disposition)" = report-only ]
  [ "$(kept_field 'stops legacy access' reportReason)" = not-authored ]
}

@test "an authorship answer of unknown is report-only with reason authorship-unknown" {
  git -C "$REPO" branch -m main trunk
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION")
  [ "$(kept_field 'repeats the records title' disposition)" = report-only ]
  [ "$(kept_field 'repeats the records title' reportReason)" = authorship-unknown ]
}

# --- --post-fix --------------------------------------------------------------

@test "post-fix passes when a same-file drop above the sibling moved its line, and the plain check does not" {
  cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION" >"$BATS_TEST_TMPDIR/one.json"
  jq -s . "$BATS_TEST_TMPDIR/one.json" >"$PROPOSALS"
  { printf '// one\n// two\n// three\n'; cat "$REPO/$SIBLING"; } >"$BATS_TEST_TMPDIR/shifted.ts"
  cp "$BATS_TEST_TMPDIR/shifted.ts" "$REPO/$SIBLING"
  rm -f "$REPO/$DROPPABLE"
  run_check --post-fix
  [ "$status" -eq 0 ]
  is_kept 'repeats the records title'
  run_check
  [ "$status" -eq 0 ]
  [ "$(reason_of 'repeats the records title')" = subject-not-found ]
}

@test "post-fix passes when a merge edits the sibling and keeps the cited assertion" {
  cite merge "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION" | jq -s . >"$PROPOSALS"
  sed "s|  expect(await page.title()).toBe('Records');|  await page.reload();\n  expect(await page.title()).toBe('Records');|" "$REPO/$SIBLING" >"$BATS_TEST_TMPDIR/edited.ts"
  cp "$BATS_TEST_TMPDIR/edited.ts" "$REPO/$SIBLING"
  rm -f "$REPO/$DROPPABLE"
  run_check --post-fix
  [ "$status" -eq 0 ]
  is_kept 'repeats the records title'
}

@test "post-fix refuses a sibling whose assertion text is gone or whose test is gone" {
  cite drop "$DROPPABLE" 'repeats the records title' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION" | jq -s . >"$PROPOSALS"
  sed "s|toBe('Records')|toBe('Changed')|" "$REPO/$SIBLING" >"$BATS_TEST_TMPDIR/edited.ts"
  cp "$BATS_TEST_TMPDIR/edited.ts" "$REPO/$SIBLING"
  rm -f "$REPO/$DROPPABLE"
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(reason_of 'repeats the records title')" = citation-unverified ]
  sed "s|shows the records page|renamed page test|" "$REPO/$SIBLING" >"$BATS_TEST_TMPDIR/renamed.ts"
  cp "$BATS_TEST_TMPDIR/renamed.ts" "$REPO/$SIBLING"
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(reason_of 'repeats the records title')" = citation-unverified ]
}

# --- the sibling-less demote -------------------------------------------------

ARCHIVE_STATUS='expect(response?.status()).toBe(200)'
ARCHIVE_HEADING="await expect(page.locator('h1')).toHaveText('Archive')"
ADMIN_STATUS='expect(response?.status()).toBe(403)'
SERVED_ARCHIVE='expect(response.status()).toBe(200)'
SERVED_ADMIN='expect(response.status()).toBe(403)'

@test "a sibling-less demote of a builder browser test is kept with its target layer and offered" {
  check_all < <(target_cite "$DEMOTE" 'shows the archive heading' false "$ARCHIVE_STATUS" "$ARCHIVE_HEADING")
  is_kept 'shows the archive heading'
  [ "$(kept_field 'shows the archive heading' layer)" = browser ]
  [ "$(kept_field 'shows the archive heading' targetLayer)" = real-server ]
  [ "$(kept_field 'shows the archive heading' disposition)" = offer ]
}

@test "a sibling-less demote of a security-boundary browser test is kept as a seam" {
  check_all < <(target_cite "$DEMOTE" 'refuses the forbidden admin page' false "$ADMIN_STATUS")
  is_kept 'refuses the forbidden admin page'
  [ "$(kept_field 'refuses the forbidden admin page' seam)" = true ]
  [ "$(kept_field 'refuses the forbidden admin page' targetLayer)" = real-server ]
}

# bats test_tags=whole-tree
@test "red twin: the seam rule against the subject's own rank refuses the browser seam demote" {
  install_mutated_module check-proposals.mjs 'Math.min(subjectRank, SEAM_CEILING)' 'subjectRank'
  check_all < <(target_cite "$DEMOTE" 'refuses the forbidden admin page' false "$ADMIN_STATUS")
  [ "$(reason_of 'refuses the forbidden admin page')" = seam-no-sibling-at-or-above ]
}

@test "a target assertion whose line or text is not in the subject test is citation-unverified" {
  check_all < <(CITE_LINE="$(line_of "$DEMOTE" "$ADMIN_STATUS")" target_cite "$DEMOTE" 'shows the archive heading' false "$ARCHIVE_STATUS")
  [ "$(reason_of 'shows the archive heading')" = citation-unverified ]
  check_all < <(CITE_LINE="$(line_of "$DEMOTE" "$ARCHIVE_STATUS")" target_cite "$DEMOTE" 'shows the archive heading' false 'toBe(418)')
  [ "$(reason_of 'shows the archive heading')" = citation-unverified ]
}

@test "a demote of a rendered test is report-only with reason rendered in both shapes" {
  check_all < <(cite demote "$RENDERED" 'shows the rendered page' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION")
  [ "$(kept_field 'shows the rendered page' disposition)" = report-only ]
  [ "$(kept_field 'shows the rendered page' reportReason)" = rendered ]
  check_all < <(target_cite "$RENDERED" 'shows the rendered page' false "expect(await page.title()).toBe('Rendered')")
  [ "$(kept_field 'shows the rendered page' disposition)" = report-only ]
  [ "$(kept_field 'shows the rendered page' reportReason)" = rendered ]
}

@test "a sibling-less demote of a route test or a real-server spec is target-not-below-subject" {
  check_all < <(
    target_cite "$ROUTE_SIBLING" 'the records route answers 200' false 'expect(200).toBe(200)'
    target_cite "$SERVED" 'serves the records list' false "$SERVED_ARCHIVE"
  )
  [ "$(reason_of 'the records route answers 200')" = target-not-below-subject ]
  [ "$(reason_of 'serves the records list')" = target-not-below-subject ]
  check_all < <(TARGET_LAYER=route target_cite "$DEMOTE" 'shows the archive heading' false "$ARCHIVE_STATUS")
  [ "$(reason_of 'shows the archive heading')" = target-not-below-subject ]
}

@test "a target on a drop and a proposal with both sibling and target are malformed" {
  check_all < <(KIND=drop target_cite "$DEMOTE" 'shows the archive heading' false "$ARCHIVE_STATUS")
  [ "$(reason_of 'shows the archive heading')" = malformed ]
  check_all < <(
    jq -s '.[0] + {target: .[1].target}' \
      <(cite demote "$DEMOTE" 'shows the archive heading' false "$SIBLING" 'shows the records page' "$LIVE_ASSERTION") \
      <(target_cite "$DEMOTE" 'shows the archive heading' false "$ARCHIVE_STATUS")
  )
  [ "$(reason_of 'shows the archive heading')" = malformed ]
}

@test "a browser seam dropped on a route sibling is still refused, and a real-server sibling clears it" {
  check_all < <(
    cite drop "$SUBJECTS" 'refuses an edit to another account' false "$ROUTE_SIBLING" 'the records route answers 200' "expect(200).toBe(200)"
    cite drop "$SUBJECTS" 'denies entry to guests' false "$SERVED" 'serves the records list' "$SERVED_ARCHIVE"
  )
  [ "$(reason_of 'refuses an edit to another account')" = seam-no-sibling-at-or-above ]
  is_kept 'denies entry to guests'
  [ "$(kept_field 'denies entry to guests' siblingLayer)" = real-server ]
}

# --- the sibling-less demote at --post-fix -----------------------------------

# prefix_kept <fullName> <assertion>: run the pre-fix check on one sibling-less
# demote of the demote fixture, leaving its output for kept_with_replacement.
prefix_kept() {
  check_all < <(target_cite "$DEMOTE" "$1" false "$2")
  is_kept "$1"
}

@test "post-fix keeps each demote whose fixer wrote a request-only replacement" {
  write_served_replacement
  prefix_kept 'shows the archive heading' "$ARCHIVE_STATUS"
  kept_with_replacement 'shows the archive heading' "$REPLACEMENT" 'serves the archive heading' "$SERVED_ARCHIVE" >"$BATS_TEST_TMPDIR/archive.json"
  prefix_kept 'refuses the forbidden admin page' "$ADMIN_STATUS"
  kept_with_replacement 'refuses the forbidden admin page' "$REPLACEMENT" 'refuses the admin page' "$SERVED_ADMIN" >"$BATS_TEST_TMPDIR/admin.json"
  rm -f "$REPO/$DEMOTE"
  jq -s 'add' "$BATS_TEST_TMPDIR/archive.json" "$BATS_TEST_TMPDIR/admin.json" >"$PROPOSALS"
  run_check --post-fix
  [ "$status" -eq 0 ]
  is_kept 'shows the archive heading'
  is_kept 'refuses the forbidden admin page'
  [ "$(kept_field 'refuses the forbidden admin page' seam)" = true ]
  [ "$(kept_field 'shows the archive heading' targetLayer)" = real-server ]
}

@test "post-fix refuses a demote with no replacement, an unwritten one, or one that opens a page" {
  prefix_kept 'refuses the forbidden admin page' "$ADMIN_STATUS"
  jq '.kept' <<<"$output" >"$BATS_TEST_TMPDIR/bare.json"
  write_served_replacement
  kept_with_replacement 'refuses the forbidden admin page' "$REPLACEMENT" 'refuses the admin page' "$SERVED_ADMIN" >"$BATS_TEST_TMPDIR/cited.json"
  rm -f "$REPO/$DEMOTE"
  cp "$BATS_TEST_TMPDIR/bare.json" "$PROPOSALS"
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(reason_of 'refuses the forbidden admin page')" = replacement-missing ]
  jq 'map(.replacement.file = "apps/web/.playwright/e2e/never-written.spec.ts")' "$BATS_TEST_TMPDIR/cited.json" >"$PROPOSALS"
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(reason_of 'refuses the forbidden admin page')" = citation-unverified ]
  sed -e 's/async ({request})/async ({page, request})/' "$REPO/$REPLACEMENT" >"$BATS_TEST_TMPDIR/paged.ts"
  cp "$BATS_TEST_TMPDIR/paged.ts" "$REPO/$REPLACEMENT"
  cp "$BATS_TEST_TMPDIR/cited.json" "$PROPOSALS"
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(reason_of 'refuses the forbidden admin page')" = replacement-wrong-layer ]
}

# bats test_tags=whole-tree
@test "red twin: a post-fix that skips the replacement check keeps the demote with no replacement" {
  prefix_kept 'refuses the forbidden admin page' "$ADMIN_STATUS"
  jq '.kept' <<<"$output" >"$PROPOSALS"
  rm -f "$REPO/$DEMOTE"
  install_mutated_module check-proposals.mjs "if (!isCitation(p.replacement)) return {reason: 'replacement-missing'};" "if (!isCitation(p.replacement)) return {reason: null, rank: REAL_SERVER};"
  run_check --post-fix
  [ "$status" -eq 0 ]
  is_kept 'refuses the forbidden admin page'
}

# write_in_place_rewrite: the fixer rewrites the demoted test in its own file as
# a request-only test under the same name.
write_in_place_rewrite() {
  cat >"$REPO/$DEMOTE" <<'EOF'
import {expect, test} from '@playwright/test';

test('shows the archive heading', async ({request}) => {
  const response = await request.get('/archive');
  expect(response.status()).toBe(200);
});
EOF
}

# write_mixed_replacement: the replacement beside a test that still opens a page.
write_mixed_replacement() {
  cat >"$REPO/$MIXED" <<'EOF'
import {expect, test} from '@playwright/test';

test('still opens the archive page', async ({page}) => {
  await page.goto('/archive');
  expect(await page.title()).toBe('Archive');
});

test('serves the archive heading', async ({request}) => {
  const response = await request.get('/archive');
  expect(response.status()).toBe(200);
});
EOF
}

@test "post-fix judges layers per test: an in-place rewrite and a replacement in a mixed file are kept" {
  prefix_kept 'shows the archive heading' "$ARCHIVE_STATUS"
  write_in_place_rewrite
  kept_with_replacement 'shows the archive heading' "$DEMOTE" 'shows the archive heading' "$SERVED_ARCHIVE" >"$PROPOSALS"
  run_check --post-fix
  [ "$status" -eq 0 ]
  is_kept 'shows the archive heading'
  write_layer_fixtures
  prefix_kept 'shows the archive heading' "$ARCHIVE_STATUS"
  write_mixed_replacement
  kept_with_replacement 'shows the archive heading' "$MIXED" 'serves the archive heading' "$SERVED_ARCHIVE" >"$PROPOSALS"
  rm -f "$REPO/$DEMOTE"
  run_check --post-fix
  [ "$status" -eq 0 ]
  is_kept 'shows the archive heading'
}

# bats test_tags=whole-tree
@test "red twin: re-reading the subject's file at post-fix refuses the in-place rewrite" {
  prefix_kept 'shows the archive heading' "$ARCHIVE_STATUS"
  write_in_place_rewrite
  kept_with_replacement 'shows the archive heading' "$DEMOTE" 'shows the archive heading' "$SERVED_ARCHIVE" >"$PROPOSALS"
  install_mutated_module check-proposals.mjs 'options.postFix && pathRankOf(p.file) === PLAYWRIGHT' 'false && pathRankOf(p.file) === PLAYWRIGHT'
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(reason_of 'shows the archive heading')" = target-not-below-subject ]
}

# bats test_tags=whole-tree
@test "red twin: judging the replacement by its whole file refuses the mixed-file replacement" {
  prefix_kept 'shows the archive heading' "$ARCHIVE_STATUS"
  write_mixed_replacement
  kept_with_replacement 'shows the archive heading' "$MIXED" 'serves the archive heading' "$SERVED_ARCHIVE" >"$PROPOSALS"
  rm -f "$REPO/$DEMOTE"
  install_mutated_module check-proposals.mjs 'const rank = testRankOf(p.replacement.file, test);' 'const rank = rankOf(p.replacement.file);'
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(reason_of 'shows the archive heading')" = replacement-wrong-layer ]
}

@test "a page a hook opens counts against a replacement in the same file" {
  prefix_kept 'shows the archive heading' "$ARCHIVE_STATUS"
  write_served_replacement
  awk 'NR == 2 { print ""; print "test.beforeEach(async ({page}) => {"; print "  await page.goto(\"/\");"; print "});" } { print }' "$REPO/$REPLACEMENT" >"$BATS_TEST_TMPDIR/hooked.ts"
  cp "$BATS_TEST_TMPDIR/hooked.ts" "$REPO/$REPLACEMENT"
  kept_with_replacement 'shows the archive heading' "$REPLACEMENT" 'serves the archive heading' "$SERVED_ARCHIVE" >"$PROPOSALS"
  rm -f "$REPO/$DEMOTE"
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(reason_of 'shows the archive heading')" = replacement-wrong-layer ]
}

# --- templated titles and helper calls ---------------------------------------

LOOPED_STATUS='expect(response.status()).toBe(200)'

@test "a sibling inside a looped test with a templated title verifies by its runtime name" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$LOOPED" '/ responds 200 and renders its own page' "$LOOPED_STATUS")
  is_kept 'repeats the records title'
  [ "$(kept_field 'repeats the records title' siblingLayer)" = real-server ]
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$LOOPED" '/about responds 404 and renders its own page' "$LOOPED_STATUS")
  [ "$(reason_of 'repeats the records title')" = citation-unverified ]
}

TABLE_OUTCOME='expect(outcome).toEqual(expectedOutcome(pageKey, userKey))'

@test "a sibling row of a printf test.each table verifies by its row name, and a name no row yields does not" {
  check_all < <(cite drop "$REFUSE_UNIT" 'refuses blank input' false "$TABLES" 'per-role page status dashboard as rita' "$TABLE_OUTCOME")
  is_kept 'refuses blank input'
  [ "$(kept_field 'refuses blank input' siblingLayer)" = route ]
  check_all < <(cite drop "$REFUSE_UNIT" 'refuses blank input' false "$TABLES" 'per-role page status dashboard for rita' "$TABLE_OUTCOME")
  [ "$(reason_of 'refuses blank input')" = citation-unverified ]
}

@test "a sibling row of an object test.for table verifies by its row name, and a name no row yields does not" {
  check_all < <(cite drop "$REFUSE_UNIT" 'refuses blank input' false "$TABLES" 'per-role page status settings answers 403' 'expect(statusOf(page)).toBe(status)')
  is_kept 'refuses blank input'
  check_all < <(cite drop "$REFUSE_UNIT" 'refuses blank input' false "$TABLES" 'per-role page status settings returns 403' 'expect(statusOf(page)).toBe(status)')
  [ "$(reason_of 'refuses blank input')" = citation-unverified ]
}

@test "a table title's row index and escaped percent sign match the name vitest prints" {
  check_all < <(cite drop "$REFUSE_UNIT" 'refuses blank input' false "$TABLES" 'per-role page status 0: rita takes 100% undefined of the quota' 'expect(quotaOf(userKey)).toBe(1)')
  is_kept 'refuses blank input'
  check_all < <(cite drop "$REFUSE_UNIT" 'refuses blank input' false "$TABLES" 'per-role page status 0: rita takes 100% of the quota' 'expect(quotaOf(userKey)).toBe(1)')
  [ "$(reason_of 'refuses blank input')" = citation-unverified ]
  check_all < <(cite drop "$REFUSE_UNIT" 'refuses blank input' false "$TABLES" 'per-role page status first: rita takes 100% undefined of the quota' 'expect(quotaOf(userKey)).toBe(1)')
  [ "$(reason_of 'refuses blank input')" = citation-unverified ]
}

@test "an escaped percent sign whose row value prints empty matches the name vitest prints" {
  check_all < <(cite drop "$REFUSE_UNIT" 'refuses blank input' false "$TABLES" 'per-role page status pays 1%  now' 'expect(feeOf(fee)).toBe(1)')
  is_kept 'refuses blank input'
}

@test "a test under a describe.each verifies by the expanded describe prefix, and a name no row yields does not" {
  check_all < <(cite drop "$REFUSE_UNIT" 'refuses blank input' false "$TABLES" 'as admin opens the records list' "expect(canOpen(role, 'records')).toBe(true)")
  is_kept 'refuses blank input'
  check_all < <(cite drop "$REFUSE_UNIT" 'refuses blank input' false "$TABLES" 'admin opens the records list' "expect(canOpen(role, 'records')).toBe(true)")
  [ "$(reason_of 'refuses blank input')" = citation-unverified ]
}

@test "a cited call to an in-file helper that asserts nothing is citation-unverified" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$HELPERS" 'calls a helper that asserts nothing' 'await assertNothing(page)')
  [ "$(reason_of 'repeats the records title')" = citation-unverified ]
}

@test "a cited call to an in-file helper that asserts is kept in a builder test" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$HELPERS" 'calls a helper that asserts' 'await assertTitle(page)')
  is_kept 'repeats the records title'
}

@test "a cited in-file helper call in a rendered test is citation-unverified even when the helper asserts" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$RENDERED_HELPERS" 'a rendered test that calls a helper' 'await assertTitle(page)')
  [ "$(reason_of 'repeats the records title')" = citation-unverified ]
}

@test "a multi-line expect continuation and an imported helper call still verify" {
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$HELPERS" 'answers a missing record over several lines' ').toBe(404)')
  is_kept 'repeats the records title'
  check_all < <(cite drop "$DROPPABLE" 'repeats the records title' false "$HELPERS" 'calls an imported helper' "await expectHeading(page, 'Records')")
  is_kept 'repeats the records title'
}

# --- fold-up and the unit reason ---------------------------------------------

SLUG_ROUTE_NAME='the slug route answers the slug'
SLUG_ROUTE_ASSERTION="expect(await slugRoute(' A b ')).toBe('a-b')"
TRIM_ROUTE_NAME='the trim route answers the trimmed text'
TRIM_ROUTE_ASSERTION="expect(await trimRoute(' a ')).toBe('a')"
STORY_NAME='Default   shows the title'
STORY_ASSERTION="await expect(canvas.getByText('Title')).toBeVisible()"

# fold_two: the fold-up of both unit subjects into the slug route test.
fold_two() {
  fold_up 'folds two unit subjects' "$SLUG_ROUTE" "$SLUG_ROUTE_NAME" "$SLUG_ROUTE_ASSERTION" \
    "$SLUG_UNIT" 'slugs a title' "$TRIM_UNIT" 'trims spaces'
}

@test "one check keeps the fold-up and the justified demotes and refuses each malformed or under-justified variant by name" {
  check_all < <(
    fold_two
    cite demote "$TROPHY_ROUTE" 'demote with both conditions' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
    UNIT_REASON=null cite demote "$TROPHY_ROUTE" 'demote onto a story' false "$STORY" "$STORY_NAME" "$STORY_ASSERTION"
    fold_up 'one subject' "$SLUG_ROUTE" "$SLUG_ROUTE_NAME" "$SLUG_ROUTE_ASSERTION" "$SLUG_UNIT" 'slugs a title'
    fold_up 'into a unit test' "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION" "$SLUG_UNIT" 'slugs a title' "$TRIM_UNIT" 'trims spaces'
    fold_up 'into a browser test' "$SIBLING" 'shows the records page' "$LIVE_ASSERTION" "$SLUG_UNIT" 'slugs a title' "$TRIM_UNIT" 'trims spaces'
    CITE_LINE="$(line_of "$SLUG_ROUTE" "$SLUG_ROUTE_ASSERTION")" fold_up 'into an absent assertion' "$SLUG_ROUTE" "$SLUG_ROUTE_NAME" "toBe('nowhere')" \
      "$SLUG_UNIT" 'slugs a title' "$TRIM_UNIT" 'trims spaces'
    UNIT_REASON=null cite demote "$TROPHY_ROUTE" 'demote with no reason' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
    UNIT_REASON='{"integrationCost":"the route layer is slow","risk":"  "}' cite demote "$TROPHY_ROUTE" 'demote with one condition' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
    UNIT_REASON=null cite drop "$TROPHY_ROUTE" 'drops a route check' false "$UNIT_SIBLING" 'formats a title' "$UNIT_ASSERTION"
    UNIT_REASON=null cite drop "$TROPHY_ROUTE" 'drops a route check' false "$STORY" "$STORY_NAME" "$STORY_ASSERTION"
    NEEDS='no existing test asserts the joined slug' fold_up 'needs a new test' - - - "$SLUG_UNIT" 'keeps digits' "$TRIM_UNIT" 'trims spaces'
    fold_up 'no target' - - - "$SLUG_UNIT" 'keeps digits' "$TRIM_UNIT" 'trims spaces'
  )
  [ "$(fold_field 'folds two unit subjects' intoLayer)" = route ]
  [ "$(fold_field 'folds two unit subjects' disposition)" = offer ]
  [ "$(jq -c '[.kept[] | select(.property == "folds two unit subjects") | .baseline[] | .file] | sort' <<<"$output")" = \
    "$(jq -nc --arg a "$SLUG_ROUTE" --arg b "$SLUG_UNIT" --arg c "$TRIM_UNIT" '[$a, $b, $c] | sort')" ]
  [ "$(jq -c --arg f "$SLUG_UNIT" '[.kept[] | .baseline[]? | select(.file == $f) | .names] | first' <<<"$output")" = '["slugs a title","keeps digits"]' ]
  [ "$(jq '[.kept[] | select(has("_subjects") or has("_needsNewTest"))] | length' <<<"$output")" -eq 0 ]
  is_kept 'demote with both conditions'
  is_kept 'demote onto a story'
  [ "$(fold_reason 'one subject')" = fold-up-one-subject ]
  [ "$(fold_reason 'into a unit test')" = fold-up-target-layer ]
  [ "$(fold_reason 'into a browser test')" = fold-up-target-layer ]
  [ "$(fold_reason 'into an absent assertion')" = citation-unverified ]
  [ "$(reason_of 'demote with no reason')" = unit-reason-missing ]
  [ "$(reason_of 'demote with one condition')" = unit-reason-one-condition ]
  [ "$(reason_of 'drops a route check')" = unit-reason-missing ]
  is_kept 'drops a route check'
  [ "$(kept_field 'drops a route check' siblingLayer)" = unit ]
  [ "$(fold_field 'needs a new test' disposition)" = report-only ]
  [ "$(fold_field 'needs a new test' reportReason)" = needs-new-test ]
  [ "$(fold_reason 'no target')" = fold-up-no-target ]
}

@test "post-fix keeps an applied fold-up only when its subjects are gone and no test name was added" {
  fold_two | jq -s . >"$BATS_TEST_TMPDIR/original.json"
  cp "$BATS_TEST_TMPDIR/original.json" "$PROPOSALS"
  run_check
  [ "$status" -eq 0 ]
  [ "$(fold_field 'folds two unit subjects' disposition)" = offer ]
  jq '.kept' <<<"$output" >"$BATS_TEST_TMPDIR/kept.json"
  cp "$BATS_TEST_TMPDIR/kept.json" "$PROPOSALS"
  write_slug_unit 'keeps digits'
  write_trim_unit
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(fold_field 'folds two unit subjects' intoLayer)" = route ]
  [ "$(jq '.discarded | length' <<<"$output")" -eq 0 ]
  cp "$BATS_TEST_TMPDIR/original.json" "$PROPOSALS"
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(fold_reason 'folds two unit subjects')" = fold-up-baseline-missing ]
  cp "$BATS_TEST_TMPDIR/kept.json" "$PROPOSALS"
  write_trim_unit 'trims spaces'
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(fold_reason 'folds two unit subjects')" = fold-up-subject-present ]
  write_trim_unit
  write_slug_route 'answers a slug the fixer added'
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(fold_reason 'folds two unit subjects')" = fold-up-new-test ]
}

@test "post-fix judges each applied subject by the seam flag recorded for it, not the proposal aggregate" {
  fold_up 'mixed seam fold-up' "$SLUG_ROUTE" "$SLUG_ROUTE_NAME" "$SLUG_ROUTE_ASSERTION" \
    "$SESSION_UNIT" "$SESSION_NAME" "$SERVED" 'serves the records list' | jq -s . >"$PROPOSALS"
  run_check
  [ "$status" -eq 0 ]
  [ "$(fold_field 'mixed seam fold-up' disposition)" = offer ]
  [ "$(jq -c '[.kept[] | select(.property == "mixed seam fold-up") | .subjectSeams[]]' <<<"$output")" = '[true,false]' ]
  jq '.kept' <<<"$output" >"$BATS_TEST_TMPDIR/kept.json"
  cp "$BATS_TEST_TMPDIR/kept.json" "$PROPOSALS"
  rm -f "$REPO/$SESSION_UNIT" "$REPO/$SERVED"
  run_check --post-fix
  [ "$status" -eq 0 ]
  [ "$(jq '.discarded | length' <<<"$output")" -eq 0 ]
  [ "$(fold_field 'mixed seam fold-up' intoLayer)" = route ]
}

@test "a drop is not sibling-removed by a report-only proposal that needs a new test" {
  check_all < <(
    NEEDS='no existing test asserts the joined slug' fold_up 'needs a new test' - - - "$SLUG_UNIT" 'keeps digits' "$TRIM_UNIT" 'trims spaces'
    cite drop "$TROPHY_ROUTE" 'drop onto a folded subject' false "$SLUG_UNIT" 'keeps digits' "expect(slugOf('a1')).toBe('a1')"
  )
  is_kept 'drop onto a folded subject'
  [ "$(fold_field 'needs a new test' disposition)" = report-only ]
}

@test "a drop citing a fold-up subject and a fold-up into a dropped test are both sibling-removed" {
  check_all < <(
    fold_two
    cite drop "$TROPHY_ROUTE" 'drop onto a folded subject' false "$SLUG_UNIT" 'slugs a title' "expect(slugOf('A b')).toBe('a-b')"
    fold_up 'into a dropped test' "$SLUG_ROUTE" "$TRIM_ROUTE_NAME" "$TRIM_ROUTE_ASSERTION" "$SLUG_UNIT" 'keeps digits' "$TRIM_UNIT" 'trims spaces'
    UNIT_REASON=null cite drop "$SLUG_ROUTE" "$TRIM_ROUTE_NAME" false "$STORY" "$STORY_NAME" "$STORY_ASSERTION"
  )
  [ "$(reason_of 'drop onto a folded subject')" = sibling-removed ]
  [ "$(fold_reason 'into a dropped test')" = sibling-removed ]
  is_kept "$TRIM_ROUTE_NAME"
  [ "$(fold_field 'folds two unit subjects' intoLayer)" = route ]
}

@test "a fold-up with a subject the branch did not write is not-authored, and an unknown authorship answer is authorship-unknown" {
  check_all < <(fold_up 'folds a legacy subject' "$SLUG_ROUTE" "$SLUG_ROUTE_NAME" "$SLUG_ROUTE_ASSERTION" "$LEGACY" 'legacy stays put' "$SLUG_UNIT" 'slugs a title')
  [ "$(fold_field 'folds a legacy subject' disposition)" = report-only ]
  [ "$(fold_field 'folds a legacy subject' reportReason)" = not-authored ]
  git -C "$REPO" branch -m main trunk
  check_all < <(fold_two)
  [ "$(fold_field 'folds two unit subjects' disposition)" = report-only ]
  [ "$(fold_field 'folds two unit subjects' reportReason)" = authorship-unknown ]
}

# --- route and changed -------------------------------------------------------

branch_with() {
  git -C "$REPO" checkout -q -B alt main
  local path
  for path in "$@"; do
    mkdir -p "$REPO/$(dirname "$path")"
    printf "import {test} from 'vitest';\n\ntest('x', () => {});\n" >"$REPO/$path"
  done
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m alt
}

@test "route runs for a changed spec alone and for a spec plus a unit test" {
  branch_with apps/web/.playwright/e2e/only.spec.ts
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = run ]
  branch_with apps/web/.playwright/e2e/only.spec.ts apps/web/app/utils/only.test.ts
  run bash "$CHECK" route --root "$REPO"
  [ "$output" = run ]
}

# branch_with_specs: a branch changing one request-only spec and one spec that
# opens a page.
branch_with_specs() {
  git -C "$REPO" checkout -q -B alt main
  printf "import {expect, test} from '@playwright/test';\n\ntest('served', async ({request}) => {\n  expect((await request.get('/')).status()).toBe(200);\n});\n" >"$REPO/apps/web/.playwright/e2e/served-only.spec.ts"
  printf "import {expect, test} from '@playwright/test';\n\ntest('paged', async ({page}) => {\n  await page.goto('/');\n  expect(await page.title()).toBe('Home');\n});\n" >"$REPO/apps/web/.playwright/e2e/paged.spec.ts"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m alt
}

@test "changed reads each spec: a request-only spec is real-server and a page-opening spec is browser" {
  branch_with_specs
  run bash "$CHECK" changed --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.file == "apps/web/.playwright/e2e/served-only.spec.ts") | .layer' <<<"$output")" = real-server ]
  [ "$(jq -r '.[] | select(.file == "apps/web/.playwright/e2e/paged.spec.ts") | .layer' <<<"$output")" = browser ]
}

@test "changed maps a spec whose page-backed fixture lives in a sibling fixtures module to browser, run from outside the root" {
  git -C "$REPO" checkout -q -B alt main
  printf "import {test as base} from '@playwright/test';\nexport const test = base.extend({\n  signedInPage: async ({page}, use) => {\n    await use(page);\n  },\n});\n" >"$REPO/apps/web/.playwright/project-fixtures.ts"
  printf "import {test} from '../project-fixtures';\n\ntest('signed in', async ({signedInPage}) => {\n  await signedInPage.goto('/');\n});\n" >"$REPO/apps/web/.playwright/e2e/signed-in.spec.ts"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m alt
  [ "$PWD" != "$REPO" ]
  run bash "$CHECK" changed --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.file == "apps/web/.playwright/e2e/signed-in.spec.ts") | .layer' <<<"$output")" = browser ]
}

@test "route runs when only a request-only spec changed and when only a route test changed" {
  branch_with apps/web/.playwright/e2e/only.spec.ts
  run bash "$CHECK" changed --root "$REPO"
  [ "$(jq -r '.[0].layer' <<<"$output")" = real-server ]
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = run ]
  branch_with apps/web/app/route-tests/only.test.ts
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = run ]
}

@test "red twin: a route that runs only for Playwright layers skips a unit-only branch" {
  local mutated="$BATS_TEST_TMPDIR/overlap-check.sh"
  mutate '.layer != null' '.layer == "real-server" or .layer == "browser"' "$HOME_ROOT/.gaia/scripts/overlap-check.sh" "$mutated"
  CHECK_SOURCE="$mutated" install_harness
  branch_with apps/web/app/utils/only.test.ts
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = skip-no-test-change ]
}

@test "route runs when only unit tests changed and skips when only non-test source changed" {
  branch_with apps/web/app/utils/only.test.ts
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = run ]
  branch_with apps/web/app/utils/only.ts
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = skip-no-test-change ]
}

@test "route prints skip-no-base when no default branch resolves" {
  git -C "$REPO" branch -m main trunk
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = skip-no-base ]
}

@test "changed lists every changed test file that sits on a layer" {
  run bash "$CHECK" changed --root "$REPO"
  [ "$status" -eq 0 ]
  jq -e --arg f "$SIBLING" 'any(.[]; .file == $f and .layer == "browser")' <<<"$output" >/dev/null
  jq -e --arg f "$ROUTE_SIBLING" 'any(.[]; .file == $f and .layer == "route")' <<<"$output" >/dev/null
  jq -e --arg f "$SERVER_SIBLING" 'any(.[]; .file == $f and .layer == "route")' <<<"$output" >/dev/null
  jq -e --arg f "$UNIT_SIBLING" 'any(.[]; .file == $f and .layer == "unit")' <<<"$output" >/dev/null
  jq -e --arg f "$PLAIN_UNIT_SIBLING" 'any(.[]; .file == $f and .layer == "unit")' <<<"$output" >/dev/null
  jq -e --arg f "$OFF_LAYER" 'any(.[]; .file == $f) | not' <<<"$output" >/dev/null
  jq -e 'any(.[]; .file == "apps/web/gaia.package.json") | not' <<<"$output" >/dev/null
}

@test "a changed test at a non-ASCII path is listed by changed and makes route run" {
  branch_with 'apps/web/.playwright/e2e/café.spec.ts' 'apps/web/app/utils/naïve.test.ts'
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = run ]
  run bash "$CHECK" changed --root "$REPO"
  [ "$status" -eq 0 ]
  jq -e 'any(.[]; .file == "apps/web/.playwright/e2e/café.spec.ts" and .layer == "real-server")' <<<"$output" >/dev/null
  jq -e 'any(.[]; .file == "apps/web/app/utils/naïve.test.ts" and .layer == "unit")' <<<"$output" >/dev/null
}

@test "changed prints an empty array and route skips when nothing changed since the base" {
  git -C "$REPO" checkout -q -B same main
  run bash "$CHECK" changed --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = skip-no-test-change ]
}

# register_members <name:path>...: replaces the registry with these members,
# each with the web-stack descriptor renamed to the member.
register_members() {
  local entry name path entries=''
  for entry in "$@"; do
    name="${entry%%:*}"
    path="${entry#*:}"
    entries="${entries:+$entries,}{\"name\":\"$name\",\"path\":\"$path\"}"
    write_package_descriptor "$REPO" "$path"
    jq --arg name "$name" '.name = $name' "$REPO/$path/gaia.package.json" >"$REPO/$path/gaia.package.json.tmp"
    mv "$REPO/$path/gaia.package.json.tmp" "$REPO/$path/gaia.package.json"
  done
  write_package_registry "$REPO" "[$entries]"
}

@test "a web member named storefront still maps spec and unit paths to their layers" {
  branch_with apps/storefront/.playwright/e2e/only.spec.ts apps/storefront/app/utils/only.test.ts
  register_members storefront:apps/storefront
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = run ]
  run bash "$CHECK" changed --root "$REPO"
  [ "$status" -eq 0 ]
  jq -e 'any(.[]; .file == "apps/storefront/.playwright/e2e/only.spec.ts" and .layer == "real-server")' <<<"$output" >/dev/null || return 1
  jq -e 'any(.[]; .file == "apps/storefront/app/utils/only.test.ts" and .layer == "unit")' <<<"$output" >/dev/null
}

@test "several web members exit 3 naming both" {
  branch_with apps/storefront/.playwright/e2e/only.spec.ts
  register_members storefront:apps/storefront admin:apps/admin
  run --separate-stderr bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *storefront* ]] || return 1
  [[ "$stderr" == *admin* ]]
}

@test "no web member leaves every path without a layer and says so on stderr" {
  branch_with apps/storefront/.playwright/e2e/only.spec.ts
  register_members storefront:apps/storefront
  jq 'del(.stack)' "$REPO/apps/storefront/gaia.package.json" >"$REPO/descriptor.tmp"
  mv "$REPO/descriptor.tmp" "$REPO/apps/storefront/gaia.package.json"
  run --separate-stderr bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = skip-no-test-change ] || return 1
  [[ "$stderr" == *stack* ]]
}

# --- exits -------------------------------------------------------------------

@test "usage mistakes exit 2 and an unreadable proposals file exits 3" {
  run --separate-stderr bash "$CHECK" check --root "$REPO"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$CHECK" bogus
  [ "$status" -eq 2 ]
  printf '{}\n' >"$PROPOSALS"
  run_check
  [ "$status" -eq 3 ]
  run --separate-stderr bash "$CHECK" check --root "$REPO" --proposals "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 3 ]
}

@test "an empty proposals array checks to empty kept and discarded lists" {
  printf '[]\n' >"$PROPOSALS"
  run_check
  [ "$status" -eq 0 ]
  [ "$output" = '{"kept":[],"discarded":[]}' ]
}

@test "the no-op detector reads an empty array as a real result" {
  printf '[]\n' >"$BATS_TEST_TMPDIR/empty.json"
  run bash "$HOME_ROOT/.gaia/scripts/audit-noop-detect.sh" --shape agent-report-file --path "$BATS_TEST_TMPDIR/empty.json"
  [ "$status" -eq 0 ]
}
