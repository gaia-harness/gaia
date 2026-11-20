#!/usr/bin/env bats
# UAT-012: gh issue create uses --repo gaia-harness/gaia, a hardcoded constant
#          read from the runbook, not derived from the git remote.

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIBRARY_DIRECTORY="$HERE/lib"
source "$LIBRARY_DIRECTORY/runbook-repo.sh"

# ---------------------------------------------------------------------------
# gh invocation surrogate
#
# Builds a temp PATH prefix containing a "gh" stub script that records argv
# to $STUB_GH_CAPTURE_FILE, then runs the surrogate that invokes gh with the
# hardcoded constants from the runbook's § 8 probable-bug branch.
# ---------------------------------------------------------------------------

invoke_gh_surrogate() {
  local capture_file="$1"
  local class="$2"
  local one_line="$3"
  local body_file="$4"

  # Build a temp bin dir with a "gh" stub
  local stub_directory
  stub_directory="$(mktemp -d)"
  cp "$LIBRARY_DIRECTORY/stub-gh.sh" "$stub_directory/gh"
  chmod +x "$stub_directory/gh"

  export STUB_GH_CAPTURE_FILE="$capture_file"

  # Simulate the runbook's gh invocation (frozen contract from forensics.md § 8)
  PATH="$stub_directory:$PATH" gh issue create \
    --repo "$RUNBOOK_REPO" \
    --label "gaia-forensics" \
    --title "forensics: $class, $one_line" \
    --body-file "$body_file"

  rm -rf "$stub_directory"
}

setup() {
  RUNBOOK_REPO="$(runbook_repo "$BATS_TEST_DIRNAME")"
  WORK_DIRECTORY="$(mktemp -d)"
  CAPTURE_FILE="$WORK_DIRECTORY/gh-argv.txt"
  BODY_FILE="$WORK_DIRECTORY/body.md"
  printf '## Symptom\nTest body.\n' > "$BODY_FILE"
}

teardown() {
  rm -rf "$WORK_DIRECTORY"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "UAT-012: gh repo arg is hardcoded constant, not derived from git remote" {
  # The frozen contract: the repo value must be exactly "gaia-harness/gaia"
  # regardless of what git remote would return.
  invoke_gh_surrogate "$CAPTURE_FILE" "init" "rename step failed" "$BODY_FILE"
  grep -xF -- "$RUNBOOK_REPO" "$CAPTURE_FILE"
  [ "$RUNBOOK_REPO" = "gaia-harness/gaia" ] || return 1
  # Confirm the captured argv does not contain any git-remote-derived value
  ! grep -q 'origin' "$CAPTURE_FILE"
}
