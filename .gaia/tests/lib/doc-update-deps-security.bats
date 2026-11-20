#!/usr/bin/env bats
# Static and executable checks over the /update-deps skill's security
# remediation text: `.claude/skills/update-deps/SKILL.md`, its final report
# `references/final-report.md` and publish step `references/publish.md`, its
# security recipe `references/security.md`, and the override audit
# `references/override-audit.md`.
#
# What this suite pins: no fixed /tmp scratch path, the worktree state line's
# null-versus-zero read, the report-only reading, and the override audit's two
# captures through the capture script and its stop-and-retain wording for an
# unanswered `pnpm audit`.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SKILL="${REPO_ROOT}/.claude/skills/update-deps/SKILL.md"
  FINAL_REPORT="${REPO_ROOT}/.claude/skills/update-deps/references/final-report.md"
  PUBLISH="${REPO_ROOT}/.claude/skills/update-deps/references/publish.md"
  SECURITY="${REPO_ROOT}/.claude/skills/update-deps/references/security.md"
  OVERRIDE_AUDIT="${REPO_ROOT}/.claude/skills/update-deps/references/override-audit.md"
  STATE_LINE_LIB="${REPO_ROOT}/.gaia/scripts/update-state-line-lib.sh"
  local file
  for file in "$SKILL" "$FINAL_REPORT" "$PUBLISH" "$SECURITY" "$OVERRIDE_AUDIT" "$STATE_LINE_LIB"; do
    [ -f "$file" ] || {
      echo "an audited page is absent: ${file}" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# No fixed /tmp scratch path
# ---------------------------------------------------------------------------

check_no_tmp() {
  local file
  for file in "$@"; do
    if grep -qF -- '/tmp/' "$file"; then
      echo "/tmp/ path in ${file}" >&2
      return 1
    fi
  done
}

@test "no /tmp/ path remains in the skill or any of its audited references" {
  check_no_tmp "$SKILL" "$FINAL_REPORT" "$PUBLISH" "$SECURITY" "$OVERRIDE_AUDIT"
}

# ---------------------------------------------------------------------------
# The worktree state line reads null apart from zero
# ---------------------------------------------------------------------------

# The function lives in the sourced state-line library, which the skill's
# guard fence sources.
# state_line_body <file>: the gaia_update_deps_state_line definition, from its
# opening line to the first line that is exactly a closing brace.
state_line_body() {
  awk '
    $0 == "gaia_update_deps_state_line() {" { inside = 1 }
    inside { print }
    inside && $0 == "}" { exit }
  ' "$1"
}

# run_state_line <cache-json>: source the extracted function and run it over
# a fixture cache.
run_state_line() {
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required to run the state line" >&2
    return 1
  }
  local function_file="${BATS_TEST_TMPDIR}/state-line.sh" cache="${BATS_TEST_TMPDIR}/update-check.json"
  state_line_body "$STATE_LINE_LIB" >"$function_file"
  [ -s "$function_file" ] || return 1
  printf '%s\n' "$1" >"$cache"
  run bash -c '. "$1" && gaia_update_deps_state_line "$2"' _ "$function_file" "$cache"
}

@test "the state line separates a null security count from a zero count" {
  run_state_line "{\"outdatedCount\":3,\"checkedAt\":$(date +%s),\"securityCount\":null,\"securitySource\":\"unavailable\"}"
  [ "$status" -eq 0 ]
  grep -qF -- 'Cached on main: 3 packages outdated, security advisories unavailable (last checked' <<<"$output"
  grep -qF -- '0 open security advisories' <<<"$output" && return 1
  run_state_line "{\"outdatedCount\":3,\"checkedAt\":$(date +%s),\"securityCount\":0,\"securitySource\":\"dependabot\"}"
  [ "$status" -eq 0 ]
  grep -qF -- 'Cached on main: 3 packages outdated, 0 open security advisories (last checked' <<<"$output"
}

# ---------------------------------------------------------------------------
# Report-only is a property of the security phase
# ---------------------------------------------------------------------------

REPORT_ONLY_SECURITY='the security phase adds, edits, and removes no `overrides:` key and applies no advisory-driven bump'
REPORT_ONLY_AUDIT='The existing Phase 6 override audit is unchanged in that run'

check_report_only_reading() {
  grep -qF -- "$REPORT_ONLY_SECURITY" "$1" || {
    echo "report-only no longer states the security phase leaves overrides alone" >&2
    return 1
  }
  grep -qF -- "$REPORT_ONLY_AUDIT" "$1" || {
    echo "report-only no longer states the Phase 6 audit is unchanged" >&2
    return 1
  }
}

@test "a report-only run leaves overrides to the unchanged Phase 6 audit" {
  check_report_only_reading "$SKILL"
}

# ---------------------------------------------------------------------------
# The override audit fails closed when pnpm audit does not answer
# ---------------------------------------------------------------------------

ADVISORY_CAPTURE='bash .gaia/scripts/override-audit-advisory-ids.sh'
BASELINE_UNANSWERED='remove no key, change nothing, and note the audit as **Not run (pnpm audit unavailable: <reason>)**'
PER_KEY_UNANSWERED='This key and every key not yet tested are **retained (pnpm audit unavailable: <reason>)**'

check_override_audit_fails_closed() {
  if grep -qF -- 'pnpm audit --json' "$1"; then
    echo "the override audit reads pnpm audit directly instead of through the capture script" >&2
    return 1
  fi
  [ "$(grep -cF -- "$ADVISORY_CAPTURE" "$1")" -eq 2 ] || {
    echo "the baseline and per-key captures do not both use the capture script" >&2
    return 1
  }
  grep -qF -- "$BASELINE_UNANSWERED" "$1" || {
    echo "an unanswered baseline audit no longer stops the loop" >&2
    return 1
  }
  grep -qF -- "$PER_KEY_UNANSWERED" "$1" || {
    echo "an unanswered per-key audit no longer retains the untested keys" >&2
    return 1
  }
}

@test "the override audit fails closed when pnpm audit does not answer" {
  check_override_audit_fails_closed "$OVERRIDE_AUDIT"
}
