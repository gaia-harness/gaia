#!/usr/bin/env bats
# The closing message of /setup-gaia: Phase 6 of `.claude/commands/setup-gaia.md`
# routes to `## The closing message` in
# `.claude/skills/gaia/references/setup/land-decisions.md`, which prints the
# "You're all set" line only when no project setting this machine can act on
# is still owed, and a setup-not-finished line naming the re-run otherwise. A
# run whose GitHub setup was refused or skipped must not end on a line that
# reads as done, and the message reads the same predicate the statusline's
# setup nudge counts, so the two never disagree. The setup-running marker the
# page touches and removes is read by the statusline.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  REFERENCE="${REPO_ROOT}/.claude/skills/gaia/references/setup/land-decisions.md"
  local file
  for file in "$PAGE" "$REFERENCE"; do
    [ -f "$file" ] || {
      echo "the audited page is absent: ${file}" >&2
      return 1
    }
  done
  PHASE_SIX="$(section_of "$PAGE" '## Phase 6: Finalize')"
  CLOSING="$(section_of "$REFERENCE" '## The closing message')"
  [ -n "$PHASE_SIX" ] || {
    echo "Phase 6 of ${PAGE} is empty or missing" >&2
    return 1
  }
  [ -n "$CLOSING" ] || {
    echo "## The closing message of ${REFERENCE} is empty or missing" >&2
    return 1
  }
}

# section_of <file> <heading>: the lines under a "## " heading, up to the next one.
section_of() {
  awk -v heading="$2" '$0 == heading { inside = 1; next } inside && /^## / { exit } inside' "$1"
}

@test "Phase 6 runs the closing message and prints no closing line of its own" {
  grep -qF -- "Then run \`land-decisions.md\`'s \`## The closing message\`." <<<"$PHASE_SIX"
  grep -qF -- "You're all set" <<<"$PHASE_SIX" && return 1
  return 0
}

@test "the closing message reads the shared setup-owed predicate" {
  grep -qF -- '. .gaia/statusline/setup-owed.sh' <<<"$CLOSING"
  grep -qF -- 'OWED_AT_END=%s' <<<"$CLOSING"
  grep -qF -- 'gaia_setup_owed_ids .' <<<"$CLOSING"
}

@test "the closing message reads the admin-owed ids from the same predicate file" {
  grep -qF -- 'ADMIN_OWED_AT_END=%s' <<<"$CLOSING"
  grep -qF -- 'gaia_setup_admin_owed_ids .' <<<"$CLOSING"
}

@test "the summary's Dependabot item is the approved line verbatim, reason included" {
  local approved="Dependabot security alerts are on. GAIA updates vulnerable packages for you and tests the result before anything changes, so Dependabot's own security fix pull requests are turned off."
  local github_repo="${REPO_ROOT}/.claude/skills/gaia/references/setup/github-repo.md"
  grep -qxF -- "$approved" <<<"$CLOSING"
  grep -qF -- 'verbatim, never a shortened form' <<<"$CLOSING"
  # The same line the Dependabot step prints, so the two cannot drift apart.
  grep -qF -- "print \`${approved}\`" "$github_repo"
}

@test "the done line is gated: the closing message names when each line prints" {
  grep -qF -- 'When `OWED_AT_END`, `ADMIN_UNCHECKED_AT_END` and `ADMIN_OWED_AT_END` are all empty:' <<<"$CLOSING"
  grep -qF -- 'When `OWED_AT_END` is not empty' <<<"$CLOSING"
  grep -qF -- 'When `OWED_AT_END` is empty and `ADMIN_UNCHECKED_AT_END` is not' <<<"$CLOSING"
  grep -qF -- 'When `OWED_AT_END` and `ADMIN_UNCHECKED_AT_END` are empty and `ADMIN_OWED_AT_END` is not' <<<"$CLOSING"
}

@test "the closing message never says a non-admin owes nothing" {
  grep -qF -- 'owes nothing on this machine and ends on the done line' <<<"$CLOSING" && return 1
  true
}

# check_running_marker <page>: Pre-flight touches the marker after the worktree
# refusal, Phase 6 removes it before the adoption ping, and the re-run section
# removes it on a halt.
check_running_marker() {
  local preflight phase_six failure touch_line refuse_line remove_line ping_line
  preflight="$(section_of "$1" '## Pre-flight: Worktree check')"
  phase_six="$(section_of "$1" '## Phase 6: Finalize')"
  failure="$(section_of "$1" '## On failure: re-run')"
  touch_line="$(grep -nxF -- 'mkdir -p .gaia/local && touch .gaia/local/setup-running' <<<"$preflight" | head -n 1 | cut -d: -f1)"
  refuse_line="$(grep -nF -- 'gaia_refuse_if_worktree "/setup-gaia" || exit 1' <<<"$preflight" | head -n 1 | cut -d: -f1)"
  [ -n "$touch_line" ] || {
    echo "Pre-flight does not touch the setup-running marker" >&2
    return 1
  }
  { [ -n "$refuse_line" ] && [ "$touch_line" -gt "$refuse_line" ]; } || {
    echo "Pre-flight touches the marker before the worktree refusal" >&2
    return 1
  }
  remove_line="$(grep -nxF -- 'rm -f .gaia/local/setup-running' <<<"$phase_six" | head -n 1 | cut -d: -f1)"
  ping_line="$(grep -nF -- '**Adoption ping.**' <<<"$phase_six" | head -n 1 | cut -d: -f1)"
  { [ -n "$remove_line" ] && [ -n "$ping_line" ] && [ "$remove_line" -lt "$ping_line" ]; } || {
    echo "Phase 6 does not remove the marker before the adoption ping" >&2
    return 1
  }
  grep -qF -- 'rm -f .gaia/local/setup-running' <<<"$failure" || {
    echo "the re-run section does not remove the marker" >&2
    return 1
  }
}

@test "setup-gaia.md marks setup running after the worktree refusal and clears it on finish and on halt" {
  check_running_marker "$PAGE"
}

# closing_block: the closing message's first bash block, the one that reads the
# owed sets. Fails when the section holds no bash block.
closing_block() {
  local block
  block="$(awk '/^```bash$/ { inside = 1; next } inside && /^```$/ { exit } inside' <<<"$CLOSING")"
  [ -n "$block" ] || {
    echo "the closing message holds no bash block" >&2
    return 1
  }
  printf '%s\n' "$block"
}

# make_closing_fixture: a checkout holding the shipped feature list, the
# shared predicate, and a committed project config that decides every project
# id but required-ci-checks. No admin answer is cached. Prints its path.
make_closing_fixture() {
  local fixture="${BATS_TEST_TMPDIR}/closing-fixture"
  mkdir -p "${fixture}/.gaia/statusline"
  cp "${REPO_ROOT}/.gaia/setup-features.json" "${fixture}/.gaia/setup-features.json"
  cp "${REPO_ROOT}/.gaia/statusline/setup-owed.sh" "${fixture}/.gaia/statusline/setup-owed.sh"
  jq '{setup_decisions: ([.features[] | select(.scope == "project" and .id != "required-ci-checks") | {key: .id, value: "applied"}] | from_entries)}' \
    "${REPO_ROOT}/.gaia/setup-features.json" >"${fixture}/.gaia/project.json"
  jq -e '[.features[] | select(.id == "required-ci-checks" and .scope == "project" and .admin == true)] | length == 1' \
    "${fixture}/.gaia/setup-features.json" >/dev/null || {
    echo "the shipped list no longer holds required-ci-checks as an admin-gated project id" >&2
    return 1
  }
  printf '%s\n' "$fixture"
}

# run_closing_block <fixture> <host> <auth status>: run the closing block from
# the fixture with Phase 1's cached HOST and AUTH_STATUS declared, as the
# closing message runs it.
run_closing_block() {
  local script="${BATS_TEST_TMPDIR}/closing-block.sh"
  closing_block >"$script"
  run bash -c 'cd "$1" && HOST="$2" && AUTH_STATUS="$3" && . "$4"' _ "$1" "$2" "$3" "$script"
}

@test "setup-owed predicate case table: undecided admin ids, a cached non-admin, and non-GitHub hosts" {
  local fixture auth_status host
  fixture="$(make_closing_fixture)"
  # a github.com origin whose admin probe failed names its undecided admin-gated ids
  for auth_status in unauthenticated api_error ''; do
    run_closing_block "$fixture" github.com "$auth_status"
    [ "$status" -eq 0 ]
    grep -qxF -- 'OWED_AT_END=' <<<"$output"
    grep -qxF -- 'ADMIN_OWED_AT_END=' <<<"$output"
    grep -qxF -- 'ADMIN_UNCHECKED_AT_END=required-ci-checks' <<<"$output" || {
      echo "auth status '${auth_status}' left the admin-gated id unnamed" >&2
      return 1
    }
  done
  # an ok admin probe leaves the unchecked set empty and a cached non-admin keeps the admin line
  mkdir -p "${fixture}/.gaia/local"
  printf '{"admin":false}\n' >"${fixture}/.gaia/local/setup-state.json"
  run_closing_block "$fixture" github.com ok
  [ "$status" -eq 0 ]
  grep -qxF -- 'ADMIN_UNCHECKED_AT_END=' <<<"$output"
  grep -qxF -- 'ADMIN_OWED_AT_END=required-ci-checks' <<<"$output"
  # another host, or no origin, names no id as admin-owed or unchecked
  rm -f "${fixture}/.gaia/local/setup-state.json"
  for host in gitlab.com ''; do
    run_closing_block "$fixture" "$host" ''
    [ "$status" -eq 0 ]
    grep -qxF -- 'ADMIN_OWED_AT_END=' <<<"$output" || {
      echo "host '${host}' named an admin-owed id" >&2
      return 1
    }
    grep -qxF -- 'ADMIN_UNCHECKED_AT_END=' <<<"$output" || {
      echo "host '${host}' named an unchecked id" >&2
      return 1
    }
  done
}
