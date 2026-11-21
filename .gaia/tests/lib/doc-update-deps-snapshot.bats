#!/usr/bin/env bats
#
# Doc-pin: the /update-deps snapshots that guard the lockfile are git baselines
# that stop the run when they fail.
#
# Static checks over the two recipes that snapshot the lockfile before changing
# it, `.claude/skills/update-deps/references/transitive-refresh.md` (Phase 5b)
# and `references/security.md` (Phase 5c), and the outcome they report in
# `SKILL.md` and `references/final-report.md`.
#
# Why the baseline is a git object: the shipped `.claude/settings.json` denies
# `Edit(pnpm-lock.yaml)`, and Claude Code refuses a `cp` of the file
# in either direction and a redirect that writes to it, so the copy and the copy back are
# refused in every session, sandboxed or not. A recipe that copies the lockfile
# has no baseline, and one that does not stop on a failed snapshot then
# rewrites the lockfile with nothing to revert to.
#
# What these checks cannot see: whether the executing agent obeys the stop
# sentence. They pin that the sentence is there and comes before the first
# command that changes the tree.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SKILL_DIR="${REPO_ROOT}/.claude/skills/update-deps"
  SKILL="${SKILL_DIR}/SKILL.md"
  REFRESH="${SKILL_DIR}/references/transitive-refresh.md"
  SECURITY="${SKILL_DIR}/references/security.md"
  FINAL_REPORT="${SKILL_DIR}/references/final-report.md"
  local file
  for file in "$SKILL" "$REFRESH" "$SECURITY" "$FINAL_REPORT"; do
    [ -f "$file" ] || {
      echo "an audited page is absent: ${file}" >&2
      return 1
    }
  done
}

# first_line <file> <fixed-string>: print the line number of the first line
# holding the string, or nothing.
first_line() {
  grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

LOCKFILE_COPY_PATTERN='^[[:space:]]*cp [^#]*pnpm-lock\.yaml'
BASELINE_CREATE='git stash create'
BASELINE_FALLBACK='git rev-parse HEAD'
BASELINE_HOLDS_LOCKFILE='git cat-file -e <'
BASELINE_RESTORE='git restore --source=<'
REFRESH_STOP='**If any of them exits non-zero or is refused, stop here:** do not run step 2'
REFRESH_STEP='2. **Refresh:**'
REFRESH_OUTCOME='`Not run (snapshot failed: <reason>)`'
SECURITY_STOP='**A snapshot that fails stops what it guards.**'
SECURITY_BATCH_STOP='a failed batch snapshot applies no resolution'
SECURITY_FIRST_APPLY='#### 4. Methods'
SECURITY_OUTCOME='`snapshot failed (<command>: <first error line>)`'

# ---------------------------------------------------------------------------
# 1. No recipe copies the lockfile
# ---------------------------------------------------------------------------

check_no_lockfile_copy() {
  if grep -En -- "$LOCKFILE_COPY_PATTERN" "$1" >&2; then
    echo "a cp names pnpm-lock.yaml in ${1}; the shipped deny refuses it" >&2
    return 1
  fi
}

@test "neither snapshot recipe copies the lockfile" {
  check_no_lockfile_copy "$REFRESH"
  check_no_lockfile_copy "$SECURITY"
}

# ---------------------------------------------------------------------------
# 2. Each recipe takes and restores a git baseline
# ---------------------------------------------------------------------------

check_git_baseline() {
  local needle
  for needle in "$BASELINE_CREATE" "$BASELINE_FALLBACK" "$BASELINE_HOLDS_LOCKFILE" "$BASELINE_RESTORE"; do
    grep -qF -- "$needle" "$1" || {
      echo "${1} lacks the baseline step: ${needle}" >&2
      return 1
    }
  done
}

@test "both recipes take, check and restore a git baseline" {
  check_git_baseline "$REFRESH"
  check_git_baseline "$SECURITY"
}

# ---------------------------------------------------------------------------
# 3. A failed snapshot stops the refresh before it touches the lockfile
# ---------------------------------------------------------------------------

check_refresh_stops() {
  local stop_at refresh_at
  stop_at="$(first_line "$1" "$REFRESH_STOP")"
  refresh_at="$(first_line "$1" "$REFRESH_STEP")"
  [ -n "$stop_at" ] || {
    echo "the refresh recipe does not stop on a failed snapshot" >&2
    return 1
  }
  [ -n "$refresh_at" ] || {
    echo "the refresh recipe has no refresh step" >&2
    return 1
  }
  [ "$stop_at" -lt "$refresh_at" ] || {
    echo "the stop on a failed snapshot comes after the refresh step" >&2
    return 1
  }
  grep -qF -- "$REFRESH_OUTCOME" "$1" || {
    echo "the refresh recipe does not report a failed snapshot" >&2
    return 1
  }
}

@test "the refresh stops on a failed snapshot before its refresh step" {
  check_refresh_stops "$REFRESH"
}

# ---------------------------------------------------------------------------
# 4. A failed security snapshot applies nothing it would have guarded
# ---------------------------------------------------------------------------

check_security_stops() {
  local stop_at apply_at needle
  for needle in "$SECURITY_STOP" "$SECURITY_BATCH_STOP" "$SECURITY_OUTCOME"; do
    grep -qF -- "$needle" "$1" || {
      echo "the security recipe lacks: ${needle}" >&2
      return 1
    }
  done
  stop_at="$(first_line "$1" "$SECURITY_STOP")"
  apply_at="$(first_line "$1" "$SECURITY_FIRST_APPLY")"
  [ -n "$apply_at" ] || {
    echo "the security recipe has no methods step" >&2
    return 1
  }
  [ "$stop_at" -lt "$apply_at" ] || {
    echo "the stop on a failed snapshot comes after the first resolution method" >&2
    return 1
  }
}

@test "the security phase applies nothing behind a failed snapshot" {
  check_security_stops "$SECURITY"
}

# ---------------------------------------------------------------------------
# 5. The orchestrator and the report carry the failed-snapshot outcome
# ---------------------------------------------------------------------------

check_outcome_carried() {
  local file
  for file in "$@"; do
    grep -qF -- 'Not run (snapshot failed: <reason>)' "$file" || {
      echo "${file} does not carry the failed-snapshot outcome" >&2
      return 1
    }
  done
}

@test "SKILL.md and the final report carry the failed-snapshot outcome" {
  check_outcome_carried "$SKILL" "$FINAL_REPORT"
}
