#!/usr/bin/env bats
# The merge-setting defaults of /setup-gaia: on a repo the run created
# (`REPO_CHOICE` is `create`, no `--reconfigure`), delete_branch_on_merge in
# `.claude/skills/gaia/references/setup/github-repo.md` and the squash-only
# PATCH in `.claude/skills/gaia/references/setup/squash-only.md` apply with no
# question; an adopted repo, or a `--reconfigure` run, is still asked. The
# delete-branch question also says truthfully when GAIA's own merges leave a
# branch behind.
#
# Assertion style: .claude/rules/bats-assertions.md.

CREATE_ARM='`REPO_CHOICE` is `create`'

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  GITHUB_REPO="${REPO_ROOT}/.claude/skills/gaia/references/setup/github-repo.md"
  SQUASH_ONLY="${REPO_ROOT}/.claude/skills/gaia/references/setup/squash-only.md"
  local file
  for file in "$GITHUB_REPO" "$SQUASH_ONLY"; do
    [ -f "$file" ] || {
      echo "the audited page is absent: ${file}" >&2
      return 1
    }
  done
  DELETE_BRANCH="$(awk '/^\*\*delete_branch_on_merge\.\*\*/ { inside = 1 } inside && /^\*\*Squash-only merges\.\*\*/ { exit } inside' "$GITHUB_REPO")"
  [ -n "$DELETE_BRANCH" ] || {
    echo "the delete_branch_on_merge block of ${GITHUB_REPO} is missing" >&2
    return 1
  }
}

@test "the connect question caches REPO_CHOICE for the merge-setting defaults" {
  grep -qF -- 'Cache the answer as `REPO_CHOICE`: `create`, `adopt` or `manual`' "$GITHUB_REPO"
}

@test "delete_branch_on_merge applies silently on a created repo and asks otherwise" {
  grep -qF -- "$CREATE_ARM" <<<"$DELETE_BRANCH"
  grep -qF -- '`RECONFIGURE` not set, run the Enable block below with no question' <<<"$DELETE_BRANCH"
  grep -qF -- 'Otherwise AskUserQuestion:' <<<"$DELETE_BRANCH"
  grep -qF -- '**Enable delete_branch_on_merge** (Recommended)' <<<"$DELETE_BRANCH"
}

@test "squash-only applies silently on a created repo and asks otherwise" {
  grep -qF -- "$CREATE_ARM" "$SQUASH_ONLY"
  grep -qF -- '`RECONFIGURE` is not set, run the PATCH below with no question' "$SQUASH_ONLY"
  grep -qF -- 'Otherwise AskUserQuestion:' "$SQUASH_ONLY"
  grep -qF -- '**Make merges squash-only** (Recommended)' "$SQUASH_ONLY"
}

@test "the delete-branch question no longer claims GAIA runs no branch cleanup" {
  grep -qF -- 'GAIA runs no branch cleanup' <<<"$DELETE_BRANCH" && return 1
  grep -qF -- 'a pull request merged on github.com leaves its branch behind' <<<"$DELETE_BRANCH"
}
