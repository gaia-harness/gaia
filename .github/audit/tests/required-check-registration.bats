#!/usr/bin/env bats

# Regression guard for the GAIA-Audit required-check registration across the
# setup recipes (.claude/commands/gaia-init.md and setup-gaia.md).
#
# The merge gate keys on the GAIA-Audit COMMIT STATUS, not the
# code-review-audit JOB NAME. The audit job reaches a green terminal step on
# every path (including a local-mode stand-down where no audit ran), so
# registering the job name as the required check would let an unaudited PR
# merge through the github.com button.
#
# Division of responsibility between the two recipes:
#   - setup-gaia.md REGISTERS the check: it owns the literal
#     `required_status_checks` PUT to the `/contexts` endpoint with `GAIA-Audit`, inside
#     Phase 3's admin-gated recommended defaults, right after the
#     default-branch protection PUT, for every admin with no other
#     precondition.
#   - gaia-init.md DELEGATES that registration to /setup-gaia rather than
#     inlining the command; it touches nothing on GitHub and must NOT carry
#     the PUT itself.
# Neither recipe may register the bare code-review-audit job name.
#
# The recipes are prose, so the testable surface is the literal command
# strings (setup-gaia) and the delegation references (gaia-init).
#
# This suite lives under .github/audit/tests/ because that is the directory
# the CI bats runner (audit-ci-tests.yml, check name "Audit CI Tests")
# executes.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  GAIA_INIT="$REPO_ROOT/.claude/commands/gaia-init.md"
  SETUP_GAIA_COMMAND_FILE="$REPO_ROOT/.claude/commands/setup-gaia.md"
  [ -f "$GAIA_INIT" ] || skip "gaia-init.md not found"
  [ -f "$SETUP_GAIA_COMMAND_FILE" ] || skip "setup-gaia.md not found"
}

# -----------------------------------------------------------------------------
# gaia-init recipe delegates registration to /setup-gaia and inlines no
# registration command of its own.
# -----------------------------------------------------------------------------

@test "gaia-init delegates GAIA-Audit required-check registration to /setup-gaia" {
  run grep -F "/setup-gaia" "$GAIA_INIT"
  [ "$status" -eq 0 ]
  run grep -E "registers? the .GAIA-Audit. required check" "$GAIA_INIT"
  [ "$status" -eq 0 ]
}

# bats test_tags=protected
@test "gaia-init inlines no GAIA-Audit registration" {
  echo "case: gaia-init does not inline the required_status_checks registration command"
  run grep -F "protection/required_status_checks" "$GAIA_INIT"
  [ "$status" -ne 0 ]
  echo "case: gaia-init does not register the bare code-review-audit job name as the required check"
  run grep -F "contexts[]=code-review-audit" "$GAIA_INIT"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# setup-gaia recipe registers the GAIA-Audit status, not the job name, via
# the required_status_checks branch-protection endpoint.
# -----------------------------------------------------------------------------

# bats test_tags=protected
@test "setup-gaia registers the GAIA-Audit status through the contexts endpoint, never the job name" {
  echo "case: setup-gaia registers GAIA-Audit as the required check"
  run grep -F '["GAIA-Audit"]' "$SETUP_GAIA_COMMAND_FILE"
  [ "$status" -eq 0 ]
  echo "case: setup-gaia registration targets the required_status_checks endpoint"
  run grep -F "protection/required_status_checks" "$SETUP_GAIA_COMMAND_FILE"
  [ "$status" -eq 0 ]
  echo "case: setup-gaia writes the contexts through the documented /contexts PUT with a JSON body"
  run grep -F -- '-X PUT "$required_checks_endpoint/contexts" --input -' "$SETUP_GAIA_COMMAND_FILE"
  [ "$status" -eq 0 ]
  run grep -F -- '-f strict=true' "$SETUP_GAIA_COMMAND_FILE"
  [ "$status" -ne 0 ]
  echo "case: setup-gaia does not register the bare code-review-audit job name as the required check"
  run grep -F "contexts[]=code-review-audit" "$SETUP_GAIA_COMMAND_FILE"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# setup-gaia registration placement: Phase 3, after the protection PUT, with
# no CI decision between the admin probe and the registration.
# -----------------------------------------------------------------------------

# phase3_section <file>: the lines under "## Phase 3:" up to the next "## ".
phase3_section() {
  awk '/^## /{inside = ($0 ~ /^## Phase 3:/)} inside' "$1"
}

# check_registration_placement <file>: every registration line sits in
# Phase 3, after the protection PUT, and the text from the admin probe to the
# registration names no CI decision.
check_registration_placement() {
  local file="$1" section in_file in_section between
  section="$(phase3_section "$file")"
  in_file="$(grep -cF '["GAIA-Audit"]' "$file" || true)"
  in_section="$(grep -cF '["GAIA-Audit"]' <<<"$section" || true)"
  [ "$in_section" -ge 1 ] || {
    echo "no registration inside Phase 3" >&2
    return 1
  }
  [ "$in_section" -eq "$in_file" ] || {
    echo "a registration sits outside Phase 3 (${in_section} of ${in_file} inside)" >&2
    return 1
  }
  awk '
    /(branches\/<default-branch>\/protection|\$protection_endpoint)" --input -/ && !protection { protection = NR }
    /\["GAIA-Audit"\]/ && !registration { registration = NR }
    END { exit !(protection && registration && protection < registration) }
  ' <<<"$section" || {
    echo "the registration does not follow the protection PUT" >&2
    return 1
  }
  between="$(awk '
    /gaia setup check-admin/ { inside = 1 }
    /\["GAIA-Audit"\]/ { inside = 0 }
    inside
  ' <<<"$section")"
  [ -n "$between" ] || {
    echo "no admin probe precedes the registration in Phase 3" >&2
    return 1
  }
  if grep -nE '(^|[^A-Za-z])CI([^A-Za-z]|$)|setup_complete|ci mode' <<<"$between"; then
    echo "a CI decision gates the registration" >&2
    return 1
  fi
}

# bats test_tags=protected
@test "setup-gaia registers GAIA-Audit in Phase 3, after the protection PUT, with no CI precondition" {
  check_registration_placement "$SETUP_GAIA_COMMAND_FILE"
}
