#!/usr/bin/env bash
# gh-stub.sh: the `gh` the dry-run fixture puts first on PATH, standing in for
# GitHub. build-fixture.sh copies it to <fixture>/bin/gh.
#
# State lives in GH_STUB_DIRECTORY: pr.json (the one open pull request),
# calls.log (every invocation, one line each) and comments/ (one file per
# `gh pr comment`, its body copied verbatim). A call it does not model fails
# with exit 1 and a `gh-stub: unsupported` line, so the run sees an error
# rather than a fabricated answer, and calls.log shows what was asked.
#
# Modelled: `pr view` and `pr list` (`--json` fields ignored, `--jq` applied),
# `pr comment <n> --body-file <f>|--body <text>`, `pr checks` (no checks
# reported), `api` for the comment, review and collaborator-permission reads,
# `auth status`, `repo view`.
set -u

stub_directory="${GH_STUB_DIRECTORY:?gh-stub: GH_STUB_DIRECTORY is unset}"
printf '%s\n' "$*" >>"$stub_directory/calls.log"
pull_request="$stub_directory/pr.json"

unsupported() {
  printf 'gh-stub: unsupported call: gh %s\n' "$*" >&2
  exit 1
}

# emit <json>: print the JSON, through the call's --jq filter when it has one.
emit() {
  local json="$1" filter="" previous=""
  for argument in "${@:2}"; do
    [ "$previous" != --jq ] || filter="$argument"
    previous="$argument"
  done
  if [ -n "$filter" ]; then
    jq -r "$filter" <<<"$json"
  else
    printf '%s\n' "$json"
  fi
}

case "${1-} ${2-}" in
  "pr view")
    emit "$(cat "$pull_request")" "$@"
    ;;
  "pr list")
    emit "$(jq -c '[.]' "$pull_request")" "$@"
    ;;
  "pr checks")
    printf "no checks reported on the '%s' branch\n" "$(jq -r .headRefName "$pull_request")" >&2
    exit 1
    ;;
  "pr comment")
    number="${3-}"
    [ "$number" = "$(jq -r .number "$pull_request")" ] || unsupported "$@"
    body=""
    previous=""
    for argument in "${@:4}"; do
      case "$previous" in
        --body-file) body="$(cat "$argument")" || exit 1 ;;
        --body | -b) body="$argument" ;;
      esac
      previous="$argument"
    done
    [ -n "$body" ] || unsupported "$@"
    mkdir -p "$stub_directory/comments"
    count="$(find "$stub_directory/comments" -type f | wc -l | tr -d ' ')"
    printf '%s\n' "$body" >"$stub_directory/comments/$((count + 1)).md"
    printf 'https://github.com/fixture/dry-run/pull/%s#issuecomment-%s\n' "$number" "$((count + 1))"
    ;;
  "auth status")
    printf 'github.com\n  Logged in to github.com account fixture-user (stub)\n'
    ;;
  "repo view")
    emit '{"nameWithOwner":"fixture/dry-run","defaultBranchRef":{"name":"main"},"url":"https://github.com/fixture/dry-run"}' "$@"
    ;;
  api*)
    for argument in "$@"; do
      case "$argument" in
        */collaborators/*/permission) emit '{"permission":"admin"}' "$@"; exit 0 ;;
        */comments | */reviews) emit '[]' "$@"; exit 0 ;;
      esac
    done
    unsupported "$@"
    ;;
  *)
    unsupported "$@"
    ;;
esac
