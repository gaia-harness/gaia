#!/usr/bin/env bats
#
# The test stage's coverage check (test-stage-check.mjs): every security,
# refusal and data-loss behavior and every SPEC flow needs a listed test, no
# behavior has two tests at one layer, and each Test line carries its
# behavior's security kind. Each refusal case has an accepting twin that
# differs only in the refused property. Fixtures live under $BATS_TEST_TMPDIR.
#
# Assertion style follows .claude/rules/bats-assertions.md.


setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI="$REPO_ROOT/.gaia/scripts/spec/test-stage-check.mjs"
  PLAN="$BATS_TEST_TMPDIR/plan"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  mkdir -p "$PLAN"
}

has_output() { grep -qF -- "$1" <<<"$output"; }

# A SPEC with one behavior of each kind and one flow.
write_spec() {
  cat >"$SPEC" <<'SPEC'
---
spec_id: X
flows:
  - flow_id: FLOW-001
    slug: main
    name: The main journey.
---

# Title

## Behaviors

- **B1** (access): A visitor cannot open the admin page.
  - Case: visitor, signed out, GET /admin -> redirect to /login.
- **B2** (forgery): A tampered cookie is rejected.
  - Case: edited cookie, GET / -> status 401.
- **B3** (secret): The token never reaches the page.
  - Case: signed in, GET / -> body lacks the token literal.
- **B4** (refusal): A closed account cannot sign in.
  - Case: closed account, POST /login -> status 403.
- **B5** (data-loss): A failed save leaves the draft.
  - Case: save fails midway -> draft text kept.
- **B6** (other): The footer shows the year.
  - Case: any visitor, GET / -> footer reads 2026.

## Next
SPEC
}

# One task doc: $1 is its stem, the remaining arguments are its Tests lines.
write_task() {
  local stem="$1"
  shift
  {
    printf '# %s\n\n## Acceptance criteria\n\n- First criterion.\n- Second criterion.\n\n## Tests\n\n' "$stem"
    printf '%s\n' "$@"
  } >"$PLAN/$stem.md"
}

# Every required line for the spec above, with one line overridable by name.
full_lines() {
  printf '%s\n' \
    '- Test (B1, route, access): a.test.ts › b1' \
    '- Test (B2, route, forgery): a.test.ts › b2' \
    '- Test (B3, route, secret): a.test.ts › b3' \
    '- Test (B4, route, none): a.test.ts › b4' \
    '- Test (B5, unit, none): a.test.ts › b5' \
    '- Flow test (FLOW-001): flow.test.ts'
}

write_full() {
  mapfile -t lines < <(full_lines)
  write_task task-one "${lines[@]}"
}

check() {
  run node "$CLI" --plan-dir "$PLAN" "$@"
}

@test "every security, refusal and data-loss behavior and every flow needs a listed test" {
  write_spec
  write_full
  check --spec "$SPEC"
  [ "$status" -eq 0 ]

  local id
  for id in B1 B2 B3 B4 B5; do
    grep -vF -- "($id," "$PLAN/task-one.md" >"$BATS_TEST_TMPDIR/trimmed.md"
    cp "$BATS_TEST_TMPDIR/trimmed.md" "$PLAN/task-one.md"
    check --spec "$SPEC"
    [ "$status" -eq 1 ]
    has_output "$id" || return 1
    write_full
  done

  grep -vF -- 'Flow test' "$PLAN/task-one.md" >"$BATS_TEST_TMPDIR/trimmed.md"
  cp "$BATS_TEST_TMPDIR/trimmed.md" "$PLAN/task-one.md"
  check --spec "$SPEC"
  [ "$status" -eq 1 ]
  has_output "FLOW-001" || return 1

  # The other-kind behavior B6 has no Test line in the full set and is accepted.
  write_full
  check --spec "$SPEC"
  [ "$status" -eq 0 ]
  run node "$CLI"
  [ "$status" -eq 2 ]
  grep -qF -- usage <<<"$output"
}

@test "a Flow test line outside the Tests heading counts, as the plan check reads it" {
  write_spec
  write_full
  grep -vF -- 'Flow test' "$PLAN/task-one.md" >"$BATS_TEST_TMPDIR/trimmed.md"
  cp "$BATS_TEST_TMPDIR/trimmed.md" "$PLAN/task-one.md"
  check --spec "$SPEC"
  [ "$status" -eq 1 ]
  has_output "FLOW-001 has no Flow test line" || return 1

  printf '\n## Flow\n\n- Flow test (FLOW-001): flow.test.ts\n' >>"$PLAN/task-one.md"
  check --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "two tests of one behavior at one layer are refused" {
  write_spec
  write_task task-one \
    '- Test (B1, route, access): a.test.ts › first' \
    '- Test (B1, route, access): a.test.ts › second'
  write_task task-two \
    '- Test (B2, route, forgery): a.test.ts › b2' \
    '- Test (B3, route, secret): a.test.ts › b3' \
    '- Test (B4, route, none): a.test.ts › b4' \
    '- Test (B5, unit, none): a.test.ts › b5' \
    '- Flow test (FLOW-001): flow.test.ts'
  check --spec "$SPEC"
  [ "$status" -eq 1 ]
  has_output "B1" || return 1
  has_output "route" || return 1

  write_task task-one \
    '- Test (B1, route, access): a.test.ts › first' \
    '- Test (B1, story, access): a.test.ts › second'
  check --spec "$SPEC"
  [ "$status" -eq 0 ]
}

@test "a listed test carries its behavior's security kind" {
  write_spec
  write_full
  sed 's/(B1, route, access)/(B1, route, none)/' "$PLAN/task-one.md" >"$BATS_TEST_TMPDIR/edited.md"
  cp "$BATS_TEST_TMPDIR/edited.md" "$PLAN/task-one.md"
  check --spec "$SPEC"
  [ "$status" -eq 1 ]
  has_output "B1" || return 1

  write_full
  sed 's/(B4, route, none)/(B4, route, access)/' "$PLAN/task-one.md" >"$BATS_TEST_TMPDIR/edited.md"
  cp "$BATS_TEST_TMPDIR/edited.md" "$PLAN/task-one.md"
  check --spec "$SPEC"
  [ "$status" -eq 1 ]
  has_output "B4" || return 1

  write_full
  sed 's/(B5, unit, none)/(B9, unit, none)/' "$PLAN/task-one.md" >"$BATS_TEST_TMPDIR/edited.md"
  cp "$BATS_TEST_TMPDIR/edited.md" "$PLAN/task-one.md"
  check --spec "$SPEC"
  [ "$status" -eq 1 ]
  has_output "B9" || return 1

  # Accepting twin: forgery marked forgery, an other behavior marked none.
  write_full
  printf '%s\n' '- Test (B6, story, none): a.test.ts › b6' >>"$PLAN/task-one.md"
  check --spec "$SPEC"
  [ "$status" -eq 0 ]
}

@test "a numbered acceptance-criteria list counts for a criterion reference" {
  printf '# task-one\n\n## Acceptance criteria\n\n1. First criterion.\n2) Second criterion.\n\n## Tests\n\n- Test (task-one:AC2, unit, none): a.test.ts › second\n' >"$PLAN/task-one.md"
  check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  sed -i.bak 's/AC2/AC3/' "$PLAN/task-one.md"
  check
  [ "$status" -eq 1 ]
  has_output "task-one:AC3" || return 1
}

@test "a malformed Test line and a spec-less acceptance-criterion reference are refused" {
  write_task task-one '- Test (task-one:AC1, unit, none): a.test.ts › fine'
  check
  [ "$status" -eq 0 ]

  write_task task-one '- Test (task-one:AC1, unit): a.test.ts › missing field'
  check
  [ "$status" -eq 1 ]
  has_output "malformed" || return 1

  write_task task-one '- Test (task-one:AC1, widget, none): a.test.ts › bad layer'
  check
  [ "$status" -eq 1 ]
  has_output "widget" || return 1

  write_task task-one '- Test (task-one:AC1, unit, none): a.test.ts > wrong separator'
  check
  [ "$status" -eq 1 ]
  has_output "malformed" || return 1

  write_task task-one '- Test (task-one:AC3, unit, none): a.test.ts › past the last criterion'
  check
  [ "$status" -eq 1 ]
  has_output "task-one:AC3" || return 1

  write_task task-one '- Test (task-gone:AC1, unit, none): a.test.ts › unknown task doc'
  check
  [ "$status" -eq 1 ]
  has_output "task-gone:AC1" || return 1

  write_task task-one '- Test (task-one:AC2, unit, none): a.test.ts › last criterion'
  check
  [ "$status" -eq 0 ]

  # The same-layer rule holds without a SPEC; no Flow test line is owed.
  write_task task-one \
    '- Test (task-one:AC1, unit, none): a.test.ts › one' \
    '- Test (task-one:AC1, unit, none): a.test.ts › two'
  check
  [ "$status" -eq 1 ]
  write_task task-one \
    '- Test (task-one:AC1, unit, none): a.test.ts › one' \
    '- Test (task-one:AC1, story, none): a.test.ts › two'
  check
  [ "$status" -eq 0 ]
}
