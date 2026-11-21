#!/usr/bin/env bats

# Tests for `command_targets_foreign_repo_slug` in
# `.claude/hooks/lib/repo-scope.sh`, the act-on-home entry point.
#
# The sibling `command_targets_foreign_repo` serves BLOCKING consumers, where
# "home" means enforce, so it resolves every ambiguity to "home" and compares
# only the repo-NAME half of a `-R`/`--repo` value against the repository
# names the home repo's remotes point at. A consumer that ACTS on the home
# repo inverts both
# properties: reading a foreign command as home makes it write to a pull
# request or an issue the command never named, so ambiguity resolves to
# "foreign", and the comparison is the whole [HOST/]OWNER/REPO that gh uses to
# identify a repository.
#
# The inversion reaches the whole question, not one arm of it. This entry point
# reads the merge with the lib's first-command scan rather than sharing the
# blocking guard's cwd arms, so any prefix ahead of the merge means the first
# command is not the merge and the verdict is foreign; s11 and s17 pin that.
#
# The suite drives the REAL lib (sourced by absolute path, never copied)
# against a sandbox git repo, with a fake `gh` on PATH answering
# `repo view --json nameWithOwner,url`. The repository the sandbox's origin
# remote points at and its home slug are deliberately UNRELATED (`gaia` vs
# `acme/widgets`), which is what lets a single fixture tell the two
# comparisons apart: a value the name-half comparison calls home and the slug
# comparison calls foreign.

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  LIBRARY_ABSOLUTE_PATH=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/repo-scope.sh

  PARENT=$(mktemp -d -t repo-scope-slug-test-XXXXXX)
  REPO="$PARENT/gaia"
  SIBLING="$PARENT/other"
  for repository_directory in "$REPO" "$SIBLING"; do
    mkdir -p "$repository_directory"
    git -C "$repository_directory" init --quiet --initial-branch=main
    git -C "$repository_directory" config user.email "test@example.com"
    git -C "$repository_directory" config user.name "Test"
    git -C "$repository_directory" config commit.gpgsign false
    echo "# readme" > "$repository_directory/README.md"
    git -C "$repository_directory" add README.md
    git -C "$repository_directory" commit --quiet -m "init"
  done
  git -C "$REPO" remote add origin https://github.com/me/gaia.git

  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  cat > "$GH_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
[ "${FAKE_GH_REPO_VIEW_EXIT:-0}" -eq 0 ] || exit "$FAKE_GH_REPO_VIEW_EXIT"
HOME_REPO="${FAKE_GH_HOME_REPO:-acme/widgets}"
HOME_HOST="${FAKE_GH_HOME_HOST:-github.com}"
case "$1 $2" in
  "repo view")
    jq -n --arg name_with_owner "$HOME_REPO" --arg url "https://$HOME_HOST/$HOME_REPO" \
      '{nameWithOwner: $name_with_owner, url: $url}'
    exit 0
    ;;
esac
exit 1
STUBEOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

teardown() {
  [ -n "${PARENT:-}" ] && rm -rf "$PARENT"
  return 0
}

# Ask the entry point about one command, from inside the sandbox repo, in a
# fresh subshell so the lib's memoized home resolution never leaks between
# cases. Echoes `foreign` or `home` so a test asserts on a word rather than on
# an inverted exit status.
#
# `set -u` is the consumers' own setting, and it is load-bearing here rather
# than hygiene: the scan hands back an array whose length the command decides,
# so an index read past the end is a fatal error under `set -u` and no error at
# all without it. Reading a verdict from a permissive shell would report every
# such read as the verdict it would have produced had it not aborted.
verdict() {
  ( cd "$REPO" || exit 1
    set -u
    # shellcheck source=/dev/null
    . "$LIBRARY_ABSOLUTE_PATH"
    if command_targets_foreign_repo_slug "$1"; then echo foreign; else echo home; fi )
}

# The name-half verdict of the blocking guard, for the fixtures whose whole
# point is that the two disagree.
name_half_verdict() {
  ( cd "$REPO" || exit 1
    # shellcheck source=/dev/null
    . "$LIBRARY_ABSOLUTE_PATH"
    if command_targets_foreign_repo "$1"; then echo foreign; else echo home; fi )
}

# Fail with the row's name when a verdict is not the expected one.
expect_verdict() {
  local row="$1" expected="$2" command_text="$3" actual
  actual="$(verdict "$command_text")"
  if [ "$actual" != "$expected" ]; then
    echo "row '$row': expected $expected, got $actual for: $command_text" >&2
    return 1
  fi
}

# One comparison rule: the whole [HOST/]OWNER/REPO decides, in any flag
# spelling. GitHub resolves OWNER/REPO case-insensitively, so a case-only
# difference is home; the same OWNER/REPO on another host is another
# repository; gh accepts flags in any position and in the = form; the scan
# resolves quoting the way the shell does, so the value gh receives is the value
# compared.
@test "slug comparison: the whole [HOST/]OWNER/REPO decides, in any flag spelling" {
  expect_verdict "s2 the home slug is home" home 'gh pr merge --repo acme/widgets 5'
  expect_verdict "s3 a home slug differing only in case is home" home 'gh pr merge --repo ACME/Widgets 5'
  expect_verdict "s4 an owner differing from home is foreign even with the same name" foreign 'gh pr merge --repo other-org/widgets 5'
  expect_verdict "s6 the = form is read" foreign 'gh pr merge --repo=other-org/widgets 5'
  expect_verdict "s7 a trailing flag decides as much as a leading one" foreign 'gh pr merge 5 --repo other-org/widgets'
  expect_verdict "s8 a host qualifier naming the home host is home" home 'gh pr merge --repo github.com/acme/widgets 5'
  expect_verdict "s9 a host qualifier naming another host is foreign" foreign 'gh pr merge --repo ghe.example.com/acme/widgets 5'
  expect_verdict "s13 a quoted double flag value is read, quotes removed" home 'gh pr merge --repo="acme/widgets" 5'
  expect_verdict "s13 a quoted single flag value is read, quotes removed" foreign "gh pr merge --repo='other-org/widgets' 5"
}

@test "s10: a merge naming no explicit target reads home" {
  # The merge is the first command in the tool call, so nothing redirected cwd
  # ahead of it and gh resolves from the hook's own checkout.
  [ "$(verdict 'gh pr merge 5')" = "home" ]
}

@test "s12: an unresolvable home is foreign, not home" {
  # Fail direction, and the whole reason this is a separate entry point: an
  # acting consumer that cannot identify its own repository must decline.
  export FAKE_GH_REPO_VIEW_EXIT=1
  [ "$(verdict 'gh pr merge --repo acme/widgets 5')" = "foreign" ]
}

# Only the first command decides. A cwd redirection ahead of the merge, or a
# first command that only resembles it, fails the first-command requirement and
# reads foreign (declining costs a findings-block posting rather than a write
# onto a pull request in a repository the merge never named). A later command's
# -R, attached or separated, is another tool's flag and does not decide this
# one. The lookalike rows each fail exactly one conjunct of the merge identity
# test and name the home repository or none, so a dropped conjunct reads home;
# the short rows pin the length check guarding the identity test's index reads
# under the consumers' `set -u`.
@test "only the first command decides: a cwd redirection or lookalike first command is foreign, a later command's -R is ignored" {
  expect_verdict "s11 a cd into a sibling checkout is foreign" foreign "cd $SIBLING && gh pr merge 5"
  expect_verdict "s15 a later attached -R (grep) does not decide" home 'gh pr merge 42 --squash && grep -Rn TODO .'
  expect_verdict "s15 a later attached -R (cp) does not decide" home 'gh pr merge 42 --squash && cp -Rp a b'
  expect_verdict "s15 a later attached -R (ls) does not decide" home 'gh pr merge 42 --squash && ls -RA'
  expect_verdict "s17 pushd ahead of the merge is foreign" foreign "pushd $SIBLING && gh pr merge 5"
  expect_verdict "s17 a subshell cd ahead of the merge is foreign" foreign "(cd $SIBLING && gh pr merge 5)"
  expect_verdict "s17 a cd to an unresolvable path is foreign" foreign "cd $PARENT/does-not-exist && gh pr merge 5"
  expect_verdict "s18 a separated -R on grep does not decide" home 'gh pr merge 42 --squash && grep -R app/routes .'
  expect_verdict "s18 a separated -R on cp does not decide" home 'gh pr merge 42 && cp -R a/b c/d'
  expect_verdict "s18 a separated -R on ls does not decide" home 'gh pr merge 42 && ls -R /tmp'
  expect_verdict "s20 fails on the subcommand" foreign 'gh pr view --repo acme/widgets 5 && gh pr merge 5'
  expect_verdict "s20 fails on the command group" foreign 'gh browse merge && gh pr merge 5'
  expect_verdict "s20 fails on the program" foreign 'hub pr merge 5 && gh pr merge 5'
  expect_verdict "s21 a two-word first command is foreign" foreign 'gh pr && gh pr merge 5'
  expect_verdict "s21 a one-word first command is foreign" foreign 'gh && gh pr merge 5'
}

# The load-bearing fixture: the sandbox's origin remote points at a repository
# named `gaia`, so `--repo other-org/gaia` matches the name-half comparison and
# reads as home there, while the home slug is `acme/widgets` and the whole-slug
# comparison reads it as the different repository it is. The blocking entry
# point is left exactly as its consumers depend on it, including the
# over-classification that is safe for them.
@test "the name-half guard says home where the slug guard says foreign, and the blocking entry point is unchanged" {
  [ "$(name_half_verdict 'gh pr merge --repo other-org/gaia 5')" = "home" ]
  [ "$(verdict 'gh pr merge --repo other-org/gaia 5')" = "foreign" ]
  [ "$(name_half_verdict 'gh pr merge --repo other-org/other-repo 5')" = "foreign" ]
}
