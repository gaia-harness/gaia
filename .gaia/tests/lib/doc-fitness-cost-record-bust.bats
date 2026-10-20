#!/usr/bin/env bats
#
# Doc-pin: the /gaia-fitness run-end section busts the update-check cache after
# the cost record is appended, so the next statusline refresh recomputes from
# the new close row. A refresh between the two would stamp the old anchor.
#
# The check is a function over a file path, so the test that proves the real
# page passes has a twin that runs the same function over a scratch copy with
# the two instructions swapped and asserts it fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  FITNESS="${REPO_ROOT}/.claude/skills/gaia/references/fitness.md"
  [ -f "$FITNESS" ] || {
    echo "the fitness playbook is absent: ${FITNESS}" >&2
    return 1
  }
}

# Prints the run-end section: from its heading to the next level-2 heading.
cost_record_section() {
  awk '
    /^## Cost record \(run end\)/ { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$1"
}

# Succeeds when the section names the fitness bust after the record recipe.
bust_follows_record_recipe() {
  local section recipe_line bust_line
  section="$(cost_record_section "$1")"
  [ -n "$section" ] || return 1
  recipe_line="$(grep -n 'Apply the shared record recipe' <<<"$section" | head -n 1 | cut -d: -f1)"
  bust_line="$(grep -n -e '--mode fitness' <<<"$section" | head -n 1 | cut -d: -f1)"
  [ -n "$recipe_line" ] || return 1
  [ -n "$bust_line" ] || return 1
  [ "$bust_line" -gt "$recipe_line" ]
}

@test "the run-end section busts the update-check cache in fitness mode after the record recipe" {
  bust_follows_record_recipe "$FITNESS"
}

@test "the run-end section resolves the main checkout through the canonical resolver" {
  cost_record_section "$FITNESS" | grep -qF 'main-root-lib.sh'
}

@test "red twin: a section with the bust before the record recipe fails the order check" {
  local scratch="${BATS_TEST_TMPDIR}/swapped.md"
  printf '## Cost record (run end)\n\nbash x/update-check-bust.sh --mode fitness\n\nApply the shared record recipe.\n' >"$scratch"
  run bust_follows_record_recipe "$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: a section with no fitness bust fails the order check" {
  local scratch="${BATS_TEST_TMPDIR}/missing.md"
  printf '## Cost record (run end)\n\nApply the shared record recipe.\n' >"$scratch"
  run bust_follows_record_recipe "$scratch"
  [ "$status" -ne 0 ]
}
