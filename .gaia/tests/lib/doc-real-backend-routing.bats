#!/usr/bin/env bats
# Doc pins for routing a real-backend then-clause out of GAIA's layers: the
# planner's paragraph after the routing ladder, the SPEC template's
# out-of-scope bullet, the SPEC audit's testability finding, and the Test
# Layering page's statement of what mocks cannot prove.
#
# Each check is a function over a file path, run once on the real file and
# once on a mutated scratch copy that must fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_FILE="$ROOT/.claude/skills/gaia/references/plan/planner.md"
  TEMPLATE_FILE="$ROOT/.claude/skills/gaia/references/spec/spec-template.md"
  SPEC_AUDIT_FILE="$ROOT/.claude/skills/gaia/references/spec/audit.md"
  LAYERING_FILE="$ROOT/wiki/decisions/Test Layering.md"
}

# has_collapsed <file> <phrase>: the file, whitespace-collapsed, holds phrase.
has_collapsed() {
  [ -f "$1" ] || { echo "target $1 does not exist" >&2; return 1; }
  tr '\n' ' ' <"$1" | sed -E 's/[[:space:]]+/ /g' | grep -Fq -- "$2" \
    || { echo "missing in $(basename "$1"): $2" >&2; return 1; }
}

check_planner() {
  has_collapsed "$1" 'A then-clause only a real backend can show (data surviving a restart, a database reset, a production start against a real store) has no surface.' || return 1
  has_collapsed "$1" 'as adopter-owned end-to-end; no task builds harness for it.' || return 1
  has_collapsed "$1" "A Given that needs data seeds it through a Given builder on the worker's MSW store" || return 1
  # The paragraph sits after the ladder's last step, before the authorization rule.
  local ladder paragraph authorization
  ladder=$(grep -nF '5. `non-ui` for harness' "$1" | head -n 1 | cut -d: -f1)
  paragraph=$(grep -nF 'A then-clause only a real backend can show' "$1" | head -n 1 | cut -d: -f1)
  authorization=$(grep -nF 'A plan routing an authorization UAT' "$1" | head -n 1 | cut -d: -f1)
  [ -n "$ladder" ] && [ -n "$paragraph" ] && [ -n "$authorization" ] || return 1
  [ "$ladder" -lt "$paragraph" ] && [ "$paragraph" -lt "$authorization" ]
}

check_template() {
  has_collapsed "$1" '- <Adopter-owned end-to-end: behavior only a real backend can show' || return 1
  has_collapsed "$1" 'Name it here, never as a UAT' || return 1
  local section bullet
  section=$(grep -nF '## Out of scope (for this SPEC)' "$1" | head -n 1 | cut -d: -f1)
  bullet=$(grep -nF -- '- <Adopter-owned end-to-end' "$1" | head -n 1 | cut -d: -f1)
  [ -n "$section" ] && [ -n "$bullet" ] && [ "$section" -lt "$bullet" ]
}

check_spec_audit() {
  grep -E '^- \*\*UAT testability' "$1" \
    | grep -Fq 'A UAT whose then-clause needs a real backend (persistence across a restart, a database reset, a production start against a real store) is a finding: move it to Out of scope as adopter-owned end-to-end.' \
    || { echo "testability lens lacks the real-backend finding" >&2; return 1; }
}

check_layering() {
  grep -Fxq '## What mocks cannot prove' "$1" || { echo "no section" >&2; return 1; }
  has_collapsed "$1" 'They cannot prove the hookup (auth cookies, CORS, environment config, proxies)' || return 1
  has_collapsed "$1" "drift between the handlers and the backend's contract is the project's to guard" || return 1
  has_collapsed "$1" "Behavior only a real backend shows is that suite's, never a GAIA layer's." || return 1
}

# scratch_copy <file> <sed expression>: a mutated copy, whose path is printed.
scratch_copy() {
  local copy
  copy="$BATS_TEST_TMPDIR/$(basename "$1")"
  sed -E "$2" "$1" >"$copy"
  cmp -s "$1" "$copy" && { echo "mutation changed nothing in $1" >&2; return 1; }
  printf '%s\n' "$copy"
}

@test "planner.md routes a real-backend then-clause out after the ladder" {
  check_planner "$PLANNER_FILE"
}

@test "red twin: the planner check fails without the paragraph or with it before the ladder" {
  copy="$(scratch_copy "$PLANNER_FILE" 's/ no task builds harness for it\./ a task builds it./')"
  run check_planner "$copy"
  [ "$status" -ne 0 ]
  copy="$(scratch_copy "$PLANNER_FILE" 's/on the worker.s MSW store/in a database/')"
  run check_planner "$copy"
  [ "$status" -ne 0 ]
  copy="$(scratch_copy "$PLANNER_FILE" '/^    5\. `non-ui` for harness/d')"
  run check_planner "$copy"
  [ "$status" -ne 0 ]
}

@test "the SPEC template names adopter-owned end-to-end under Out of scope" {
  check_template "$TEMPLATE_FILE"
}

@test "red twin: the template check fails without the bullet" {
  copy="$(scratch_copy "$TEMPLATE_FILE" 's/Adopter-owned end-to-end/Real backend/')"
  run check_template "$copy"
  [ "$status" -ne 0 ]
}

@test "the SPEC audit's testability lens flags a real-backend UAT" {
  check_spec_audit "$SPEC_AUDIT_FILE"
}

@test "red twin: the SPEC audit check fails without the finding" {
  copy="$(scratch_copy "$SPEC_AUDIT_FILE" 's/ is a finding: move it to Out of scope/ is fine/')"
  run check_spec_audit "$copy"
  [ "$status" -ne 0 ]
}

@test "Test Layering says what mocks cannot prove" {
  check_layering "$LAYERING_FILE"
}

@test "red twin: the layering check fails without the section or a limit" {
  copy="$(scratch_copy "$LAYERING_FILE" 's/^## What mocks cannot prove$/## Mocks/')"
  run check_layering "$copy"
  [ "$status" -ne 0 ]
  copy="$(scratch_copy "$LAYERING_FILE" 's/ \(auth cookies, CORS, environment config, proxies\)//')"
  run check_layering "$copy"
  [ "$status" -ne 0 ]
}
