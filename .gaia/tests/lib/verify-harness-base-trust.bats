#!/usr/bin/env bats
#
# Tests for when .gaia/tests/verify-harness.sh trusts a merge-base re-run of a
# failing bats test: the base must fail the same way, its pnpm must not try to
# install into the linked dependencies, and a base that runs on the branch's
# changed dependencies cannot show that main is red. Fixtures come from
# .gaia/tests/lib/helpers/verify-harness-fixture.sh.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/verify-harness-base-trust.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/lib/helpers/verify-harness-fixture.sh"
}

fixture() {
  vhf_init "$@" || return 1
  PATH="$VHF_SHIM:$PATH"
  cd "$VHF_ROOT" || return 1
}

run_runner() {
  run bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" "$@"
}

has() {
  grep -qF -- "$1" <<<"$output" && return 0
  printf 'expected output to contain: %s\n--- output ---\n%s\n' "$1" "$output" >&2
  return 1
}

has_line() {
  grep -qE -- "$1" <<<"$output" && return 0
  printf 'expected a line matching: %s\n--- output ---\n%s\n' "$1" "$output" >&2
  return 1
}

# block_after <line prefix>: the indented lines following the first output
# line that starts with the prefix.
block_after() {
  awk -v prefix="$1" '
    found && /^  / { print; next }
    found { exit }
    index($0, prefix) == 1 { found = 1 }
  ' <<<"$output"
}

# block_has <line prefix> <text>: the block after the prefix line has a line
# containing the text.
block_has() {
  block_after "$1" | grep -qF -- "$2" && return 0
  printf 'expected the block after "%s" to contain: %s\n--- output ---\n%s\n' "$1" "$2" "$output" >&2
  return 1
}

# write_two_statement_suite: one test that fails at its first statement while
# control/step-one holds text and at its second while control/step-two does.
# It names src/x-input.txt, so a branch change to that file selects it.
write_two_statement_suite() {
  {
    printf '#!/usr/bin/env bats\n'
    printf '# reads src/x-input.txt\n'
    printf 'setup() {\n  fixture_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"\n}\n'
    printf '@test "two step" {\n'
    printf '  [ ! -s "$fixture_root/control/step-one" ]\n'
    printf '  [ ! -s "$fixture_root/control/step-two" ]\n'
    printf '}\n'
  } >"$VHF_ROOT/suites/two.bats"
}

@test "a test the base fails at a different statement is a new failure, not pre-existing" {
  fixture --no-branch
  write_two_statement_suite
  vhf_control step-two "broken on main"
  vhf_commit "main fails the second statement"
  vhf_branch
  vhf_control step-two ""
  vhf_control step-one "broken on the branch"
  printf 'x two\n' >src/x-input.txt
  vhf_commit "the branch fails the first statement instead"
  run_runner branch
  [ "$status" -eq 1 ]
  grep -qF 'PRE-EXISTING' <<<"$output" && return 1
  has_line '^FAIL  bats selected \([0-9]+s\)$'
  block_has 'FAIL  bats selected' '  suites/two.bats: two step'
  block_has 'FAIL  bats selected' 'failed these at a different statement'
  block_has 'FAIL  bats selected' '    suites/two.bats: two step'
  [ ! -e "$VHF_RECORD" ]
}

@test "the merge-base re-run tells pnpm not to install into the linked dependencies" {
  fixture --no-branch
  {
    printf '#!/usr/bin/env bats\n'
    printf '# reads src/x-input.txt\n'
    printf '@test "env probe" {\n'
    printf '  printf "env|%%s|%%s\\n" "${pnpm_config_verify_deps_before_run-unset}" "$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)" >>"$VERIFY_FIXTURE_LOG"\n'
    printf '  [ ! -s "$BATS_TEST_DIRNAME/../control/env-probe" ]\n'
    printf '}\n'
  } >"$VHF_ROOT/suites/env.bats"
  vhf_control env-probe "broken on main"
  vhf_commit "main fails the probe"
  vhf_branch
  printf 'x two\n' >src/x-input.txt
  vhf_commit "the branch selects the probe"
  unset pnpm_config_verify_deps_before_run
  run_runner branch
  [ "$status" -eq 0 ]
  has_line '^PRE-EXISTING  bats selected: '
  # Every HEAD run leaves pnpm's own setting alone; the base run turns it off.
  [ "$(awk -F'|' -v root="$VHF_ROOT" '$1 == "env" && $3 == root { print $2 }' "$VERIFY_FIXTURE_LOG" | sort -u)" = unset ]
  [ "$(awk -F'|' -v root="$VHF_ROOT" '$1 == "env" && $3 != root { print $2 }' "$VERIFY_FIXTURE_LOG" | sort -u)" = false ]
}

@test "a dependency-reading failure the base shares is unverified when the branch changes a dependency manifest" {
  fixture --no-branch
  {
    printf '#!/usr/bin/env bats\n'
    printf '# bats %s\n' 'file_tags=installed-dependencies'
    printf '# reads src/x-input.txt\n'
    printf '@test "deps probe" {\n'
    printf '  [ ! -s "$BATS_TEST_DIRNAME/../control/deps-probe" ]\n'
    printf '}\n'
  } >"$VHF_ROOT/suites/deps.bats"
  printf '{"name":"fixture","version":"1.0.0"}\n' >package.json
  vhf_control deps-probe "broken on main"
  vhf_control whole-one "broken on main"
  vhf_commit "main fails the dependency probe and a whole-tree test"
  vhf_branch
  printf '{"name":"fixture","version":"2.0.0"}\n' >package.json
  printf 'x two\n' >src/x-input.txt
  vhf_commit "the branch bumps a dependency manifest"
  run_runner branch
  [ "$status" -eq 1 ]
  has_line '^UNVERIFIED-BASE  bats selected: '
  block_has 'UNVERIFIED-BASE  bats selected' '  suites/deps.bats: deps probe'
  block_has 'UNVERIFIED-BASE  bats selected' 'clean main install'
  # A suite that reads no installed dependencies still trusts the base.
  has_line '^PRE-EXISTING  bats whole-tree: '
  block_after 'PRE-EXISTING  bats selected' | grep -qF 'deps probe' && return 1
  [ ! -e "$VHF_RECORD" ]

  printf '{"name":"fixture","version":"1.0.0"}\n' >package.json
  vhf_commit "the branch restores the manifest"
  run_runner branch
  [ "$status" -eq 0 ]
  grep -qF 'UNVERIFIED-BASE' <<<"$output" && return 1
  block_has 'PRE-EXISTING  bats selected' '  suites/deps.bats: deps probe'
}
