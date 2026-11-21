#!/usr/bin/env bats
# Order guard for `wiki/concepts/PR Merge Workflow.md`: the cross-repository
# (fork) check must come before every step that checks out the PR head and
# before every fenced command that runs a repo script.
#
# Why order and not presence. Every script the page tells an agent to run
# (`bash .gaia/...`, `bash .claude/...`, `.gaia/cli/gaia ...`) executes from the
# checked-out tree. A fork head that reached the working tree makes those
# scripts the fork's own code running with the operator's credentials, and no
# guard that runs afterwards can be trusted to refuse. The first step of the
# page is therefore the only control that acts in time, and it only acts when
# an agent reaches it before anything else. A page that carried the check but
# listed it below the first script fence would pass a presence test and still
# run fork code first.
#
# The order is read from the page's shell fences by line number of first
# occurrence: the first fenced line naming `isCrossRepository` against the
# fenced lines that check out a head or run a repo script. Prose lines are not
# read, because prose does not run.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded and out of wiki-style.md's scope.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/wiki/concepts/PR Merge Workflow.md"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
}

# Every tag that carries shell, the same set the fence suite reads.
FENCE_OPEN_REGEX='^```(bash|sh|shell)[[:space:]]*$'

# fenced_lines <file>: `<line-number><TAB><text>` for every line inside a shell
# fence, fence markers excluded.
fenced_lines() {
  awk -v regex="$FENCE_OPEN_REGEX" '
    !inside && $0 ~ regex { inside = 1; next }
    inside && /^```[[:space:]]*$/ { inside = 0; next }
    inside { printf "%d\t%s\n", NR, $0 }
  ' "$1"
}

# first_fork_check_line <file>: the line of the first FENCED line naming
# isCrossRepository, or nothing.
first_fork_check_line() {
  fenced_lines "$1" | awk -F'\t' 'index($2, "isCrossRepository") { print $1; exit }'
}

# gated_lines <file>: `<line-number><TAB><text>` for every fenced line that
# checks out a PR head or runs a repo script.
gated_lines() {
  fenced_lines "$1" | awk -F'\t' '
    $2 ~ /(^|[^[:alnum:]_.\/-])gh[[:space:]]+pr[[:space:]]+checkout([[:space:]]|$)/ { print; next }
    $2 ~ /(^|[^[:alnum:]_.\/-])git[[:space:]]+fetch[[:space:]].*pull\// { print; next }
    $2 ~ /(^|[^[:alnum:]_.\/-])git[[:space:]]+checkout([[:space:]]|$)/ { print; next }
    $2 ~ /(^|[^[:alnum:]_.\/-])bash[[:space:]]+\.(gaia|claude)\// { print; next }
    $2 ~ /(^|[^[:alnum:]_.\/-])\.gaia\/cli\/gaia([[:space:]]|$)/ { print; next }
  '
}

# order_violations <file>: prints one line per gated fenced line at or before
# the fork check, or a single line when the fork check is missing. Exit 0 when
# the order holds (nothing printed), 1 when it does not.
order_violations() {
  local file="$1" fork_line gated
  fork_line="$(first_fork_check_line "$file")"
  gated="$(gated_lines "$file")"
  if [ -z "$fork_line" ]; then
    echo "no fenced isCrossRepository check in ${file}"
    return 1
  fi
  if [ -z "$gated" ]; then
    echo "no gated fenced line found in ${file}: the guard would be vacuous"
    return 1
  fi
  local bad
  bad="$(awk -F'\t' -v fork="$fork_line" '$1 <= fork { print "line " $1 " precedes the fork check at " fork ": " $2 }' <<<"$gated")"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

@test "the fork check precedes every head checkout and every repo-script fence" {
  run order_violations "$PAGE"
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
  [ -z "$output" ]
}
