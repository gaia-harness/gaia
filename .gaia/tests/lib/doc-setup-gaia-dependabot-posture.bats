#!/usr/bin/env bats
# The Phase 3 Dependabot posture step in the GitHub repository setup
# reference: it calls the configure-dependabot-alerts subcommand, warns about
# existing Dependabot and Renovate config, tells the human what to change, and
# never instructs a write, create, or edit of `.github/dependabot.yml`.
#
# Each check is a function over a file path, so every test that proves the real
# reference passes has a twin that runs the same function over a scratch copy
# with the content removed or the forbidden instruction inserted and asserts it
# fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  GITHUB_REPO_REFERENCE="${REPO_ROOT}/.claude/skills/gaia/references/setup/github-repo.md"
  [ -f "$GITHUB_REPO_REFERENCE" ] || {
    echo "the GitHub repository reference is absent: ${GITHUB_REPO_REFERENCE}" >&2
    return 1
  }
}

# scratch_copy <source> <name>: copy a file into the test's temp dir and print
# the copy's path, so a mutation never touches the shared tree.
scratch_copy() {
  local copy="${BATS_TEST_TMPDIR}/$2"
  cp "$1" "$copy"
  printf '%s\n' "$copy"
}

# ---------------------------------------------------------------------------
# The posture step calls its subcommand
# ---------------------------------------------------------------------------

# check_posture_subcommand <file>: the page invokes the posture subcommand.
check_posture_subcommand() {
  grep -qF -- 'setup configure-dependabot-alerts' "$1" || {
    echo "the page does not invoke setup configure-dependabot-alerts" >&2
    return 1
  }
}

@test "the posture step calls the configure-dependabot-alerts subcommand" {
  check_posture_subcommand "$GITHUB_REPO_REFERENCE"
}

@test "the posture-subcommand check fails when the subcommand is renamed" {
  local copy
  copy="$(scratch_copy "$GITHUB_REPO_REFERENCE" "posture-call-renamed.md")"
  sed 's/setup configure-dependabot-alerts/setup configure-dependabot-alert/g' "$GITHUB_REPO_REFERENCE" >"$copy"
  cmp -s "$GITHUB_REPO_REFERENCE" "$copy" && return 1
  run check_posture_subcommand "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The Dependabot posture step warns and never edits
# ---------------------------------------------------------------------------

# posture_section <file>: the posture step's text, from its bold lead-in to the
# next level-two heading.
posture_section() {
  awk '
    /^## / { inside = 0 }
    /^\*\*Dependabot posture\.\*\*/ { inside = 1 }
    inside
  ' "$1"
}

# check_posture_warns_only <file>: passes only when the posture step invokes
# warn-existing-tools, tells the human to delete the npm entry, tells the human
# to disable Renovate's npm and pnpm management, and instructs no write,
# create, or edit of .github/dependabot.yml. The removal step is phrased with
# "delete", the refusals avoid those verbs, and "writes" (as in "GAIA writes
# no ...") is a different word, so only an imperative write, create, or edit
# verb on a line naming dependabot.yml counts as an edit instruction.
check_posture_warns_only() {
  local section
  section="$(posture_section "$1")"
  [ -n "$section" ] || {
    echo "the posture step is absent" >&2
    return 1
  }
  grep -qF -- 'setup warn-existing-tools' <<<"$section" || {
    echo "the posture step does not invoke warn-existing-tools" >&2
    return 1
  }
  grep -qE 'delete the `package-ecosystem: npm` entry from \.github/dependabot\.yml' <<<"$section" || {
    echo "the posture step does not tell the human to delete the npm entry" >&2
    return 1
  }
  grep -E 'disable Renovate' <<<"$section" | grep -qF 'npm and pnpm' || {
    echo "the posture step carries no Renovate warning naming the disable step" >&2
    return 1
  }
  if grep -iE 'dependabot\.ya?ml' <<<"$section" | grep -qiE '(^|[^a-z])(write|create|edit)([^a-z]|$)'; then
    echo "the posture step instructs a write, create, or edit of dependabot.yml" >&2
    return 1
  fi
  return 0
}

@test "the posture step warns about existing tools and never edits their files" {
  check_posture_warns_only "$GITHUB_REPO_REFERENCE"
}

@test "the posture check fails when the warn-existing-tools call is removed" {
  local copy
  copy="$(scratch_copy "$GITHUB_REPO_REFERENCE" "posture-no-warn.md")"
  grep -vF -- 'setup warn-existing-tools' "$GITHUB_REPO_REFERENCE" >"$copy" || true
  cmp -s "$GITHUB_REPO_REFERENCE" "$copy" && return 1
  run check_posture_warns_only "$copy"
  [ "$status" -ne 0 ]
}

@test "the posture check fails when the npm entry removal sentence is removed" {
  local copy
  copy="$(scratch_copy "$GITHUB_REPO_REFERENCE" "posture-no-removal.md")"
  grep -vF -- 'package-ecosystem: npm' "$GITHUB_REPO_REFERENCE" >"$copy" || true
  cmp -s "$GITHUB_REPO_REFERENCE" "$copy" && return 1
  run check_posture_warns_only "$copy"
  [ "$status" -ne 0 ]
}

@test "the posture check fails when the Renovate warning is removed" {
  local copy
  copy="$(scratch_copy "$GITHUB_REPO_REFERENCE" "posture-no-renovate.md")"
  grep -vF -- 'disable Renovate' "$GITHUB_REPO_REFERENCE" >"$copy" || true
  cmp -s "$GITHUB_REPO_REFERENCE" "$copy" && return 1
  run check_posture_warns_only "$copy"
  [ "$status" -ne 0 ]
}

@test "the posture check fails when an instruction to write dependabot.yml is inserted" {
  local copy
  copy="$(scratch_copy "$GITHUB_REPO_REFERENCE" "posture-writes.md")"
  awk '{ print } /^\*\*Dependabot posture\.\*\*/ { print ""; print "Write .github/dependabot.yml with the npm entry." }' \
    "$GITHUB_REPO_REFERENCE" >"$copy"
  cmp -s "$GITHUB_REPO_REFERENCE" "$copy" && return 1
  run check_posture_warns_only "$copy"
  [ "$status" -ne 0 ]
}
