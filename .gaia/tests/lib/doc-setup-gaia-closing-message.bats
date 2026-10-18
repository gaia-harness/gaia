#!/usr/bin/env bats
# The closing message of /setup-gaia: Phase 6 of `.claude/commands/setup-gaia.md`
# routes to `## The closing message` in
# `.claude/skills/gaia/references/setup/land-decisions.md`, which prints the
# "You're all set" line only when no project setting this machine can act on
# is still owed, and a setup-not-finished line naming the re-run otherwise. A
# run whose GitHub setup was refused or skipped must not end on a line that
# reads as done, and the message reads the same predicate the statusline's
# setup nudge counts, so the two never disagree.
#
# Assertion style: .claude/rules/bats-assertions.md.

DONE_LINE="You're all set: your GAIA project is ready. Restart Claude Code to load your new plugins and skills."
NOT_DONE_LINE="Setup isn't finished: these project settings are still owed: <the OWED_AT_END ids>. Fix what stopped them above, then re-run /setup-gaia; it resumes from the first owed step. Restart Claude Code to load your new plugins and skills."
DOCS_LINE='New to GAIA? The docs walk you through your first feature: https://docs.gaiareact.com/'

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
  PHASE_SIX="$(awk '/^## Phase 6: Finalize$/ { inside = 1; next } inside && /^## / { exit } inside' "$PAGE")"
  CLOSING="$(awk '/^## The closing message$/ { inside = 1; next } inside && /^## / { exit } inside' "$REFERENCE")"
  [ -n "$PHASE_SIX" ] || {
    echo "Phase 6 of ${PAGE} is empty or missing" >&2
    return 1
  }
  [ -n "$CLOSING" ] || {
    echo "## The closing message of ${REFERENCE} is empty or missing" >&2
    return 1
  }
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

@test "the closing message prints the done line, the not-finished line and the docs line" {
  grep -qxF -- "$DONE_LINE" <<<"$CLOSING"
  grep -qxF -- "$NOT_DONE_LINE" <<<"$CLOSING"
  grep -qxF -- "$DOCS_LINE" <<<"$CLOSING"
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
  grep -qF -- 'When `OWED_AT_END` is empty:' <<<"$CLOSING"
  grep -qF -- 'When `OWED_AT_END` is not empty' <<<"$CLOSING"
}
