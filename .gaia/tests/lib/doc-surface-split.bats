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
  ROUTING_SENTENCE='A database-only or harness self-check that opens no page runs in the Vitest node project, not under Playwright.'
  WIRING_SENTENCE='A self-test of the Playwright fixture wiring itself is dropped: the specs that use the fixture prove it.'
}

# ---------- helpers ----------

# bullet_of <file> <lead>: the one line starting with "- **<lead>".
bullet_of() {
  local text
  text=$(grep -F -- "- **$2" "$1") || return 1
  [ "$(printf '%s\n' "$text" | wc -l)" -eq 1 ] || return 1
  printf '%s\n' "$text"
}

# copy_with <source> <name> <sed expression>: a mutated copy that must differ.
copy_with() {
  local copy="$BATS_TEST_TMPDIR/$2"
  sed "$3" "$1" >"$copy"
  cmp -s "$1" "$copy" && { echo "mutation changed nothing" >&2; return 1; }
  printf '%s' "$copy"
}

check_playwright_rule_sentence() {
  grep -qF -- "$ROUTING_SENTENCE" "$1" || { echo "playwright rule lacks the sentence" >&2; return 1; }
}

check_audit_bullet_sentence() {
  local lead bullet
  for lead in 'Decomposition & dependency soundness' 'SPEC coverage'; do
    bullet=$(bullet_of "$1" "$lead") || { echo "no bullet: $lead" >&2; return 1; }
    printf '%s' "$bullet" | grep -qF -- "$ROUTING_SENTENCE" || { echo "no sentence in: $lead" >&2; return 1; }
  done
}

check_wiring_sentence() {
  local lead bullet
  for lead in 'Decomposition & dependency soundness' 'SPEC coverage'; do
    bullet=$(bullet_of "$1" "$lead") || { echo "no bullet: $lead" >&2; return 1; }
    printf '%s' "$bullet" | grep -qF -- "$WIRING_SENTENCE" || { echo "no wiring sentence in: $lead" >&2; return 1; }
  done
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

check_page_surfaces() {
  local file="$1"
  grep -qF '**Real server.**' "$file" || return 1
  grep -qF '**Browser.**' "$file" || return 1
  grep -qF "the server's rendered HTML" "$file" || return 1
  grep -qE '`e2e`' "$file" && return 1
  return 0
}

# ---------- routing sentence ----------

@test "playwright rule and both audit bullets carry the self-check routing sentence" {
  check_playwright_rule_sentence "$PW_RULE"
  check_audit_bullet_sentence "$AUDIT"
}

@test "no self-check routes to Playwright in the rule or the audit" {
  check_no_playwright_routing "$PW_RULE" "$AUDIT"
}

@test "red twin: a rule copy without the sentence fails" {
  local copy
  copy=$(copy_with "$PW_RULE" rule.md 's/A database-only or harness self-check that opens no page runs in the Vitest node project, not under Playwright\.//')
  run check_playwright_rule_sentence "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: the sentence removed from the DP bullet only, or the COV bullet only, fails" {
  local copy
  copy=$(copy_with "$AUDIT" dp.md '/^- \*\*Decomposition & dependency soundness/s/A database-only or harness self-check that opens no page runs in the Vitest node project, not under Playwright\.//')
  run check_audit_bullet_sentence "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$AUDIT" cov.md '/^- \*\*SPEC coverage/s/A database-only or harness self-check that opens no page runs in the Vitest node project, not under Playwright\.//')
  run check_audit_bullet_sentence "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: a sentence rewritten to run under Playwright fails the routing check" {
  local copy
  copy=$(copy_with "$AUDIT" rewritten.md 's/runs in the Vitest node project, not under Playwright\./runs under Playwright./')
  run check_no_playwright_routing "$copy"
  [ "$status" -ne 0 ]
}

# ---------- fixture-wiring sentence ----------

@test "both audit bullets drop a self-test of the fixture wiring" {
  check_wiring_sentence "$AUDIT"
}

@test "red twin: the wiring sentence missing from one bullet fails" {
  local copy
  copy=$(copy_with "$AUDIT" wiring.md '/^- \*\*SPEC coverage/s/A self-test of the Playwright fixture wiring itself is dropped: the specs that use the fixture prove it\.//')
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

@test "Test Layering names both surfaces, the rendered HTML and no bare e2e surface" {
  check_page_surfaces "$PAGE"
}

@test "red twin: the page without the rendered-HTML clause, or with an e2e row, fails" {
  local copy
  copy=$(copy_with "$PAGE" nohtml.md "s/the server's rendered HTML/something/")
  run check_page_surfaces "$copy"
  [ "$status" -ne 0 ]
  copy=$(copy_with "$PAGE" e2e.md 's/^1\. \*\*Unit and story\.\*\*/1. **Unit and story.** an `e2e` row/')
  run check_page_surfaces "$copy"
  [ "$status" -ne 0 ]
}
