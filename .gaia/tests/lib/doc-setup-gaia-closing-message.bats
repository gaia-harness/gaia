#!/usr/bin/env bats
# The closing message of `.claude/commands/setup-gaia.md`: Phase 6 prints the
# "You're all set" line only when no project-scope setup feature is still owed
# by this runner, and a setup-not-finished line naming the re-run otherwise.
# A run whose GitHub setup was refused or skipped must not end on a line that
# reads as done.
#
# Assertion style: .claude/rules/bats-assertions.md.

DONE_LINE="You're all set: your GAIA project is ready. Restart Claude Code to load your new plugins and skills."
NOT_DONE_LINE="Setup isn't finished: these project settings are still owed: <the OWED_AT_END ids>. Fix what stopped them above, then re-run /setup-gaia; it resumes from the first owed step. Restart Claude Code to load your new plugins and skills."
DOCS_LINE='New to GAIA? The docs walk you through your first feature: https://docs.gaiareact.com/'

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
  CLOSING="$(awk '/^## Phase 6: Finalize$/ { inside = 1; next } inside && /^## / { exit } inside' "$PAGE")"
  [ -n "$CLOSING" ] || {
    echo "Phase 6 of ${PAGE} is empty or missing" >&2
    return 1
  }
}

@test "Phase 6 computes the project-scope ids still owed at the end of the run" {
  grep -qF -- 'OWED_AT_END=' <<<"$CLOSING"
  grep -qF -- 'select(.scope == "project")' <<<"$CLOSING"
}

@test "Phase 6 prints the done line, the not-finished line and the docs line" {
  grep -qxF -- "$DONE_LINE" <<<"$CLOSING"
  grep -qxF -- "$NOT_DONE_LINE" <<<"$CLOSING"
  grep -qxF -- "$DOCS_LINE" <<<"$CLOSING"
}

@test "the done line is gated: Phase 6 names when each line prints" {
  grep -qF -- '`OWED_AT_END` is empty' <<<"$CLOSING"
  grep -qF -- '`OWED_AT_END` is not empty' <<<"$CLOSING"
}

@test "a non-admin of an existing repo owes no project setting" {
  grep -qF -- '`admin` is `false` and `auth_status` is `"ok"`' <<<"$CLOSING"
}
