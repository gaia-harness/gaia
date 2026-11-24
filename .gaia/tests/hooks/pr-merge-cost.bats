#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/pr-merge-cost.sh, the PostToolUse hook on
# `gh pr merge`: arming, the jq-absent marker, the unavailable marker when
# usage-merge.sh fails, the hard error on a missing library, and the per-PR
# block passing through. The block's own contents are usage-merge.bats's and
# usage-merge-audit-line.bats's.
#
# Every test builds a tmp git repo holding copies of the hook, the libraries it
# sources and the usage scripts at their repo-relative paths (the shared
# helpers/usage-merge-env.sh), so the hook runs with cwd = that repo and never
# reads the live telemetry. Arming cases swap usage-merge.sh for a stub that
# prints one fixed line, so a printed line means the hook armed.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/pr-merge-cost.bats

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/usage-merge-env.sh"
  # shellcheck disable=SC2034  # read by build_repo in the helper
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_SOURCE="$SOURCE_ROOT/.claude/hooks/pr-merge-cost.sh"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GAIA_USAGE_HOOKS_DISABLE
  unset GAIA_LEDGER_LOCK_FORCE_FALLBACK GAIA_LEDGER_LOCK_TIMEOUT_SECONDS GAIA_USAGE_MERGE_CAP_SECONDS GAIA_USAGE_RENDER_CAP_SECONDS
  export GAIA_LEDGER_LOCK_POLL_SECONDS=0.1
  export GIT_AUTHOR_NAME="GAIA Test" GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test" GIT_COMMITTER_EMAIL="gaia-test@example.com"
  GH_STUB_DIRECTORY="$TEMPORARY_DIRECTORY/ghstub"
  mkdir -p "$GH_STUB_DIRECTORY" "$TEMPORARY_DIRECTORY/bin"
  export GH_STUB_DIRECTORY
  make_stubs
  export PATH="$TEMPORARY_DIRECTORY/bin:$PATH"
  build_repo
}

# stub_usage_merge <exit-code>: usage-merge.sh prints one fixed line, then exits.
stub_usage_merge() {
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "STUB BLOCK\\n"\nexit %s\n' "$1" >"$REPO/.gaia/scripts/usage-merge.sh"
}

# run_hook_split <command>: the real hook with stdout and stderr kept apart.
run_hook_split() {
  run --separate-stderr bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$(payload_for "$1")" "$REPO/.claude/hooks/pr-merge-cost.sh"
}

# open_run <workflow>: the start row of a recorded run in session s-hook, with no close.
open_run() {
  jq -nc --arg workflow "$1" '{schema_version:1,kind:"binding",type:"start",session_id:"s-hook",ts:"2026-09-25T01:00:00Z",workflow:$workflow}' \
    >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}

# stub_gh_home <owner/repo>: `gh repo view` names the home repository; every other call keeps the shared stub.
stub_gh_home() {
  mv "$TEMPORARY_DIRECTORY/bin/gh" "$TEMPORARY_DIRECTORY/bin/gh.shared"
  cat >"$TEMPORARY_DIRECTORY/bin/gh" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "repo view" ] && { printf '{"nameWithOwner":"$1","url":"https://github.com/$1"}\\n'; exit 0; }
exec "\$(dirname "\$0")/gh.shared" "\$@"
EOF
  chmod +x "$TEMPORARY_DIRECTORY/bin/gh"
}

# run_nojq <hook> <command>: the hook under a PATH that carries cat and grep
# and no jq.
run_nojq() {
  local directory="$BATS_TEST_TMPDIR/nojq-bin"
  mkdir -p "$directory"
  ln -sf "$(command -v cat)" "$directory/cat"
  ln -sf "$(command -v grep)" "$directory/grep"
  run bash -c 'printf %s "$1" | PATH="$2" /bin/bash "$3"' _ "$(payload_for "$2")" "$directory" "$1"
}

@test "the hook file is executable" {
  [ -x "$HOOK_SOURCE" ]
}

@test "an armed merge prints the per-PR block the real usage-merge.sh renders, and never a cycle roll-up" {
  {
    segment_row branch:fix/foo s74 2026-09-23T09:00:00Z 400000 40000
  } >"$TELEMETRY_DIRECTORY/usage.jsonl"
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z
  run_merge "gh pr merge 103 --squash"
  [ "$status" -eq 0 ]
  has_line "Cost: 0.4M tokens, \$1.20, 0s"
  lacks "[cycle cost at merge]"
}

@test "arming table: non-merge, non-JSON, foreign repo, quoted mention, heredoc and past-bound, quoted verb and multi-statement" {
  # The foreign-repo row runs against the real usage-merge.sh, so a gh read would show in argv.log.
  gh_view 45 45 fix/foo MERGED 2026-09-25T02:00:00Z
  run_merge "gh pr merge 45 --repo other/project"
  [ "$status" -eq 0 ] || { echo "row foreign repo: status $status" >&2; return 1; }
  [ -z "$output" ] || { echo "row foreign repo: printed [$output]" >&2; return 1; }
  [ ! -e "$GH_STUB_DIRECTORY/argv.log" ] || { echo "row foreign repo: gh was read" >&2; return 1; }

  stub_usage_merge 0
  run bash -c 'cd "$1" && printf %s "not json" | bash "$2"' _ "$REPO" "$REPO/.claude/hooks/pr-merge-cost.sh"
  [ "$status" -eq 0 ] || { echo "row non-JSON: status $status" >&2; return 1; }
  [ -z "$output" ] || { echo "row non-JSON: printed [$output]" >&2; return 1; }

  local pad over_limit_command
  pad=$(printf 'x%.0s' $(seq 1 16400))
  over_limit_command=$'cat > /tmp/notes.txt <<EOF\n'"$pad"$'\ngh pr merge 7\nEOF'
  [ "${#over_limit_command}" -gt 16384 ] || return 1

  # Each row: the expectation (silent = no output, arms = the stub's line), then the command.
  local -a rows=(
    silent "git commit -m x"
    silent "gh pr view 7"
    silent 'echo "remember to gh pr merge later"'
    arms "gh pr merge 7 --squash"
    silent $'cat > /tmp/notes.txt <<EOF\ngh pr merge 7\nEOF'
    arms "$over_limit_command"
    arms 'gh pr "merge" 7'
    arms "echo start && gh pr merge 7"
  )
  local index expectation command
  for ((index = 0; index < ${#rows[@]}; index += 2)); do
    expectation="${rows[index]}" command="${rows[index + 1]}"
    run_merge "$command"
    [ "$status" -eq 0 ] || { echo "row ${command:0:60}: status $status" >&2; return 1; }
    if [ "$expectation" = silent ]; then
      [ -z "$output" ] || { echo "row ${command:0:60}: expected silence, got [$output]" >&2; return 1; }
    else
      has_line "STUB BLOCK" || { echo "row ${command:0:60}: did not arm" >&2; return 1; }
    fi
  done
}

@test "unavailable marker: one line naming the rerun command, branch form and hostile-branch placeholder" {
  stub_usage_merge 3
  run_merge "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  has_line "STUB BLOCK"
  [ "$(grep -c '^\[PR cost\] unavailable' <<<"$output")" -eq 1 ]
  has_line "[PR cost] unavailable: usage-merge.sh exited 3; rerun: bash .gaia/scripts/usage.sh pr 7"

  git -C "$REPO" checkout -q -b fix/numberless
  run_merge "gh pr merge"
  [ "$status" -eq 0 ]
  has_line "[PR cost] unavailable: usage-merge.sh exited 3; rerun: bash .gaia/scripts/usage.sh pr --branch fix/numberless"
  git -C "$REPO" checkout -q -b 'fix/a;touch$IFS/pwn'
  run_merge "gh pr merge"
  [ "$status" -eq 0 ]
  has_line "[PR cost] unavailable: usage-merge.sh exited 3; rerun: bash .gaia/scripts/usage.sh pr --branch <branch>"
  [ ! -e "$REPO/pwn" ]
}

@test "missing library table: hook-payload.sh or verb-arming.sh absent exits non-zero naming it" {
  local library
  for library in hook-payload.sh verb-arming.sh; do
    mv "$REPO/.claude/hooks/lib/$library" "$BATS_TEST_TMPDIR/$library.saved"
    run_hook_split "gh pr merge 7"
    mv "$BATS_TEST_TMPDIR/$library.saved" "$REPO/.claude/hooks/lib/$library"
    [ "$status" -ne 0 ] || { echo "row $library: exited 0" >&2; return 1; }
    grep -qF "$library" <<<"$stderr" || { echo "row $library: stderr does not name it: [$stderr]" >&2; return 1; }
  done
}

@test "jq absent: an armed merge prints the inactive marker and exits 0; a non-merge prints nothing" {
  run_nojq "$REPO/.claude/hooks/pr-merge-cost.sh" "gh pr merge 101"
  [ "$status" -eq 0 ]
  [ "$output" = "usage tracking inactive: jq not found" ]
  run_nojq "$REPO/.claude/hooks/pr-merge-cost.sh" "gh pr view 101"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a merge in a session with an open run prints the record command with the workflow and the merged PR" {
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z
  open_run gaia-debt
  run_merge "gh pr merge 103 --squash"
  [ "$status" -eq 0 ]
  has_line "[run cost] this session has an open run; if nothing else records it once the merge has landed, close the run with: bash .gaia/scripts/usage.sh record command:gaia-debt --workflow gaia-debt --pr 103"
}

@test "no run-cost line when the session never opened a run or the run already has its record" {
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z
  run_merge "gh pr merge 103 --squash"
  [ "$status" -eq 0 ]
  lacks "[run cost]"
  open_run gaia-debt
  run bash -c 'cd "$1" && CLAUDE_CODE_SESSION_ID=s-hook bash .gaia/scripts/usage.sh record command:gaia-debt --workflow gaia-debt' _ "$REPO"
  [ "$status" -eq 0 ]
  run_merge "gh pr merge 103 --squash"
  [ "$status" -eq 0 ]
  lacks "[run cost]"
}

@test "the run-cost line arms on -R naming this repository before or after the subcommand, and not on another repository" {
  stub_gh_home acme/widgets
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z
  open_run gaia-debt
  local row
  for row in "gh pr merge -R acme/widgets 103 --squash" "gh -R acme/widgets pr merge 103 --squash" "gh pr merge 103 --repo=acme/widgets --squash"; do
    run_merge "$row"
    [ "$status" -eq 0 ] || return 1
    has_line "[run cost] this session has an open run; if nothing else records it once the merge has landed, close the run with: bash .gaia/scripts/usage.sh record command:gaia-debt --workflow gaia-debt --pr 103" || { echo "row $row: no line" >&2; return 1; }
  done
  run_merge "gh pr merge 103 -R other/project --squash"
  [ "$status" -eq 0 ]
  lacks "[run cost]"
}

@test "a plan run's line points at its skill's own record step and carries no command" {
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z
  open_run gaia-plan
  run_merge "gh pr merge 103 --squash"
  [ "$status" -eq 0 ]
  has_line "[run cost] this session has an open run; if nothing else records it once the merge has landed, close the run with the record step of its own skill"
}
