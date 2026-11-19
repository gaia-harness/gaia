#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/gh-artifact-lib.sh, the shared breadcrumb lib
# for the GitHub pull-request artifact a run produced. Sourced, not executed:
# every test sources the lib in setup() and calls its functions directly.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIBRARY="$SCRIPT_DIRECTORY/gh-artifact-lib.sh"
  # shellcheck source=.gaia/scripts/gh-artifact-lib.sh
  source "$LIBRARY"
  unset GAIA_GH_ARTIFACT_CACHE_DIRECTORY
}

# ========== source-time purity ==========

# ---------- 1 ----------
@test "sourcing the lib has no side effects: succeeds under set -u with no git repo and no external PATH" {
  scratch="$BATS_TEST_TMPDIR/no-side-effects"
  mkdir -p "$scratch"
  run bash -c "cd '$scratch' && PATH='' && set -u && source '$LIBRARY' && echo sourced-ok"
  [ "$status" -eq 0 ]
  grep -qF "sourced-ok" <<<"$output"
  [ -z "$(ls -A "$scratch")" ]
}

# ========== gaia_gh_artifact_cache_directory ==========

# ---------- 2 ----------
@test "gaia_gh_artifact_cache_directory: GAIA_GH_ARTIFACT_CACHE_DIRECTORY test seam wins" {
  GAIA_GH_ARTIFACT_CACHE_DIRECTORY=/x/y
  export GAIA_GH_ARTIFACT_CACHE_DIRECTORY
  run gaia_gh_artifact_cache_directory
  [ "$status" -eq 0 ]
  [ "$output" = "/x/y" ]
}

# ---------- 3 ----------
@test "gaia_gh_artifact_cache_directory: inside a real repo, echoes <repo-root>/.gaia/local/cache" {
  repo="$BATS_TEST_TMPDIR/repo3"
  mkdir -p "$repo"
  git init -q "$repo"
  # pwd -P: the resolver behind this function physically resolves (mirrors the
  # worktree-safe test below); $BATS_TEST_TMPDIR itself can sit under a
  # symlinked component (e.g. macOS /var -> private/var), so the comparison
  # side must canonicalize too or this drifts from the resolver's own answer.
  repo_absolute_path="$(cd "$repo" && pwd -P)"
  resolved_cache_directory="$(cd "$repo" && gaia_gh_artifact_cache_directory)"
  [ "$resolved_cache_directory" = "$repo_absolute_path/.gaia/local/cache" ]
}

# ---------- 4 ----------
@test "gaia_gh_artifact_cache_directory: worktree-safe, resolves the MAIN checkout's cache dir" {
  main="$BATS_TEST_TMPDIR/wtmain"
  linked="$BATS_TEST_TMPDIR/wtlinked"
  mkdir -p "$main"
  git init -q "$main"
  git -C "$main" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m init
  git -C "$main" worktree add -q -b feat-wt "$linked" >/dev/null
  # pwd -P: macOS resolves /var -> /private/var inside `git rev-parse`, and
  # the function's output comes back through that canonical form, so the
  # comparison side must canonicalize too.
  main_absolute_path="$(cd "$main" && pwd -P)"
  worktree_absolute_path="$(cd "$linked" && pwd -P)"
  resolved_cache_directory="$(cd "$linked" && gaia_gh_artifact_cache_directory)"
  [ "$resolved_cache_directory" = "$main_absolute_path/.gaia/local/cache" ]
  [ "$resolved_cache_directory" != "$worktree_absolute_path/.gaia/local/cache" ]
}

# ---------- 5 ----------
@test "gaia_gh_artifact_cache_directory: outside any git repo, echoes nothing on stdout and returns 0" {
  plain="$BATS_TEST_TMPDIR/no-git"
  mkdir -p "$plain"
  # The shared resolver behind this function writes one diagnostic to STDERR
  # on failure (by design, unlike the old silent-on-both-streams derivation);
  # this function's own contract is stdout-silence only, so the inner stderr
  # is redirected away rather than merged into $output.
  run bash -c "cd '$plain' && source '$LIBRARY' && gaia_gh_artifact_cache_directory 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ========== gaia_gh_artifact_path ==========

@test "gaia_gh_artifact_path: keyed filename, percent-encoding, empty inputs, distinct branches and a failing slug" {
  echo "case: cache_directory and branch both present yields the keyed filename"
  run gaia_gh_artifact_path "/x/y" "some-branch"
  [ "$status" -eq 0 ]
  [ "$output" = "/x/y/gh-artifact-pr.some-branch.json" ]

  echo "case: a branch containing / percent-encodes into the filename"
  run gaia_gh_artifact_path "/x/y" "feat/thing"
  [ "$status" -eq 0 ]
  [ "$output" = "/x/y/gh-artifact-pr.feat%2Fthing.json" ]

  echo "case: a branch containing . percent-encodes into the filename"
  run gaia_gh_artifact_path "/x/y" "release/1.2"
  [ "$status" -eq 0 ]
  [ "$output" = "/x/y/gh-artifact-pr.release%2F1%2E2.json" ]

  echo "case: an empty cache_directory echoes nothing and returns 0"
  run gaia_gh_artifact_path "" "some-branch"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  echo "case: an empty branch echoes nothing and returns 0"
  run gaia_gh_artifact_path "/x/y" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  echo "case: an empty cache_directory and an empty branch echo nothing and return 0"
  run gaia_gh_artifact_path "" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  echo "case: two different branches under the same cache_directory yield two different paths"
  path_a="$(gaia_gh_artifact_path "/x/y" "branch-a")"
  path_b="$(gaia_gh_artifact_path "/x/y" "branch-b")"
  [ -n "$path_a" ]
  [ -n "$path_b" ]
  [ "$path_a" != "$path_b" ]

  # A failing slug is the third way this path is undeterminable, alongside an
  # empty cache_directory and an empty branch, and it takes the same empty-output exit.
  # The slug is captured and checked rather than interpolated into the printf,
  # because a command substitution discards its own status: an unchecked failure
  # would echo "gh-artifact-pr..json", the unkeyed shared path this function's
  # contract promises never to invent, and both callers would then treat it as a
  # real path because it is non-empty.
  #
  # The stub is a sibling file rather than a function override: the function
  # sources audit-key-lib.sh from beside ITSELF at call time, so an override in
  # this test body would be clobbered by that source. Copying the real lib next
  # to a stub slug exercises the real resolution path.
  echo "case: a failing slug echoes nothing, never an unkeyed shared path"
  local scratch="$BATS_TEST_TMPDIR/failing-slug"
  mkdir -p "$scratch"
  cp "$LIBRARY" "$scratch/gh-artifact-lib.sh"
  printf 'gaia_key_slug() { return 1; }\n' >"$scratch/audit-key-lib.sh"

  run bash -c "source '$scratch/gh-artifact-lib.sh'; gaia_gh_artifact_path '/x/y' 'some-branch'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF 'gh-artifact-pr..json' <<<"$output" && return 1
  return 0
}

# ---------- 5f ----------
@test "gaia_gh_artifact_path: end-to-end -- tree A's write-then-read survives a same-cache_directory write from tree B" {
  cache_directory="$BATS_TEST_TMPDIR/shared-cache"
  mkdir -p "$cache_directory"

  path_a="$(gaia_gh_artifact_path "$cache_directory" "tree-a")"
  path_b="$(gaia_gh_artifact_path "$cache_directory" "tree-b")"
  [ "$path_a" != "$path_b" ]

  gaia_gh_artifact_write "$path_a" 100 "gaia-react/gaia" "tree-a" "sess-a"
  gaia_gh_artifact_write "$path_b" 200 "gaia-react/gaia" "tree-b" "sess-b"

  run gaia_gh_artifact_read "$path_a" "sess-a" "tree-a"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(jq -r '.number' <<<"$output")" -eq 100 ]
}

# ========== gaia_gh_artifact_parse_url ==========

# ---------- 6 ----------
@test "gaia_gh_artifact_parse_url: parses the first anchored PR URL, number is a JSON integer" {
  blob=$'some preamble\nOpening a pull request:\nhttps://github.com/gaia-react/gaia/pull/712\ntrailer text\n'
  run gaia_gh_artifact_parse_url "$blob"
  [ "$status" -eq 0 ]
  [ "$output" = '{"type":"pr","number":712,"repo":"gaia-react/gaia"}' ]
  jq -e '.number | type == "number"' >/dev/null 2>&1 <<<"$output" || return 1
}

@test "gaia_gh_artifact_parse_url: rejects issue URLs, gitlab host, http scheme, non-numeric number, unsafe owner, and an injection canary" {
  local rejected
  for rejected in \
    'https://github.com/owner/name/issues/415' \
    'https://gitlab.com/owner/name/pull/1' \
    'http://github.com/owner/name/pull/1' \
    'https://github.com/owner/name/pull/abc' \
    'https://github.com/o;rm -rf //n/pull/1'; do
    echo "case: $rejected"
    run gaia_gh_artifact_parse_url "$rejected"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done

  echo "case: injection canary, no command execution and no match"
  cd "$BATS_TEST_TMPDIR" || return 1
  bad='https://github.com/o$(touch CANARY)/n/pull/1'
  run gaia_gh_artifact_parse_url "$bad"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  if [ -e "$BATS_TEST_TMPDIR/CANARY" ]; then
    return 1
  fi
}

# ---------- 9 ----------
@test "gaia_gh_artifact_parse_url: when two PR URLs are present, the first wins" {
  blob=$'https://github.com/first-org/first-repo/pull/1\nhttps://github.com/second-org/second-repo/pull/2'
  run gaia_gh_artifact_parse_url "$blob"
  [ "$status" -eq 0 ]
  [ "$output" = '{"type":"pr","number":1,"repo":"first-org/first-repo"}' ]
}

# ========== gaia_gh_artifact_write ==========

@test "gaia_gh_artifact_write: a valid write has exactly the breadcrumb key set, and a repo name with dots and dashes succeeds" {
  echo "case: a valid write has exactly the branch/number/repo/session_id/ts/type key set"
  breadcrumb_path="$BATS_TEST_TMPDIR/write-valid.json"
  run gaia_gh_artifact_write "$breadcrumb_path" 712 "gaia-react/gaia" "spec-040-command-cost-telemetry" "sess-abc"
  [ "$status" -eq 0 ]
  [ -f "$breadcrumb_path" ]
  [ "$(jq -r 'keys | @csv' "$breadcrumb_path")" = '"branch","number","repo","session_id","ts","type"' ]
  [ "$(jq -r '.type' "$breadcrumb_path")" = "pr" ]
  jq -e '.number | type == "number"' >/dev/null 2>&1 <"$breadcrumb_path" || return 1
  timestamp_value="$(jq -r '.ts' "$breadcrumb_path")"
  case "$timestamp_value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac

  echo "case: a repo name with legal dot/dash characters succeeds"
  breadcrumb_path="$BATS_TEST_TMPDIR/write-dotdash.json"
  run gaia_gh_artifact_write "$breadcrumb_path" 5 "my-org/my.repo" "some-branch" "sess-abc"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repo' "$breadcrumb_path")" = "my-org/my.repo" ]
}

# assert_write_refused <label> <file-name> <number> <repo> <branch> <session>:
# the write must fail and leave nothing at the path.
assert_write_refused() {
  local label=$1 breadcrumb_path="$BATS_TEST_TMPDIR/$2.json"
  echo "case: $label"
  run gaia_gh_artifact_write "$breadcrumb_path" "$3" "$4" "$5" "$6"
  [ "$status" -ne 0 ]
  [ ! -e "$breadcrumb_path" ]
}

@test "gaia_gh_artifact_write: refuses every invalid input and writes nothing" {
  assert_write_refused "empty branch" write-nobranch 712 "gaia-react/gaia" "" "sess-abc"
  assert_write_refused "empty session_id" write-nosession 712 "gaia-react/gaia" "some-branch" ""
  assert_write_refused "repo with a shell metacharacter" write-badrepo1 712 "o;rm -rf /" "some-branch" "sess-abc"
  assert_write_refused "repo with a space" write-badrepo2 712 "owner/na me" "some-branch" "sess-abc"
  assert_write_refused "number 1x" write-badnum1 "1x" "gaia-react/gaia" "some-branch" "sess-abc"
  assert_write_refused "empty number" write-badnum2 "" "gaia-react/gaia" "some-branch" "sess-abc"
  assert_write_refused "negative number" write-badnum3 "-3" "gaia-react/gaia" "some-branch" "sess-abc"
}

# ---------- 15 ----------
@test "gaia_gh_artifact_write: a second write overwrites, last writer wins" {
  breadcrumb_path="$BATS_TEST_TMPDIR/write-overwrite.json"
  run gaia_gh_artifact_write "$breadcrumb_path" 100 "gaia-react/gaia" "branch-one" "sess-one"
  [ "$status" -eq 0 ]
  run gaia_gh_artifact_write "$breadcrumb_path" 200 "gaia-react/gaia" "branch-two" "sess-two"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.number' "$breadcrumb_path")" -eq 200 ]
  [ "$(jq -r '.branch' "$breadcrumb_path")" = "branch-two" ]
  # exactly one JSON object left in the file, not two concatenated (jq's
  # writer is not required to be single-line; FC-1's own example is
  # pretty-printed, so "one object" is checked structurally, not by wc -l)
  [ "$(jq -s 'length' "$breadcrumb_path")" -eq 1 ]
}

# ========== gaia_gh_artifact_read ==========

# ---------- 17 ----------
@test "gaia_gh_artifact_read: session_id and branch match, returns the type/number/repo triple" {
  breadcrumb_path="$BATS_TEST_TMPDIR/read-valid.json"
  gaia_gh_artifact_write "$breadcrumb_path" 712 "gaia-react/gaia" "spec-040-command-cost-telemetry" "sess-abc"
  run gaia_gh_artifact_read "$breadcrumb_path" "sess-abc" "spec-040-command-cost-telemetry"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'keys | @csv' <<<"$output")" = '"number","repo","type"' ]
  [ "$(jq -r '.type' <<<"$output")" = "pr" ]
  [ "$(jq -r '.number' <<<"$output")" -eq 712 ]
  [ "$(jq -r '.repo' <<<"$output")" = "gaia-react/gaia" ]
}

@test "gaia_gh_artifact_read: never consumes the breadcrumb, and reading twice returns identical output" {
  breadcrumb_path="$BATS_TEST_TMPDIR/read-nodelete.json"
  gaia_gh_artifact_write "$breadcrumb_path" 42 "gaia-react/gaia" "some-branch" "sess-xyz"
  echo "case: a read never deletes the breadcrumb"
  gaia_gh_artifact_read "$breadcrumb_path" "sess-xyz" "some-branch" >/dev/null
  [ -f "$breadcrumb_path" ]

  echo "case: reading twice returns identical output"
  first="$(gaia_gh_artifact_read "$breadcrumb_path" "sess-xyz" "some-branch")"
  second="$(gaia_gh_artifact_read "$breadcrumb_path" "sess-xyz" "some-branch")"
  [ -n "$first" ]
  [ "$first" = "$second" ]
}

# assert_read_empty <label> <breadcrumb-path> <session> <branch> [ttl]: the read
# must succeed and echo nothing.
assert_read_empty() {
  echo "case: $1"
  run gaia_gh_artifact_read "$2" "$3" "$4" ${5:+"$5"}
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gaia_gh_artifact_read: echoes nothing on every refusal kind" {
  local matching="$BATS_TEST_TMPDIR/read-branchmismatch.json"
  gaia_gh_artifact_write "$matching" 42 "gaia-react/gaia" "branch-a" "sess-xyz"
  assert_read_empty "branch mismatch" "$matching" "sess-xyz" "branch-b"
  assert_read_empty "session mismatch" "$matching" "sess-other" "branch-a"

  old="$BATS_TEST_TMPDIR/read-old.json"
  printf '{"type":"pr","number":1,"repo":"gaia-react/gaia","branch":"branch-a","session_id":"sess-xyz","ts":"2020-01-01T00:00:00Z"}' >"$old"
  assert_read_empty "a ts older than the TTL" "$old" "sess-xyz" "branch-a"

  fresh="$BATS_TEST_TMPDIR/read-fresh-tinyttl.json"
  gaia_gh_artifact_write "$fresh" 1 "gaia-react/gaia" "branch-a" "sess-xyz"
  assert_read_empty "a fresh ts under a zero TTL" "$fresh" "sess-xyz" "branch-a" 0

  # Build the future stamp with jq, not date: BSD date wants -v+2H and GNU date
  # wants -d '+2 hours', and the losing form exits non-zero, which aborts the
  # test under bats' set -e before any fallback runs. jq is already the reader's
  # own clock, so this matches what it parses.
  future_timestamp="$(jq -rn '(now + 7200) | todateiso8601')"
  future="$BATS_TEST_TMPDIR/read-future.json"
  printf '{"type":"pr","number":1,"repo":"gaia-react/gaia","branch":"branch-a","session_id":"sess-xyz","ts":"%s"}' "$future_timestamp" >"$future"
  assert_read_empty "a ts more than 60s in the future" "$future" "sess-xyz" "branch-a"

  assert_read_empty "a missing file" "$BATS_TEST_TMPDIR/does-not-exist.json" "sess-xyz" "branch-a"

  empty="$BATS_TEST_TMPDIR/read-empty.json"
  : >"$empty"
  assert_read_empty "an empty file" "$empty" "sess-xyz" "branch-a"

  garbage="$BATS_TEST_TMPDIR/read-garbage.json"
  printf 'not json at all {{{' >"$garbage"
  assert_read_empty "malformed JSON" "$garbage" "sess-xyz" "branch-a"

  array_breadcrumb_path="$BATS_TEST_TMPDIR/read-array.json"
  printf '[1,2,3]' >"$array_breadcrumb_path"
  assert_read_empty "a JSON array" "$array_breadcrumb_path" "sess-xyz" "branch-a"

  now_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  missing_number="$BATS_TEST_TMPDIR/read-missingnum.json"
  printf '{"type":"pr","repo":"gaia-react/gaia","branch":"branch-a","session_id":"sess-xyz","ts":"%s"}' "$now_timestamp" >"$missing_number"
  assert_read_empty "a missing number" "$missing_number" "sess-xyz" "branch-a"

  echo "case: jq unavailable on PATH"
  breadcrumb_path="$BATS_TEST_TMPDIR/read-nojq.json"
  gaia_gh_artifact_write "$breadcrumb_path" 1 "gaia-react/gaia" "branch-a" "sess-xyz"
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  run gaia_gh_artifact_read "$breadcrumb_path" "sess-xyz" "branch-a"
  PATH="$saved_path"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
