#!/usr/bin/env bats

# Tests for `gaia_gh_merge_reference_to_home_pr` in
# `.claude/hooks/lib/repo-scope.sh`, the URL half of the act-on-home boundary.
#
# `-R`/`--repo` cannot qualify a URL: gh resolves the repository from the URL
# itself and ignores the flag, so the scanned repository is empty and
# `command_targets_foreign_repo_slug` reads it as home. This function is what the
# two acting consumers ask instead, and it lives in the lib so they cannot
# answer it differently.
#
# Two shapes are matched as loosely as gh matches them, and everywhere else
# the matcher stays deliberately tighter; h12 and h20 pin the limits. The two
# followed are the suffixed and port-bearing spellings: gh's URL matcher is
# unanchored after the number and its comparison drops a port, so each of
# those names the home pull request to gh, and declining one would cost a
# merge that really did land on home. That decline is a silent no-op rather
# than a wrong write, which is why the followed group reads as coverage
# rather than as safety.
#
# The tighter cases are not symmetric with it. An ACCEPT where gh declines is
# the one direction a boundary that acts cannot have, so the scheme, the
# separator before a suffix, and userinfo on the authority all stay strict on
# purpose, and h12 and h20 exist to keep a later reader from loosening them.
#
# The suite drives the REAL lib (sourced by absolute path, never copied)
# against a sandbox git repo, with a fake `gh` on PATH answering
# `repo view --json nameWithOwner,url`.
#
# Assertions are POSIX `[ ... ]` per `.claude/rules/bats-assertions.md`: a bare
# `[[ ]]` that is not a test's last command does not fail on bash 3.2.

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  LIBRARY_ABSOLUTE_PATH=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/repo-scope.sh

  REPO=$(mktemp -d -t repo-scope-home-pr-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

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
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Ask the function about one reference, from inside the sandbox repo, in a
# fresh subshell so the lib's memoized home resolution never leaks between
# cases. Echoes the resolved number, or `decline` on a non-zero return.
#
# `set -u` is the consumers' own setting, and it is load-bearing rather than
# hygiene: a read of an unset capture is fatal under it and silent without it,
# so a permissive shell would report a verdict the consumers never reach.
resolve() {
  ( cd "$REPO" || exit 1
    set -u
    # shellcheck source=/dev/null
    . "$LIBRARY_ABSOLUTE_PATH"
    if gaia_gh_merge_reference_to_home_pr "$1"; then
      echo "$GAIA_HOME_PR_NUMBER"
    else
      echo decline
    fi )
}

# Fail with the row's name when a reference does not resolve as expected. An
# optional fourth argument sets the fake home host for that row only.
expect_resolve() {
  local row="$1" expected="$2" reference="$3" home_host="${4:-}" actual
  if [ -n "$home_host" ]; then
    actual="$(FAKE_GH_HOME_HOST="$home_host" resolve "$reference")"
  else
    actual="$(resolve "$reference")"
  fi
  if [ "$actual" != "$expected" ]; then
    echo "row '$row': expected $expected, got $actual for: $reference" >&2
    return 1
  fi
}

# One boundary rule, eight inputs: the home repository resolves, another
# repository or host declines, an enterprise home host resolves its own URL and
# not github.com (without it the host comparison could pass by hardcoding
# github.com), the slug and host compare case-insensitively, and neither a
# suffix nor a port widens the comparison. The relaxation is to the shape,
# never to the boundary.
@test "repo and host comparison: home resolves, foreign repo or host declines, enterprise home host, case-insensitive slug and host, suffix and port never widen the comparison" {
  expect_resolve "h1 a home-repository URL resolves to its number" 7 'https://github.com/acme/widgets/pull/7'
  expect_resolve "h2 another repository's URL declines" decline 'https://github.com/other-org/other-repo/pull/7'
  expect_resolve "h3 the home slug on another host declines" decline 'https://ghe.example.com/acme/widgets/pull/7'
  expect_resolve "h4 an enterprise home host resolves its own URL" 7 'https://ghe.example.com/acme/widgets/pull/7' ghe.example.com
  expect_resolve "h4 an enterprise home host declines github.com" decline 'https://github.com/acme/widgets/pull/7' ghe.example.com
  expect_resolve "h5 a slug differing only in case resolves" 7 'https://github.com/ACME/Widgets/pull/7'
  expect_resolve "h6 a host differing only in case resolves" 7 'https://GitHub.COM/acme/widgets/pull/7'
  expect_resolve "h11 a suffix does not widen the repository comparison (other repo)" decline 'https://github.com/other-org/other-repo/pull/7/files'
  expect_resolve "h11 a suffix does not widen the repository comparison (other host)" decline 'https://ghe.example.com/acme/widgets/pull/7/files'
  expect_resolve "h14 a port does not widen the host comparison" decline 'https://ghe.example.com:443/acme/widgets/pull/7'
}

# One parser, many input shapes. h7-h10 are the suffix group: gh's URL matcher
# is unanchored after the number, so each is a URL gh merges as home pull
# request 7 while an anchored matcher declines and posts nothing. The h12 and
# h20 rows pin the relaxation's limits: a suffix has to start with a separator
# (`7files` is an unrecognized shape), userinfo stays on the compared authority
# where gh's `u.Hostname()` drops it, and only http and https are read as a URL
# (the `http` and mixed-case rows are the control). h15 keeps a bracketed IPv6
# authority's brackets: a strip cutting at the LAST colon would leave `[:` and
# decline a URL naming the home host outright. h16 pins that the function
# refuses a non-URL itself rather than depending on its callers' `*://*` arm.
@test "URL shape: suffix, query, fragment and slash resolve; 7files, userinfo, non-URL, no-PR URLs and odd schemes decline; default port and IPv6 resolve" {
  expect_resolve "h7 a /files suffix resolves" 7 'https://github.com/acme/widgets/pull/7/files'
  expect_resolve "h8 a query suffix resolves" 7 'https://github.com/acme/widgets/pull/7?w=1'
  expect_resolve "h9 a fragment suffix resolves" 7 'https://github.com/acme/widgets/pull/7#issuecomment-1'
  expect_resolve "h10 a trailing slash resolves" 7 'https://github.com/acme/widgets/pull/7/'
  expect_resolve "h12 7files declines" decline 'https://github.com/acme/widgets/pull/7files'
  expect_resolve "h12 userinfo declines" decline 'https://user@github.com/acme/widgets/pull/7'
  expect_resolve "h13 the default port resolves, as gh's own Hostname() drops it" 7 'https://github.com:443/acme/widgets/pull/7'
  expect_resolve "h15 a bracketed IPv6 authority keeps its brackets" 7 'https://[::1]/acme/widgets/pull/7' '[::1]'
  expect_resolve "h15 a bracketed IPv6 authority with a port resolves" 7 'https://[::1]:443/acme/widgets/pull/7' '[::1]'
  expect_resolve "h16 a number declines" decline '7'
  expect_resolve "h16 a branch name declines" decline 'some-branch'
  expect_resolve "h16 an empty reference declines" decline ''
  expect_resolve "h17 a URL with no pull request declines" decline 'https://github.com/acme/widgets'
  expect_resolve "h17 an issue URL declines" decline 'https://github.com/acme/widgets/issues/7'
  expect_resolve "h17 an empty pull number declines" decline 'https://github.com/acme/widgets/pull/'
  expect_resolve "h20 ftp declines" decline 'ftp://github.com/acme/widgets/pull/7'
  expect_resolve "h20 ssh declines" decline 'ssh://github.com/acme/widgets/pull/7'
  expect_resolve "h20 httpx declines" decline 'httpx://github.com/acme/widgets/pull/7'
  expect_resolve "h20 http resolves" 7 'http://github.com/acme/widgets/pull/7'
  expect_resolve "h20 a mixed-case scheme resolves" 7 'HTTPS://github.com/acme/widgets/pull/7'
}

@test "h18: an unresolvable home declines rather than reading the URL" {
  # Fail direction, and the same one the sibling entry point takes: an acting
  # consumer that cannot identify its own repository must not act.
  #
  # The behavior has two independent causes, and this pins the behavior rather
  # than either one: the early return, and the fact that an unresolved home
  # leaves both globals empty, which no authority or slug the URL can carry
  # compares equal to. Deleting the early return alone therefore leaves this
  # green, so read it as a claim about the answer and not about the line.
  export FAKE_GH_REPO_VIEW_EXIT=1
  [ "$(resolve 'https://github.com/acme/widgets/pull/7')" = "decline" ]
}

@test "h19: a decline leaves no number behind for a caller to read" {
  # The consumers read the global only after a zero return, but a stale value
  # surviving a decline is one `||` typo away from a post onto whatever the
  # previous question resolved.
  run bash -c '
    cd "'"$REPO"'" || exit 1
    set -u
    . "'"$LIBRARY_ABSOLUTE_PATH"'"
    gaia_gh_merge_reference_to_home_pr "https://github.com/acme/widgets/pull/7" || true
    gaia_gh_merge_reference_to_home_pr "https://github.com/other-org/other-repo/pull/9" || true
    printf "[%s]" "$GAIA_HOME_PR_NUMBER"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
