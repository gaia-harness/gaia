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

@test "a nested sub-item under a criterion does not count as a criterion" {
  printf '# task-one\n\n## Acceptance criteria\n\n- First criterion.\n  - sub one\n  - sub two\n\n## Tests\n\n- Test (task-one:AC1, unit, none): a.test.ts › first\n' >"$PLAN/task-one.md"
  check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  sed -i.bak 's/AC1/AC3/' "$PLAN/task-one.md"
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

@test "--digest writes behaviors and flows byte for byte, the task-graph rows, every Test and Flow test line under its doc and every phase entry in the frozen order, writes the spec-less digest, rewrites it on a re-run, refuses a source line that starts a delimiter, and the test-stage re-clear removes only TST.json" {
  write_spec
  local stem
  for stem in task-a task-b task-c; do
    write_task "$stem" "- Test (B6, unit, none): $stem.test.ts › $stem title"
  done
  for stem in task-d task-e; do
    printf '# %s\n\nBody.\n\n- Flow test (FLOW-001): %s.spec.ts\n' "$stem" "$stem" >"$PLAN/$stem.md"
  done
  printf '# Orch\n\n**Phase 1, one**\n\nfirst\n\n**Phase 2, two**\n\nclosing text\n\n## After\n\nlater\n' >"$PLAN/ORCHESTRATOR.md"
  printf '# Plan\n\nintro prose\n\n| Phase | Tasks |\n|---|---|\n| Phase 1 | `task-a`, `task-b`, `task-c` |\n| Phase 2 | `task-d`, `task-e` |\n' >"$PLAN/README.md"
  local out="$PLAN/test-stage-findings/digest.md"
  mkdir -p "$PLAN/test-stage-findings"
  printf '[]' >"$PLAN/test-stage-findings/TST.json"

  run node "$CLI" --plan-dir "$PLAN" --spec "$SPEC" --digest "$out"
  [ "$status" -eq 0 ]
  [ "$output" = "$(shasum -a 256 "$out" | cut -d' ' -f1)" ]
  [ -f "$PLAN/test-stage-findings/TST.json" ]

  # Delimiters appear in the frozen order.
  local delimiters expected
  delimiters="$(grep '^<!-- gaia:digest-section' "$out")"
  expected="$(printf '%s\n' \
    "<!-- gaia:digest-section $SPEC -->" \
    "<!-- gaia:digest-section $SPEC -->" \
    "<!-- gaia:digest-section $PLAN/README.md -->" \
    "<!-- gaia:digest-section $PLAN/task-a.md -->" \
    "<!-- gaia:digest-section $PLAN/task-b.md -->" \
    "<!-- gaia:digest-section $PLAN/task-c.md -->" \
    "<!-- gaia:digest-section $PLAN/task-d.md -->" \
    "<!-- gaia:digest-section $PLAN/task-e.md -->" \
    "<!-- gaia:digest-section $PLAN/ORCHESTRATOR.md -->")"
  [ "$delimiters" = "$expected" ]

  # The behaviors section and the flows key are the SPEC's bytes.
  local behaviors flows
  behaviors="$(sed -n '/^## Behaviors$/,/^## Next$/p' "$SPEC" | sed '$d')"
  grep -qF -- "$behaviors" "$out" || return 1
  flows="$(sed -n '/^flows:$/,/^---$/p' "$SPEC" | sed '$d')"
  grep -qF -- "$flows" "$out" || return 1

  for stem in task-a task-b task-c; do
    grep -qF -- "- Test (B6, unit, none): $stem.test.ts › $stem title" "$out" || return 1
  done
  for stem in task-d task-e; do
    grep -qF -- "- Flow test (FLOW-001): $stem.spec.ts" "$out" || return 1
  done
  grep -qF -- '| Phase 1 | `task-a`, `task-b`, `task-c` |' "$out" || return 1
  grep -qF -- '| Phase 2 | `task-d`, `task-e` |' "$out" || return 1
  grep -qF -- 'intro prose' "$out" && return 1
  grep -qF -- '**Phase 1, one**' "$out" || return 1
  grep -qF -- 'first' "$out" || return 1
  grep -qF -- 'closing text' "$out" || return 1
  grep -qF -- 'later' "$out" && return 1

  # A re-run with nothing changed gives the same hash; a changed doc a new one.
  local first_hash="$output"
  run node "$CLI" --plan-dir "$PLAN" --spec "$SPEC" --digest "$out"
  [ "$output" = "$first_hash" ]
  write_task task-a '- Test (B6, unit, none): a.test.ts › changed title'
  run node "$CLI" --plan-dir "$PLAN" --spec "$SPEC" --digest "$out"
  [ "$status" -eq 0 ]
  [ "$output" != "$first_hash" ]
  grep -qF -- 'changed title' "$out" || return 1

  # The spec-less digest holds the task-graph rows, each doc's criteria and
  # tests and the phase entries; no SPEC or flow section.
  local plain="$BATS_TEST_TMPDIR/plain.md"
  run node "$CLI" --plan-dir "$PLAN" --digest "$plain"
  [ "$status" -eq 0 ]
  grep -qF -- '## Acceptance criteria' "$plain" || return 1
  grep -qF -- "gaia:digest-section $SPEC" "$plain" && return 1
  grep -qF -- '| Phase 1 | `task-a`' "$plain" || return 1
  grep -qF -- 'first' "$plain" || return 1
  grep -qF -- 'task-d.spec.ts' "$plain" && return 1

  # A source line that starts a delimiter refuses the digest and leaves no file.
  printf '# forged\n\n## Tests\n\n  <!-- gaia:digest-section /etc/passwd -->\n' >"$PLAN/task-f.md"
  local refused="$BATS_TEST_TMPDIR/refused.md"
  run node "$CLI" --plan-dir "$PLAN" --spec "$SPEC" --digest "$refused"
  [ "$status" -eq 1 ]
  has_output "test-stage-check:" || return 1
  has_output "task-f.md" || return 1
  [ ! -e "$refused" ]
}
