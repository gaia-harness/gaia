#!/usr/bin/env bats
#
# The signal library behind the statusline's /gaia-fitness nudge
# (.gaia/scripts/fitness-nudge-lib.sh): report usability and grade, harness
# paths and pathspecs, the newest fitness close on the usage ledger, the
# commit-count threshold, GAIA-delivered subjects, the harness commit count, the
# version comparison and the blend signal. Fixtures are JSON files and scratch
# git repositories under $BATS_TEST_TMPDIR.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh
# .gaia/scripts/tests/fitness-nudge-lib.bats < /dev/null`.

# shellcheck disable=SC2016 # the Markdown code spans here are literal
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY="$REPO_ROOT/.gaia/scripts/fitness-nudge-lib.sh"
  if ! command -v jq >/dev/null 2>&1; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "jq not present on a CI runner; these probes would report green" >&2
      return 1
    fi
    skip "jq required"
  fi
  # shellcheck source=.gaia/scripts/fitness-nudge-lib.sh
  . "$LIBRARY"
  FIXTURE_REPORT="$BATS_TEST_TMPDIR/report.json"
}

# Write a report: $1 findings JSON, $2 inventory JSON (defaults to one known file).
write_report() {
  local findings=$1 inventory=${2:-'[{"path":"a.md","kinds":["rule"],"ownership":"adopter"}]'}
  jq -n --argjson findings "$findings" --argjson inventory "$inventory" \
    '{overall: "B+", findings: $findings, upstream: [], suppressed: [], inventory: $inventory}' \
    >"$FIXTURE_REPORT"
}

INVENTORY_MIXED='[
  {"path":".claude/rules/a.md","kinds":["rule"],"ownership":"adopter"},
  {"path":"frontend/.claude/skills/x/SKILL.md","kinds":["skill"],"ownership":"adopter"},
  {"path":"CLAUDE.md","kinds":["claudemd"],"ownership":"adopter"},
  {"path":"frontend/CLAUDE.md","kinds":["claudemd"],"ownership":"gaia-shipped"},
  {"path":"wiki/concepts/A.md","kinds":["wiki"],"ownership":"adopter"},
  {"path":".gaia/tests/fixtures/.claude/rules/b.md","kinds":["rule"],"ownership":"adopter"},
  {"path":".claude/skills/vendor-skill/SKILL.md","kinds":["skill"],"ownership":"third-party"},
  {"path":"notes/ignored.md","kinds":["rule"],"ownership":"ignored"}
]'

# ---------------------------------------------------------------- usability

@test "a well-formed report is usable" {
  write_report '[]'
  run gaia_fitness_report_usable "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
}

@test "a report with an empty inventory and the other fields is usable" {
  write_report '[]' '[]'
  run gaia_fitness_report_usable "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
}

@test "a report that is not JSON is unusable" {
  printf 'not json' >"$FIXTURE_REPORT"
  run gaia_fitness_report_usable "$FIXTURE_REPORT"
  [ "$status" -eq 1 ]
}

@test "a JSON array is an unusable report" {
  printf '[]' >"$FIXTURE_REPORT"
  run gaia_fitness_report_usable "$FIXTURE_REPORT"
  [ "$status" -eq 1 ]
}

@test "a report missing findings is unusable" {
  jq -n '{overall: "A", upstream: [], inventory: []}' >"$FIXTURE_REPORT"
  run gaia_fitness_report_usable "$FIXTURE_REPORT"
  [ "$status" -eq 1 ]
}

@test "a report whose overall is not a string is unusable" {
  jq -n '{overall: 3, findings: [], upstream: [], inventory: []}' >"$FIXTURE_REPORT"
  run gaia_fitness_report_usable "$FIXTURE_REPORT"
  [ "$status" -eq 1 ]
}

@test "a report whose whole inventory is unknown ownership (a failed classifier) is unusable" {
  write_report '[]' '[{"path":"a.md","kinds":[],"ownership":"unknown"},{"path":"b.md","kinds":[],"ownership":"unknown"}]'
  run gaia_fitness_report_usable "$FIXTURE_REPORT"
  [ "$status" -eq 1 ]
}

@test "a missing report file is unusable" {
  run gaia_fitness_report_usable "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 1 ]
}

# -------------------------------------------------------------------- grade

@test "an adopter finding under a real rule yields the grade at every severity" {
  local severity
  for severity in error warning info; do
    write_report "[{\"rule_id\":\"hooks.rooted-command\",\"ownership\":\"adopter\",\"severity\":\"$severity\"}]"
    run gaia_fitness_grade "$FIXTURE_REPORT"
    [ "$status" -eq 0 ]
    [ "$output" = "B+" ] || return 1
  done
}

@test "a budget-only adopter finding yields no grade" {
  write_report '[{"rule_id":"claudemd.budget","ownership":"adopter","severity":"error"}]'
  run gaia_fitness_grade "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "findings owned by anyone but the adopter yield no grade" {
  local owner
  for owner in unknown gaia-shipped third-party ignored; do
    write_report "[{\"rule_id\":\"hooks.rooted-command\",\"ownership\":\"$owner\",\"severity\":\"error\"}]"
    run gaia_fitness_grade "$FIXTURE_REPORT"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || return 1
  done
}

@test "an adopter finding only in upstream yields no grade" {
  write_report '[]'
  jq '.upstream = [{"rule_id":"hooks.rooted-command","ownership":"adopter","severity":"error"}]' \
    "$FIXTURE_REPORT" >"$FIXTURE_REPORT.next" && mv "$FIXTURE_REPORT.next" "$FIXTURE_REPORT"
  run gaia_fitness_grade "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an adopter finding only in suppressed yields no grade" {
  write_report '[]'
  jq '.suppressed = [{"rule_id":"hooks.rooted-command","ownership":"adopter","severity":"error"}]' \
    "$FIXTURE_REPORT" >"$FIXTURE_REPORT.next" && mv "$FIXTURE_REPORT.next" "$FIXTURE_REPORT"
  run gaia_fitness_grade "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a budget error beside an adopter warning prints the overall unchanged" {
  write_report '[{"rule_id":"claudemd.budget","ownership":"adopter","severity":"error"},{"rule_id":"hooks.rooted-command","ownership":"adopter","severity":"warning"}]'
  jq '.overall = "C"' "$FIXTURE_REPORT" >"$FIXTURE_REPORT.next" && mv "$FIXTURE_REPORT.next" "$FIXTURE_REPORT"
  run gaia_fitness_grade "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
  [ "$output" = "C" ]
}

@test "grading a file that does not parse returns 1" {
  printf 'not json' >"$FIXTURE_REPORT"
  run gaia_fitness_grade "$FIXTURE_REPORT"
  [ "$status" -eq 1 ]
}

# ------------------------------------------------- harness paths, pathspecs

@test "harness paths are the non-wiki, non-test, non-excluded inventory files" {
  write_report '[]' "$INVENTORY_MIXED"
  run gaia_fitness_harness_paths "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
  [ "$output" = ".claude/rules/a.md
CLAUDE.md
frontend/.claude/skills/x/SKILL.md
frontend/CLAUDE.md" ]
}

@test "pathspecs list the includes then the excludes, each sorted" {
  write_report '[]' "$INVENTORY_MIXED"
  run gaia_fitness_harness_pathspecs "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
  [ "$output" = ":(glob).claude/rules/**/*.md
:(glob)frontend/.claude/skills/**/*.md
:(literal)CLAUDE.md
:(literal)frontend/CLAUDE.md
:(exclude,glob).claude/skills/vendor-skill/**" ]
}

@test "an excluded third-party path outside a skill tree becomes a literal exclude" {
  write_report '[]' '[{"path":"CLAUDE.md","kinds":["claudemd"],"ownership":"adopter"},{"path":"docs/vendored.md","kinds":["rule"],"ownership":"third-party"}]'
  run gaia_fitness_harness_pathspecs "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
  [ "$output" = ":(literal)CLAUDE.md
:(exclude,literal)docs/vendored.md" ]
}

@test "an inventory with no harness path prints no paths and no pathspecs" {
  write_report '[]' '[{"path":"wiki/concepts/A.md","kinds":["wiki"],"ownership":"adopter"},{"path":".claude/skills/v/SKILL.md","kinds":["skill"],"ownership":"third-party"}]'
  run gaia_fitness_harness_paths "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run gaia_fitness_harness_pathspecs "$FIXTURE_REPORT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "harness paths and pathspecs return 1 on a file that does not parse" {
  printf 'not json' >"$FIXTURE_REPORT"
  run gaia_fitness_harness_paths "$FIXTURE_REPORT"
  [ "$status" -eq 1 ]
  run gaia_fitness_harness_pathspecs "$FIXTURE_REPORT"
  [ "$status" -ne 0 ]
}

# Build a repository with one commit per scenario of the pathspec check; $1 is the repo.
commit_file() {
  local repo=$1 file=$2 subject=$3
  mkdir -p "$repo/$(dirname "$file")"
  printf '%s\n' "$subject" >>"$repo/$file"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$subject"
}

init_repo() {
  local repo=$1
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" commit -q --allow-empty -m "root"
}

pathspecs_into_array() {
  PATHSPECS=()
  while IFS= read -r line; do
    PATHSPECS+=("$line")
  done < <(gaia_fitness_harness_pathspecs "$FIXTURE_REPORT")
}

@test "the pathspecs count harness commits and leave the rest alone" {
  write_report '[]' "$INVENTORY_MIXED"
  pathspecs_into_array
  [ "${#PATHSPECS[@]}" -eq 5 ]
  local repo="$BATS_TEST_TMPDIR/repo"
  init_repo "$repo"

  commit_file "$repo" wiki/concepts/A.md "wiki only"
  run gaia_fitness_count_commits "$repo" "" 999 "${PATHSPECS[@]}"
  [ "$output" = "0" ]

  mkdir -p "$repo/.claude/rules"
  printf 'x\n' >"$repo/.claude/rules/a.md"
  printf 'y\n' >>"$repo/wiki/concepts/A.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "wiki and rule"
  run gaia_fitness_count_commits "$repo" "" 999 "${PATHSPECS[@]}"
  [ "$output" = "1" ]

  commit_file "$repo" frontend/app/routes/x.tsx "app route"
  run gaia_fitness_count_commits "$repo" "" 999 "${PATHSPECS[@]}"
  [ "$output" = "1" ]

  commit_file "$repo" frontend/CLAUDE.md "frontend claude"
  run gaia_fitness_count_commits "$repo" "" 999 "${PATHSPECS[@]}"
  [ "$output" = "2" ]

  commit_file "$repo" .claude/skills/vendor-skill/SKILL.md "vendored skill"
  run gaia_fitness_count_commits "$repo" "" 999 "${PATHSPECS[@]}"
  [ "$output" = "2" ]

  commit_file "$repo" .claude/rules/gone.md "add gone rule"
  git -C "$repo" rm -q .claude/rules/gone.md
  git -C "$repo" commit -q -m "remove gone rule"
  run gaia_fitness_count_commits "$repo" "" 999 "${PATHSPECS[@]}"
  [ "$output" = "4" ]
}

# ------------------------------------------------------------ newest close

write_ledger() {
  LEDGER="$BATS_TEST_TMPDIR/usage.jsonl"
  printf '%s\n' "$@" >"$LEDGER"
}

close_row() {
  printf '{"schema_version":1,"kind":"binding","type":"close","workflow":"%s","ts":"%s"}' "$1" "$2"
}

@test "the newest of several fitness close rows wins, whatever their order" {
  write_ledger \
    "$(close_row gaia-fitness 2026-03-01T00:00:10Z)" \
    "$(close_row gaia-fitness 2026-05-01T00:00:10Z)" \
    "$(close_row gaia-fitness 2026-04-01T00:00:10Z)"
  run gaia_fitness_newest_close "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$output" = "1777593610" ]
}

@test "a start row and a close row of another workflow never anchor" {
  write_ledger \
    '{"schema_version":1,"kind":"binding","type":"start","workflow":"gaia-fitness","ts":"2026-06-01T00:00:00Z"}' \
    "$(close_row gaia-cleanse 2026-06-02T00:00:00Z)" \
    "$(close_row gaia-fitness 2026-01-01T00:00:00Z)"
  run gaia_fitness_newest_close "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$output" = "1767225600" ]
}

@test "rows are selected by field name, not key order" {
  write_ledger \
    '{"ts":"2026-02-01T00:00:00Z","workflow":"gaia-fitness","type":"close","kind":"binding"}'
  run gaia_fitness_newest_close "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$output" = "1769904000" ]
}

@test "a timestamp parses with and without fractional seconds" {
  write_ledger "$(close_row gaia-fitness 2026-01-01T00:00:00.789Z)"
  run gaia_fitness_newest_close "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$output" = "1767225600" ]
  write_ledger "$(close_row gaia-fitness 2026-01-01T00:00:00Z)"
  run gaia_fitness_newest_close "$LEDGER"
  [ "$output" = "1767225600" ]
}

@test "an absent ledger prints nothing and returns 0" {
  run gaia_fitness_newest_close "$BATS_TEST_TMPDIR/absent.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a ledger with no fitness close row prints nothing and returns 0" {
  write_ledger "$(close_row gaia-cleanse 2026-06-02T00:00:00Z)" '{"kind":"other"}'
  run gaia_fitness_newest_close "$LEDGER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a torn gaia-fitness line is skipped and a newer valid close still anchors" {
  write_ledger \
    '{"schema_version":1,"kind":"binding","type":"close","workflow":"gaia-fit' \
    "$(close_row gaia-fitness 2026-01-01T00:00:00Z)"
  run gaia_fitness_newest_close "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$output" = "1767225600" ]
}

@test "a ledger whose only gaia-fitness line is torn prints nothing and returns 0" {
  write_ledger '{"kind":"binding","type":"close","workflow":"gaia-fit' 'gaia-fitness'
  run gaia_fitness_newest_close "$LEDGER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unreadable ledger returns 1" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root reads a mode 000 file"
  fi
  write_ledger "$(close_row gaia-fitness 2026-01-01T00:00:00Z)"
  chmod 000 "$LEDGER"
  run gaia_fitness_newest_close "$LEDGER"
  chmod 600 "$LEDGER"
  [ "$status" -eq 1 ]
}

# --------------------------------------------------------------- threshold

@test "a positive whole threshold is read" {
  printf '{"fitness_commit_threshold":25}' >"$BATS_TEST_TMPDIR/project.json"
  run gaia_fitness_commit_threshold "$BATS_TEST_TMPDIR/project.json"
  [ "$status" -eq 0 ]
  [ "$output" = "25" ]
}

@test "every unusable threshold falls back to the default" {
  local fixture
  for fixture in '{}' '{"fitness_commit_threshold":0}' '{"fitness_commit_threshold":-3}' \
    '{"fitness_commit_threshold":15.5}' '{"fitness_commit_threshold":"25"}' \
    '{"fitness_commit_threshold":true}' '{"fitness_commit_threshold":null}' 'not json' '[]'; do
    printf '%s' "$fixture" >"$BATS_TEST_TMPDIR/project.json"
    run gaia_fitness_commit_threshold "$BATS_TEST_TMPDIR/project.json"
    [ "$status" -eq 0 ]
    [ "$output" = "15" ] || { echo "fixture $fixture gave $output" >&2; return 1; }
  done
}

@test "an absent project file gives the default threshold" {
  run gaia_fitness_commit_threshold "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 0 ]
  [ "$output" = "15" ]
}

# ------------------------------------------------------------ GAIA subjects

@test "every GAIA-delivered prefix matches, with and without a squash suffix" {
  [ "${#GAIA_FITNESS_GAIA_SUBJECT_PREFIXES[@]}" -gt 0 ] || return 1
  local prefix
  for prefix in "${GAIA_FITNESS_GAIA_SUBJECT_PREFIXES[@]}"; do
    gaia_fitness_is_gaia_subject "${prefix}x" || { echo "no match: $prefix" >&2; return 1; }
    gaia_fitness_is_gaia_subject "${prefix}x (#123)" || return 1
  done
  gaia_fitness_is_gaia_subject 'chore(gaia): update to v2.0.4 (#123)'
}

@test "a team subject that merely resembles a GAIA prefix does not match" {
  gaia_fitness_is_gaia_subject 'chore: update the readme' && return 1
  gaia_fitness_is_gaia_subject 'feat(gaia): update to v2' && return 1
  gaia_fitness_is_gaia_subject 'fix: chore(gaia): update to' && return 1
  gaia_fitness_is_gaia_subject 'chore(gaia) update to v2' && return 1
  true
}

# Print each backticked chore subject of a migration file that no prefix matches.
unmatched_chore_subjects() {
  local file=$1 subject
  while IFS= read -r subject; do
    subject="${subject#\`}"
    subject="${subject%\`}"
    gaia_fitness_is_gaia_subject "$subject" || printf '%s\n' "$subject"
  done < <(grep -oE '`chore[:(][^`]*`' "$file")
}

@test "every chore subject the 2.0.0 migration commits is a GAIA subject" {
  local migration="$REPO_ROOT/.gaia/migrations/2.0.0.md"
  [ -f "$migration" ] || skip "migration file absent"
  [ "$(grep -oEc '`chore[:(][^`]*`' "$migration")" -gt 0 ] || return 1
  run unmatched_chore_subjects "$migration"
  [ -z "$output" ]
}

@test "the migration drift check reports an invented chore subject" {
  local migration="$REPO_ROOT/.gaia/migrations/2.0.0.md"
  [ -f "$migration" ] || skip "migration file absent"
  cp "$migration" "$BATS_TEST_TMPDIR/migration.md"
  printf '\nRun `chore: an invented migration step` next.\n' >>"$BATS_TEST_TMPDIR/migration.md"
  run unmatched_chore_subjects "$BATS_TEST_TMPDIR/migration.md"
  [ "$output" = "chore: an invented migration step" ]
}

# ----------------------------------------------------------- commit count

# Commit with explicit author and committer dates: $1 repo, $2 file, $3 subject,
# $4 author epoch, $5 committer epoch.
commit_dated() {
  local repo=$1 file=$2 subject=$3 author=$4 committer=$5
  mkdir -p "$repo/$(dirname "$file")"
  printf '%s\n' "$subject" >>"$repo/$file"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE="@$author +0000" GIT_COMMITTER_DATE="@$committer +0000" \
    git -C "$repo" commit -q -m "$subject"
}

build_counted_repo() {
  COUNT_REPO="$BATS_TEST_TMPDIR/counted"
  init_repo "$COUNT_REPO"
  commit_file "$COUNT_REPO" .claude/rules/scaffold.md "chore: scaffold from GAIA v2.0.0"
  commit_file "$COUNT_REPO" .claude/rules/init.md "chore: initialize project with /gaia-init"
  local index
  for index in 1 2 3 4 5 6 7 8; do
    commit_file "$COUNT_REPO" ".claude/rules/team-$index.md" "feat: team rule $index"
  done
  commit_file "$COUNT_REPO" .claude/rules/squash.md "chore(gaia): update to v2.0.4 (#12)"
  for index in 9 10 11 12 13 14 15 16; do
    commit_file "$COUNT_REPO" "CLAUDE.md" "docs: team claude $index"
  done
  git -C "$COUNT_REPO" checkout -q -b update-branch
  commit_file "$COUNT_REPO" .claude/rules/update.md "chore(gaia): update to v2.0.5"
  git -C "$COUNT_REPO" checkout -q -
  git -C "$COUNT_REPO" merge -q --no-ff update-branch -m "Merge branch 'update-branch'"
  COUNT_PATHSPECS=(':(glob).claude/rules/**/*.md' ':(literal)CLAUDE.md')
}

@test "the whole history counts only the team's harness commits" {
  build_counted_repo
  run gaia_fitness_count_commits "$COUNT_REPO" "" 999 "${COUNT_PATHSPECS[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "16" ]
}

@test "the committer date decides which commits count after an epoch" {
  local repo="$BATS_TEST_TMPDIR/dated"
  init_repo "$repo"
  commit_dated "$repo" .claude/rules/c.md "feat: committed before" 1700000100 1700000500
  commit_dated "$repo" .claude/rules/b.md "feat: committed at the epoch" 1700003000 1700002000
  commit_dated "$repo" .claude/rules/a.md "feat: authored early, committed late" 1700000100 1700003000
  run gaia_fitness_count_commits "$repo" 1700002000 999 ':(glob).claude/rules/**/*.md'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "the cap stops the count" {
  build_counted_repo
  run gaia_fitness_count_commits "$COUNT_REPO" "" 3 "${COUNT_PATHSPECS[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "a shallow clone returns 2" {
  build_counted_repo
  git clone -q --depth 1 "file://$COUNT_REPO" "$BATS_TEST_TMPDIR/shallow"
  run gaia_fitness_count_commits "$BATS_TEST_TMPDIR/shallow" "" 999 "${COUNT_PATHSPECS[@]}"
  [ "$status" -eq 2 ]
}

@test "a path that is not a git repository returns 1" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run gaia_fitness_count_commits "$BATS_TEST_TMPDIR/plain" "" 999 ':(literal)CLAUDE.md'
  [ "$status" -eq 1 ]
}

@test "a detached HEAD counts the commits reachable from it" {
  local repo="$BATS_TEST_TMPDIR/detached"
  init_repo "$repo"
  commit_file "$repo" .claude/rules/a.md "feat: first"
  commit_file "$repo" .claude/rules/b.md "feat: second"
  git -C "$repo" checkout -q --detach HEAD~1
  run gaia_fitness_count_commits "$repo" "" 999 ':(glob).claude/rules/**/*.md'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "no pathspec prints 0" {
  build_counted_repo
  run gaia_fitness_count_commits "$COUNT_REPO" "" 999
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------------------------------------------------------- version reached

@test "a version reaches an older, an equal and a prerelease core" {
  gaia_fitness_version_reached 2.0.5 2.0.4
  gaia_fitness_version_reached 2.0.4 2.0.4
  gaia_fitness_version_reached 2.0.4 2.0.4-rc.1
  gaia_fitness_version_reached v2.0.4 2.0.4
  gaia_fitness_version_reached 2.0.4 v2.0.4
  gaia_fitness_version_reached 2.0.4-rc.1 2.0.4-rc.1
  gaia_fitness_version_reached 10.0.0 9.9.9
}

@test "a version does not reach a newer core or a release from its prerelease" {
  gaia_fitness_version_reached 2.0.3 2.0.4 && return 1
  gaia_fitness_version_reached 2.0.4-rc.1 2.0.4 && return 1
  gaia_fitness_version_reached 2.0.4-rc.1 2.0.4-rc.2 && return 1
  gaia_fitness_version_reached 1.9.9 2.0.0 && return 1
  true
}

@test "an unparsable version reaches nothing and is reached by nothing" {
  gaia_fitness_version_reached garbage 2.0.4 && return 1
  gaia_fitness_version_reached 2.0.4 garbage && return 1
  true
}

# ------------------------------------------------------------ blend signal

write_record() {
  RECORD="$BATS_TEST_TMPDIR/blend-record.json"
  printf '%s' "$1" >"$RECORD"
}

TWO_ENTRIES='{"version":1,"entries":[{"path":".claude/rules/a.md","version":"2.0.4"},{"path":".claude/rules/b.md","version":"2.0.4"}]}'

@test "an absent record gives zero and no landings" {
  run gaia_fitness_blend_signal "$BATS_TEST_TMPDIR/absent.json" 2.0.4 "" '{}' 1000
  [ "$status" -eq 0 ]
  [ "$output" = '{"count":0,"landed":{}}' ]
}

@test "a malformed record is refused with no output" {
  local record
  for record in 'not json' '{"version":2,"entries":[]}' '{"version":1,"entries":{}}' \
    '{"version":1,"entries":[{"version":"2.0.4"}]}' '[]'; do
    write_record "$record"
    run gaia_fitness_blend_signal "$RECORD" 2.0.4 "" '{}' 1000
    [ "$status" -eq 1 ]
    [ -z "$output" ] || return 1
  done
}

@test "a landed value that is not an object is refused" {
  write_record "$TWO_ENTRIES"
  run gaia_fitness_blend_signal "$RECORD" 2.0.4 "" '[]' 1000
  [ "$status" -eq 1 ]
  run gaia_fitness_blend_signal "$RECORD" 2.0.4 "" 'null' 1000
  [ "$status" -eq 1 ]
}

@test "entries the main checkout has not reached do not count or land" {
  write_record "$TWO_ENTRIES"
  run gaia_fitness_blend_signal "$RECORD" 2.0.3 "" '{}' 1000
  [ "$status" -eq 0 ]
  [ "$output" = '{"count":0,"landed":{}}' ]
}

@test "reaching the version counts the entries and stamps the landing" {
  write_record "$TWO_ENTRIES"
  run gaia_fitness_blend_signal "$RECORD" 2.0.4 "" '{}' 1000
  [ "$status" -eq 0 ]
  [ "$output" = '{"count":2,"landed":{"2.0.4":1000}}' ]
}

@test "a close from before the landing leaves the entries counted and the stamp kept" {
  write_record "$TWO_ENTRIES"
  run gaia_fitness_blend_signal "$RECORD" 2.0.4 900 '{"2.0.4":1000}' 5000
  [ "$status" -eq 0 ]
  [ "$output" = '{"count":2,"landed":{"2.0.4":1000}}' ]
}

@test "a close after the landing answers the entries" {
  write_record "$TWO_ENTRIES"
  run gaia_fitness_blend_signal "$RECORD" 2.0.4 1100 '{"2.0.4":1000}' 5000
  [ "$status" -eq 0 ]
  [ "$output" = '{"count":0,"landed":{"2.0.4":1000}}' ]
}

@test "a later main version keeps counting and keeps the earlier stamp" {
  write_record "$TWO_ENTRIES"
  run gaia_fitness_blend_signal "$RECORD" 2.0.5 "" '{"2.0.4":1000}' 5000
  [ "$status" -eq 0 ]
  [ "$output" = '{"count":2,"landed":{"2.0.4":1000}}' ]
}

@test "a landed version no longer in the record is dropped" {
  write_record "$TWO_ENTRIES"
  run gaia_fitness_blend_signal "$RECORD" 2.0.4 "" '{"2.0.4":1000,"1.9.0":10}' 5000
  [ "$status" -eq 0 ]
  [ "$output" = '{"count":2,"landed":{"2.0.4":1000}}' ]
}

@test "the jq and bash version comparisons agree on the same pairs" {
  write_record '{"version":1,"entries":[{"path":"p","version":"2.0.4-rc.1"}]}'
  local main entry expected counted
  for main in 2.0.5 2.0.4 2.0.3 2.0.4-rc.1 v2.0.4; do
    for entry in 2.0.4 2.0.4-rc.1; do
      write_record "{\"version\":1,\"entries\":[{\"path\":\"p\",\"version\":\"$entry\"}]}"
      expected=0
      gaia_fitness_version_reached "$main" "$entry" && expected=1
      counted="$(gaia_fitness_blend_signal "$RECORD" "$main" "" '{}' 1000 | jq '.count')"
      [ "$counted" = "$expected" ] || { echo "$main vs $entry: count $counted, reached $expected" >&2; return 1; }
    done
  done
}

# -------------------------------------------------------- source-time silence

@test "sourcing prints nothing, defines every function and leaves status 0" {
  run bash -c '. "$1"; status=$?; printf "status=%s\n" "$status"; for f in gaia_fitness_report_usable gaia_fitness_grade gaia_fitness_harness_paths gaia_fitness_harness_pathspecs gaia_fitness_newest_close gaia_fitness_commit_threshold gaia_fitness_is_gaia_subject gaia_fitness_count_commits gaia_fitness_version_reached gaia_fitness_blend_signal; do declare -F "$f" >/dev/null || echo "missing $f"; done' _ "$LIBRARY"
  [ "$status" -eq 0 ]
  [ "$output" = "status=0" ]
}

@test "the library parses under the system bash" {
  run /bin/bash -n "$LIBRARY"
  [ "$status" -eq 0 ]
}
