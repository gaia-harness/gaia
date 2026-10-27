#!/usr/bin/env bash
# Decides what the tests workflow's `Shellcheck and bats` job does, before it
# checks anything out.
#
# Usage:
#   shell-checks-select.sh plan --repository <owner/name> --head-sha <sha>
#       --output-directory <dir>
#       [--pull-request <n> --base-sha <sha> [--changed-file-count <n>]
#        [--remote <git-url>]]
#   shell-checks-select.sh filter [--owned <file>]
#
# plan reads everything it needs through `gh api` (GH_TOKEN in the
# environment): the pull request's changed files, the head .gaia/project.json,
# and the merge-base and head .gaia/VERSION and .gaia/manifest.json. It prints
# `key=value` lines for $GITHUB_OUTPUT:
#   lint=none|changed|full   what to lint
#   bats=true|false          whether `pnpm test:shell` runs
#   checkout=none|sparse|full
# and writes into the output directory: `lint-paths` (NUL-delimited paths for
# lint=changed), `owned` (the GAIA-owned paths a GAIA update skips, one per
# line) and `sparse-patterns` (the non-cone sparse checkout for lint=changed).
#
# Without --pull-request (a manual run) there is no diff: lint=full, and bats
# runs when a suite exists.
#
# The owned rule is the audit's release rule (.claude/hooks/lib/
# audit-scope-release.sh): a file either the merge-base or the head manifest
# lists as `owned` is skipped only when .gaia/VERSION differs between the merge
# base and the head, which marks a GAIA update. On any other pull request an
# owned file the pull request changed is an adopter edit and is linted. Every
# unreadable input on that path (a manifest that is absent or does not parse, a
# VERSION absent on either side) skips nothing, so the failure direction is
# over-lint, never under-lint. A shell parity suite holds the two to the same
# answer.
#
# A pull request at the files endpoint's cap (--changed-file-count) may list
# more files than the endpoint returns, so plan fetches the base and head
# commits blobless from --remote (default: the repository on github.com,
# authenticated with GH_TOKEN) and takes the diff from git instead.
#
# filter reads NUL-delimited paths on stdin and prints, NUL-delimited, the ones
# ending `.sh` or `.bats` that the --owned list does not name.
#
# Exit: 0 on a decision, 1 on an API or tool failure (the check goes red and is
# re-run; it never guesses a selection), 2 on a usage error.

set -euo pipefail

# The pull request files endpoint returns at most this many files.
PULL_REQUEST_FILES_CAP=3000

die_usage() {
  echo "shell-checks-select: $1" >&2
  exit 2
}

die() {
  echo "shell-checks-select: $1" >&2
  exit 1
}

# filter_shell_paths <owned-file-or-empty>: NUL paths in, NUL shell paths out.
filter_shell_paths() {
  local owned_file="$1" owned_framed=$'\n' path
  if [ -n "$owned_file" ] && [ -s "$owned_file" ]; then
    owned_framed=$'\n'"$(cat "$owned_file")"$'\n'
  fi
  while IFS= read -r -d '' path; do
    case "$path" in
      *.sh | *.bats) ;;
      *) continue ;;
    esac
    case "$owned_framed" in
      *$'\n'"$path"$'\n'*) continue ;;
    esac
    printf '%s\0' "$path"
  done
}

# fetch_raw <ref> <path> <out-file>: 0 written, 3 not found, 1 any other error.
fetch_raw() {
  local error_file="$output_directory/.fetch-error" status=0
  gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$repository/contents/$2?ref=$1" > "$3" 2> "$error_file" || status=$?
  [ "$status" -eq 0 ] && return 0
  if grep -q 'HTTP 404' "$error_file"; then
    rm -f "$3"
    return 3
  fi
  cat "$error_file" >&2
  return 1
}

# fetch_optional <ref> <path> <out-file>: like fetch_raw, but a missing file is
# not an error (the out-file is then absent); any other error ends the run.
fetch_optional() {
  local status=0
  fetch_raw "$@" || status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ] || die "cannot read $2 at $1"
}

owned_keys() {
  jq -r '.files | to_entries[] | select(.value == "owned") | .key' "$1" 2>/dev/null
}

# pinned_shellcheck_version <workflow-file>: the SHELLCHECK_VERSION value.
pinned_shellcheck_version() {
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*SHELLCHECK_VERSION:[[:space:]]*['\"]\{0,1\}\([^'\"[:space:]]*\).*/\1/p" "$1" | head -n 1
}

# sparse_pattern <path>: an anchored non-cone pattern matching exactly <path>.
sparse_pattern() {
  local escaped
  escaped="$(printf '%s' "$1" | sed 's/[][\\*?]/\\&/g; s/ $/\\ /')"
  printf '/%s\n' "$escaped"
}

# diff_through_git <out-file>: the merge-base-to-head diff from a blobless
# fetch of the two commits, for a pull request too large for the files
# endpoint. The token rides in an extra header, never in the URL or the
# repository config.
diff_through_git() {
  local clone="$output_directory/clone" merge_base_commit
  local -a authentication=()
  [ -n "$remote" ] || remote="https://github.com/$repository.git"
  case "$remote" in
    https://*)
      [ -z "${GH_TOKEN:-}" ] || authentication=(-c "http.extraHeader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')")
      ;;
  esac
  rm -rf "$clone"
  git init -q "$clone" || die "cannot create the diff clone"
  git -C "$clone" ${authentication[@]+"${authentication[@]}"} fetch -q --filter=blob:none --no-tags "$remote" "$base_sha" "$head_sha" \
    || die "cannot fetch the base and head commits"
  merge_base_commit="$(git -C "$clone" merge-base "$base_sha" "$head_sha")" || die "cannot resolve the merge base"
  git -C "$clone" diff -z --name-status --no-renames "$merge_base_commit" "$head_sha" > "$1" \
    || die "cannot diff the pull request"
}

run_filter() {
  local owned_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --owned)
        [ "$#" -ge 2 ] || die_usage "--owned needs a value"
        owned_file="$2"
        shift 2
        ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done
  filter_shell_paths "$owned_file"
}

run_plan() {
  repository="" head_sha="" output_directory="" pull_request="" base_sha=""
  changed_file_count="" remote=""
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || die_usage "$1 needs a value"
    case "$1" in
      --repository) repository="$2" ;;
      --head-sha) head_sha="$2" ;;
      --output-directory) output_directory="$2" ;;
      --pull-request) pull_request="$2" ;;
      --base-sha) base_sha="$2" ;;
      --changed-file-count) changed_file_count="$2" ;;
      --remote) remote="$2" ;;
      *) die_usage "unknown argument: $1" ;;
    esac
    shift 2
  done
  [ -n "$repository" ] && [ -n "$head_sha" ] && [ -n "$output_directory" ] \
    || die_usage "--repository, --head-sha and --output-directory are required"
  if [ -n "$pull_request" ] && [ -z "$base_sha" ]; then
    die_usage "--pull-request needs --base-sha"
  fi
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v gh >/dev/null 2>&1 || die "gh is required"
  mkdir -p "$output_directory"
  : > "$output_directory/lint-paths"
  : > "$output_directory/owned"
  : > "$output_directory/sparse-patterns"

  # Records are `<status>\0<path>\0`, the format of
  # `git diff -z --name-status --no-renames`; a `D` status is a deletion.
  local changes="$output_directory/changes"
  if [ -n "$pull_request" ]; then
    if [ -n "$changed_file_count" ] && [ "$changed_file_count" -ge "$PULL_REQUEST_FILES_CAP" ]; then
      diff_through_git "$changes"
    else
      # A rename lists its new path and, as a deletion, its old one, the
      # records `git diff --no-renames` would give.
      gh api --paginate "repos/$repository/pulls/$pull_request/files?per_page=100" \
        | jq -j '.[] | if .status == "removed" then "D\u0000" + .filename + "\u0000"
            elif .status == "renamed" then "D\u0000" + .previous_filename + "\u0000" + "A\u0000" + .filename + "\u0000"
            else "M\u0000" + .filename + "\u0000" end' > "$changes" \
        || die "cannot list the pull request's changed files"
    fi
  fi

  # Relevance: shell, the bats suite directory, a shellcheck policy file, or
  # the workflow that pins the shellcheck version. Anything else is nothing to
  # do, decided on the files list alone.
  local status path relevant=0 rc_changed=0 workflow_changed=0 suite_changed=0
  if [ -n "$pull_request" ]; then
    while IFS= read -r -d '' status && IFS= read -r -d '' path; do
      case "$path" in
        *.sh | *.bats) relevant=1 ;;
      esac
      case "$path" in
        tests/shell/*) relevant=1; suite_changed=1 ;;
      esac
      case "$path" in
        .shellcheckrc | */.shellcheckrc) relevant=1; rc_changed=1 ;;
      esac
      [ "$path" != ".github/workflows/tests.yml" ] || { relevant=1; workflow_changed=1; }
    done < "$changes"
    if [ "$relevant" -eq 0 ]; then
      printf 'lint=none\nbats=false\ncheckout=none\n'
      return 0
    fi
  fi

  local inputs="$output_directory/inputs"
  mkdir -p "$inputs"
  local lint_enabled=1
  fetch_optional "$head_sha" .gaia/project.json "$inputs/project.json"
  if [ -f "$inputs/project.json" ] \
    && [ "$(jq -r 'if type == "object" and .shellcheck == false then "off" else "on" end' "$inputs/project.json" 2>/dev/null)" = "off" ]; then
    lint_enabled=0
  fi

  local merge_base=""
  if [ -n "$pull_request" ]; then
    merge_base="$(gh api "repos/$repository/compare/$base_sha...$head_sha?per_page=1" | jq -r '.merge_base_commit.sha')" \
      || die "cannot resolve the merge base"
    [ -n "$merge_base" ] && [ "$merge_base" != "null" ] || die "cannot resolve the merge base"

    fetch_optional "$merge_base" .gaia/VERSION "$inputs/base-VERSION"
    fetch_optional "$head_sha" .gaia/VERSION "$inputs/head-VERSION"
    if [ -f "$inputs/base-VERSION" ] && [ -f "$inputs/head-VERSION" ] \
      && ! cmp -s "$inputs/base-VERSION" "$inputs/head-VERSION"; then
      fetch_optional "$merge_base" .gaia/manifest.json "$inputs/base-manifest.json"
      fetch_optional "$head_sha" .gaia/manifest.json "$inputs/head-manifest.json"
      local base_owned head_owned
      if [ -f "$inputs/base-manifest.json" ] && [ -f "$inputs/head-manifest.json" ] \
        && base_owned="$(owned_keys "$inputs/base-manifest.json")" \
        && head_owned="$(owned_keys "$inputs/head-manifest.json")"; then
        printf '%s\n%s\n' "$base_owned" "$head_owned" | awk 'NF && !seen[$0]++' > "$output_directory/owned"
      fi
    fi
  fi

  # What the pull request changed, minus a GAIA update's owned files: the
  # still-present ones are linted, and any of them (deleted too, since a suite
  # may source a deleted script) makes bats due.
  local lint="none" bats_trigger=0
  if [ -n "$pull_request" ]; then
    [ "$suite_changed" -eq 0 ] || bats_trigger=1
    while IFS= read -r -d '' status && IFS= read -r -d '' path; do
      if [ -n "$(printf '%s\0' "$path" | filter_shell_paths "$output_directory/owned" | tr -d '\0')" ]; then
        bats_trigger=1
        [ "$status" = "D" ] || printf '%s\0' "$path" >> "$output_directory/lint-paths"
      fi
    done < "$changes"

    if [ "$lint_enabled" -eq 1 ]; then
      local full=0
      [ "$rc_changed" -eq 0 ] || full=1
      if [ "$workflow_changed" -eq 1 ]; then
        fetch_optional "$merge_base" .github/workflows/tests.yml "$inputs/base-tests.yml"
        fetch_optional "$head_sha" .github/workflows/tests.yml "$inputs/head-tests.yml"
        [ "$(pinned_shellcheck_version "$inputs/base-tests.yml")" = "$(pinned_shellcheck_version "$inputs/head-tests.yml")" ] || full=1
      fi
      if [ "$full" -eq 1 ]; then
        lint="full"
      elif [ -s "$output_directory/lint-paths" ]; then
        lint="changed"
      fi
    fi
  else
    bats_trigger=1
    [ "$lint_enabled" -eq 0 ] || lint="full"
  fi
  [ "$lint" = "changed" ] || : > "$output_directory/lint-paths"

  local bats="false"
  if [ "$bats_trigger" -eq 1 ]; then
    local listing="$inputs/tests-shell.json" fetch_status=0
    gh api "repos/$repository/contents/tests/shell?ref=$head_sha" > "$listing" 2> "$output_directory/.fetch-error" || fetch_status=$?
    if [ "$fetch_status" -eq 0 ]; then
      if jq -e 'type == "array" and any(.[]; .type == "file" and (.name | endswith(".bats")))' "$listing" >/dev/null; then
        bats="true"
      fi
    elif ! grep -q 'HTTP 404' "$output_directory/.fetch-error"; then
      cat "$output_directory/.fetch-error" >&2
      die "cannot list tests/shell"
    fi
  fi

  local checkout="none"
  if [ "$bats" = "true" ] || [ "$lint" = "full" ]; then
    checkout="full"
  elif [ "$lint" = "changed" ]; then
    checkout="sparse"
    # The paths are NUL-delimited, so any newline is inside a path, and such a
    # path cannot be a sparse pattern line.
    if [ "$(tr -cd '\n' < "$output_directory/lint-paths" | wc -c | tr -d ' ')" -eq 0 ]; then
      while IFS= read -r -d '' path; do
        sparse_pattern "$path"
      done < "$output_directory/lint-paths" > "$output_directory/sparse-patterns"
      echo ".shellcheckrc" >> "$output_directory/sparse-patterns"
    else
      checkout="full"
    fi
  fi

  printf 'lint=%s\nbats=%s\ncheckout=%s\n' "$lint" "$bats" "$checkout"
}

[ "$#" -ge 1 ] || die_usage "usage: shell-checks-select.sh plan|filter [options]"
command="$1"
shift
case "$command" in
  plan) run_plan "$@" ;;
  filter) run_filter "$@" ;;
  *) die_usage "unknown command: $command" ;;
esac
