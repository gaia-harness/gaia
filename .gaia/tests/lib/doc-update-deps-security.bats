#!/usr/bin/env bats
# Static and executable checks over the /update-deps skill's security
# remediation text: `.claude/skills/update-deps/SKILL.md`, its final report
# `references/final-report.md` and publish step `references/publish.md`, its
# security recipe `references/security.md`, and the override audit
# `references/override-audit.md`.
#
# What this suite pins: a run with no outdated package but an open advisory is
# a real run, the security phase's batch gate and per-resolution revert, the
# Phase 7 Security section's source line, introduced marker, and cache rewrite,
# the Phase 8 security-only subject, acceptance only after a per-advisory
# question, the release-age and trust settings rule, no fixed /tmp scratch path,
# the worktree state line's null-versus-zero read, the report-only reading,
# the security phase's own snapshot directories, the override audit's two
# captures through the capture script and its stop-and-retain wording for an
# unanswered `pnpm audit`, and the plain sub-dependency wording of the
# SKILL.md preview, menu and skip lines and the final report's heading.
#
# Each check is a function over a file path, so every test that proves the
# real page passes has a twin that runs the same function over a scratch copy
# with the guarded content removed or altered and asserts it fails.
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

# scratch_copy <source> <name>: copy a file into the test's temp dir and print
# the copy's path, so a mutation never touches the shared tree.
scratch_copy() {
  local copy="${BATS_TEST_TMPDIR}/$2"
  cp "$1" "$copy"
  printf '%s\n' "$copy"
}

# remove_fixed <file> <fixed-string>: delete every occurrence of a fixed
# string in place (no regex, so backticks, dollars, and brackets are literal).
remove_fixed() {
  replace_fixed "$1" "$2" ""
}

# replace_fixed <file> <fixed-string> <replacement>: replace every occurrence
# of a fixed string in place, and fail when the string was not there, so a
# twin can never pass because its mutation silently missed.
replace_fixed() {
  local file="$1" needle="$2" replacement="$3" mutated="${1}.mutated"
  grep -qF -- "$needle" "$file" || {
    echo "mutation target not found: ${needle}" >&2
    return 1
  }
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '
    BEGIN { needle = ENVIRON["NEEDLE"]; replacement = ENVIRON["REPLACEMENT"] }
    {
      line = $0; out = ""
      while ((position = index(line, needle)) > 0) {
        out = out substr(line, 1, position - 1) replacement
        line = substr(line, position + length(needle))
      }
      print out line
    }
  ' "$file" >"$mutated"
  mv "$mutated" "$file"
}

# section <file> <start-heading> <next-heading>: print the lines from the
# start heading (exact line) up to, not including, the next heading.
section() {
  START="$2" STOP="$3" awk '
    $0 == ENVIRON["START"] { inside = 1; print; next }
    inside && $0 == ENVIRON["STOP"] { exit }
    inside { print }
  ' "$1"
}

phase7() { section "$1" "## Phase 7: Final report" "@@end-of-file@@"; }

# ---------------------------------------------------------------------------
# 2. Zero outdated with an advisory is a real run
# ---------------------------------------------------------------------------

check_zero_outdated_with_advisory() {
  grep -qF -- '**A zero `total_count` with at least one advisory**' "$1" || return 1
  grep -qF -- 'is a real run, not "nothing to do"' "$1" || {
    echo "the zero-outdated advisory branch no longer refuses nothing-to-do" >&2
    return 1
  }
}

@test "a zero-outdated run with an advisory does not exit as nothing to do" {
  check_zero_outdated_with_advisory "$SKILL"
}

@test "the zero-outdated check fails with the branch sentence deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "zero.md")"
  remove_fixed "$copy" 'is a real run, not "nothing to do"'
  run check_zero_outdated_with_advisory "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 3. Per-resolution revert and the re-gate cap
# ---------------------------------------------------------------------------

check_revert_and_cap() {
  grep -qF -- 'A failure reverts that resolution alone from its own resolution snapshot' "$1" || {
    echo "the per-resolution revert is not stated" >&2
    return 1
  }
  grep -qF -- 'Stop after 5 individual re-gates' "$1" || {
    echo "the 5 re-gate cap is not stated" >&2
    return 1
  }
}

@test "the security recipe states the per-resolution revert and the 5 re-gate cap" {
  check_revert_and_cap "$SECURITY"
}

@test "the revert check fails with the revert sentence deleted" {
  local copy
  copy="$(scratch_copy "$SECURITY" "revert.md")"
  remove_fixed "$copy" 'A failure reverts that resolution alone from its own resolution snapshot'
  run check_revert_and_cap "$copy"
  [ "$status" -ne 0 ]
}

@test "the revert check fails with the re-gate cap deleted" {
  local copy
  copy="$(scratch_copy "$SECURITY" "cap.md")"
  remove_fixed "$copy" 'Stop after 5 individual re-gates'
  run check_revert_and_cap "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 5, 13, 14, 15. The Phase 7 Security section
# ---------------------------------------------------------------------------

check_not_run_source_line() {
  grep -qF -- 'Dependabot alerts: Not run (' <<<"$(phase7 "$1")"
}

@test "the Phase 7 Security instructions carry the alerts Not run source line" {
  check_not_run_source_line "$FINAL_REPORT"
}

@test "the source-line check fails with the Not run literal deleted" {
  local copy
  copy="$(scratch_copy "$FINAL_REPORT" "not-run.md")"
  remove_fixed "$copy" 'Dependabot alerts: Not run ('
  run check_not_run_source_line "$copy"
  [ "$status" -ne 0 ]
}

check_cache_rewrite() {
  local body
  body="$(phase7 "$1")"
  grep -qF -- '.gaia/cli/gaia update-deps write-security-cache --count' <<<"$body" || {
    echo "Phase 7 does not call write-security-cache" >&2
    return 1
  }
  grep -qF -- '.gaia/cli/gaia update-deps advisories --emit .gaia/local/cache/shared/update-deps-advisories-count.json --count-only' <<<"$body" || {
    echo "the cache count does not come from advisories --count-only" >&2
    return 1
  }
  grep -qF -- "never from the report's tables" <<<"$body" || {
    echo "the cache count is not barred from the report tables" >&2
    return 1
  }
  grep -qF -- 'never in CI: there the rewrite is skipped entirely' <<<"$body" || {
    echo "the CI skip of the cache rewrite is not stated" >&2
    return 1
  }
}

@test "Phase 7 rewrites the security cache from advisories --count-only, skipped in CI" {
  check_cache_rewrite "$FINAL_REPORT"
}

@test "the cache-rewrite check fails with the write-security-cache call deleted" {
  local copy
  copy="$(scratch_copy "$FINAL_REPORT" "cache-call.md")"
  remove_fixed "$copy" '.gaia/cli/gaia update-deps write-security-cache --count'
  run check_cache_rewrite "$copy"
  [ "$status" -ne 0 ]
}

@test "the cache-rewrite check fails with the --count-only call deleted" {
  local copy
  copy="$(scratch_copy "$FINAL_REPORT" "cache-count.md")"
  remove_fixed "$copy" '.gaia/cli/gaia update-deps advisories --emit .gaia/local/cache/shared/update-deps-advisories-count.json --count-only'
  run check_cache_rewrite "$copy"
  [ "$status" -ne 0 ]
}

@test "the cache-rewrite check fails with the CI skip sentence deleted" {
  local copy
  copy="$(scratch_copy "$FINAL_REPORT" "cache-ci.md")"
  remove_fixed "$copy" 'never in CI: there the rewrite is skipped entirely'
  run check_cache_rewrite "$copy"
  [ "$status" -ne 0 ]
}

check_no_bare_none_and_introduced() {
  local body
  body="$(phase7 "$1")"
  grep -qF -- 'never a bare `None`' <<<"$body" || {
    echo "Phase 7 no longer states the section never reads a bare None" >&2
    return 1
  }
  grep -qF -- 'Mark `introduced by this run` on a row whose key is not in the opening advisory set Phase 1 kept (`advisories[].key`, `auditKeys`, and `dismissedGhsas`)' <<<"$body" || {
    echo "the introduced marker is not tied to the opening-set comparison" >&2
    return 1
  }
}

@test "Phase 7 never reads a bare None and ties the introduced marker to the opening set" {
  check_no_bare_none_and_introduced "$FINAL_REPORT"
}

@test "the no-bare-None check fails with that sentence deleted" {
  local copy
  copy="$(scratch_copy "$FINAL_REPORT" "bare-none.md")"
  remove_fixed "$copy" 'never a bare `None`'
  run check_no_bare_none_and_introduced "$copy"
  [ "$status" -ne 0 ]
}

@test "the introduced-marker check fails with the comparison clause deleted" {
  local copy
  copy="$(scratch_copy "$FINAL_REPORT" "introduced.md")"
  remove_fixed "$copy" ', `auditKeys`,'
  run check_no_bare_none_and_introduced "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 7. Phase 8 publishes security-only runs under chore(deps):
# ---------------------------------------------------------------------------

check_phase8_security_only() {
  local body
  body="$(section "$1" "## Phase 8: Publish" "@@end-of-file@@")"
  grep -qF -- 'Phase 8 runs when the only landed work is security resolutions.' <<<"$body" || {
    echo "Phase 8 does not run for security-only work" >&2
    return 1
  }
  grep -qF -- 'only security resolutions, with no devDependency-only version bump, always uses `chore(deps):`' <<<"$body" || {
    echo "the security-only subject is not chore(deps):" >&2
    return 1
  }
}

@test "Phase 8 runs for security-only work and its subject begins chore(deps):" {
  check_phase8_security_only "$PUBLISH"
}

@test "the Phase 8 check fails with the security-only run clause deleted" {
  local copy
  copy="$(scratch_copy "$PUBLISH" "phase8-run.md")"
  remove_fixed "$copy" 'Phase 8 runs when the only landed work is security resolutions.'
  run check_phase8_security_only "$copy"
  [ "$status" -ne 0 ]
}

@test "the Phase 8 check fails with the chore(deps): subject clause deleted" {
  local copy
  copy="$(scratch_copy "$PUBLISH" "phase8-subject.md")"
  remove_fixed "$copy" 'only security resolutions, with no devDependency-only version bump, always uses `chore(deps):`'
  run check_phase8_security_only "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 10. Acceptance asks per advisory and never runs in CI
# ---------------------------------------------------------------------------

check_acceptance() {
  local body
  body="$(section "$1" "#### 7. Acceptance" "#### Return value")"
  grep -qF -- 'Ask with `AskUserQuestion`, one advisory per question' <<<"$body" || {
    echo "acceptance does not ask per advisory" >&2
    return 1
  }
  grep -qF -- 'dismiss-alert --alert <n> --reason <tolerable_risk|not_used> --comment' <<<"$body" || return 1
  grep -qF -- '`--confirmed` is passed only after that advisory'"'"'s `AskUserQuestion` was answered yes' <<<"$body" || {
    echo "--confirmed is not tied to the per-advisory question" >&2
    return 1
  }
  grep -qF -- 'Never dismiss in CI' <<<"$body" || {
    echo "acceptance does not state it never runs in CI" >&2
    return 1
  }
}

@test "acceptance dismisses with --confirmed only after a per-advisory question, never in CI" {
  check_acceptance "$SECURITY"
}

@test "the acceptance check fails with the CI sentence deleted" {
  local copy
  copy="$(scratch_copy "$SECURITY" "acceptance-ci.md")"
  remove_fixed "$copy" 'Never dismiss in CI'
  run check_acceptance "$copy"
  [ "$status" -ne 0 ]
}

@test "the acceptance check fails with the --confirmed ordering deleted" {
  local copy
  copy="$(scratch_copy "$SECURITY" "acceptance-confirmed.md")"
  remove_fixed "$copy" '`--confirmed` is passed only after that advisory'"'"'s `AskUserQuestion` was answered yes'
  run check_acceptance "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 11. The release-age and trust settings stay untouched
# ---------------------------------------------------------------------------

RELEASE_AGE_RULE='never add a `minimumReleaseAgeExclude` entry, and never change `minimumReleaseAge`, `minimumReleaseAgeStrict`, `minimumReleaseAgeExclude`, `trustPolicy`, or `trustPolicyExclude`'

check_release_age_rule() {
  grep -qF -- "$RELEASE_AGE_RULE" "$1"
}

@test "the security recipe forbids touching the five release-age and trust settings" {
  check_release_age_rule "$SECURITY"
}

@test "the release-age check fails with the rule deleted" {
  local copy
  copy="$(scratch_copy "$SECURITY" "release-age.md")"
  remove_fixed "$copy" "$RELEASE_AGE_RULE"
  run check_release_age_rule "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 12. No fixed /tmp scratch path
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

@test "the /tmp check fails on a /tmp/ path inserted into each file" {
  local source count=0 copy
  for source in "$SKILL" "$FINAL_REPORT" "$PUBLISH" "$SECURITY" "$OVERRIDE_AUDIT"; do
    count=$((count + 1))
    copy="$(scratch_copy "$source" "tmp-${count}.md")"
    printf '\nmkdir -p /tmp/update-deps-scratch\n' >>"$copy"
    run check_no_tmp "$copy"
    [ "$status" -ne 0 ] || {
      echo "the check passed with /tmp/ inserted into a copy of ${source}" >&2
      return 1
    }
  done
  [ "$count" -eq 5 ]
}

# ---------------------------------------------------------------------------
# 16. The worktree state line reads null apart from zero
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

@test "the state line prints security advisories unavailable for a null count" {
  run_state_line "{\"outdatedCount\":3,\"checkedAt\":$(date +%s),\"securityCount\":null,\"securitySource\":\"unavailable\"}"
  [ "$status" -eq 0 ]
  grep -qF -- 'Cached on main: 3 packages outdated, security advisories unavailable (last checked' <<<"$output"
  grep -qF -- '0 open security advisories' <<<"$output" && return 1
  true
}

@test "the state line prints 0 open security advisories for a zero count" {
  run_state_line "{\"outdatedCount\":3,\"checkedAt\":$(date +%s),\"securityCount\":0,\"securitySource\":\"dependabot\"}"
  [ "$status" -eq 0 ]
  grep -qF -- 'Cached on main: 3 packages outdated, 0 open security advisories (last checked' <<<"$output"
}

# ---------------------------------------------------------------------------
# 17. Report-only is a property of the security phase
# ---------------------------------------------------------------------------

REPORT_ONLY_SECURITY='the security phase adds, edits, and removes no `overrides:` key and applies no advisory-driven bump'
REPORT_ONLY_AUDIT='The existing Phase 0 and Phase 6 override audit is unchanged in those runs'

check_report_only_reading() {
  grep -qF -- "$REPORT_ONLY_SECURITY" "$1" || {
    echo "report-only no longer states the security phase leaves overrides alone" >&2
    return 1
  }
  grep -qF -- "$REPORT_ONLY_AUDIT" "$1" || {
    echo "report-only no longer states the Phase 0/6 audit is unchanged" >&2
    return 1
  }
}

@test "report-only runs leave overrides to the unchanged Phase 0/6 audit" {
  check_report_only_reading "$SKILL"
}

@test "the report-only check fails with the security-phase sentence deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "report-only.md")"
  remove_fixed "$copy" "$REPORT_ONLY_SECURITY"
  run check_report_only_reading "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 18. The security phase keeps its own snapshot directories
# ---------------------------------------------------------------------------

RESOLUTION_SNAPSHOT_PATH='.gaia/local/cache/shared/update-deps-security-resolution'

check_own_snapshots() {
  grep -qF -- '.gaia/local/cache/shared/update-deps-security-batch' "$1" || {
    echo "no batch snapshot under .gaia/local/cache/shared/" >&2
    return 1
  }
  grep -qF -- "$RESOLUTION_SNAPSHOT_PATH" "$1" || {
    echo "no per-resolution snapshot under .gaia/local/cache/shared/" >&2
    return 1
  }
  grep -qF -- 'rm -rf <snapshot>' "$1" || {
    echo "a snapshot directory is not cleared before it is taken" >&2
    return 1
  }
  if grep -qF -- 'update-deps-refresh' "$1"; then
    echo "the security recipe reuses the transitive refresh directory" >&2
    return 1
  fi
}

@test "the security recipe takes its own batch and per-resolution snapshots" {
  check_own_snapshots "$SECURITY"
}

@test "the snapshot check fails with the per-resolution snapshot moved to the refresh directory" {
  local copy
  copy="$(scratch_copy "$SECURITY" "snapshot.md")"
  replace_fixed "$copy" "$RESOLUTION_SNAPSHOT_PATH" '.gaia/local/cache/shared/update-deps-refresh'
  run check_own_snapshots "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 19. The override audit fails closed when pnpm audit does not answer
# ---------------------------------------------------------------------------

ADVISORY_CAPTURE='bash .gaia/scripts/override-audit-advisory-ids.sh'
PER_KEY_CAPTURE='bash .gaia/scripts/override-audit-advisory-ids.sh "$audit_now"'
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

@test "the fail-closed check fails with a capture reading pnpm audit directly" {
  local copy
  copy="$(scratch_copy "$OVERRIDE_AUDIT" "direct.md")"
  replace_fixed "$copy" "$PER_KEY_CAPTURE" 'pnpm audit --json 2>/dev/null | jq -r ".advisories // {} | keys[]?" | sort -u > "$audit_now"'
  run check_override_audit_fails_closed "$copy"
  [ "$status" -ne 0 ]
}

@test "the fail-closed check fails with the unanswered-baseline stop deleted" {
  local copy
  copy="$(scratch_copy "$OVERRIDE_AUDIT" "baseline.md")"
  remove_fixed "$copy" "$BASELINE_UNANSWERED"
  run check_override_audit_fails_closed "$copy"
  [ "$status" -ne 0 ]
}

@test "the fail-closed check fails with the per-key retention deleted" {
  local copy
  copy="$(scratch_copy "$OVERRIDE_AUDIT" "per-key.md")"
  remove_fixed "$copy" "$PER_KEY_UNANSWERED"
  run check_override_audit_fails_closed "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 20. Printed copy calls the transitive refresh the sub-dependency update
# ---------------------------------------------------------------------------

SUB_DEPENDENCY_LINE='`Sub-dependencies: also updates the packages your packages use to the newest'
SKIP_DESCRIPTION='skip, or say "sub-dependencies" to skip that part.`'
SKIP_SPELLING='which the human may type as `sub-dependencies`'

check_plain_sub_dependency_copy() {
  local skill="$1" report="$2"
  grep -qF -- "$SUB_DEPENDENCY_LINE" "$skill" || {
    echo "the preview's sub-dependency line is not stated" >&2
    return 1
  }
  grep -qF -- '**Update sub-dependencies** (Recommended, first option)' "$skill" || {
    echo "the zero-outdated option is not labelled Update sub-dependencies" >&2
    return 1
  }
  grep -qF -- '`Apply every update, including sub-dependencies.`' "$skill" || {
    echo "the Update all description does not name sub-dependencies" >&2
    return 1
  }
  grep -qF -- "$SKIP_DESCRIPTION" "$skill" || {
    echo "the Choose what to skip description does not offer the plain skip word" >&2
    return 1
  }
  grep -qF -- "$SKIP_SPELLING" "$skill" || {
    echo "the plain skip word is not accepted for transitive-refresh" >&2
    return 1
  }
  grep -qF -- '`Transitive refresh:' "$skill" && {
    echo "a printed line still opens with Transitive refresh:" >&2
    return 1
  }
  grep -qxF -- '### Sub-dependency updates' "$report" || {
    echo "the final report heading is not Sub-dependency updates" >&2
    return 1
  }
  grep -qxF -- '### Transitive refresh' "$report" && {
    echo "the final report still prints a Transitive refresh heading" >&2
    return 1
  }
  true
}

@test "printed copy names the transitive refresh as the sub-dependency update" {
  check_plain_sub_dependency_copy "$SKILL" "$FINAL_REPORT"
}

@test "the plain-copy check fails with the preview line reverted to jargon" {
  local copy
  copy="$(scratch_copy "$SKILL" "preview.md")"
  replace_fixed "$copy" "$SUB_DEPENDENCY_LINE" '`Transitive refresh: re-resolve every'
  run check_plain_sub_dependency_copy "$copy" "$FINAL_REPORT"
  [ "$status" -ne 0 ]
}

@test "the plain-copy check fails with the plain skip word no longer accepted" {
  local copy
  copy="$(scratch_copy "$SKILL" "spelling.md")"
  remove_fixed "$copy" "$SKIP_SPELLING"
  run check_plain_sub_dependency_copy "$copy" "$FINAL_REPORT"
  [ "$status" -ne 0 ]
}

@test "the plain-copy check fails with the skip description deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "description.md")"
  remove_fixed "$copy" "$SKIP_DESCRIPTION"
  run check_plain_sub_dependency_copy "$copy" "$FINAL_REPORT"
  [ "$status" -ne 0 ]
}

@test "the plain-copy check fails with the report heading reverted to jargon" {
  local copy
  copy="$(scratch_copy "$FINAL_REPORT" "report.md")"
  replace_fixed "$copy" '### Sub-dependency updates' '### Transitive refresh'
  run check_plain_sub_dependency_copy "$SKILL" "$copy"
  [ "$status" -ne 0 ]
}
