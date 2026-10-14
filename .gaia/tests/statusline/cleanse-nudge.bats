#!/usr/bin/env bats

# The /gaia-cleanse nudge's drift signals (.gaia/scripts/check-updates.sh):
# the last-cleanse anchor read from the newest applied report under
# .gaia/local/cleanse/, the one-time move of reports out of .gaia/local/audit/,
# and the memory count taken from the CLI inventory.
#
# The fixture is a real main-checkout git repository holding copies of the real
# refresher, main-root-lib.sh and knowledge-inventory.sh, with a `gaia` wrapper
# that answers every subcommand the refresher calls with an inert stub, except
# `fitness`, which runs the committed CLI bundle. HOME is
# a throwaway directory, so no real machine state is read or written. The
# assertions read the cache keys the statusline reads.
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/statusline/cleanse-nudge.bats < /dev/null

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  command -v jq >/dev/null 2>&1 || skip "jq required"

  TEMPORARY_HOME=$(mktemp -d -t gaia-cleanse-nudge-home-XXXXXX)
  FIXTURE_PARENT=$(mktemp -d -t gaia-cleanse-nudge-fix-XXXXXX)
  # A dot in the root's own name is what the memory directory key must survive.
  REPOSITORY_FIXTURE="$FIXTURE_PARENT/root.with.dots"
  mkdir -p "$REPOSITORY_FIXTURE"
  # Physical path: the refresher keys the memory directory on the resolved root.
  REPOSITORY_FIXTURE=$(cd "$REPOSITORY_FIXTURE" && pwd -P)

  git -C "$REPOSITORY_FIXTURE" init --quiet --initial-branch=main
  git -C "$REPOSITORY_FIXTURE" config user.email "test@example.com"
  git -C "$REPOSITORY_FIXTURE" config user.name "Test"
  git -C "$REPOSITORY_FIXTURE" config commit.gpgsign false
  printf '.gaia/local/\n' >> "$REPOSITORY_FIXTURE/.git/info/exclude"
  mkdir -p "$REPOSITORY_FIXTURE/.gaia/scripts" "$REPOSITORY_FIXTURE/.gaia/cli" \
    "$REPOSITORY_FIXTURE/.gaia/local/cache/shared" "$REPOSITORY_FIXTURE/.gaia/local/audit" \
    "$REPOSITORY_FIXTURE/.claude/rules" "$REPOSITORY_FIXTURE/wiki"
  cp "$REPO_ROOT/.gaia/scripts/check-updates.sh" "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$REPOSITORY_FIXTURE/.gaia/scripts/main-root-lib.sh"
  cp "$REPO_ROOT/.gaia/scripts/knowledge-inventory.sh" "$REPOSITORY_FIXTURE/.gaia/scripts/knowledge-inventory.sh"
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
    exec "$GAIA_TEST_FITNESS_BUNDLE" "$@"
    ;;
  *) exit 1 ;;
esac
WRAPPER
  chmod +x "$REPOSITORY_FIXTURE/.gaia/cli/gaia"
  export GAIA_TEST_FITNESS_BUNDLE="$REPO_ROOT/.gaia/cli/gaia"
  printf '1.0.0\n' > "$REPOSITORY_FIXTURE/.gaia/VERSION"
  printf 'seed\n' > "$REPOSITORY_FIXTURE/wiki/index.md"
  printf 'short project instructions\n' > "$REPOSITORY_FIXTURE/CLAUDE.md"
  printf '# Rule\n\nOne short rule.\n' > "$REPOSITORY_FIXTURE/.claude/rules/short.md"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$REPOSITORY_FIXTURE/.gaia/local/setup-state.json"
  git -C "$REPOSITORY_FIXTURE" add -A
  git -C "$REPOSITORY_FIXTURE" commit --quiet -m "chore: fixture"

  CACHE_FILE="$REPOSITORY_FIXTURE/.gaia/local/cache/shared/update-check.json"
  MEMORY_DIRECTORY="$TEMPORARY_HOME/.claude/projects/$(printf %s "$REPOSITORY_FIXTURE" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
}

teardown() {
  [ -n "${FIXTURE_PARENT:-}" ] && rm -rf "$FIXTURE_PARENT" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

cache_value() {
  jq -r ".$1" "$CACHE_FILE"
}

# write_report <directory> <days-old> [status]: a KNOWLEDGE report whose mtime
# is <days-old> days in the past.
write_report() {
  local directory="$1" days="$2" status="${3:-applied}" epoch stamp
  mkdir -p "$directory"
  printf -- '---\nstatus: %s\n---\n\n# Report\n' "$status" > "$directory/KNOWLEDGE-2026-01-01-1200.md"
  epoch=$(( $(date +%s) - days * 86400 ))
  stamp=$(date -u -r "$epoch" +%Y%m%d%H%M 2>/dev/null || date -u -d "@$epoch" +%Y%m%d%H%M)
  touch -t "$stamp" "$directory/KNOWLEDGE-2026-01-01-1200.md"
}

# refresh [script]: one fresh run of the refresher from the fixture root.
refresh() {
  local script="${1:-$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh}"
  rm -f "$CACHE_FILE"
  run env HOME="$TEMPORARY_HOME" bash "$script"
  [ "$status" -eq 0 ]
}

# A broken scratch copy of the refresher lives beside the original:
# check-updates.sh derives every path from its own location.
broken_copy() {
  broken="$REPOSITORY_FIXTURE/.gaia/scripts/check-updates-broken.sh"
  # The texts travel through the environment: awk -v would interpret the
  # backslashes in them.
  SEARCH_TEXT="$1" REPLACEMENT_TEXT="$2" SKIP_AFTER="${3:-0}" awk '
    skip > 0 { skip--; next }
    index($0, ENVIRON["SEARCH_TEXT"]) > 0 { print ENVIRON["REPLACEMENT_TEXT"]; skip = ENVIRON["SKIP_AFTER"] + 0; hits++; next }
    { print }
    END { exit (hits == 1 ? 0 : 1) }
  ' "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh" > "$broken"
  chmod +x "$broken"
}

@test "an applied report older than the drift threshold under audit/ moves to cleanse/ and raises the nudge" {
  write_report "$REPOSITORY_FIXTURE/.gaia/local/audit" 40
  refresh
  [ -f "$REPOSITORY_FIXTURE/.gaia/local/cleanse/KNOWLEDGE-2026-01-01-1200.md" ]
  [ ! -e "$REPOSITORY_FIXTURE/.gaia/local/audit/KNOWLEDGE-2026-01-01-1200.md" ]
  [ "$(cache_value cleanseNudge)" = "true" ]
  [ "$(cache_value cleanseNudgeReason)" = "40 days since review" ]
}

@test "a fresh applied report leaves the cleanse nudge off" {
  write_report "$REPOSITORY_FIXTURE/.gaia/local/audit" 2
  refresh
  [ -f "$REPOSITORY_FIXTURE/.gaia/local/cleanse/KNOWLEDGE-2026-01-01-1200.md" ]
  [ "$(cache_value cleanseNudge)" = "false" ]
}

@test "a draft report in cleanse/ raises the resume nudge" {
  write_report "$REPOSITORY_FIXTURE/.gaia/local/cleanse" 1 draft
  refresh
  [ "$(cache_value cleanseNudgeReason)" = "resume draft" ]
}

@test "the cache carries the cleanse keys and none of the old audit nudge keys" {
  refresh
  [ "$(jq -r 'has("cleanseNudge") and has("cleanseNudgeReason") and has("cleanseLastAppliedAt") and has("cleanseMemoryCount") and has("cleanseMemoryBaseline")' "$CACHE_FILE")" = "true" ]
  [ "$(jq -r 'has("auditNudge") or has("auditNudgeReason") or has("auditLastAppliedAt") or has("auditMemoryCount") or has("auditMemoryBaseline")' "$CACHE_FILE")" = "false" ]
}

@test "a root whose path carries dots reads the memory directory keyed with every non-alphanumeric as a dash" {
  mkdir -p "$MEMORY_DIRECTORY"
  touch "$MEMORY_DIRECTORY/a.md" "$MEMORY_DIRECTORY/b.md" "$MEMORY_DIRECTORY/c.md"
  refresh
  [ "$(cache_value cleanseMemoryCount)" = "3" ]
}

@test "a CLI that cannot answer leaves the previous memory count in place, never zero" {
  # An unknown-subcommand style failure: exit 1 with no inventory on stdout.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/failing-bundle"
  chmod +x "$BATS_TEST_TMPDIR/failing-bundle"
  GAIA_TEST_FITNESS_BUNDLE="$BATS_TEST_TMPDIR/failing-bundle"
  export GAIA_TEST_FITNESS_BUNDLE
  mkdir -p "$MEMORY_DIRECTORY"
  touch "$MEMORY_DIRECTORY/a.md" "$MEMORY_DIRECTORY/b.md" "$MEMORY_DIRECTORY/c.md"
  printf '{"checkedAt":0,"cleanseMemoryCount":7}' > "$CACHE_FILE"
  run env HOME="$TEMPORARY_HOME" bash "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(cache_value cleanseMemoryCount)" = "7" ]
}

@test "the anchor reads a numeric epoch when stat -f answers with filesystem text" {
  # A GNU-style stat treats -f as filesystem status, so a BSD-first order reads
  # non-numeric text from it. The shim answers that way for -f and passes -c
  # through (translating to the BSD form on a host whose stat lacks -c).
  local real_stat shim_directory
  real_stat=$(command -v stat)
  shim_directory="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim_directory"
  cat > "$shim_directory/stat" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "-f" ]; then
  printf 'File: "%s"\n' "\$3"
  exit 0
fi
if [ "\$1" = "-c" ]; then
  "$real_stat" -c "\$2" "\$3" 2>/dev/null || "$real_stat" -f %m "\$3"
  exit \$?
fi
exec "$real_stat" "\$@"
SHIM
  chmod +x "$shim_directory/stat"

  write_report "$REPOSITORY_FIXTURE/.gaia/local/cleanse" 40
  rm -f "$CACHE_FILE"
  run env HOME="$TEMPORARY_HOME" PATH="$shim_directory:$PATH" bash "$REPOSITORY_FIXTURE/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(cache_value cleanseLastAppliedAt)" -gt 0 ]
  [ "$(cache_value cleanseNudgeReason)" = "40 days since review" ]

  # Refusal proof: restore the BSD-first order in a scratch copy.
  broken_copy '        modification_epoch=$(stat -c %Y' \
    '        modification_epoch=$(stat -f %m "$cleanse_report_file" 2>/dev/null || stat -c %Y "$cleanse_report_file" 2>/dev/null)'
  rm -f "$CACHE_FILE"
  run env HOME="$TEMPORARY_HOME" PATH="$shim_directory:$PATH" bash "$broken"
  [ "$status" -eq 0 ]
  [ "$(cache_value cleanseLastAppliedAt)" = "0" ]
}

@test "a refresh run from a linked worktree leaves the main checkout's audit/ reports in place" {
  write_report "$REPOSITORY_FIXTURE/.gaia/local/audit" 40
  git -C "$REPOSITORY_FIXTURE" worktree add -q "$REPOSITORY_FIXTURE/.claude/worktrees/wt" -b wt
  rm -f "$CACHE_FILE"
  run env HOME="$TEMPORARY_HOME" bash "$REPOSITORY_FIXTURE/.claude/worktrees/wt/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ -f "$REPOSITORY_FIXTURE/.gaia/local/audit/KNOWLEDGE-2026-01-01-1200.md" ]
  [ ! -e "$REPOSITORY_FIXTURE/.gaia/local/cleanse" ]
}
