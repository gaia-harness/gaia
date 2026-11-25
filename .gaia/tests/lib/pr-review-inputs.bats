#!/usr/bin/env bats
#
# Flow test: the input bundle handed to the pull request reviewer, built from a
# PR that changes a script and a wiki page and closes one issue, then carried
# through the review record. It drives pr-review-bundle.sh and pr-review-record.sh
# at their entry points over a throwaway repository with a stub `gh`. Per-case
# literals of the bundle stay with pr-review-bundle.bats.
#
# Maintainer-only. `.gaia/tests` is release-excluded, so this never reaches an
# adopter.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/pr-review-inputs.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init

  GH_DIR="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$GH_DIR/bin"
  printf 'false\n' >"$GH_DIR/fork-answer"
  cat >"$GH_DIR/bin/gh" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "pr view")
    case "$*" in
      *isCrossRepository*) cat "$GH_DIR/fork-answer" ;;
      *) cat "$GH_DIR/pr.json" ;;
    esac ;;
  "issue view") cat "$GH_DIR/issue.json" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$GH_DIR/bin/gh"
  export GH_DIR PATH="$GH_DIR/bin:$PATH"

  mkdir -p "$ALF_ROOT/.claude/rules"
  printf 'always\n' >"$ALF_ROOT/.claude/rules/always.md"
  alf_git add -A
  alf_git commit -q -m context
  alf_git push -q origin main 2>/dev/null
  alf_git fetch -q origin
  alf_branch feat/review
  alf_fill src/a.sh 3 script
  alf_fill wiki/b.md 3 page
  alf_commit "feature"
  # The audit run's own files, which the bundle must not carry.
  printf '[]\n' >"$ALF_ROOT/.gaia/local/audit/abc.findings.json"
}

@test "a bundle built for the PR opens the review record at its head and the record takes a finding on a listed file" {
  jq -n -c --arg body "$(printf 'Summary line\n\nCloses #3743')" '{baseRefName: "main", body: $body}' >"$GH_DIR/pr.json"
  jq -n -c '{body: "Some request", authorAssociation: "OWNER"}' >"$GH_DIR/issue.json"

  local bundle="$BATS_TEST_TMPDIR/bundle"
  run bash "$SCRIPTS/pr-review-bundle.sh" --root "$ALF_ROOT" --pr 50 --out "$bundle"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -qxF src/a.sh "$bundle/changed-files.txt" || return 1
  grep -qxF wiki/b.md "$bundle/changed-files.txt" || return 1
  local reviewed_head
  reviewed_head="$(jq -r '.reviewed_head' "$bundle/meta.json")"
  [ "$reviewed_head" = "$ALF_COMMIT" ] || return 1

  local run_folder="$ALF_ROOT/.gaia/local/runs/feat/review"
  run bash "$SCRIPTS/pr-review-record.sh" open --root "$ALF_ROOT" --run-folder "$run_folder" --pr 50 \
    --head "$reviewed_head" --bundle "$bundle"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = opened ] || return 1

  run bash "$SCRIPTS/pr-review-record.sh" attempt-open --run-folder "$run_folder"
  [ "$status" -eq 0 ] || return 1
  local findings="$BATS_TEST_TMPDIR/findings.json"
  jq -n -c '[{file: "src/a.sh", line: 2, severity: "Major", summary: "a defect", failure_scenario: "the failing input", verified: true}]' >"$findings"
  run bash "$SCRIPTS/pr-review-record.sh" outcome --run-folder "$run_folder" --findings "$findings"
  [ "$status" -eq 0 ] || return 1

  local record="$run_folder/pr-review.json"
  [ "$(jq -r '.reviewed_head' "$record")" = "$reviewed_head" ] || return 1
  [ "$(jq -r '.outcome' "$record")" = ran ] || return 1
  [ "$(jq -r '[.findings[] | "\(.id) \(.file)"] | join(",")' "$record")" = "pr-1 src/a.sh" ] || return 1
}
