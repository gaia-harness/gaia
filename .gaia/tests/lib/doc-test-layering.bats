#!/usr/bin/env bats
#
# Doc-conformance suite for the Test Layering page and the documents that point
# at it.
#
# wiki/decisions/Test Layering.md owns the layering principle, its rationale,
# the stack mapping and the authorization bug classes. This suite pins:
#
#   - the page holds the principle, a route row and an isolation row naming a
#     non-React stack, the frontend-only statement, each bug class with its
#     layer, and the `pnpm dev` limit of a real-server check;
#   - tests-react.md holds route, real-server and browser rows in order, each honest
#     limit, a link to the page, no copy of the rationale and no sentence
#     sending a route's redirect to E2E;
#   - routes.md holds its new path and both anonymous-access conventions;
#   - the session README and the routing page no longer say a child inherits a
#     guard, and hold the replacement;
#   - the index lists the page, every wikilink in the changed pages resolves,
#     and no changed shipped file carries a pilot figure or a working-document id.
#
# Every check is a function taking the file it reads, so each red twin runs the
# same function against a mutated copy and proves it can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="$REPO_ROOT/wiki/decisions/Test Layering.md"
  TESTS_REACT="$REPO_ROOT/apps/web/.claude/skills/tdd-react/references/tests-react.md"
  CODING_GUIDELINES_REACT="$REPO_ROOT/apps/web/.claude/rules/coding-guidelines-react.md"
  ROUTES_RULE="$REPO_ROOT/apps/web/.claude/rules/routes.md"
  SESSION_README="$REPO_ROOT/apps/web/app/routes/_session/README.md"
  ROUTING="$REPO_ROOT/wiki/modules/Routing.md"
  INDEX="$REPO_ROOT/wiki/index.md"
  CHANGED_PAGES=(
    "$PAGE"
    "$ROUTING"
    "$REPO_ROOT/wiki/modules/Testing.md"
    "$REPO_ROOT/wiki/modules/Claude Integration.md"
    "$REPO_ROOT/wiki/decisions/Determinism Classifier.md"
    "$REPO_ROOT/wiki/decisions/TDD RED Verification.md"
    "$REPO_ROOT/wiki/decisions/Worthiness Audit.md"
    "$REPO_ROOT/wiki/decisions/Worthiness Presence Gate.md"
    "$REPO_ROOT/wiki/decisions/Worthiness And Wiki Before The Audit.md"
    "$REPO_ROOT/wiki/concepts/Task Orchestration.md"
  )
  SHIPPED_FILES=(
    "${CHANGED_PAGES[@]}"
    "$TESTS_REACT"
    "$ROUTES_RULE"
    "$SESSION_README"
    "$REPO_ROOT/apps/web/.claude/rules/coding-guidelines-react.md"
    "$REPO_ROOT/apps/web/.claude/rules/playwright.md"
    "$REPO_ROOT/.claude/skills/gaia/references/plan/decomposition-audit.md"
    "$REPO_ROOT/README.md"
  )
  RATIONALE='the route layer is the default home for behavior'
}

# ---------- helpers ----------

has() { grep -qF -- "$2" "$1"; }

# Line number of the first line of $1 starting with $2, empty when absent.
line_of() { grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1; }

check_page() {
  local file="$1" needle
  for needle in \
    "$RATIONALE" \
    'both unit-test conditions' \
    'the integration layer cannot cover its cases cheaply' \
    'the logic is important or likely to fail' \
    'a parameterized table is one test' \
    'Rails request specs' 'Django test client' 'supertest' 'httptest' \
    'one Postgres schema per worker' 'Rails `parallelize`' 'pytest-xdist' \
    'one SQLite file and server per worker' \
    'Only the frontend package' \
    'A rule function returns the wrong answer' \
    'A route module omits its guard' \
    'A guarded route module'"'"'s refusal is served with the wrong HTTP status' \
    '`pnpm dev` with MSW' \
    "the server's rendered HTML"; do
    has "$file" "$needle" || { echo "missing: $needle"; return 1; }
  done
  has "$file" 'Every check lives at the lowest layer that can prove it' && { echo "present: old axiom"; return 1; }
  grep -E '^\| A rule function.*\| Unit ' "$file" >/dev/null || return 1
  grep -E '^\| A route module omits.*\| Route ' "$file" >/dev/null || return 1
  grep -E '^\| A guarded route module.s refusal is served.*\| Real server ' "$file" >/dev/null || return 1
}

check_tests_react() {
  local file="$1" service route real_server browser needle
  service=$(line_of "$file" '| Pure / service')
  route=$(line_of "$file" '| Route ')
  real_server=$(line_of "$file" '| Real server ')
  browser=$(line_of "$file" '| Browser ')
  [ -n "$service" ] && [ -n "$route" ] && [ -n "$real_server" ] && [ -n "$browser" ] || return 1
  [ "$service" -lt "$route" ] && [ "$route" -lt "$real_server" ] && [ "$real_server" -lt "$browser" ] || return 1
  has "$file" '| E2E ' && return 1
  for needle in \
    'skips middleware, so a middleware guard is proven by a real-server check' \
    'A parent loader guards no action' \
    'a direct anonymous call to it is the proof' \
    'proven by a real-server `.data` request naming only the child route' \
    'cannot be proven by a route test' \
    'wiki/decisions/Test Layering.md' \
    'serializeForm'; do
    has "$file" "$needle" || { echo "missing: $needle"; return 1; }
  done
  has "$file" 'client-submitted' && return 1
  local token tokens
  tokens=$(capability_names_of "$PAGE")
  [ "$(printf '%s\n' "$tokens" | wc -l)" -eq 5 ] || { echo "expected five capability tokens"; return 1; }
  while IFS= read -r token; do
    has "$file" "$token" && { echo "copied token: $token"; return 1; }
  done <<<"$tokens"
  has "$file" "$RATIONALE" && return 1
  has "$file" "a route's redirect is E2E" && return 1
  return 0
}

check_routes_rule() {
  local file="$1" needle
  for needle in \
    "app/route-tests/**/*" \
    'an anonymous request is refused with no side effect' \
    'an anonymous request receives none of it'; do
    has "$file" "$needle" || { echo "missing: $needle"; return 1; }
  done
}

check_no_inherited_guard() {
  local file="$1"
  grep -iE 'inherit.*guard|guard.*inherit' "$file" >/dev/null && return 1
  has "$file" "guards neither a child's action nor a child's loader" || return 1
  return 0
}

check_index() { has "$1" '[[Test Layering]]'; }

# Every [[wikilink]] in the files resolves to a wiki page by title.
check_wikilinks() {
  local file target
  for file in "$@"; do
    while IFS= read -r target; do
      target="${target%%|*}"
      target="${target%%#*}"
      [ -n "$target" ] || continue
      # gaia-lint-ignore whole-tree-mark-guard: every test that reaches this find carries the per-test mark
      find "$REPO_ROOT/wiki" -name "$target.md" | grep -q . || {
        echo "broken: $target in $file"
        return 1
      }
    done < <(grep -o '\[\[[^]]*\]\]' "$file" | sed 's/^\[\[//; s/\]\]$//')
  done
}

check_no_pilot_figures() {
  grep -E '469|12 minutes' "$@" >/dev/null && return 1
  return 0
}

check_no_working_doc_ids() {
  grep -E 'UAT-[0-9]+|SPEC-[0-9]+' "$@" >/dev/null && return 1
  return 0
}

LAYERING_HEADING='## When a test needs a real browser'

# The five browser capabilities, as the page's list names them.
CAPABILITY_NAMES=(
  'client JavaScript'
  'layout or visual position'
  'focus or keyboard'
  'rendered-DOM accessibility scan'
  'browser-only navigation'
)

# Prints the leading backticked or bold name of each bullet between the list
# heading and the next `## ` heading, one per line.
capability_names_of() {
  awk -v heading="$LAYERING_HEADING" '
    $0 == heading { inside = 1; next }
    inside && /^## / { inside = 0 }
    inside && /^- / {
      line = $0
      sub(/^- (`|\*\*)/, "", line)
      sub(/(`|\*\*).*$/, "", line)
      print line
    }
  ' "$1"
}

# The page's list names exactly the five capabilities, each one under the heading.
check_capability_list() {
  local file="$1" names count name
  has "$file" "$LAYERING_HEADING" || { echo "missing heading"; return 1; }
  names=$(capability_names_of "$file")
  count=$(printf '%s\n' "$names" | grep -c .)
  [ "$count" -eq 5 ] || { echo "expected five capability names, read $count"; return 1; }
  for name in "${CAPABILITY_NAMES[@]}"; do
    printf '%s\n' "$names" | grep -qxF -- "$name" || { echo "missing capability: $name"; return 1; }
  done
}

check_flow_spec_admission() {
  local file="$1" needle
  for needle in \
    '.playwright/flows/' \
    'one Playwright spec per critical web flow' \
    'whatever a cheaper layer could prove'; do
    has "$file" "$needle" || { echo "missing: $needle"; return 1; }
  done
}

check_points_at_layering() {
  local file="$1"
  has "$file" 'wiki/decisions/Test Layering.md' || { echo "missing Test Layering pointer"; return 1; }
  has "$file" 'planner.md' && { echo "present: planner.md pointer"; return 1; }
  return 0
}

check_layering_absences() {
  local file="$1"
  has "$file" 'planner.md' && { echo "present: planner.md pointer"; return 1; }
  has "$file" "planner's ladder" && { echo "present: planner's ladder"; return 1; }
  grep -qE '\bUATs?\b' "$file" && { echo "present: UAT term"; return 1; }
  return 0
}

mutate_copy() {
  local source="$1" expression="$2" copy="$BATS_TEST_TMPDIR/mutated.md"
  sed "$expression" "$source" >"$copy"
  printf '%s' "$copy"
}

# ---------- the page ----------

@test "the page holds the principle, both mappings, the bug classes and the pnpm dev limit" {
  run check_page "$PAGE"
  [ "$status" -eq 0 ]
}

@test "red twin: the page without a stack row, a bug class or the limit fails" {
  local copy
  copy=$(mutate_copy "$PAGE" 's/supertest/express test/')
  run check_page "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's/Only the frontend package/Every package/')
  run check_page "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's/| Real server |/| Unit |/')
  run check_page "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's/`pnpm dev` with MSW/a server/')
  run check_page "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" "s/the server's rendered HTML/something/")
  run check_page "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: the page without the trophy axiom or a unit-test needle, or with the old axiom restored, fails" {
  local copy
  copy=$(mutate_copy "$PAGE" 's/the route layer is the default home for behavior/the route layer is one home/')
  run check_page "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's/both unit-test conditions/the unit-test conditions/g')
  run check_page "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's/the integration layer cannot cover its cases cheaply/the integration layer is slow/')
  run check_page "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's/the logic is important or likely to fail/the logic is complex/')
  run check_page "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's/a parameterized table is one test/a table is a test/')
  run check_page "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's/^Write tests, not too many/Every check lives at the lowest layer that can prove it. Write tests, not too many/')
  run check_page "$copy"
  [ "$status" -ne 0 ]
}

# ---------- tests-react.md ----------

@test "tests-react holds the route row, the limits and the link, with no rationale copy" {
  run check_tests_react "$TESTS_REACT"
  [ "$status" -eq 0 ]
}

@test "red twin: tests-react without serializeForm, or with a client-submitted row or a copied token, fails" {
  local copy token
  copy=$(mutate_copy "$TESTS_REACT" 's/serializeForm/serializeBody/')
  run check_tests_react "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$TESTS_REACT" 's/one journey per user flow/client-submitted forms, one journey per user flow/')
  run check_tests_react "$copy"
  [ "$status" -ne 0 ]
  token=$(capability_names_of "$PAGE" | head -n 1)
  [ -n "$token" ]
  copy=$(mutate_copy "$TESTS_REACT" "s/one journey per user flow/$token, one journey per user flow/")
  run check_tests_react "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: tests-react with a missing limit, a rationale copy or the old redirect line fails" {
  local copy
  copy=$(mutate_copy "$TESTS_REACT" 's/| Route  /| Rout3  /')
  run check_tests_react "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$TESTS_REACT" 's/A parent loader guards no action/A parent loader guards/')
  run check_tests_react "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$TESTS_REACT" 's/Write tests at the/Write tests at the route layer is the default home for behavior, the/')
  run check_tests_react "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$TESTS_REACT" "s/a route's redirect is a route test/a route's redirect is E2E/")
  run check_tests_react "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$TESTS_REACT" 's#wiki/decisions/Test Layering.md#nowhere#g')
  run check_tests_react "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: a route row placed after the Playwright rows fails" {
  local copy="$BATS_TEST_TMPDIR/reordered.md"
  awk '/^\| Route /{held=$0; next} {print} /^\| Browser /{print held}' "$TESTS_REACT" >"$copy"
  run check_tests_react "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: a single E2E row in place of the real-server and browser rows fails" {
  local copy="$BATS_TEST_TMPDIR/single-row.md"
  awk '/^\| Real server /{print "| E2E               | Playwright | Playwright | x | y |"; next} /^\| Browser /{next} {print}' "$TESTS_REACT" >"$copy"
  run check_tests_react "$copy"
  [ "$status" -ne 0 ]
}

# ---------- routes.md ----------

@test "routes rule holds its new path and both anonymous conventions" {
  run check_routes_rule "$ROUTES_RULE"
  [ "$status" -eq 0 ]
}

@test "red twin: routes rule without the path or a convention fails" {
  local copy
  copy=$(mutate_copy "$ROUTES_RULE" "s#app/route-tests/\*\*/\*#app/other#")
  run check_routes_rule "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$ROUTES_RULE" 's/receives none of it/is fine/')
  run check_routes_rule "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$ROUTES_RULE" 's/is refused with no side effect/is refused/')
  run check_routes_rule "$copy"
  [ "$status" -ne 0 ]
}

# ---------- inherited-guard text ----------

@test "the session README and the routing page do not say a child inherits a guard" {
  run check_no_inherited_guard "$SESSION_README"
  [ "$status" -eq 0 ]
  run check_no_inherited_guard "$ROUTING"
  [ "$status" -eq 0 ]
}

@test "red twin: a restored inheritance sentence or a lost replacement fails" {
  local copy
  copy=$(mutate_copy "$ROUTING" 's/a parent loader guards neither/every child inherits the guard, a parent loader guards neither/')
  run check_no_inherited_guard "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$SESSION_README" "s/guards neither a child's action/guards a child's action/")
  run check_no_inherited_guard "$copy"
  [ "$status" -ne 0 ]
}

# ---------- index, links, style ----------

@test "the index lists the page" {
  run check_index "$INDEX"
  [ "$status" -eq 0 ]
}

@test "red twin: an index without the page fails" {
  local copy
  copy=$(mutate_copy "$INDEX" 's/\[\[Test Layering\]\]/[[Other]]/')
  run check_index "$copy"
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "every wikilink in the changed pages resolves to a wiki page" {
  [ "${#CHANGED_PAGES[@]}" -gt 0 ]
  run check_wikilinks "${CHANGED_PAGES[@]}"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "red twin: a broken wikilink fails the resolver" {
  local copy="$BATS_TEST_TMPDIR/broken.md"
  printf 'See [[No Such Page Anywhere]].\n' >"$copy"
  run check_wikilinks "$copy"
  [ "$status" -ne 0 ]
}

@test "the changed shipped files carry no pilot figure and no working-document id" {
  [ "${#SHIPPED_FILES[@]}" -gt 0 ]
  run check_no_pilot_figures "${SHIPPED_FILES[@]}"
  [ "$status" -eq 0 ]
  run check_no_working_doc_ids "${SHIPPED_FILES[@]}"
  [ "$status" -eq 0 ]
}

@test "red twin: a pilot figure or a working-document id fails" {
  local copy="$BATS_TEST_TMPDIR/figure.md"
  printf 'it took 469 seconds\n' >"$copy"
  run check_no_pilot_figures "$copy"
  [ "$status" -ne 0 ]
  printf 'see UAT-007\n' >"$copy"
  run check_no_working_doc_ids "$copy"
  [ "$status" -ne 0 ]
}

# ---------- the browser capability list ----------

@test "the page lists each browser capability under the real-browser heading" {
  run check_capability_list "$PAGE"
  [ "$status" -eq 0 ]
}

@test "red twin: a page missing a capability, the heading or a bullet fails" {
  local copy name
  for name in "${CAPABILITY_NAMES[@]}"; do
    copy="$BATS_TEST_TMPDIR/dropped.md"
    grep -vF -- "$name" "$PAGE" >"$copy"
    run check_capability_list "$copy"
    [ "$status" -ne 0 ]
  done
  copy=$(mutate_copy "$PAGE" 's/^## When a test needs a real browser$/## Browsers/')
  run check_capability_list "$copy"
  [ "$status" -ne 0 ]
}

@test "the page admits one browser spec per critical web flow whatever a cheaper layer could prove" {
  run check_flow_spec_admission "$PAGE"
  [ "$status" -eq 0 ]
}

@test "red twin: a page without the flows folder, the admission or the override fails" {
  local copy
  copy=$(mutate_copy "$PAGE" 's#\.playwright/flows/#.playwright/other/#g')
  run check_flow_spec_admission "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's/one Playwright spec per critical web flow/one spec/g')
  run check_flow_spec_admission "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's/whatever a cheaper layer could prove/when nothing cheaper proves it/g')
  run check_flow_spec_admission "$copy"
  [ "$status" -ne 0 ]
}

@test "the React rule and the tests reference point at the page, not at the planner, for the ladder" {
  local file
  for file in "$CODING_GUIDELINES_REACT" "$TESTS_REACT"; do
    run check_points_at_layering "$file"
    [ "$status" -eq 0 ]
  done
}

@test "red twin: a React rule or reference that points at the planner or loses the page pointer fails" {
  local copy
  copy=$(mutate_copy "$CODING_GUIDELINES_REACT" 's#wiki/decisions/Test Layering\.md#nowhere#g')
  run check_points_at_layering "$copy"
  [ "$status" -ne 0 ]
  printf 'wiki/decisions/Test Layering.md and .claude/skills/gaia/references/plan/planner.md\n' >"$BATS_TEST_TMPDIR/pointer.md"
  run check_points_at_layering "$BATS_TEST_TMPDIR/pointer.md"
  [ "$status" -ne 0 ]
}

@test "the page carries no planner pointer, no planner ladder and no UAT term" {
  run check_layering_absences "$PAGE"
  [ "$status" -eq 0 ]
}

@test "red twin: a restored planner pointer, planner ladder or UAT word fails" {
  local copy
  copy=$(mutate_copy "$PAGE" 's#^Only the frontend package#See planner.md. Only the frontend package#')
  run check_layering_absences "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" "s#^Only the frontend package#Routed by the planner's ladder. Only the frontend package#")
  run check_layering_absences "$copy"
  [ "$status" -ne 0 ]
  copy=$(mutate_copy "$PAGE" 's#^Only the frontend package#Sibling UATs fold. Only the frontend package#')
  run check_layering_absences "$copy"
  [ "$status" -ne 0 ]
}
