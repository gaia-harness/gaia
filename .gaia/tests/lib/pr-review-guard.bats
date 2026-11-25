#!/usr/bin/env bats
#
# Suite for .gaia/scripts/pr-review-guard.sh, the before/after check around the
# read-only pull request reviewer. Each case drives the script through its
# arguments, exit status and output over a throwaway git repository whose local
# state folder is ignored, with a fake `gh` answering the commit statuses.
#
# Maintainer-only. `.gaia/tests` is release-excluded, so this never reaches an
# adopter.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/pr-review-guard.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GUARD="$REPO_ROOT/.gaia/scripts/pr-review-guard.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$FIXTURE/wiki" "$FIXTURE/.gaia/local/audit" "$FIXTURE/.gaia/local/runs/feat-x" "$SCRATCH" "$BATS_TEST_TMPDIR/bin"
  git -C "$FIXTURE" init -q
  git -C "$FIXTURE" config user.email t@example.com
  git -C "$FIXTURE" config user.name t
  printf '.gaia/local/\n' >"$FIXTURE/.gitignore"
  printf 'a\n' >"$FIXTURE/wiki/a.md"
  printf 'one\n' >"$FIXTURE/.gaia/local/audit/abc.findings.json"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m init
  # The fake gh prints whatever the test last put in the statuses file.
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SCRATCH/statuses.json" >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  printf '[{"context":"GAIA-Audit","state":"success"}]' >"$SCRATCH/statuses.json"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  SNAPSHOT="$SCRATCH/before.json"
  AFTER="$SCRATCH/after.json"
  REVIEWER_OUTPUT="$SCRATCH/review.json"
}

take_snapshot() {
  "$GUARD" snapshot --root "$FIXTURE" --run-folder "$FIXTURE/.gaia/local/runs/feat-x" --pr 7 --out "$SNAPSHOT"
}

compare_after() {
  "$GUARD" compare --before "$SNAPSHOT" --after "$AFTER" --output-file "$REVIEWER_OUTPUT"
}

@test "compare ignores a commit status other than GAIA-Audit posted during the review" {
  take_snapshot
  printf '[]' >"$REVIEWER_OUTPUT"
  printf '[{"context":"GAIA-Audit","state":"success"},{"context":"chromatic","state":"pending"}]' >"$SCRATCH/statuses.json"
  run compare_after
  [ "$status" -eq 0 ]
}

@test "snapshot and compare stop on a dirty tree, changed audit state or changed commit statuses" {
  # A dirty tree before the dispatch refuses the snapshot.
  printf 'b\n' >>"$FIXTURE/wiki/a.md"
  run "$GUARD" snapshot --root "$FIXTURE" --run-folder "$FIXTURE/.gaia/local/runs/feat-x" --pr 7 --out "$SNAPSHOT"
  [ "$status" -eq 1 ]
  [ "$output" = 'PR review: tree dirty before dispatch: wiki/a.md' ]
  git -C "$FIXTURE" checkout -q -- wiki/a.md

  # Nothing changed, the reviewer's own output file aside: clean.
  take_snapshot
  printf '[]' >"$REVIEWER_OUTPUT"
  run compare_after
  [ "$status" -eq 0 ]

  # A modified tracked file and an untracked one are both named, sorted.
  printf 'b\n' >>"$FIXTURE/wiki/a.md"
  printf 'x\n' >"$FIXTURE/new.md"
  run compare_after
  [ "$status" -eq 1 ]
  [ "$output" = 'PR review left the tree dirty: new.md,wiki/a.md' ]
  git -C "$FIXTURE" checkout -q -- wiki/a.md
  rm "$FIXTURE/new.md"

  # An added audit file is the first changed path.
  : >"$FIXTURE/.gaia/local/audit/abc.ok"
  run compare_after
  [ "$status" -eq 1 ]
  [ "$output" = 'PR review changed audit state: .gaia/local/audit/abc.ok' ]
  rm "$FIXTURE/.gaia/local/audit/abc.ok"

  # A rewritten audit file reads as a change too.
  printf 'two\n' >"$FIXTURE/.gaia/local/audit/abc.findings.json"
  run compare_after
  [ "$status" -eq 1 ]
  [ "$output" = 'PR review changed audit state: .gaia/local/audit/abc.findings.json' ]
  printf 'one\n' >"$FIXTURE/.gaia/local/audit/abc.findings.json"

  # A changed status list is reported on HEAD's short sha.
  printf '[{"context":"GAIA-Audit","state":"failure"}]' >"$SCRATCH/statuses.json"
  run compare_after
  [ "$status" -eq 1 ]
  short_sha=$(git -C "$FIXTURE" rev-parse --short=7 HEAD)
  [ "$output" = "PR review changed commit statuses on $short_sha" ]
}
