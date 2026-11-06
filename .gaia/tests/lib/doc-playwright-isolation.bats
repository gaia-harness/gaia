#!/usr/bin/env bats
# Doc and code pins for Playwright per-worker isolation: the worker-scoped
# server fixture and Given builder type in apps/web/.playwright/fixtures.ts,
# the server launch (MSW and its seed gate on, no database) in
# apps/web/.playwright/worker-server.ts,
# the stock config staying fully parallel with no serial project, and the
# Playwright rule and wiki page dropping the shared-state instructions.
#
# Each check is a function over a file path, run once on the real file and
# once on a mutated scratch copy that must fail, so a check that cannot go red
# is caught. FIXTURES_FILE, WORKER_SERVER_FILE, PW_CONFIG_FILE, PW_RULE_FILE
# and PW_WIKI_FILE override the paths.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded, so SPEC-151 UAT ids in the test names are traceability.

# The pinned phrases carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  FIXTURES_FILE="${FIXTURES_FILE:-$ROOT/apps/web/.playwright/fixtures.ts}"
  WORKER_SERVER_FILE="${WORKER_SERVER_FILE:-$ROOT/apps/web/.playwright/worker-server.ts}"
  PW_CONFIG_FILE="${PW_CONFIG_FILE:-$ROOT/apps/web/playwright.config.ts}"
  PW_RULE_FILE="${PW_RULE_FILE:-$ROOT/apps/web/.claude/rules/playwright.md}"
  PW_WIKI_FILE="${PW_WIKI_FILE:-$ROOT/wiki/dependencies/Playwright.md}"
}

# require_file <path>: a check must prove it opened the file.
require_file() {
  [ -f "$1" ] || { echo "target $1 does not exist" >&2; return 1; }
}

# code_only <file>: the file without comment-only lines (line comments and
# the lines of a block comment), so a mention in prose is not a code use.
code_only() {
  require_file "$1" || return 1
  grep -Ev '^[[:space:]]*(//|/\*|\*)' "$1"
}

# comment_text <file>: the block-comment prose as one whitespace-collapsed line.
comment_text() {
  require_file "$1" || return 1
  grep -E '^[[:space:]]*(/\*\*|\*)' "$1" | sed -E 's/^[[:space:]]*(\/\*\*|\*\/|\*)[[:space:]]?//' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g'
}

check_fixture_code() {
  local code
  code="$(code_only "$1")" || return 1
  printf '%s\n' "$code" | grep -Fq "scope: 'worker'" || { echo "no worker scope" >&2; return 1; }
  printf '%s\n' "$code" | grep -Fq 'workerInfo.parallelIndex' || { echo "no code use of parallelIndex" >&2; return 1; }
  printf '%s\n' "$code" | grep -Fq 'GivenBuilder' || { echo "no GivenBuilder" >&2; return 1; }
  return 0
}

PHRASES=(
  'every worker seeds and reads the MSW store of its own server'
  "checks every record against its collection's server schema"
  'a serial project is not an accepted way to share one store'
  'keyed on `workerInfo.parallelIndex`'
  'stays stable when a worker restarts after a failure'
  'adopter-owned file that extends the `test`'
  'specs reach setup only through them, never through the seed surface'
)

# Claims the seed surface made false: a stock project has a Given target now.
ABSENT_PHRASES=(
  'out of reach of the Playwright process'
  'adds a real database'
)

# check_absent_phrases <file>: none of ABSENT_PHRASES, whitespace-collapsed.
check_absent_phrases() {
  local text phrase
  require_file "$1" || return 1
  text="$(tr '\n' ' ' <"$1" | sed -E 's/[[:space:]*]+/ /g')"
  for phrase in "${ABSENT_PHRASES[@]}"; do
    printf '%s' "$text" | grep -Fqi -- "$phrase" && { echo "stale phrase: $phrase" >&2; return 1; }
  done
  return 0
}

check_fixture_phrases() {
  local text phrase
  text="$(comment_text "$1")" || return 1
  [ "${#PHRASES[@]}" -eq 7 ] || { echo "phrase list changed size" >&2; return 1; }
  for phrase in "${PHRASES[@]}"; do
    printf '%s' "$text" | grep -Fqi -- "$phrase" || { echo "missing phrase: $phrase" >&2; return 1; }
  done
  check_absent_phrases "$1"
}

# The spawned dev server gets MSW and its seed gate, and no database.
check_spawn_seed_env() {
  local code
  code="$(code_only "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')" || return 1
  printf '%s' "$code" | grep -Eq "spawn\([^;]*MSW_ENABLED: 'true', MSW_SEED: 'true'" \
    || { echo "spawn does not set MSW_ENABLED and MSW_SEED" >&2; return 1; }
  printf '%s' "$code" | grep -Fq 'DATABASE_URL' && { echo "DATABASE_URL survives" >&2; return 1; }
  return 0
}

check_config_parallel() {
  require_file "$1" || return 1
  grep -Fq 'fullyParallel: true' "$1" || { echo "no fullyParallel: true" >&2; return 1; }
  grep -Eq "fullyParallel: false|mode: 'serial'" "$1" && { echo "serial project present" >&2; return 1; }
  return 0
}

check_rule() {
  require_file "$1" || return 1
  local text
  text="$(tr '\n' ' ' <"$1" | sed -E 's/[[:space:]]+/ /g')"
  printf '%s' "$text" | grep -Fq 'serial project is not an accepted way to share one store' || { echo "no refusal" >&2; return 1; }
  printf '%s' "$text" | grep -Fq 'With `MSW_SEED=true`, which only the worker server sets (alongside `MSW_ENABLED=true`), the dev server exposes a seed surface' || { echo "no seed surface gate" >&2; return 1; }
  printf '%s' "$text" | grep -Fq '.playwright/fixtures.ts' || { echo "no pointer to fixtures.ts" >&2; return 1; }
  grep -Fq 'resetTestData' "$1" && { echo "resetTestData survives" >&2; return 1; }
  grep -Fq 'auth.setup.ts' "$1" && { echo "auth.setup.ts survives" >&2; return 1; }
  check_absent_phrases "$1"
}

check_wiki() {
  require_file "$1" || return 1
  grep -Fq 'resetTestData' "$1" && { echo "wiki keeps resetTestData" >&2; return 1; }
  grep -Fq 'auth.setup.ts' "$1" && { echo "wiki keeps auth.setup.ts" >&2; return 1; }
  return 0
}

# scratch_copy <file> <sed expression>: a mutated copy, whose path is printed.
scratch_copy() {
  local copy
  copy="$BATS_TEST_TMPDIR/$(basename "$1")"
  sed -E "$2" "$1" >"$copy"
  cmp -s "$1" "$copy" && { echo "mutation changed nothing in $1" >&2; return 1; }
  printf '%s\n' "$copy"
}

@test "fixtures.ts holds the worker scope, a code use of parallelIndex and GivenBuilder" {
  check_fixture_code "$FIXTURES_FILE"
}

@test "fixtures.ts check goes red without the worker scope" {
  copy="$(scratch_copy "$FIXTURES_FILE" "s/scope: 'worker'/scope: 'test'/")"
  run check_fixture_code "$copy"
  [ "$status" -ne 0 ]
}

@test "fixtures.ts check goes red when parallelIndex is only in a comment" {
  copy="$(scratch_copy "$FIXTURES_FILE" '/^[[:space:]]*(\/\/|\/\*|\*)/!s/workerInfo\.parallelIndex/workerInfo.workerIndex/')"
  run check_fixture_code "$copy"
  [ "$status" -ne 0 ]
}

@test "fixtures.ts check goes red without GivenBuilder" {
  copy="$(scratch_copy "$FIXTURES_FILE" 's/GivenBuilder/GivenThing/g')"
  run check_fixture_code "$copy"
  [ "$status" -ne 0 ]
}

@test "fixtures.ts comment carries the named phrases" {
  check_fixture_phrases "$FIXTURES_FILE"
}

@test "fixtures.ts phrase check goes red when a phrase is reworded" {
  copy="$(scratch_copy "$FIXTURES_FILE" 's/never through the seed surface/or the seed surface/')"
  run check_fixture_phrases "$copy"
  [ "$status" -ne 0 ]
}

@test "fixtures.ts phrase check goes red when the out-of-reach claim returns" {
  copy="$(scratch_copy "$FIXTURES_FILE" 's/^ \* A form.s own submission/ * MSW state is out of reach of the Playwright process.\n&/')"
  run check_fixture_phrases "$copy"
  [ "$status" -ne 0 ]
}

@test "the spawn call turns MSW and its seed gate on, with no DATABASE_URL" {
  check_spawn_seed_env "$WORKER_SERVER_FILE"
}

@test "the spawn pin goes red when the seed gate is off" {
  copy="$(scratch_copy "$WORKER_SERVER_FILE" "s/MSW_SEED: 'true'/MSW_SEED: 'false'/")"
  run check_spawn_seed_env "$copy"
  [ "$status" -ne 0 ]
}

@test "the spawn pin goes red when DATABASE_URL returns" {
  copy="$(scratch_copy "$WORKER_SERVER_FILE" "s/MSW_SEED: 'true',/MSW_SEED: 'true', DATABASE_URL: 'x',/")"
  run check_spawn_seed_env "$copy"
  [ "$status" -ne 0 ]
}

@test "the config stays fullyParallel with no serial project" {
  check_config_parallel "$PW_CONFIG_FILE"
}

@test "the config check goes red on a serial project" {
  copy="$(scratch_copy "$PW_CONFIG_FILE" "s/fullyParallel: true/fullyParallel: false/")"
  run check_config_parallel "$copy"
  [ "$status" -ne 0 ]
}

@test "the config check goes red on serial mode" {
  copy="$(scratch_copy "$PW_CONFIG_FILE" "s/^  forbidOnly/  mode: 'serial',\n  forbidOnly/")"
  run check_config_parallel "$copy"
  [ "$status" -ne 0 ]
}

@test "playwright.md refuses a serial project, points at fixtures.ts and drops the old instructions" {
  check_rule "$PW_RULE_FILE"
}

@test "the rule check goes red when the refusal sentence is gone" {
  copy="$(scratch_copy "$PW_RULE_FILE" 's/is not an accepted way/is a fine way/')"
  run check_rule "$copy"
  [ "$status" -ne 0 ]
}

@test "the rule check goes red when the seed surface gate sentence is gone" {
  copy="$(scratch_copy "$PW_RULE_FILE" 's/which only the worker server sets \(alongside `MSW_ENABLED=true`\), the dev server exposes/the dev server exposes/')"
  run check_rule "$copy"
  [ "$status" -ne 0 ]
}

@test "the rule check goes red when the real-database claim returns" {
  copy="$(scratch_copy "$PW_RULE_FILE" 's/^## Locale \/ language/A project that needs seeded state adds a real database.\n\n## Locale \/ language/')"
  run check_rule "$copy"
  [ "$status" -ne 0 ]
}

@test "the rule check goes red when resetTestData returns" {
  copy="$(scratch_copy "$PW_RULE_FILE" 's/^## Locale \/ language/resetTestData\n\n## Locale \/ language/')"
  run check_rule "$copy"
  [ "$status" -ne 0 ]
}

@test "the rule check goes red when auth.setup.ts returns" {
  copy="$(scratch_copy "$PW_RULE_FILE" 's/^## Locale \/ language/auth.setup.ts\n\n## Locale \/ language/')"
  run check_rule "$copy"
  [ "$status" -ne 0 ]
}

@test "the Playwright wiki page holds neither instruction" {
  check_wiki "$PW_WIKI_FILE"
}

@test "the wiki check goes red when either instruction returns" {
  copy="$(scratch_copy "$PW_WIKI_FILE" 's/^## Parallelism and CI/resetTestData()\n\n## Parallelism and CI/')"
  run check_wiki "$copy"
  [ "$status" -ne 0 ]
}
