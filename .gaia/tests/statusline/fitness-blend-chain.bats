#!/usr/bin/env bats

# The blended-update path of the /gaia-fitness nudge, chained end to end: the
# real blend-record writer (what the update skill's recording step runs), the
# real background refresher, and the real statusline. Each unit has its own
# suite against hand-written inputs; this suite proves the three agree when one
# feeds the next.
#
# The fixture is a throwaway main-checkout git repository holding the refresher,
# the writer, the signal library, the cache bust and the statusline, with a
# `gaia` wrapper that answers each subcommand the refresher calls with an inert
# stub. Its `fitness check` prints $FITNESS_REPORT_FIXTURE: an adopter-scope
# report with no adopter findings and an inventory naming the fixture's harness
# files. A linked worktree of the fixture is the acting tree of the simulated
# update, so the writer is called the way the update skill calls it: from the
# main checkout, with --tree the worktree and --main-root the main checkout.
# One simulated update is: write the merge report and decisions, run the writer,
# land the update on the main checkout (version file, committed), refresh, render.
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/statusline/fitness-blend-chain.bats < /dev/null

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v git >/dev/null 2>&1 || skip "git required"

  TEMPORARY_HOME=$(mktemp -d -t gaia-blend-chain-home-XXXXXX)
  FIXTURE_PARENT=$(mktemp -d -t gaia-blend-chain-fix-XXXXXX)
  MAIN_CHECKOUT="$FIXTURE_PARENT/main-checkout"
  mkdir -p "$MAIN_CHECKOUT"
  MAIN_CHECKOUT=$(cd "$MAIN_CHECKOUT" && pwd -P)
  ACTING_TREE="$FIXTURE_PARENT/update-tree"
  RUN_DIRECTORY="$BATS_TEST_TMPDIR/run"
  mkdir -p "$RUN_DIRECTORY"
  COMMIT_SEQUENCE=1
  COMMIT_WHEN="2026-02-01T12:00:00Z"
  CACHE_FILE="$MAIN_CHECKOUT/.gaia/local/cache/shared/update-check.json"
  RECORD_FILE="$MAIN_CHECKOUT/.gaia/local/fitness/blend-record.json"
  LEDGER_FILE="$MAIN_CHECKOUT/.gaia/local/telemetry/usage.jsonl"

  git -C "$MAIN_CHECKOUT" init --quiet --initial-branch=main
  git -C "$MAIN_CHECKOUT" config user.email "test@example.com"
  git -C "$MAIN_CHECKOUT" config user.name "Test"
  git -C "$MAIN_CHECKOUT" config commit.gpgsign false
  printf '.gaia/local/\n' >> "$MAIN_CHECKOUT/.git/info/exclude"
  mkdir -p "$MAIN_CHECKOUT/.gaia/scripts" "$MAIN_CHECKOUT/.gaia/cli" \
    "$MAIN_CHECKOUT/.gaia/statusline" "$MAIN_CHECKOUT/.gaia/local/cache/shared" \
    "$MAIN_CHECKOUT/.claude/rules" "$MAIN_CHECKOUT/wiki"
  for script_name in check-updates.sh main-root-lib.sh knowledge-inventory.sh \
    fitness-nudge-lib.sh fitness-blend-record.sh update-check-bust.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$script_name" "$MAIN_CHECKOUT/.gaia/scripts/$script_name"
  done
  chmod -x "$MAIN_CHECKOUT/.gaia/scripts/check-updates.sh"
  cp "$REPO_ROOT/.gaia/statusline/gaia-statusline.sh" "$MAIN_CHECKOUT/.gaia/statusline/gaia-statusline.sh"
  cp "$REPO_ROOT/.gaia/statusline/gaia-statusline-right.sh" "$MAIN_CHECKOUT/.gaia/statusline/gaia-statusline-right.sh"

  cat > "$MAIN_CHECKOUT/.gaia/cli/gaia" <<'WRAPPER'
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
    if [ "$2" = "check" ]; then
      cat "$FITNESS_REPORT_FIXTURE"
      exit 0
    fi
    exit 1
    ;;
  *) exit 1 ;;
esac
WRAPPER
  chmod +x "$MAIN_CHECKOUT/.gaia/cli/gaia"
  FITNESS_REPORT_FIXTURE="$BATS_TEST_TMPDIR/report.json"
  export FITNESS_REPORT_FIXTURE
  unset FITNESS_EXIT FITNESS_USE_REAL_BUNDLE FITNESS_CLI_LOG GAIA_FITNESS_OWNERSHIP_CLASSIFIER

  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_BIN/gh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_BIN/curl"
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/curl"

  printf '2.0.3\n' > "$MAIN_CHECKOUT/.gaia/VERSION"
  printf 'seed\n' > "$MAIN_CHECKOUT/wiki/index.md"
  printf 'short project instructions\n' > "$MAIN_CHECKOUT/CLAUDE.md"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$MAIN_CHECKOUT/.gaia/local/setup-state.json"
  git -C "$MAIN_CHECKOUT" add -A
  GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
    git -C "$MAIN_CHECKOUT" commit --quiet -m "chore: scaffold from GAIA 2.0.0"
  git -C "$MAIN_CHECKOUT" worktree add --quiet -b update-branch "$ACTING_TREE"
}

teardown() {
  [ -n "${FIXTURE_PARENT:-}" ] && rm -rf "$FIXTURE_PARENT" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# ---------- fixture builders ----------

# write_fitness_report <harness-path>...: the report the stub CLI prints. The
# inventory holds each given path as an adopter rule plus one wiki page; no
# findings, so the grade reason stays unarmed.
write_fitness_report() {
  local paths_json
  paths_json=$(printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  jq -n --argjson paths "$paths_json" '{
      overall: "A", findings: [], upstream: [],
      inventory: ([$paths[] | {path: ., kinds: ["rule"], ownership: "adopter"}]
                  + [{path: "wiki/page.md", kinds: ["wiki"], ownership: "adopter"}])
    }' > "$FITNESS_REPORT_FIXTURE"
}

# write_merge_report: stdin lines `path status` become the update's merge report.
write_merge_report() {
  jq -R -s '
    {schemaVersion: 1, files: (split("\n") | map(select(length > 0) | split(" ")
      | {path: .[0], status: .[1]}))}' > "$RUN_DIRECTORY/report.json"
}

# write_decisions <tag> <path:decision>...: the update's decisions file, one
# keyless entry per argument.
write_decisions() {
  local tag="$1" pair
  shift
  for pair in "$@"; do printf '%s\n' "$pair"; done | jq -R -s --arg tag "$tag" '
    {schemaVersion: 1, decisions: (split("\n") | map(select(length > 0) | split(":")
      | {path: .[0], decision: .[1], tag: $tag}))}' > "$RUN_DIRECTORY/update-decisions.json"
}

# commit_team_change <path>: one team commit in the main checkout.
commit_team_change() {
  mkdir -p "$(dirname "$MAIN_CHECKOUT/$1")"
  printf '# Rule\n\nchange %s\n' "$COMMIT_SEQUENCE" > "$MAIN_CHECKOUT/$1"
  COMMIT_SEQUENCE=$((COMMIT_SEQUENCE + 1))
  git -C "$MAIN_CHECKOUT" add -- "$1"
  GIT_AUTHOR_DATE="$COMMIT_WHEN" GIT_COMMITTER_DATE="$COMMIT_WHEN" \
    git -C "$MAIN_CHECKOUT" commit --quiet -m "feat: team harness change $COMMIT_SEQUENCE"
}

# add_team_commits <n>: n team commits, each touching its own rule file.
add_team_commits() {
  local index
  for ((index = 1; index <= $1; index++)); do
    commit_team_change ".claude/rules/team-$COMMIT_SEQUENCE.md"
  done
}

iso_from_epoch() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

append_close_row() {
  mkdir -p "$(dirname "$LEDGER_FILE")"
  printf '{"ts":"%s","workflow":"gaia-fitness","type":"close","kind":"binding","outcome":"done"}\n' \
    "$(iso_from_epoch "$1")" >> "$LEDGER_FILE"
}

# ---------- the simulated update ----------

# run_writer <tag>: the main checkout's writer, called the way the update
# skill's recording step calls it.
run_writer() {
  run env HOME="$TEMPORARY_HOME" bash "$MAIN_CHECKOUT/.gaia/scripts/fitness-blend-record.sh" record \
    --main-root "$MAIN_CHECKOUT" --tree "$ACTING_TREE" \
    --report "$RUN_DIRECTORY/report.json" --decisions "$RUN_DIRECTORY/update-decisions.json" --tag "$1"
  [ "$status" -eq 0 ]
}

# land_update <tag> <pull-request-number>: the update reaches the main checkout.
land_update() {
  printf '%s\n' "${1#v}" > "$MAIN_CHECKOUT/.gaia/VERSION"
  git -C "$MAIN_CHECKOUT" add .gaia/VERSION
  git -C "$MAIN_CHECKOUT" commit --quiet -m "chore(gaia): update to $1 (#$2)"
}

run_refresher() {
  run env HOME="$TEMPORARY_HOME" PATH="$STUB_BIN:$PATH" bash "$MAIN_CHECKOUT/.gaia/scripts/check-updates.sh" < /dev/null
  [ "$status" -eq 0 ]
}

# refresh: a first refresh, the cache deleted beforehand.
refresh() {
  rm -f "$CACHE_FILE"
  run_refresher
}

# render_wide: sets $plain to the wide rendered line with colors stripped.
render_wide() {
  local json
  json=$(jq -n --arg current_directory "$MAIN_CHECKOUT" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TEMPORARY_HOME" COLUMNS=400 bash -c "printf '%s' '$json' | bash '$MAIN_CHECKOUT/.gaia/statusline/gaia-statusline.sh'" < /dev/null
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
}

assert_fitness_nudge() {
  grep -qF -- "/gaia-fitness $1" <<<"$plain" || { printf 'missing "/gaia-fitness %s" in: %s\n' "$1" "$plain" >&2; return 1; }
}

assert_no_fitness_nudge() {
  grep -qF -- "/gaia-fitness" <<<"$plain" && { printf 'unexpected nudge in: %s\n' "$plain" >&2; return 1; }
  true
}

record_entry_count() {
  jq '.entries | length' "$RECORD_FILE"
}

# A v2.0.4 update that blended three harness files: two clean both-sides merges
# and one open item answered Combine. The fixture's report names all of them and
# one team-owned rule that the team's commits touch.
blend_three_files() {
  write_fitness_report .claude/rules/blend-a.md .claude/rules/blend-b.md \
    .claude/rules/blend-c.md .claude/rules/team-owned.md
  {
    printf '%s\n' \
      '.claude/rules/blend-a.md auto-merged' \
      '.claude/rules/blend-b.md auto-merged' \
      '.claude/rules/blend-c.md open'
  } | write_merge_report
  write_decisions v2.0.4 .claude/rules/blend-c.md:blend
}

# ---------- criteria ----------

@test "a blended update shows the blended count whatever the harness commit count" {
  blend_three_files
  add_team_commits 20

  run_writer v2.0.4
  [ "$output" = "RECORDED 3" ]
  [ "$(record_entry_count)" -eq 3 ]
  land_update v2.0.4 12
  refresh

  [ "$(jq -r '.fitnessBlendCount' "$CACHE_FILE")" -eq 3 ]
  [ "$(jq -r '.fitnessCommitCount' "$CACHE_FILE")" -ge 15 ]
  render_wide
  assert_fitness_nudge "(3 blended files)"
  grep -qF -- "harness commits" <<<"$plain" && return 1
  true
}

@test "an update with only non-blending outcomes never arms the nudge" {
  write_fitness_report .claude/rules/overwritten.md .claude/rules/kept.md \
    .claude/rules/taken.md .claude/rules/added.md .claude/rules/team-owned.md
  {
    printf '%s\n' \
      '.claude/rules/overwritten.md overwrite' \
      '.claude/rules/kept.md open' \
      '.claude/rules/taken.md open' \
      '.claude/rules/added.md add'
  } | write_merge_report
  write_decisions v2.0.4 .claude/rules/kept.md:keep .claude/rules/taken.md:gaia
  add_team_commits 3

  run_writer v2.0.4
  [ "$output" = "UNCHANGED 0" ]
  [ -e "$RECORD_FILE" ] && return 1
  land_update v2.0.4 12
  refresh

  [ "$(jq -r '.fitnessBlendCount' "$CACHE_FILE")" -eq 0 ]
  render_wide
  assert_no_fitness_nudge
}

@test "an update that never landed is dropped by the next update's record" {
  write_fitness_report .claude/rules/never-landed-a.md .claude/rules/never-landed-b.md \
    .claude/rules/landed.md
  {
    printf '%s\n' \
      '.claude/rules/never-landed-a.md auto-merged' \
      '.claude/rules/never-landed-b.md auto-merged'
  } | write_merge_report
  write_decisions v2.0.4
  run_writer v2.0.4
  [ "$output" = "RECORDED 2" ]

  printf '.claude/rules/landed.md auto-merged\n' | write_merge_report
  write_decisions v2.0.5
  run_writer v2.0.5
  [ "$output" = "RECORDED 1" ]
  [ "$(record_entry_count)" -eq 1 ]
  land_update v2.0.5 13
  refresh

  render_wide
  assert_fitness_nudge "(1 blended file)"
  [ "$(record_entry_count)" -eq 1 ]
  [ "$(jq -r '.entries[0].path' "$RECORD_FILE")" = ".claude/rules/landed.md" ]
  [ "$(jq -r '.entries[0].version' "$RECORD_FILE")" = "2.0.5" ]
}

@test "a fitness run clears the blended nudge and the next update's record drops the answered entries" {
  blend_three_files
  run_writer v2.0.4
  [ "$output" = "RECORDED 3" ]
  land_update v2.0.4 12
  refresh
  render_wide
  assert_fitness_nudge "(3 blended files)"

  local landed_at
  landed_at=$(jq -r '.fitnessBlendLandedAt["2.0.4"]' "$CACHE_FILE")
  [ "$landed_at" -gt 0 ]
  append_close_row $((landed_at + 1))
  run bash "$MAIN_CHECKOUT/.gaia/scripts/update-check-bust.sh" --cache "$CACHE_FILE" --mode fitness
  [ "$status" -eq 0 ]
  run_refresher

  [ "$(jq -r '.fitnessBlendCount' "$CACHE_FILE")" -eq 0 ]
  render_wide
  assert_no_fitness_nudge

  printf '.claude/rules/overwritten.md overwrite\n' | write_merge_report
  write_decisions v2.0.5
  run_writer v2.0.5
  [ "$output" = "RECORDED 0" ]
  [ "$(record_entry_count)" -eq 0 ]
}

@test "defeating the harness filter leaves the blend unrecorded and the nudge dark" {
  # The three blended paths are absent from the inventory, so the writer's
  # harness filter drops them. This is the blended-update case above with only
  # that input changed.
  blend_three_files
  write_fitness_report .claude/rules/team-owned.md
  add_team_commits 20

  run_writer v2.0.4
  [ "$output" = "UNCHANGED 0" ]
  [ -e "$RECORD_FILE" ] && return 1
  land_update v2.0.4 12
  refresh

  [ "$(jq -r '.fitnessBlendCount' "$CACHE_FILE")" -eq 0 ]
  render_wide
  grep -qF -- "blended" <<<"$plain" && return 1
  true
}
