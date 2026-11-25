#!/usr/bin/env bats
# .gaia/scripts/spec/flow-runner.sh: the gate line the test stage writes for a
# command flow is one plan-verify's runner check accepts, and a path no runner
# runs is refused; the probe case reads the registry, .gaia/flow-runners.json.
# Shell level only.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI="$REPO_ROOT/.gaia/scripts/spec/flow-runner.sh"
  # shellcheck source=.gaia/scripts/spec/flow-runners-lib.sh
  . "$REPO_ROOT/.gaia/scripts/spec/flow-runners-lib.sh"
}

@test "the printed run line, filled in, is one the plan check accepts for a bats, a Vitest and the registered probe test path; a path no runner runs exits 1" {
  local test_path run_line
  for test_path in .gaia/tests/lib/release-cut.bats apps/web/app/utils/format.test.ts .gaia/tests/claude-probe/expectations.json; do
    run bash "$CLI" "$test_path"
    [ "$status" -eq 0 ] || { echo "$test_path: $output" >&2; return 1; }
    run_line="${output//<test_path>/$test_path}"
    run_line="${run_line//<package-relative path>/$(basename "$test_path")}"
    flow_runners_line_runs "$REPO_ROOT" command "$test_path" "$run_line" >/dev/null || { echo "$test_path: $run_line" >&2; return 1; }
  done

  run bash "$CLI" tools/check.py
  [ "$status" -eq 1 ]
  [[ "$output" == *'no flow runner runs tools/check.py'* ]]
}
