#!/usr/bin/env bash
# shellcheck shell=bash
#
# update-claim.sh: the one place that defines an in-progress GAIA update claim
# and makes every gh call a claim needs. /update-gaia calls it live; the
# detached refresher (check-updates.sh) calls `cache-fields` to fill the
# update-check cache the statusline reads.
#
#   bash .gaia/scripts/update-claim.sh list          --tree <dir>
#   bash .gaia/scripts/update-claim.sh login         --tree <dir>
#   bash .gaia/scripts/update-claim.sh origin-version --tree <dir>
#   bash .gaia/scripts/update-claim.sh cache-fields  --tree <dir>
#   bash .gaia/scripts/update-claim.sh fetch-branch  --tree <dir> --branch <name>
#   bash .gaia/scripts/update-claim.sh start         --tree <dir> --tag <tag> --branch <name> --base <default branch>
#   bash .gaia/scripts/update-claim.sh tie-break     --tree <dir> --own <number>
#   bash .gaia/scripts/update-claim.sh close-own     --tree <dir> --number <n> --branch <name>
#
# A LIVE CLAIM is an open pull request from the same repository (not a fork)
# whose head branch is update/v<semver>-<suffix>. When the branch ends in the
# minted stamp -YYYY-MM-DD-HHMM the tag is what sits between update/ and the
# stamp; otherwise the tag is v<MAJOR>.<MINOR>.<PATCH> and the rest must be a
# dash followed by [0-9A-Za-z.-]. The tag, the author login and createdAt are
# checked against closed sets, and an entry that fails any check is dropped,
# never stripped: a login that reached a shell, a statusline or a cache with a
# control byte in it is not worth repairing.
#
# --tree is the checkout whose repository a call reads or writes, and every
# subcommand requires it (a missing one is a usage error, exit 2). git runs as
# `git -C <tree>`. gh has no -C, so each gh call runs in a subshell that enters
# the tree first; the caller's shell and working directory are never changed.
#
# Output tokens and exit codes are the contract the skill and the refresher are
# written against. Every gh failure fails open: a refresher or a run that
# cannot reach GitHub skips the claim and carries on.
#
# The claim commit is never made with --no-verify and a refused commit is not
# retried; no push is forced.
#
# Bash 3.2 compatible. jq is required to parse claim data; without it list,
# login and origin-version exit 3 and cache-fields prints its empty form.

set -uo pipefail

PROGRAM_NAME="update-claim.sh"

VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
TAG_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
CLAIM_BRANCH_PATTERN='^update/v[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+$'
LOGIN_PATTERN='^[A-Za-z0-9](-?[A-Za-z0-9])*$'
BASE_PATTERN='^[A-Za-z0-9][A-Za-z0-9._/-]*$'

EMPTY_CACHE_FIELDS='{"gaiaOriginVersion":null,"gaiaUpdateClaims":[],"ghLogin":""}'

usage() {
  cat <<EOF
Usage: bash .gaia/scripts/$PROGRAM_NAME <subcommand> --tree <dir> [options]

Subcommands: list, login, origin-version, cache-fields, fetch-branch, start,
tie-break, close-own. Every subcommand requires --tree. Exit 2 is a usage error.
EOF
}

die_usage() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$1" >&2
  usage >&2
  exit 2
}

# One jq program turns the raw `gh pr list` payload into the validated, sorted
# claim array. The isCrossRepository line is the fork filter.
# shellcheck disable=SC2016
CLAIM_FILTER='
def clean: test("[\u0001-\u001f\u007f]") | not;
def minted_stamp: "-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$";
def tag_of($head):
  if ($head | startswith("update/")) then
    ($head | ltrimstr("update/")) as $rest
    | if ($rest | test(minted_stamp)) then ($rest | sub(minted_stamp; ""))
      else (($rest | capture("^(?<tag>v[0-9]+\\.[0-9]+\\.[0-9]+)-[0-9A-Za-z.-]+$") | .tag)? // null)
      end
  else null end;
if type != "array" then error("not an array") else . end
| [ .[]
    | select(.isCrossRepository == false)
    | select((.number | type) == "number")
    | select((.headRefName | type) == "string" and (.headRefName | clean))
    | (tag_of(.headRefName)) as $tag
    | select($tag != null and ($tag | test($tagPattern)) and ($tag | clean))
    | ((try .author.login catch "") // "") as $login
    | select(($login | type) == "string" and ($login | length) <= 39 and ($login | test($loginPattern)) and ($login | clean))
    | select((.createdAt | type) == "string" and (.createdAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and (.createdAt | clean))
    | {number: .number, headRefName: .headRefName, tag: $tag, authorLogin: $login, createdAt: .createdAt}
  ]
| sort_by(.number)
'

tree=""
tag=""
branch=""
base=""
own_number=""
pull_number=""
subcommand=""

gh_in_tree() {
  ( cd "$tree" && gh "$@" )
}

has_jq() {
  command -v jq >/dev/null 2>&1
}

# Sets CLAIMS_JSON to the validated array and returns 0, or sets FAILURE_REASON
# and returns 1.
FAILURE_REASON=""
CLAIMS_JSON="[]"
fetch_claims() {
  local payload
  CLAIMS_JSON="[]"
  if ! command -v gh >/dev/null 2>&1; then
    FAILURE_REASON="gh-missing"
    return 1
  fi
  if ! has_jq; then
    FAILURE_REASON="jq-missing"
    return 1
  fi
  if ! payload="$(gh_in_tree pr list --state open --limit 1000 --json number,headRefName,author,createdAt,isCrossRepository 2>/dev/null)"; then
    FAILURE_REASON="gh-failed"
    return 1
  fi
  if ! CLAIMS_JSON="$(printf '%s' "$payload" | jq -c --arg tagPattern "$TAG_PATTERN" --arg loginPattern "$LOGIN_PATTERN" "$CLAIM_FILTER" 2>/dev/null)"; then
    CLAIMS_JSON="[]"
    FAILURE_REASON="gh-failed"
    return 1
  fi
  return 0
}

# Sets CURRENT_LOGIN or FAILURE_REASON.
CURRENT_LOGIN=""
fetch_login() {
  local value
  CURRENT_LOGIN=""
  if ! command -v gh >/dev/null 2>&1; then
    FAILURE_REASON="gh-missing"
    return 1
  fi
  if ! has_jq; then
    FAILURE_REASON="jq-missing"
    return 1
  fi
  if ! value="$(gh_in_tree api user --jq .login 2>/dev/null)"; then
    FAILURE_REASON="gh-failed"
    return 1
  fi
  if [ "${#value}" -gt 39 ] || ! grep -Eq "$LOGIN_PATTERN" <<<"$value" \
    || [ "$(printf '%s' "$value" | wc -l | tr -d ' ')" != "0" ]; then
    FAILURE_REASON="login-out-of-set"
    return 1
  fi
  CURRENT_LOGIN="$value"
  return 0
}

# Sets ORIGIN_VERSION or FAILURE_REASON. A read-only API call of the default
# branch's file: a `git fetch` here would move refs under the caller.
ORIGIN_VERSION=""
fetch_origin_version() {
  local value
  ORIGIN_VERSION=""
  if ! command -v gh >/dev/null 2>&1; then
    FAILURE_REASON="gh-missing"
    return 1
  fi
  if ! has_jq; then
    FAILURE_REASON="jq-missing"
    return 1
  fi
  if ! value="$(gh_in_tree api -H 'Accept: application/vnd.github.raw+json' 'repos/{owner}/{repo}/contents/.gaia/VERSION' 2>/dev/null)"; then
    FAILURE_REASON="gh-failed"
    return 1
  fi
  value="$(printf '%s' "$value" | tr -d '\r')"
  if [ "$(printf '%s' "$value" | wc -l | tr -d ' ')" != "0" ] || ! grep -Eq "$VERSION_PATTERN" <<<"$value"; then
    FAILURE_REASON="not-a-version"
    return 1
  fi
  ORIGIN_VERSION="$value"
  return 0
}

is_claim_branch() {
  grep -Eq "$CLAIM_BRANCH_PATTERN" <<<"$1"
}

is_digits() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

command_list() {
  if ! fetch_claims; then
    printf 'CLAIM_CHECK_SKIPPED %s\n' "$FAILURE_REASON"
    exit 3
  fi
  printf '%s' "$CLAIMS_JSON" | jq -r '.[] | "CLAIM \(.number) \(.tag) \(.authorLogin) \(.createdAt) \(.headRefName)"'
  exit 0
}

command_login() {
  if ! fetch_login; then
    printf 'LOGIN_UNAVAILABLE %s\n' "$FAILURE_REASON"
    exit 3
  fi
  printf 'LOGIN %s\n' "$CURRENT_LOGIN"
  exit 0
}

command_origin_version() {
  if ! fetch_origin_version; then
    printf 'ORIGIN_VERSION_UNAVAILABLE %s\n' "$FAILURE_REASON"
    exit 3
  fi
  printf 'ORIGIN_VERSION %s\n' "$ORIGIN_VERSION"
  exit 0
}

command_cache_fields() {
  local claims="[]" login="" origin_json="null"
  if ! has_jq; then
    printf '%s\n' "$EMPTY_CACHE_FIELDS"
    exit 0
  fi
  if fetch_claims; then
    claims="$CLAIMS_JSON"
  fi
  if fetch_login; then
    login="$CURRENT_LOGIN"
  fi
  if fetch_origin_version; then
    origin_json="$(jq -n --arg version "$ORIGIN_VERSION" '$version')"
  fi
  if ! jq -nc --argjson origin "$origin_json" --argjson claims "$claims" --arg login "$login" \
    '{gaiaOriginVersion: $origin, gaiaUpdateClaims: $claims, ghLogin: $login}' 2>/dev/null; then
    printf '%s\n' "$EMPTY_CACHE_FIELDS"
  fi
  exit 0
}

command_fetch_branch() {
  [ -n "$branch" ] || die_usage "fetch-branch needs --branch"
  is_claim_branch "$branch" || die_usage "not a claim branch: $branch"
  if git -C "$tree" fetch origin "refs/heads/$branch:refs/heads/$branch" >/dev/null 2>&1; then
    printf 'FETCHED %s\n' "$branch"
    exit 0
  fi
  printf 'FETCH_FAILED git-fetch-failed\n'
  exit 1
}

skip_claim() {
  printf 'CLAIM_SKIPPED %s\n' "$1"
  exit 0
}

command_start() {
  local existing_subjects claim_subject pull_line pull_url created_url pull_id
  [ -n "$tag" ] || die_usage "start needs --tag"
  [ -n "$branch" ] || die_usage "start needs --branch"
  [ -n "$base" ] || die_usage "start needs --base"
  grep -Eq "$TAG_PATTERN" <<<"$tag" || die_usage "not a tag: $tag"
  is_claim_branch "$branch" || die_usage "not a claim branch: $branch"
  grep -Eq "$BASE_PATTERN" <<<"$base" || die_usage "not a branch name: $base"

  command -v gh >/dev/null 2>&1 || skip_claim "gh-missing"
  gh_in_tree auth status >/dev/null 2>&1 || skip_claim "gh-unauthenticated"

  claim_subject="chore(gaia): start update to $tag"
  existing_subjects="$(git -C "$tree" log --format=%s "origin/$base..HEAD" 2>/dev/null || git -C "$tree" log --format=%s -n 50 HEAD 2>/dev/null || true)"
  if ! grep -Fxq -- "$claim_subject" <<<"$existing_subjects"; then
    if ! git -C "$tree" commit --allow-empty -m "$claim_subject" >&2; then
      skip_claim "commit-refused"
    fi
  fi

  if ! git -C "$tree" push -u origin "$branch" >&2; then
    skip_claim "push-rejected"
  fi

  if ! pull_line="$(gh_in_tree pr list --head "$branch" --state open --json number,url,isCrossRepository \
    --jq '.[] | select(.isCrossRepository | not) | "\(.number) \(.url)"' 2>/dev/null)"; then
    skip_claim "gh-failed"
  fi
  pull_line="$(printf '%s\n' "$pull_line" | head -n 1)"
  if [ -n "$pull_line" ]; then
    pull_id="${pull_line%% *}"
    pull_url="${pull_line#* }"
    if is_digits "$pull_id"; then
      printf 'CLAIMED %s %s\n' "$pull_id" "$pull_url"
      exit 0
    fi
    skip_claim "gh-failed"
  fi

  if ! created_url="$(gh_in_tree pr create --draft --base "$base" --head "$branch" \
    --title "chore(gaia): update to $tag" \
    --body "Claims the GAIA $tag update so teammates see it in progress. The update commit and its summary follow on this branch." 2>/dev/null)"; then
    skip_claim "pr-create-failed"
  fi
  created_url="$(printf '%s\n' "$created_url" | tail -n 1)"
  pull_id="${created_url##*/}"
  if ! is_digits "$pull_id" || ! grep -Eq '^https://[A-Za-z0-9._/-]+/pull/[0-9]+$' <<<"$created_url"; then
    skip_claim "gh-failed"
  fi
  printf 'CLAIMED %s %s\n' "$pull_id" "$created_url"
  exit 0
}

# Closes pull request $1 and deletes remote branch $2. Returns non-zero when
# the close itself fails; a branch-delete failure only warns.
close_and_delete() {
  gh_in_tree pr close "$1" >/dev/null 2>&1 || return 1
  if ! git -C "$tree" push origin --delete "$2" >/dev/null 2>&1; then
    printf '%s: could not delete remote branch %s\n' "$PROGRAM_NAME" "$2" >&2
  fi
  return 0
}

command_tie_break() {
  local own_branch lower_line
  is_digits "$own_number" || die_usage "tie-break needs --own <number>"
  if ! fetch_claims; then
    printf 'TIE_BREAK_SKIPPED %s\n' "$FAILURE_REASON"
    exit 0
  fi
  own_branch="$(printf '%s' "$CLAIMS_JSON" | jq -r --argjson own "$own_number" '[.[] | select(.number == $own)] | .[0].headRefName // empty')"
  if [ -z "$own_branch" ]; then
    printf 'TIE_BREAK_SKIPPED own-not-listed\n'
    exit 0
  fi
  lower_line="$(printf '%s' "$CLAIMS_JSON" | jq -r --argjson own "$own_number" '[.[] | select(.number < $own)] | .[0] | select(. != null) | "\(.number) \(.authorLogin)"')"
  if [ -z "$lower_line" ]; then
    printf 'WON\n'
    exit 0
  fi
  if ! close_and_delete "$own_number" "$own_branch"; then
    printf 'TIE_BREAK_SKIPPED close-failed\n'
    exit 0
  fi
  printf 'LOST %s\n' "$lower_line"
  exit 0
}

command_close_own() {
  local details state head_name author_login cross_repository
  is_digits "$pull_number" || die_usage "close-own needs --number <n>"
  [ -n "$branch" ] || die_usage "close-own needs --branch"
  is_claim_branch "$branch" || die_usage "not a claim branch: $branch"
  if ! fetch_login; then
    printf 'CLOSE_FAILED %s\n' "$FAILURE_REASON"
    exit 3
  fi
  if ! details="$(gh_in_tree pr view "$pull_number" --json state,headRefName,author,isCrossRepository \
    --jq '[.state, .headRefName, .author.login, (.isCrossRepository | tostring)] | @tsv' 2>/dev/null)"; then
    printf 'CLOSE_FAILED gh-failed\n'
    exit 3
  fi
  state="$(printf '%s' "$details" | cut -f1)"
  head_name="$(printf '%s' "$details" | cut -f2)"
  author_login="$(printf '%s' "$details" | cut -f3)"
  cross_repository="$(printf '%s' "$details" | cut -f4)"
  if [ "$state" != "OPEN" ]; then
    printf 'CLOSE_REFUSED not-open\n'
    exit 1
  fi
  if [ "$head_name" != "$branch" ] || [ "$cross_repository" != "false" ]; then
    printf 'CLOSE_REFUSED head-mismatch\n'
    exit 1
  fi
  if [ "$author_login" != "$CURRENT_LOGIN" ]; then
    printf 'CLOSE_REFUSED not-author\n'
    exit 1
  fi
  if ! close_and_delete "$pull_number" "$branch"; then
    printf 'CLOSE_FAILED gh-failed\n'
    exit 3
  fi
  printf 'CLOSED %s\n' "$pull_number"
  exit 0
}

[ "$#" -ge 1 ] || die_usage "a subcommand is required"
case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
esac
subcommand="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tree | --tag | --branch | --base | --own | --number)
      [ "$#" -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in
        --tree) tree="$2" ;;
        --tag) tag="$2" ;;
        --branch) branch="$2" ;;
        --base) base="$2" ;;
        --own) own_number="$2" ;;
        --number) pull_number="$2" ;;
      esac
      shift 2
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

case "$subcommand" in
  list | login | origin-version | cache-fields | fetch-branch | start | tie-break | close-own) ;;
  *) die_usage "unknown subcommand: $subcommand" ;;
esac

[ -n "$tree" ] || die_usage "--tree is required"
[ -d "$tree" ] || die_usage "--tree is not a directory: $tree"

case "$subcommand" in
  list) command_list ;;
  login) command_login ;;
  origin-version) command_origin_version ;;
  cache-fields) command_cache_fields ;;
  fetch-branch) command_fetch_branch ;;
  start) command_start ;;
  tie-break) command_tie_break ;;
  close-own) command_close_own ;;
esac
