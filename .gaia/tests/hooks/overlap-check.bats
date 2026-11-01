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
SIBLING='frontend/.playwright/e2e/sibling.spec.ts'
SUBJECTS='frontend/.playwright/e2e/subjects.spec.ts'
DROPPABLE='frontend/.playwright/e2e/droppable.spec.ts'
RENDERED='frontend/.playwright/e2e/rendered.spec.ts'
LEGACY='frontend/.playwright/e2e/legacy.spec.ts'
LEGACY_EDITED='frontend/.playwright/e2e/legacy-edited.spec.ts'
ROUTE_SIBLING='frontend/app/route-tests/records.test.ts'
UNIT_SIBLING='frontend/app/utils/format.test.ts'
SERVER_SIBLING='frontend/test/x.server.test.ts'
PLAIN_UNIT_SIBLING='frontend/test/x.test.ts'
OFF_LAYER='frontend/lib/other.test.ts'
REFUSE_UNIT='frontend/app/utils/refuse.test.ts'
SESSION_UNIT='frontend/app/sessions.server/plain.test.ts'

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
  mkdir -p "$REPO/frontend/.playwright/e2e"
  printf '# readme\n' >"$REPO/README.md"
  legacy_source 'legacy stays put' >"$REPO/$LEGACY"
  legacy_source 'blocks legacy access' >"$REPO/$LEGACY_EDITED"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  git -C "$REPO" checkout -q -b feature

  cp -R "$FIXTURES/." "$REPO/"
  legacy_source 'stops legacy access' >"$REPO/$LEGACY_EDITED"
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
  for library in branch-authorship-lib.sh main-root-lib.sh red-ledger overlap; do
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

line_of() { grep -n -F -m1 -- "$2" "$REPO/$1" | cut -d: -f1; }

# cite <kind> <file> <fullName> <seam> <sibling-file> <sibling-fullName> <assertion> [bug]
# The cited line is CITE_LINE when set, else where the assertion sits.
cite() {
  local line="${CITE_LINE:-$(line_of "$5" "$7")}"
  jq -n --arg kind "$1" --arg file "$2" --arg name "$3" --argjson seam "$4" \
    --arg sf "$5" --argjson sl "${line:-0}" --arg sn "$6" --arg sa "$7" --arg bug "${8:-}" '{
      proposal: $kind, file: $file, fullName: $name, seam: $seam,
      property: "the property", actor: "the actor", action: "the action",
      sibling: {file: $sf, line: $sl, fullName: $sn, assertion: $sa}
    } + (if $bug == "" then {} else {bug: $bug} end)'
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
  [ "$(kept_field 'refuses an edit to another account' layer)" = e2e ]
  [ "$(kept_field 'refuses an edit to another account' siblingLayer)" = e2e ]
  [ "$(jq '[.kept[] | select(.fullName == "refuses blank input")] | length' <<<"$output")" -eq 2 ]
  [ "$(jq -r '[.kept[] | select(.fullName == "refuses blank input") | .siblingLayer] | join(",")' <<<"$output")" = route,e2e ]
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
  branch_with frontend/.playwright/e2e/only.spec.ts
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = run ]
  branch_with frontend/.playwright/e2e/only.spec.ts frontend/app/utils/only.test.ts
  run bash "$CHECK" route --root "$REPO"
  [ "$output" = run ]
}

@test "route skips when only unit tests changed" {
  branch_with frontend/app/utils/only.test.ts
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = skip-no-playwright-change ]
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
  jq -e --arg f "$SIBLING" 'any(.[]; .file == $f and .layer == "e2e")' <<<"$output" >/dev/null
  jq -e --arg f "$ROUTE_SIBLING" 'any(.[]; .file == $f and .layer == "route")' <<<"$output" >/dev/null
  jq -e --arg f "$SERVER_SIBLING" 'any(.[]; .file == $f and .layer == "route")' <<<"$output" >/dev/null
  jq -e --arg f "$UNIT_SIBLING" 'any(.[]; .file == $f and .layer == "unit")' <<<"$output" >/dev/null
  jq -e --arg f "$PLAIN_UNIT_SIBLING" 'any(.[]; .file == $f and .layer == "unit")' <<<"$output" >/dev/null
  jq -e --arg f "$OFF_LAYER" 'any(.[]; .file == $f) | not' <<<"$output" >/dev/null
  jq -e 'any(.[]; .file == "frontend/gaia.package.json") | not' <<<"$output" >/dev/null
}

@test "a changed test at a non-ASCII path is listed by changed and makes route run" {
  branch_with 'frontend/.playwright/e2e/café.spec.ts' 'frontend/app/utils/naïve.test.ts'
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = run ]
  run bash "$CHECK" changed --root "$REPO"
  [ "$status" -eq 0 ]
  jq -e 'any(.[]; .file == "frontend/.playwright/e2e/café.spec.ts" and .layer == "e2e")' <<<"$output" >/dev/null
  jq -e 'any(.[]; .file == "frontend/app/utils/naïve.test.ts" and .layer == "unit")' <<<"$output" >/dev/null
}

@test "changed prints an empty array and route skips when nothing changed since the base" {
  git -C "$REPO" checkout -q -B same main
  run bash "$CHECK" changed --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = skip-no-playwright-change ]
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
  jq -e 'any(.[]; .file == "apps/storefront/.playwright/e2e/only.spec.ts" and .layer == "e2e")' <<<"$output" >/dev/null || return 1
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
  [ "$output" = skip-no-playwright-change ] || return 1
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
