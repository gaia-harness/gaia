#!/usr/bin/env bats
#
# Doc-conformance suite for the real-server and browser surface split in the
# Playwright rule, the Test Layering page and the plan decomposition audit.
#
# Every check is a function taking the file it reads, so each red twin runs the
# same function against a mutated copy and proves it can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned phrases carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PW_RULE="$REPO_ROOT/apps/web/.claude/rules/playwright.md"
  AUDIT="$REPO_ROOT/.claude/skills/gaia/references/plan/decomposition-audit.md"
  PAGE="$REPO_ROOT/wiki/decisions/Test Layering.md"
  DOCTRINE="$REPO_ROOT/.claude/doctrine/testing.md"
  DOCTRINE_SENTENCE='A harness self-check that opens no page is a Vitest `node` test, never a Playwright spec.'
  # The plan audit's test-design lens owns the layer and test-double checks,
  # against the doctrine; the other lenses carry no copy of them.
  LAYER_CHECK="a wrong layer for what the row asserts, per the doctrine's layer rule"
  WIRING_CHECK='the Playwright fixture wiring'
  GIVEN_CHECK="the plan's own Given builders"
  DOUBLE_CHECK='- a test of a test double ('
}

# ---------- helpers ----------

# copy_with <source> <name> <sed expression>: a mutated copy that must differ.
copy_with() {
  local copy="$BATS_TEST_TMPDIR/$2"
  sed "$3" "$1" >"$copy"
  cmp -s "$1" "$copy" && { echo "mutation changed nothing" >&2; return 1; }
  printf '%s' "$copy"
}

# The sentence moved to the testing doctrine; the playwright rule points at it.
check_playwright_rule_sentence() {
  grep -qF -- '.claude/doctrine/testing.md' "$1" || { echo "playwright rule lacks the doctrine pointer" >&2; return 1; }
  grep -qF -- "$DOCTRINE_SENTENCE" "$2" || { echo "doctrine lacks the sentence" >&2; return 1; }
}

# The test-design lens: its bullet line and the check lines under it, up to
# the next heading.
td_lens_of() {
  local text
  text=$(awk '
    index($0, "- **Test design") == 1 { inside = 1 }
    inside && /^## / { exit }
    inside { print }
  ' "$1")
  [ -n "$text" ] || return 1
  printf '%s\n' "$text"
}

# The test-design lens checks layer against the doctrine's layer rule.
check_audit_bullet_sentence() {
  local lens
  lens=$(td_lens_of "$1") || { echo "no test-design lens" >&2; return 1; }
  printf '%s' "$lens" | grep -qF -- '.claude/doctrine/testing.md' || { echo "test-design lens lacks the doctrine pointer" >&2; return 1; }
  printf '%s' "$lens" | grep -qF -- "$LAYER_CHECK" || { echo "test-design lens lacks the layer check" >&2; return 1; }
}

# check_double_named <file> <name>: the lens's test-double check names <name>.
check_double_named() {
  local lens line
  lens=$(td_lens_of "$1") || { echo "no test-design lens" >&2; return 1; }
  line=$(printf '%s\n' "$lens" | grep -F -- "$DOUBLE_CHECK") || { echo "no test-double check" >&2; return 1; }
  printf '%s' "$line" | grep -qF -- "$2" || { echo "test-double check lacks: $2" >&2; return 1; }
}

check_wiring_sentence() { check_double_named "$1" "$WIRING_CHECK"; }

check_given_sentence() { check_double_named "$1" "$GIVEN_CHECK"; }

# The closed capability tokens, one per line: the name leading each bullet of the
# doctrine's browser-only capability list.
capability_tokens_of() {
  local tokens
  tokens=$(awk '
    index($0, "**Browser-only capabilities.**") == 1 { inside = 1; next }
    inside && /^- / {
      line = $0
      sub(/^- /, "", line)
      sub(/[:;].*$/, "", line)
      print line
      next
    }
    inside && NF { inside = 0 }
  ' "$DOCTRINE")
  [ "$(printf '%s\n' "$tokens" | wc -l)" -eq 5 ] || { echo "expected five capability tokens" >&2; return 1; }
  printf '%s\n' "$tokens"
}

# The docs point at the planner's ladder and copy none of the five tokens.
check_no_copied_tokens() {
  local token file tokens
  tokens=$(capability_tokens_of) || return 1
  for file in "$@"; do
    while IFS= read -r token; do
      grep -qF -- "$token" "$file" && { echo "copied token '$token' in $file" >&2; return 1; }
    done <<<"$tokens"
  done
  return 0
}

# Absent phrases that route a form, a journey or a rule to the browser.
check_no_browser_overrouting() {
  local file phrase
  for file in "$@"; do
    for phrase in 'client-submitted' 'multi-page journey' 'are route tests, not more browser files' \
      'one spec per form stays on the UI path' 'route-surface UAT'; do
      grep -qiF -- "$phrase" "$file" && { echo "has '$phrase' in $file" >&2; return 1; }
    done
  done
  return 0
}

check_realserver_routing_wording() {
  local file="$1"
  grep -qiF 'JavaScript-disabled' "$file" || { echo "no JavaScript-disabled routing: $file" >&2; return 1; }
  grep -qiF 'native form post' "$file" || { echo "no native form post routing: $file" >&2; return 1; }
  grep -qiF 'multi-page workflow over native forms' "$file" || { echo "no multi-page workflow routing: $file" >&2; return 1; }
  grep -qiE 'real-server (check|spec)s?' "$file" || { echo "no real-server routing: $file" >&2; return 1; }
}

check_rule_points_at_ladder() {
  grep -qF -- '.claude/doctrine/testing.md' "$1" || { echo "rule lacks the doctrine pointer" >&2; return 1; }
  grep -qF 'serializeForm' "$1" || { echo "rule lacks serializeForm" >&2; return 1; }
}

# The doctrine routes a flow's native checks page-less into its flow test.
check_doctrine_routing_wording() {
  grep -qiF 'native form posts' "$1" || { echo "no native form post routing: $1" >&2; return 1; }
  grep -qiF 'without JavaScript' "$1" || { echo "no without-JavaScript routing: $1" >&2; return 1; }
  grep -qiF 'page-less in its flow test' "$1" || { echo "no flow-test routing: $1" >&2; return 1; }
}

check_doctrine_case_table() {
  grep -qF 'exactly one case table' "$1" || { echo "doctrine lacks the per-rule wording" >&2; return 1; }
}

# No line routes a self-check or self-test to Playwright.
check_no_playwright_routing() {
  local file
  for file in "$@"; do
    grep -iE 'self-(check|test)[^.]*(belongs|goes|runs|lives) (in|under|to) Playwright' "$file" >/dev/null && {
      echo "routes a self-check to Playwright: $file" >&2
      return 1
    }
  done
  return 0
}

check_rule_surfaces() {
  local file="$1"
  grep -qF 'One spec file per UAT-backed flow' "$file" && return 1
  grep -qiF 'one journey per user flow' "$file" || return 1
  grep -qF 'parseHtml(' "$file" || return 1
  grep -qF '.playwright/html.ts' "$file" || return 1
  grep -qF 'request.get(' "$file" || return 1
  grep -qF 'signedInRequest.get(' "$file" || return 1
  grep -qiE 'no chromium|without chromium|needs? no chromium' "$file" && return 1
  return 0
}

check_doctrine_surfaces() {
  local file="$1"
  grep -qF '**Real-server check**' "$file" || return 1
  grep -qF '**Browser test**' "$file" || return 1
  grep -qF 'what only the framework serves' "$file" || return 1
  grep -qE '`e2e`' "$file" && return 1
  return 0
}

# ---------- routing sentence ----------

@test "the doctrine holds the self-check routing sentence the playwright rule points at, and the test-design lens checks layer against it" {
  check_playwright_rule_sentence "$PW_RULE" "$DOCTRINE"
  check_audit_bullet_sentence "$AUDIT"
}

@test "no self-check routes to Playwright in the rule or the audit" {
  check_no_playwright_routing "$PW_RULE" "$AUDIT"
}

@test "red twin: a doctrine copy without the sentence, or a rule without the pointer, fails" {
  local copy
  copy=$(copy_with "$DOCTRINE" doctrine.md 's/A harness self-check that opens no page is a Vitest `node` test, never a Playwright spec\.//')
  run check_playwright_rule_sentence "$PW_RULE" "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$PW_RULE" rule.md 's#\.claude/doctrine/testing\.md#nowhere#g')
  run check_playwright_rule_sentence "$copy" "$DOCTRINE"
  [ "$status" -ne 0 ]
}

@test "red twin: the test-design lens without its layer check, or without the doctrine pointer, fails" {
  local copy
  copy=$(copy_with "$AUDIT" layer.md "s/a wrong layer for what the row asserts, per the doctrine's layer rule/a wrong layer/")
  run check_audit_bullet_sentence "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$AUDIT" pointer.md '/^- \*\*Test design/s#\.claude/doctrine/testing\.md#nowhere#g')
  run check_audit_bullet_sentence "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: a sentence routing a self-check to Playwright fails the routing check" {
  local copy
  copy=$(copy_with "$AUDIT" rewritten.md 's/^- \*\*Contract grounding/A harness self-check runs under Playwright. &/')
  run check_no_playwright_routing "$copy"
  [ "$status" -ne 0 ]
}

# ---------- fixture-wiring sentence ----------

@test "the test-design lens flags a self-test of the fixture wiring" {
  check_wiring_sentence "$AUDIT"
}

@test "red twin: the test-double check without the fixture wiring fails" {
  local copy
  copy=$(copy_with "$AUDIT" wiring.md 's/, the Playwright fixture wiring//')
  run check_wiring_sentence "$copy"
  [ "$status" -ne 0 ]
}

# ---------- the rule and the page ----------

@test "the playwright rule says one journey per flow and shows the request and helper patterns" {
  check_rule_surfaces "$PW_RULE"
}

@test "red twin: the old per-flow sentence restored, or no parseHtml, fails" {
  local copy
  copy=$(copy_with "$PW_RULE" old.md 's/One journey per user flow: one browser journey file per flow/One spec file per UAT-backed flow: one browser journey file per flow/')
  run check_rule_surfaces "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$PW_RULE" noparse.md 's/parseHtml(/parseMarkup(/g')
  run check_rule_surfaces "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: a rule that says a real-server test needs no Chromium fails" {
  local copy
  copy=$(copy_with "$PW_RULE" chromium.md 's/Every Playwright run needs Chromium installed/A real-server run needs no Chromium/')
  run check_rule_surfaces "$copy"
  [ "$status" -ne 0 ]
}

@test "the doctrine names both surfaces, what only the framework serves and no bare e2e surface" {
  check_doctrine_surfaces "$DOCTRINE"
}

@test "red twin: the doctrine without the served clause, or with an e2e row, fails" {
  local copy
  copy=$(copy_with "$DOCTRINE" nohtml.md 's/what only the framework serves/something/')
  run check_doctrine_surfaces "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$DOCTRINE" e2e.md 's/^- \*\*Unit test\*\*/- `e2e` row/')
  run check_doctrine_surfaces "$copy"
  [ "$status" -ne 0 ]
}

# ---------- Given-builder sentence ----------

@test "the test-design lens flags a self-test of the plan's own Given builders" {
  check_given_sentence "$AUDIT"
}

@test "red twin: the test-double check without the Given builders fails" {
  local copy
  copy=$(copy_with "$AUDIT" given.md "s/, the plan's own Given builders//")
  run check_given_sentence "$copy"
  [ "$status" -ne 0 ]
}

# ---------- the docs point at the ladder ----------

@test "the rule and the doctrine point at the Test Layering ladder and the doctrine routes a flow's native checks into its flow test" {
  check_rule_points_at_ladder "$PW_RULE"
  check_doctrine_routing_wording "$DOCTRINE"
  check_doctrine_case_table "$DOCTRINE"
}

@test "red twin: a rule without the ladder pointer, serializeForm or a routing phrase fails" {
  local copy
  copy=$(copy_with "$PW_RULE" noladder.md 's#\.claude/doctrine/testing\.md#nowhere#g')
  run check_rule_points_at_ladder "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$PW_RULE" noserialize.md 's/serializeForm/serializeBody/g')
  run check_rule_points_at_ladder "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$DOCTRINE" nojs.md 's/without JavaScript/scripted/g')
  run check_doctrine_routing_wording "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$DOCTRINE" nopost.md 's/native form posts/form posts/g')
  run check_doctrine_routing_wording "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$DOCTRINE" noflow.md 's/page-less in its flow test/as a real-server check/g')
  run check_doctrine_routing_wording "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: a doctrine without the per-rule case table wording fails" {
  local copy
  copy=$(copy_with "$DOCTRINE" norule.md 's/exactly one case table/one table/')
  run check_doctrine_case_table "$copy"
  [ "$status" -ne 0 ]
}

@test "the doctrine's browser capability list yields five capability tokens" {
  run capability_tokens_of
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "the rule copies no capability token, and neither doc routes a form, journey or rule to the browser" {
  check_no_copied_tokens "$PW_RULE"
  check_no_browser_overrouting "$PW_RULE" "$PAGE" "$DOCTRINE"
}

@test "red twin: a copied token or an over-routing phrase fails" {
  local copy token
  token=$(capability_tokens_of | head -n 1)
  copy=$(copy_with "$PW_RULE" token.md "s/^# Playwright Conventions.*/&\n\nA browser spec for $token./")
  run check_no_copied_tokens "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$DOCTRINE" submitted.md 's/its native form posts/client-submitted forms/')
  run check_no_browser_overrouting "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$DOCTRINE" routetests.md 's/exactly one case table holding every case, at the layer the layer rule picks\./exactly one case table holding every case, and these are route tests, not more browser files./')
  run check_no_browser_overrouting "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$PW_RULE" ui.md "s/a form's own submission is checked/one spec per form stays on the UI path; a form submission is checked/")
  run check_no_browser_overrouting "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$DOCTRINE" surface.md 's/a case table is one test\./A route-surface UAT per rule./')
  run check_no_browser_overrouting "$copy"
  [ "$status" -ne 0 ]
}
