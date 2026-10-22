#!/usr/bin/env bats

# The /gaia-fitness nudge from the background refresher to the rendered line.
# The refresher (.gaia/scripts/check-updates.sh) computes the grade, blended
# file and harness commit signals into the update-check cache; the statusline
# reads only those cached fields. Every case here runs the real refresher, then
# the real renderer, against a throwaway main-checkout git repository.
#
# The fixture holds copies of the refresher, the signal library, the cache bust
# and the statusline, with a `gaia` wrapper that answers each subcommand the
# refresher calls with an inert stub. Its `fitness check` prints the contents of
# $FITNESS_REPORT_FIXTURE (exit $FITNESS_EXIT, 2 meaning no output), or runs the
# committed CLI bundle when $FITNESS_USE_REAL_BUNDLE is set. `gh` and `curl` are
# stubs on PATH, so no case touches the network. The fixture's refresher is not
# executable, so a render never starts a detached refresh of its own.
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/statusline/fitness-nudge.bats < /dev/null

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v git >/dev/null 2>&1 || skip "git required"

  TEMPORARY_HOME=$(mktemp -d -t gaia-fitness-nudge-home-XXXXXX)
  FIXTURE_PARENT=$(mktemp -d -t gaia-fitness-nudge-fix-XXXXXX)
  REPOSITORY_FIXTURE="$FIXTURE_PARENT/main-checkout"
  mkdir -p "$REPOSITORY_FIXTURE"
  REPOSITORY_FIXTURE=$(cd "$REPOSITORY_FIXTURE" && pwd -P)
  COMMIT_REPO="$REPOSITORY_FIXTURE"
  COMMIT_SEQUENCE=1
  COMMIT_WHEN="2026-02-01T12:00:00Z"

  git -C "$REPOSITORY_FIXTURE" init --quiet --initial-branch=main
  git -C "$REPOSITORY_FIXTURE" config user.email "test@example.com"
  git -C "$REPOSITORY_FIXTURE" config user.name "Test"
  git -C "$REPOSITORY_FIXTURE" config commit.gpgsign false
  printf '.gaia/local/\n' >> "$REPOSITORY_FIXTURE/.git/info/exclude"
  mkdir -p "$REPOSITORY_FIXTURE/.gaia/scripts" "$REPOSITORY_FIXTURE/.gaia/cli" \
    "$REPOSITORY_FIXTURE/.gaia/statusline" "$REPOSITORY_FIXTURE/.gaia/local/cache/shared" \
    "$REPOSITORY_FIXTURE/.claude/rules" "$REPOSITORY_FIXTURE/wiki"
  for script_name in check-updates.sh main-root-lib.sh knowledge-inventory.sh \
    fitness-nudge-lib.sh update-check-bust.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$script_name" "$REPOSITORY_FIXTURE/.gaia/scripts/$script_name"
  done
  chmod -x "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh"
  cp "$REPO_ROOT/.gaia/statusline/gaia-statusline.sh" "$REPOSITORY_FIXTURE/.gaia/statusline/gaia-statusline.sh"
  cp "$REPO_ROOT/.gaia/statusline/gaia-statusline-right.sh" "$REPOSITORY_FIXTURE/.gaia/statusline/gaia-statusline-right.sh"

  cat > "$REPOSITORY_FIXTURE/.gaia/cli/gaia" <<'WRAPPER'
#!/usr/bin/env bash
case "$1" in
  update-deps)
    output_path=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --emit-updates) output_path="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$output_path" ] && printf '{"actionable_count":0}' > "$output_path"
    exit 0
    ;;
  codify-tally)
    printf '{"candidate_count":0,"unclassified":null,"gh_ok":true,"window_days":90}'
    exit 0
    ;;
  residue-tally)
    printf '{"gh_ok":false,"aged_candidate_count":0}'
    exit 0
    ;;
  wiki)
    printf '{"drift_count":0}'
    exit 0
    ;;
  fitness)
    if [ -n "${FITNESS_USE_REAL_BUNDLE:-}" ]; then
      exec "$GAIA_TEST_FITNESS_BUNDLE" "$@"
    fi
    if [ "$2" = "check" ]; then
      [ -z "${FITNESS_CLI_LOG:-}" ] || printf '%s\n' "$*" >> "$FITNESS_CLI_LOG"
      [ "${FITNESS_EXIT:-0}" -ne 2 ] || exit 2
      cat "$FITNESS_REPORT_FIXTURE"
      exit "${FITNESS_EXIT:-0}"
    fi
    exit 1
    ;;
  *) exit 1 ;;
esac
WRAPPER
  chmod +x "$REPOSITORY_FIXTURE/.gaia/cli/gaia"
  export GAIA_TEST_FITNESS_BUNDLE="$REPO_ROOT/.gaia/cli/gaia"
  FITNESS_REPORT_FIXTURE="$BATS_TEST_TMPDIR/report.json"
  export FITNESS_REPORT_FIXTURE
  unset FITNESS_EXIT FITNESS_USE_REAL_BUNDLE FITNESS_CLI_LOG GAIA_FITNESS_OWNERSHIP_CLASSIFIER

  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ -n "${GH_HOLD_FILE:-}" ]; then
  : > "$GH_HOLD_FILE.started"
  while [ -e "$GH_HOLD_FILE" ]; do sleep 0.1; done
fi
exit 1
STUB
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_BIN/curl"
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/curl"

  printf '1.0.0\n' > "$REPOSITORY_FIXTURE/.gaia/VERSION"
  printf 'seed\n' > "$REPOSITORY_FIXTURE/wiki/index.md"
  printf 'short project instructions\n' > "$REPOSITORY_FIXTURE/CLAUDE.md"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$REPOSITORY_FIXTURE/.gaia/local/setup-state.json"
  git -C "$REPOSITORY_FIXTURE" add -A
  GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
    git -C "$REPOSITORY_FIXTURE" commit --quiet -m "chore: scaffold from GAIA 2.0.0"

  CACHE_FILE="$REPOSITORY_FIXTURE/.gaia/local/cache/shared/update-check.json"
  RENDER_ROOT="$REPOSITORY_FIXTURE"
  write_report A
}

teardown() {
  [ -n "${FIXTURE_PARENT:-}" ] && rm -rf "$FIXTURE_PARENT" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# ---------- fixture builders ----------

# write_report <overall> [findings-array] [upstream-array] [extra-inventory-array]:
# the check report the stub prints. The inventory always holds one harness rule
# and one wiki page.
write_report() {
  jq -n --arg overall "$1" --argjson findings "${2:-[]}" --argjson upstream "${3:-[]}" \
    --argjson extra "${4:-[]}" '{
      overall: $overall, findings: $findings, upstream: $upstream,
      inventory: ([{path: ".claude/rules/r1.md", kinds: ["rule"], ownership: "adopter"},
                   {path: "wiki/page.md", kinds: ["wiki"], ownership: "adopter"}] + $extra)
    }' > "$FITNESS_REPORT_FIXTURE"
}

# adopter_finding [rule-id] [severity]: one adopter-owned finding as JSON.
adopter_finding() {
  printf '{"rule_id":"%s","severity":"%s","file":"CLAUDE.md","line":1,"message":"m","ownership":"adopter"}' \
    "${1:-authoring.other}" "${2:-warning}"
}

# shipped_finding: one GAIA-shipped finding as JSON.
shipped_finding() {
  printf '{"rule_id":"authoring.other","severity":"warning","file":".claude/rules/shipped.md","line":1,"message":"m","ownership":"gaia-shipped"}'
}

# commit_touching <iso-date> <subject> <path>...: one commit in $COMMIT_REPO
# whose author and committer dates are <iso-date>.
commit_touching() {
  local when="$1" subject="$2" file
  shift 2
  for file in "$@"; do
    mkdir -p "$(dirname "$COMMIT_REPO/$file")"
    printf '# Rule\n\nchange %s\n' "$COMMIT_SEQUENCE" > "$COMMIT_REPO/$file"
  done
  COMMIT_SEQUENCE=$((COMMIT_SEQUENCE + 1))
  git -C "$COMMIT_REPO" add -- "$@"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$COMMIT_REPO" commit --quiet -m "$subject"
}

# add_harness_commits <n> [iso-date]: n team commits, each touching its own rule file.
add_harness_commits() {
  local index when="${2:-$COMMIT_WHEN}"
  for ((index = 1; index <= $1; index++)); do
    commit_touching "$when" "feat: harness change $COMMIT_SEQUENCE" ".claude/rules/r$COMMIT_SEQUENCE.md"
  done
}

# add_app_commits <n> [iso-date]: n commits touching only frontend/app/.
add_app_commits() {
  local index when="${2:-$COMMIT_WHEN}"
  for ((index = 1; index <= $1; index++)); do
    commit_touching "$when" "feat: app change $COMMIT_SEQUENCE" "frontend/app/x$COMMIT_SEQUENCE.ts"
  done
}

ledger_file() {
  printf '%s/.gaia/local/telemetry/usage.jsonl' "$REPOSITORY_FIXTURE"
}

append_ledger_row() {
  local file
  file=$(ledger_file)
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$1" >> "$file"
}

# Rows are written with their keys out of canonical order on purpose: the
# refresher selects them by field name.
append_close_row() {
  append_ledger_row "$(printf '{"ts":"%s","workflow":"gaia-fitness","type":"close","kind":"binding","outcome":"done"}' "$1")"
}

append_start_row() {
  append_ledger_row "$(printf '{"workflow":"gaia-fitness","kind":"binding","ts":"%s","type":"start"}' "$1")"
}

iso_from_epoch() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

set_version() {
  printf '%s\n' "$1" > "$REPOSITORY_FIXTURE/.gaia/VERSION"
}

# write_blend_record <version> <entry-count>
write_blend_record() {
  mkdir -p "$REPOSITORY_FIXTURE/.gaia/local/fitness"
  jq -n --arg version "$1" --argjson count "$2" \
    '{version: 1, entries: [range($count) | {path: (".claude/rules/blend-\(.).md"), version: $version}]}' \
    > "$REPOSITORY_FIXTURE/.gaia/local/fitness/blend-record.json"
}

write_project_config() {
  printf '%s' "$1" > "$REPOSITORY_FIXTURE/.gaia/project.json"
}

# use_real_bundle: the stub hands `fitness` to the committed CLI, and the
# fixture gets what that bundle reads to classify ownership.
use_real_bundle() {
  export FITNESS_USE_REAL_BUNDLE=1
  cp "$REPO_ROOT/.gaia/scripts/fitness-ownership.sh" "$REPOSITORY_FIXTURE/.gaia/scripts/fitness-ownership.sh"
  printf '{"files":{}}' > "$REPOSITORY_FIXTURE/.gaia/manifest.json"
}

# ---------- run and read ----------

cache_value() {
  jq -r ".$1" "$CACHE_FILE"
}

# run_refresher [script]: one run of the refresher, the cache left as it is.
run_refresher() {
  local script="${1:-$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh}"
  run env HOME="$TEMPORARY_HOME" PATH="$STUB_BIN:$PATH" bash "$script" < /dev/null
  [ "$status" -eq 0 ]
}

# refresh: a first refresh, the cache deleted beforehand.
refresh() {
  rm -f "$CACHE_FILE"
  run_refresher
}

# set_checked_at <epoch>
set_checked_at() {
  jq --argjson checked_at "$1" '.checkedAt = $checked_at' "$CACHE_FILE" > "$CACHE_FILE.next"
  mv "$CACHE_FILE.next" "$CACHE_FILE"
}

# seed_probe: marks the cache with a field only a rewrite drops and leaves it
# well inside its TTL, so a recompute and a hold are told apart.
seed_probe() {
  jq --argjson now "$(date +%s)" '. + {probe: 1, checkedAt: ($now - 100)}' "$CACHE_FILE" > "$CACHE_FILE.next"
  mv "$CACHE_FILE.next" "$CACHE_FILE"
}

assert_held() {
  [ "$(jq -r 'has("probe")' "$CACHE_FILE")" = "true" ]
}

assert_recomputed() {
  [ "$(jq -r 'has("probe")' "$CACHE_FILE")" = "false" ]
}

# refresh_within_ttl: the cache stays and is fresh, so only a basis check can
# make the run recompute.
refresh_within_ttl() {
  seed_probe
  run_refresher
}

bust() {
  run bash "$REPOSITORY_FIXTURE/.gaia/scripts/update-check-bust.sh" --cache "$CACHE_FILE" "$@"
  [ "$status" -eq 0 ]
}

# render_at <columns>: sets $plain to the rendered line with colors stripped.
render_at() {
  local json
  json=$(jq -n --arg current_directory "$RENDER_ROOT" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TEMPORARY_HOME" COLUMNS="$1" bash -c "printf '%s' '$json' | bash '$RENDER_ROOT/.gaia/statusline/gaia-statusline.sh'" < /dev/null
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
}

render_wide() {
  render_at 400
}

# assert_fitness_nudge <reason>: the rendered line carries "/gaia-fitness <reason>".
assert_fitness_nudge() {
  grep -qF -- "/gaia-fitness $1" <<<"$plain" || { printf 'missing "/gaia-fitness %s" in: %s\n' "$1" "$plain" >&2; return 1; }
}

assert_no_fitness_nudge() {
  grep -qF -- "/gaia-fitness" <<<"$plain" && { printf 'unexpected nudge in: %s\n' "$plain" >&2; return 1; }
  true
}

# mutated_copy <name> <search> <replacement> [source]: a scratch copy of the
# refresher with the one line holding <search> replaced; fails unless exactly
# one line matched. The copy sits beside the original because the refresher
# derives every path from its own location.
mutated_copy() {
  local target="$REPOSITORY_FIXTURE/.gaia/scripts/$1"
  local source="${4:-$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh}"
  # The texts travel through the environment: awk -v would interpret the
  # backslashes in them.
  SEARCH_TEXT="$2" REPLACEMENT_TEXT="$3" awk '
    index($0, ENVIRON["SEARCH_TEXT"]) > 0 { print ENVIRON["REPLACEMENT_TEXT"]; hits++; next }
    { print }
    END { exit (hits == 1 ? 0 : 1) }
  ' "$source" > "$target"
}

# ---------- the pre-TTL gate ----------

@test "the gate inside the TTL neither reads the usage ledger nor runs git log" {
  local real_grep real_git spy_bin marker before after
  real_grep=$(command -v grep)
  real_git=$(command -v git)
  spy_bin="$BATS_TEST_TMPDIR/spy-bin"
  marker="$BATS_TEST_TMPDIR/spy-marker"
  mkdir -p "$spy_bin"
  cat > "$spy_bin/grep" <<SPY
#!/usr/bin/env bash
case "\$*" in *usage.jsonl*) : > "$marker" ;; esac
exec "$real_grep" "\$@"
SPY
  cat > "$spy_bin/git" <<SPY
#!/usr/bin/env bash
for argument in "\$@"; do [ "\$argument" = log ] && : > "$marker"; done
exec "$real_git" "\$@"
SPY
  chmod +x "$spy_bin/grep" "$spy_bin/git"
  append_close_row 2026-01-15T00:00:00Z
  add_harness_commits 16

  # Positive control: a full refresh reads the ledger and runs git log, so the
  # spies do fire when the refresher does either.
  rm -f "$CACHE_FILE"
  run env HOME="$TEMPORARY_HOME" PATH="$spy_bin:$STUB_BIN:$PATH" bash "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh" < /dev/null
  [ "$status" -eq 0 ]
  [ -e "$marker" ]

  rm -f "$marker"
  before=$(cksum < "$CACHE_FILE")
  run env HOME="$TEMPORARY_HOME" PATH="$spy_bin:$STUB_BIN:$PATH" bash "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh" < /dev/null
  [ "$status" -eq 0 ]
  [ -e "$marker" ] && return 1
  after=$(cksum < "$CACHE_FILE")
  [ "$before" = "$after" ]
}

@test "a fitness start row alone leaves the commit nudge showing after the cache goes stale" {
  add_harness_commits 15
  refresh
  render_wide
  assert_fitness_nudge "(15 harness commits)"

  append_start_row 2026-03-01T00:00:00Z
  set_checked_at 0
  run_refresher
  [ "$(cache_value checkedAt)" -gt 0 ]
  render_wide
  assert_fitness_nudge "(15 harness commits)"
}

# ---------- basis staleness ----------

@test "a changed .gaia/VERSION recomputes inside the TTL and keeps the cache" {
  refresh
  set_version 1.0.1
  refresh_within_ttl
  assert_recomputed
  [ "$(cache_value fitnessBasisVersion)" = "1.0.1" ]
}

@test "a changed blend record alone does not recompute inside the TTL" {
  refresh
  seed_probe
  write_blend_record 2.0.4 2
  run_refresher
  assert_held
}

@test "a cache without the basis field recomputes once and then holds, even with no version file" {
  rm -f "$REPOSITORY_FIXTURE/.gaia/VERSION"
  refresh
  jq 'del(.fitnessBasisVersion)' "$CACHE_FILE" > "$CACHE_FILE.next"
  mv "$CACHE_FILE.next" "$CACHE_FILE"
  refresh_within_ttl
  assert_recomputed
  [ "$(jq -r 'has("fitnessBasisVersion")' "$CACHE_FILE")" = "true" ]
  refresh_within_ttl
  run_refresher
  assert_held
}

@test "an update bust keeps the basis and holds, while a pull bust and a version change recompute" {
  refresh
  seed_probe
  bust --mode gaia --version 1.0.0
  run_refresher
  assert_held

  bust --mode pull --version 1.0.0
  run_refresher
  assert_recomputed

  seed_probe
  set_version 1.0.2
  run_refresher
  assert_recomputed
}

@test "a blend record written before an update bust does not recompute before the TTL, and a record checksum in the gate would" {
  local before after record_gate
  refresh
  seed_probe
  write_blend_record 2.0.4 2
  bust --mode gaia --version 1.0.0
  before=$(jq -c '[.checkedAt, .gaiaCurrent, .gaiaLatest, .gaiaHasUpdate, .gaiaOriginVersion, .gaiaUpdateClaims]' "$CACHE_FILE")
  run_refresher
  after=$(jq -c '[.checkedAt, .gaiaCurrent, .gaiaLatest, .gaiaHasUpdate, .gaiaOriginVersion, .gaiaUpdateClaims]' "$CACHE_FILE")
  [ "$before" = "$after" ]
  assert_held

  # Refusal proof: a gate that also compares a checksum of the record undoes
  # the bust and recomputes.
  record_gate='if [ -f "$STATE_ROOT/.gaia/local/fitness/blend-record.json" ] && [ "$(cksum < "$STATE_ROOT/.gaia/local/fitness/blend-record.json")" != "$(jq -r ".fitnessRecordSum // \"\"" "$CACHE_FILE")" ]; then previous_checked_at=0; fi'
  mutated_copy check-updates-record-gate.sh '# TTL gate.' "$record_gate"$'\n# TTL gate.'
  run_refresher "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates-record-gate.sh"
  assert_recomputed
}

# ---------- carry-forward ----------

@test "a failing fitness CLI keeps every previous signal and still writes the basis" {
  add_harness_commits 16
  write_report B+ "[$(adopter_finding)]"
  refresh
  render_wide
  assert_fitness_nudge "(grade B+)"

  export FITNESS_EXIT=2
  set_version 1.0.1
  set_checked_at 0
  run_refresher
  [ "$(cache_value fitnessBasisVersion)" = "1.0.1" ]
  [ "$(cache_value fitnessGrade)" = "B+" ]
  [ "$(cache_value fitnessCommitCount)" = "16" ]
  render_wide
  assert_fitness_nudge "(grade B+)"

  seed_probe
  run_refresher
  assert_held
}

@test "a first refresh with no previous cache and a failing CLI shows no fitness nudge" {
  add_harness_commits 16
  export FITNESS_EXIT=2
  refresh
  [ "$(cache_value fitnessCommitCount)" = "0" ]
  render_wide
  assert_no_fitness_nudge
}

@test "a report whose inventory is all unknown keeps the previous grade and commit count" {
  add_harness_commits 15
  write_report B+ "[$(adopter_finding)]"
  refresh
  render_wide
  assert_fitness_nudge "(grade B+)"

  add_harness_commits 1
  write_report A
  jq '.inventory |= map(.ownership = "unknown")' "$FITNESS_REPORT_FIXTURE" > "$FITNESS_REPORT_FIXTURE.next"
  mv "$FITNESS_REPORT_FIXTURE.next" "$FITNESS_REPORT_FIXTURE"
  set_checked_at 0
  run_refresher
  [ "$(cache_value fitnessGrade)" = "B+" ]
  [ "$(cache_value fitnessCommitCount)" = "15" ]
  render_wide
  assert_fitness_nudge "(grade B+)"
}

@test "an unreadable usage ledger keeps the previous commit count rather than counting the whole history" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  add_harness_commits 20 2026-01-10T00:00:00Z
  append_close_row 2026-01-15T00:00:00Z
  add_harness_commits 16
  refresh
  render_wide
  assert_fitness_nudge "(16 harness commits)"

  add_harness_commits 1
  chmod 000 "$(ledger_file)"
  set_checked_at 0
  run_refresher
  [ "$(cache_value fitnessCommitCount)" = "16" ]
  render_wide
  assert_fitness_nudge "(16 harness commits)"
}

@test "a malformed blend record keeps the previous blend count and landed stamps" {
  set_version 2.0.4
  write_blend_record 2.0.4 2
  refresh
  render_wide
  assert_fitness_nudge "(2 blended files)"
  local landed
  landed=$(jq -c '.fitnessBlendLandedAt' "$CACHE_FILE")

  printf '{bad' > "$REPOSITORY_FIXTURE/.gaia/local/fitness/blend-record.json"
  set_checked_at 0
  run_refresher
  [ "$(cache_value fitnessBlendCount)" = "2" ]
  [ "$(jq -c '.fitnessBlendLandedAt' "$CACHE_FILE")" = "$landed" ]
  render_wide
  assert_fitness_nudge "(2 blended files)"
}

@test "a git log failure keeps the previous commit count" {
  local real_git failing_bin
  real_git=$(command -v git)
  failing_bin="$BATS_TEST_TMPDIR/failing-git-bin"
  mkdir -p "$failing_bin"
  cat > "$failing_bin/git" <<SPY
#!/usr/bin/env bash
for argument in "\$@"; do [ "\$argument" = log ] && exit 128; done
exec "$real_git" "\$@"
SPY
  chmod +x "$failing_bin/git"
  add_harness_commits 16
  refresh
  render_wide
  assert_fitness_nudge "(16 harness commits)"

  add_harness_commits 1
  set_checked_at 0
  run env HOME="$TEMPORARY_HOME" PATH="$failing_bin:$STUB_BIN:$PATH" bash "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh" < /dev/null
  [ "$status" -eq 0 ]
  [ "$(cache_value fitnessCommitCount)" = "16" ]
  render_wide
  assert_fitness_nudge "(16 harness commits)"
}

@test "a torn ledger line is skipped and the newer close row anchors the count" {
  add_harness_commits 18 2026-03-15T00:00:00Z
  append_close_row 2026-03-01T00:00:00Z
  refresh
  render_wide
  assert_fitness_nudge "(18 harness commits)"

  append_ledger_row '{"ts":"2026-03-20T00:00:00Z","workflow":"gaia-fitness","type":"cl'
  append_close_row 2026-04-01T00:00:00Z
  add_harness_commits 2 2026-05-01T00:00:00Z
  set_checked_at 0
  run_refresher
  [ "$(cache_value fitnessCommitCount)" = "2" ]
  render_wide
  assert_no_fitness_nudge

  add_harness_commits 15 2026-05-10T00:00:00Z
  set_checked_at 0
  run_refresher
  render_wide
  assert_fitness_nudge "(17 harness commits)"

  append_close_row 2026-06-01T00:00:00Z
  bust --mode fitness
  run_refresher
  render_wide
  assert_no_fitness_nudge
}

# ---------- main checkout pinning ----------

@test "a refresher run from a linked worktree counts the main checkout and asks the CLI about it" {
  local worktree="$REPOSITORY_FIXTURE/.claude/worktrees/wt"
  write_report B+ "[$(adopter_finding)]"
  add_harness_commits 3
  git -C "$REPOSITORY_FIXTURE" worktree add --quiet "$worktree" -b wt
  COMMIT_REPO="$worktree"
  add_harness_commits 16
  export FITNESS_CLI_LOG="$BATS_TEST_TMPDIR/cli.log"
  : > "$FITNESS_CLI_LOG"

  rm -f "$CACHE_FILE"
  run_refresher "$worktree/.gaia/scripts/check-updates.sh"
  [ "$(cache_value fitnessCommitCount)" = "3" ]
  [ "$(cache_value fitnessGrade)" = "B+" ]
  grep -qF -- "--root $REPOSITORY_FIXTURE" "$FITNESS_CLI_LOG"
  [ ! -e "$worktree/.gaia/local/cache/shared/update-check.json" ]
}

# ---------- acceptance scenarios, refresher to render ----------

@test "fifteen harness commits since the last run arm the nudge and fourteen do not" {
  add_harness_commits 14
  refresh
  render_wide
  assert_no_fitness_nudge

  add_harness_commits 1
  refresh
  render_wide
  assert_fitness_nudge "(15 harness commits)"
}

@test "an adopter finding under a non-budget rule shows the grade ahead of a blended file and the commits" {
  write_report B+ "[$(adopter_finding authoring.path.windows-separator)]"
  write_blend_record 1.0.0 1
  add_harness_commits 16
  refresh
  render_wide
  assert_fitness_nudge "(grade B+)"
}

@test "findings only in the GAIA-shipped list leave a few commits unnudged" {
  write_report C "[]" "[$(shipped_finding)]"
  add_harness_commits 3
  refresh
  render_wide
  assert_no_fitness_nudge
}

@test "a fitness run-end bust clears the commit nudge on the next refresh that keeps the cache" {
  add_harness_commits 16
  refresh
  render_wide
  assert_fitness_nudge "(16 harness commits)"

  seed_probe
  append_close_row 2026-03-01T00:00:00Z
  bust --mode fitness
  run_refresher
  assert_recomputed
  [ "$(cache_value checkedAt)" -gt 0 ]
  render_wide
  assert_no_fitness_nudge
}

@test "scaffold, init and update commits stay out of the count in a whole-history walk" {
  commit_touching "$COMMIT_WHEN" "chore: initialize project with /gaia-init" .claude/rules/init.md
  add_harness_commits 16
  commit_touching "$COMMIT_WHEN" "chore(gaia): update to v1.1.0 (#12)" .claude/rules/update-squash.md
  git -C "$REPOSITORY_FIXTURE" checkout --quiet -b update-branch
  commit_touching "$COMMIT_WHEN" "chore(gaia): update to v1.2.0" .claude/rules/update-branch.md
  git -C "$REPOSITORY_FIXTURE" checkout --quiet main
  GIT_AUTHOR_DATE="$COMMIT_WHEN" GIT_COMMITTER_DATE="$COMMIT_WHEN" \
    git -C "$REPOSITORY_FIXTURE" merge --quiet --no-ff update-branch -m "Merge branch update-branch"
  refresh
  render_wide
  assert_fitness_nudge "(16 harness commits)"
}

@test "a fresh project whose harness commits are all scaffold, init and update commits shows no nudge" {
  local index
  commit_touching "$COMMIT_WHEN" "chore: initialize project with /gaia-init" .claude/rules/init.md
  for index in $(seq 1 15); do
    commit_touching "$COMMIT_WHEN" "chore(gaia): update to v1.0.$index" ".claude/rules/update-$index.md"
  done
  refresh
  [ "$(cache_value fitnessCommitCount)" = "0" ]
  render_wide
  assert_no_fitness_nudge
}

@test "a history of 2.0.0 migration commits plus a few team commits shows no nudge" {
  local subject index=0
  local -a migration_subjects=(
    "chore: re-render code-review-audit.yml for v1.6.1"
    "chore: audit roster check"
    "chore: bump pnpm and Node for GAIA 2.0.0"
    "chore: drop the root React Doctor skill copy"
    "chore: meet @gaia-react/lint 3.0.0 rules"
    "chore: merge the GAIA 2.0.0 frontend"
    "chore: merge the GAIA 2.0.0 harness and split the workspace"
    "chore: point references at frontend/"
    "chore: upgrade to GAIA 2.0.0"
  )
  for subject in "${migration_subjects[@]}"; do
    index=$((index + 1))
    commit_touching "$COMMIT_WHEN" "$subject" ".claude/rules/migration-$index.md"
  done
  for index in 1 2 3 4 5 6 7; do
    commit_touching "$COMMIT_WHEN" "chore: update GAIA to v1.6.$index" ".claude/rules/legacy-$index.md"
  done
  add_harness_commits 3
  refresh
  [ "$(cache_value fitnessCommitCount)" = "3" ]
  render_wide
  assert_no_fitness_nudge
}

@test "wiki-only commits never count and a commit touching a wiki page and a harness file counts once" {
  local index
  for index in $(seq 1 20); do
    commit_touching "$COMMIT_WHEN" "docs: wiki edit $index" wiki/page.md
  done
  refresh
  [ "$(cache_value fitnessCommitCount)" = "0" ]
  render_wide
  assert_no_fitness_nudge

  write_project_config '{"fitness_commit_threshold":1}'
  commit_touching "$COMMIT_WHEN" "docs: wiki and rule" wiki/page.md .claude/rules/r1.md
  refresh
  render_wide
  assert_fitness_nudge "(1 harness commit)"
}

@test "the grade nudge survives a close row when the finding is unchanged" {
  write_report B+ "[$(adopter_finding)]"
  refresh
  render_wide
  assert_fitness_nudge "(grade B+)"

  append_close_row 2026-03-01T00:00:00Z
  bust --mode fitness
  run_refresher
  render_wide
  assert_fitness_nudge "(grade B+)"
}

@test "a record entry for a version main has not reached raises no blend reason" {
  write_blend_record 2.0.4 2
  refresh
  [ "$(cache_value fitnessBlendCount)" = "0" ]
  render_wide
  assert_no_fitness_nudge
}

@test "a blend nudge clears after a close row dated after its landing stamp, a bust and a refresh" {
  local stamp
  set_version 2.0.4
  write_blend_record 2.0.4 2
  refresh
  render_wide
  assert_fitness_nudge "(2 blended files)"

  stamp=$(cache_value 'fitnessBlendLandedAt["2.0.4"]')
  append_close_row "$(iso_from_epoch $((stamp + 60)))"
  bust --mode fitness
  run_refresher
  [ "$(cache_value fitnessBlendCount)" = "0" ]
  render_wide
  assert_no_fitness_nudge
}

@test "a record for a version main reaches later raises the blend nudge once the version file changes" {
  write_blend_record 2.0.4 2
  refresh
  render_wide
  assert_no_fitness_nudge

  set_version 2.0.4
  refresh_within_ttl
  assert_recomputed
  render_wide
  assert_fitness_nudge "(2 blended files)"
}

@test "a landed blend keeps counting when the version file moves past it" {
  set_version 2.0.4
  write_blend_record 2.0.4 2
  refresh
  render_wide
  assert_fitness_nudge "(2 blended files)"

  set_version 2.0.5
  refresh_within_ttl
  assert_recomputed
  render_wide
  assert_fitness_nudge "(2 blended files)"
}

@test "a close row from before a blend landed does not answer it, and a later one does" {
  local stamp
  set_version 2.0.3
  write_blend_record 2.0.4 2
  refresh
  render_wide
  assert_no_fitness_nudge

  append_close_row "$(iso_from_epoch $(($(date +%s) - 3600)))"
  set_version 2.0.4
  refresh_within_ttl
  assert_recomputed
  render_wide
  assert_fitness_nudge "(2 blended files)"

  stamp=$(cache_value 'fitnessBlendLandedAt["2.0.4"]')
  append_close_row "$(iso_from_epoch $((stamp + 60)))"
  bust --mode fitness
  run_refresher
  render_wide
  assert_no_fitness_nudge
}

@test "a configured threshold of 25 holds the nudge until 25 commits" {
  write_project_config '{"fitness_commit_threshold":25}'
  add_harness_commits 20
  refresh
  render_wide
  assert_no_fitness_nudge

  add_harness_commits 5
  refresh
  render_wide
  assert_fitness_nudge "(25 harness commits)"
}

@test "a zero, negative, fractional, string or unparsable threshold falls back to 15" {
  local value
  add_harness_commits 15
  for value in '{"fitness_commit_threshold":0}' '{"fitness_commit_threshold":-3}' \
    '{"fitness_commit_threshold":15.5}' '{"fitness_commit_threshold":"25"}' '{not json'; do
    write_project_config "$value"
    refresh
    render_wide
    assert_fitness_nudge "(15 harness commits)"
  done
}

@test "an over-budget CLAUDE.md alone raises the cleanse nudge and no fitness nudge" {
  write_report B "[$(adopter_finding claudemd.budget error)]"
  refresh
  render_wide
  assert_no_fitness_nudge
  grep -qF -- "/gaia-cleanse (over budget)" <<<"$plain"
}

@test "a budget error beside another adopter finding shows the unchanged grade and still raises the cleanse nudge" {
  write_report B- "[$(adopter_finding claudemd.budget error),$(adopter_finding authoring.path.windows-separator)]"
  refresh
  render_wide
  assert_fitness_nudge "(grade B-)"
  grep -qF -- "/gaia-cleanse (over budget)" <<<"$plain"
}

@test "a single info finding shows grade A and keeps showing it after a close row" {
  write_report A "[$(adopter_finding authoring.content.time-sensitive info)]"
  refresh
  render_wide
  assert_fitness_nudge "(grade A)"

  append_close_row 2026-03-01T00:00:00Z
  bust --mode fitness
  run_refresher
  render_wide
  assert_fitness_nudge "(grade A)"
}

@test "harness commits count and application commits do not" {
  write_report A "[]" "[]" '[{"path":"frontend/CLAUDE.md","kinds":["claudemd"],"ownership":"adopter"}]'
  add_harness_commits 14
  add_app_commits 5
  refresh
  render_wide
  assert_no_fitness_nudge

  commit_touching "$COMMIT_WHEN" "docs: frontend instructions" frontend/CLAUDE.md
  refresh
  render_wide
  assert_fitness_nudge "(15 harness commits)"
}

@test "a fresh clone counts its own history against its own ledger" {
  local clone="$FIXTURE_PARENT/clone"
  add_harness_commits 16
  append_close_row 2026-03-01T00:00:00Z
  git clone --quiet -- "$REPOSITORY_FIXTURE" "$clone"
  git -C "$clone" config user.email "test@example.com"
  git -C "$clone" config user.name "Test"
  mkdir -p "$clone/.gaia/local"
  cp "$REPOSITORY_FIXTURE/.gaia/local/setup-state.json" "$clone/.gaia/local/setup-state.json"
  REPOSITORY_FIXTURE="$clone"
  RENDER_ROOT="$clone"
  CACHE_FILE="$clone/.gaia/local/cache/shared/update-check.json"

  refresh
  render_wide
  assert_fitness_nudge "(16 harness commits)"

  append_close_row 2026-03-02T00:00:00Z
  bust --mode fitness
  run_refresher
  render_wide
  assert_no_fitness_nudge
}

@test "a classifier failure keeps the commit nudge showing and arms no grade" {
  local failing_classifier="$BATS_TEST_TMPDIR/failing-classifier.sh"
  use_real_bundle
  add_harness_commits 15
  refresh
  render_wide
  assert_fitness_nudge "(15 harness commits)"
  # The same tree reports adopter ownership while the classifier works.
  run env HOME="$TEMPORARY_HOME" "$REPO_ROOT/.gaia/cli/gaia" fitness check --json --root "$REPOSITORY_FIXTURE" < /dev/null
  [ "$(printf '%s' "$output" | jq -r '[.inventory[].ownership] | unique | join(",")')" = "adopter" ]

  printf '#!/usr/bin/env bash\nexit 1\n' > "$failing_classifier"
  export GAIA_FITNESS_OWNERSHIP_CLASSIFIER="$failing_classifier"
  add_harness_commits 1
  set_checked_at 0
  run_refresher
  [ "$(cache_value fitnessGrade)" = "" ]
  [ "$(cache_value fitnessCommitCount)" = "15" ]
  render_wide
  assert_fitness_nudge "(15 harness commits)"
}

@test "a grade nudge clears once its only finding is suppressed with a reason" {
  use_real_bundle
  commit_touching "$COMMIT_WHEN" "docs: windows path" .claude/rules/windows.md
  printf '# Rule\n\nSee src\\app\\main.ts for details.\n' > "$REPOSITORY_FIXTURE/.claude/rules/windows.md"
  refresh
  [ -n "$(cache_value fitnessGrade)" ]
  render_wide
  assert_fitness_nudge "(grade $(cache_value fitnessGrade))"

  printf '{"version":1,"ignore":[{"rule_id":"authoring.path.windows-separator","path":".claude/rules/windows.md","reason":"kept on purpose"}]}' \
    > "$REPOSITORY_FIXTURE/.claude/gaia-fitness.json"
  # The CLI reads suppressions only from a tracked config file.
  git -C "$REPOSITORY_FIXTURE" add -- .claude/gaia-fitness.json
  GIT_AUTHOR_DATE="$COMMIT_WHEN" GIT_COMMITTER_DATE="$COMMIT_WHEN" \
    git -C "$REPOSITORY_FIXTURE" commit --quiet -m "chore: suppress a windows path finding"
  set_checked_at 0
  run_refresher
  [ "$(cache_value fitnessGrade)" = "" ]
  render_wide
  assert_no_fitness_nudge
}

@test "a grade nudge clears once its only finding is fixed" {
  use_real_bundle
  commit_touching "$COMMIT_WHEN" "docs: windows path" .claude/rules/windows.md
  printf '# Rule\n\nSee src\\app\\main.ts for details.\n' > "$REPOSITORY_FIXTURE/.claude/rules/windows.md"
  refresh
  [ -n "$(cache_value fitnessGrade)" ]
  render_wide
  assert_fitness_nudge "(grade $(cache_value fitnessGrade))"

  printf '# Rule\n\nSee src/app/main.ts for details.\n' > "$REPOSITORY_FIXTURE/.claude/rules/windows.md"
  set_checked_at 0
  run_refresher
  [ "$(cache_value fitnessGrade)" = "" ]
  render_wide
  assert_no_fitness_nudge
}

# ---------- a bust during an in-flight refresh ----------

# start_blocked_refresh <script> <hold-file>: starts a refresh in the
# background whose `gh` stub blocks until <hold-file> is removed. `gh` runs
# after the refresher has read the ledger, so the refresh is past its reads
# when the caller busts the cache. Sets $blocked_pid.
start_blocked_refresh() {
  : > "$2"
  env HOME="$TEMPORARY_HOME" PATH="$STUB_BIN:$PATH" GH_HOLD_FILE="$2" bash "$1" < /dev/null > /dev/null 2>&1 &
  blocked_pid=$!
  local waited=0
  while [ ! -e "$2.started" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$2.started" ]
}

# race_scenario <script>: a showing commit nudge, a refresh that reads the
# ledger and blocks, a close row plus the run-end bust landing meanwhile, then
# the refresh finishing. Leaves the cache's checkedAt in $race_checked_at.
race_scenario() {
  local hold_file="$BATS_TEST_TMPDIR/gh-hold"
  rm -f "$(ledger_file)" "$hold_file" "$hold_file.started"
  append_close_row 2026-01-15T00:00:00Z
  refresh
  set_checked_at $(($(date +%s) - 30000))
  start_blocked_refresh "$1" "$hold_file"
  append_close_row 2026-03-01T00:00:00Z
  bust --mode fitness
  rm -f "$hold_file"
  wait "$blocked_pid"
  race_checked_at=$(cache_value checkedAt)
}

@test "a close row and bust landing during an in-flight refresh leave the cache stale so the next refresh clears the nudge" {
  add_harness_commits 16
  race_scenario "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh"
  [ "$race_checked_at" = "0" ]
  run_refresher
  render_wide
  assert_no_fitness_nudge
}

@test "the pre-write bust check alone holds checkedAt at zero when the cache fingerprint check is out of play" {
  add_harness_commits 16
  mutated_copy check-updates-no-fingerprint.sh \
    'if [ "$(cache_fingerprint)" != "$cache_fingerprint_before" ]; then' 'if false; then'
  race_scenario "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates-no-fingerprint.sh"
  [ "$race_checked_at" = "0" ]

  # Refusal proof: without the pre-write check the same race stamps a fresh
  # checkedAt over the bust.
  mutated_copy check-updates-no-bust-check.sh \
    '  && [ "$cache_checked_at_before" != "0" ] \' '  && [ "$cache_checked_at_before" = "never" ] \' \
    "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates-no-fingerprint.sh"
  race_scenario "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates-no-bust-check.sh"
  [ "$race_checked_at" -gt 0 ]
}
