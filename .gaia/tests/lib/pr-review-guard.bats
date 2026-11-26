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

# arm_branch_digests: put the fixture on a branch with a local base reference
# and the audit roster, the inputs the branch-own digests need.
arm_branch_digests() {
  git -C "$FIXTURE" update-ref refs/remotes/origin/main HEAD
  git -C "$FIXTURE" checkout -q -b feat/x
  mkdir -p "$FIXTURE/.gaia"
  cp "$REPO_ROOT/.gaia/audit-ci.yml" "$FIXTURE/.gaia/audit-ci.yml"
  printf 'b\n' >>"$FIXTURE/wiki/a.md"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m branch
  AUDIT_DIRECTORY="$FIXTURE/.gaia/local/audit"
  OWN_DIGEST=$(bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_branch_digests_local "$2"' _ "$REPO_ROOT" "$FIXTURE" | head -n 1 | cut -f2)
  [ "${#OWN_DIGEST}" -eq 64 ]
  FOREIGN_DIGEST=$(printf 'f%.0s' $(seq 1 64))
  FOREIGN_TREE=$(printf 'a%.0s' $(seq 1 40))
  FOREIGN_SHA=$(printf 'b%.0s' $(seq 1 40))
  HEAD_SHA=$(git -C "$FIXTURE" rev-parse HEAD)
  HEAD_TREE=$(git -C "$FIXTURE" rev-parse 'HEAD^{tree}')
}

# marker_body <tree> <sha> [<digest>]: an earned marker body.
marker_body() {
  printf '{"member":"code-audit-frontend","provenance":"earned","digest":"%s","tree":"%s","sha":"%s"}\n' "${3:-x}" "$1" "$2"
}

@test "compare ignores audit records another lane writes for another head or branch" {
  arm_branch_digests
  marker_body "$HEAD_TREE" "$HEAD_SHA" "$OWN_DIGEST" >"$AUDIT_DIRECTORY/$OWN_DIGEST.ok"
  take_snapshot
  printf '[]' >"$REVIEWER_OUTPUT"
  marker_body "$FOREIGN_TREE" "$FOREIGN_SHA" >"$AUDIT_DIRECTORY/$FOREIGN_DIGEST.code-audit-maintainer-shell.ok"
  printf '{}\n' >"$AUDIT_DIRECTORY/$FOREIGN_SHA.other-branch.code-audit-frontend.findings.json"
  run compare_after
  [ "$status" -eq 0 ]
}

@test "compare stops when the reviewed head's own marker is rewritten" {
  arm_branch_digests
  marker_body "$HEAD_TREE" "$HEAD_SHA" "$OWN_DIGEST" >"$AUDIT_DIRECTORY/$OWN_DIGEST.ok"
  take_snapshot
  printf '[]' >"$REVIEWER_OUTPUT"
  marker_body "$HEAD_TREE" "$HEAD_SHA" changed >"$AUDIT_DIRECTORY/$OWN_DIGEST.ok"
  run compare_after
  [ "$status" -eq 1 ]
  [ "$output" = "PR review changed audit state: .gaia/local/audit/$OWN_DIGEST.ok" ]
}

@test "compare stops on a marker forged at the reviewed head's own digest, even one that lies about its tree" {
  arm_branch_digests
  take_snapshot
  printf '[]' >"$REVIEWER_OUTPUT"
  marker_body "$FOREIGN_TREE" "$FOREIGN_SHA" >"$AUDIT_DIRECTORY/$OWN_DIGEST.code-audit-maintainer-shell.ok"
  run compare_after
  [ "$status" -eq 1 ]
}

@test "compare stops on a marker at another digest that names this branch's own tree" {
  arm_branch_digests
  take_snapshot
  printf '[]' >"$REVIEWER_OUTPUT"
  marker_body "$HEAD_TREE" "$HEAD_SHA" >"$AUDIT_DIRECTORY/$FOREIGN_DIGEST.ok"
  run compare_after
  [ "$status" -eq 1 ]
}

@test "compare stops when this branch's own rerun ledger changes" {
  arm_branch_digests
  ledger="$AUDIT_DIRECTORY/$HEAD_SHA.feat%2Fx.rerun.json"
  printf '{"round":1}\n' >"$ledger"
  take_snapshot
  printf '[]' >"$REVIEWER_OUTPUT"
  printf '{"round":2}\n' >"$ledger"
  run compare_after
  [ "$status" -eq 1 ]
  [ "$output" = "PR review changed audit state: .gaia/local/audit/$HEAD_SHA.feat%2Fx.rerun.json" ]
}

@test "compare keeps every marker in the check when the branch's own digests cannot be computed" {
  # The default fixture has no local base reference and no roster, so no marker can be attributed.
  take_snapshot
  printf '[]' >"$REVIEWER_OUTPUT"
  marker_body "$(printf 'a%.0s' $(seq 1 40))" "$(printf 'b%.0s' $(seq 1 40))" >"$FIXTURE/.gaia/local/audit/$(printf 'f%.0s' $(seq 1 64)).ok"
  run compare_after
  [ "$status" -eq 1 ]
}
