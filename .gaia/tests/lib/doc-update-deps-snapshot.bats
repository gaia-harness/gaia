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
# Each check is a function over a file path, so every test that proves the real
# page passes has a twin that runs the same function over a scratch copy with
# the guarded content removed or altered and asserts it fails.
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

# scratch_copy <source> <name>: copy a file into the test's temp dir and print
# the copy's path, so a mutation never touches the shared tree.
scratch_copy() {
  local copy="${BATS_TEST_TMPDIR}/$2"
  cp "$1" "$copy"
  printf '%s\n' "$copy"
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

@test "the copy check fails on a lockfile cp inserted into each recipe" {
  local source copy
  for source in "$REFRESH" "$SECURITY"; do
    copy="$(scratch_copy "$source" "copy-$(basename "$source")")"
    printf '\n   cp package.json pnpm-lock.yaml /tmp/update-deps-refresh/\n' >>"$copy"
    run check_no_lockfile_copy "$copy"
    [ "$status" -ne 0 ] || {
      echo "the check passed with a lockfile cp inserted into ${source}" >&2
      return 1
    }
  done
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

@test "the baseline check fails with each baseline step removed from each recipe" {
  local source needle copy
  for source in "$REFRESH" "$SECURITY"; do
    for needle in "$BASELINE_CREATE" "$BASELINE_FALLBACK" "$BASELINE_HOLDS_LOCKFILE" "$BASELINE_RESTORE"; do
      copy="$(scratch_copy "$source" "baseline-$(basename "$source")")"
      replace_fixed "$copy" "$needle" 'git status'
      run check_git_baseline "$copy"
      [ "$status" -ne 0 ] || {
        echo "the check passed with '${needle}' removed from ${source}" >&2
        return 1
      }
    done
  done
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

@test "the refresh stop check fails with the stop sentence deleted" {
  local copy
  copy="$(scratch_copy "$REFRESH" "stop.md")"
  replace_fixed "$copy" "$REFRESH_STOP" ''
  run check_refresh_stops "$copy"
  [ "$status" -ne 0 ]
}

@test "the refresh stop check fails with the stop sentence moved after the refresh step" {
  local copy
  copy="$(scratch_copy "$REFRESH" "late.md")"
  replace_fixed "$copy" "$REFRESH_STOP" ''
  printf '\n%s\n' "$REFRESH_STOP" >>"$copy"
  run check_refresh_stops "$copy"
  [ "$status" -ne 0 ]
}

@test "the refresh stop check fails with the reported outcome deleted" {
  local copy
  copy="$(scratch_copy "$REFRESH" "outcome.md")"
  replace_fixed "$copy" "$REFRESH_OUTCOME" '`Reverted (<reason>)`'
  run check_refresh_stops "$copy"
  [ "$status" -ne 0 ]
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

@test "the security stop check fails with each stop clause deleted" {
  local needle copy
  for needle in "$SECURITY_STOP" "$SECURITY_BATCH_STOP" "$SECURITY_OUTCOME"; do
    copy="$(scratch_copy "$SECURITY" "security-stop.md")"
    replace_fixed "$copy" "$needle" ''
    run check_security_stops "$copy"
    [ "$status" -ne 0 ] || {
      echo "the check passed with '${needle}' deleted" >&2
      return 1
    }
  done
}

@test "the security stop check fails with the stop moved after the methods step" {
  local copy
  copy="$(scratch_copy "$SECURITY" "security-late.md")"
  replace_fixed "$copy" "$SECURITY_STOP" ''
  printf '\n%s\n' "$SECURITY_STOP" >>"$copy"
  run check_security_stops "$copy"
  [ "$status" -ne 0 ]
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

@test "the outcome check fails with the outcome deleted from each page" {
  local source copy
  for source in "$SKILL" "$FINAL_REPORT"; do
    copy="$(scratch_copy "$source" "carried-$(basename "$source")")"
    replace_fixed "$copy" 'Not run (snapshot failed: <reason>)' 'Nothing moved'
    run check_outcome_carried "$copy"
    [ "$status" -ne 0 ] || {
      echo "the check passed with the outcome deleted from ${source}" >&2
      return 1
    }
  done
}
