#!/usr/bin/env bats
# The post-build drift check end to end on a scratch git repo: every action row
# confirmed by its own rule, an unnamed unchanged test left alone, and each
# class of drift routed to the list that owns it.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DRIFT_CHECK="$REPO_ROOT/.gaia/scripts/test-drift-check.sh"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  PLAN="$BATS_TEST_TMPDIR/plan"
}

git_fixture() {
  git -C "$FIXTURE" -c user.name=fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@"
}

# write_file <repo-relative path> <content>
write_file() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  printf '%s\n' "$2" >"$FIXTURE/$1"
}

# suite_file <test bodies>: a test file with one describe wrapping the bodies.
suite_file() {
  printf "import {describe, expect, test} from 'vitest';\ndescribe('suite', () => {\n%s\n});" "$1"
}

# plain_test <name> <expected value>
plain_test() {
  printf "  test('%s', () => {\n    expect(%s).toBe(%s);\n  });\n" "$1" "$2" "$2"
}

# each_test <name> <cases, quoted and comma separated>
each_test() {
  printf "  test.each([%s])('%s %%s', (value) => {\n    expect(value).toBeTruthy();\n  });\n" "$2" "$1"
}

# row <id> <file> <title> <action> [extra JSON fields]
row() {
  printf '{"id":"%s","source":"flow:alpha","case":"c","file":"%s","title":"%s","layer":"unit","task":"task-one","action":"%s","security":"none"%s}' \
    "$1" "$2" "$3" "$4" "${5:-}"
}

@test "the drift check confirms each action by its rule and routes each kind of drift to its list" {
  mkdir -p "$FIXTURE"
  git -C "$FIXTURE" init -q -b main
  write_file src/base.test.ts "$(suite_file "$(plain_test 'reuse me' 1)
$(plain_test 'change me' 2)
$(each_test 'extend me' "'alpha'")
$(plain_test 'retire me' 4)
$(plain_test 'leave me' 5)
$(plain_test 'delete me' 6)")"
  git_fixture add -A
  git_fixture commit -q -m base
  git_fixture checkout -q -b feature

  mkdir -p "$PLAN"
  printf '{"schema": 1, "rows": [%s]}\n' "$(row T1 src/fresh.test.ts 'suite brand new' new),$(row T2 src/base.test.ts 'suite reuse me' reuse),$(row T3 src/base.test.ts 'suite change me' change),$(row T4 src/base.test.ts 'suite extend me %s' extend ',"caseKey":"beta"'),$(row T5 src/base.test.ts 'suite retire me' retire),$(row T6 src/never.test.ts 'suite never written' new | sed 's/flow:alpha/flow:beta/'),$(row T7 src/planned.test.ts 'suite wrong place' new)" >"$PLAN/tests.json"
  printf 'schema: 1\n' >"$PLAN/TEST-DESIGN"
  node "$TABLE_CLI" approve --plan-dir "$PLAN" >/dev/null

  write_file src/fresh.test.ts "$(suite_file "$(plain_test 'brand new' 7)")"
  write_file src/base.test.ts "$(suite_file "$(plain_test 'reuse me' 1)
$(plain_test 'change me' 20)
$(each_test 'extend me' "'alpha', 'beta'")
$(plain_test 'leave me' 5)")"
  write_file src/extra.test.ts "$(suite_file "$(plain_test 'nobody asked' 8)")"
  write_file src/elsewhere.test.ts "$(suite_file "$(plain_test 'wrong place' 9)")"
  git_fixture add -A
  git_fixture commit -q -m branch

  run "$DRIFT_CHECK" classify --root "$FIXTURE" --plan-dir "$PLAN" --base main
  [ "$status" -eq 0 ] || { echo "exit $status: $output" >&2; return 1; }

  jq -e '([.matched[].row] | sort) == ["T1","T2","T3","T4","T5"]' <<<"$output" >/dev/null ||
    { echo "matched: $output" >&2; return 1; }
  jq -e '[.missing[].row] == ["T6"] and [.fixer[].row] == ["T6"] and .uncoveredKeys == ["flow:beta"]' <<<"$output" >/dev/null ||
    { echo "missing, fixer or uncoveredKeys: $output" >&2; return 1; }
  jq -e '[.unplanned[].title] == ["suite nobody asked"]' <<<"$output" >/dev/null ||
    { echo "unplanned: $output" >&2; return 1; }
  jq -e '[.moved[] | [.row, .title, .file, .fromFile]] == [["T7","suite wrong place","src/elsewhere.test.ts","src/planned.test.ts"]]' <<<"$output" >/dev/null ||
    { echo "moved: $output" >&2; return 1; }
  jq -e '([.evaluator[].title] | sort) == ["suite nobody asked","suite wrong place"]' <<<"$output" >/dev/null ||
    { echo "evaluator: $output" >&2; return 1; }
  jq -e '.unplannedDeletes == [{"file":"src/base.test.ts","title":"suite delete me"}]' <<<"$output" >/dev/null ||
    { echo "unplannedDeletes: $output" >&2; return 1; }
  jq -e '([.honesty[].row] | sort) == ["T1","T2","T3","T4"]' <<<"$output" >/dev/null ||
    { echo "honesty: $output" >&2; return 1; }
  # The unchanged unnamed test and the deleted one reach no route list.
  jq -e '[.matched, .missing, .unplanned, .moved, .honesty, .evaluator | .[] | .title // empty] | map(select(. == "suite leave me" or . == "suite delete me")) == []' <<<"$output" >/dev/null ||
    { echo "unnamed tests leaked into a list: $output" >&2; return 1; }
}
