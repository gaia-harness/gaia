#!/usr/bin/env bats

# .gaia/scripts/update-claim.sh: the live-claim definition and every gh call a
# claim needs. gh is a stub that logs its working directory and arguments and
# answers from fixture files; git is a logging shim over the real binary, run
# against a bare origin and a clone in temp directories.
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/tests/lib/update-claim.bats < /dev/null

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  CLAIM_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)/update-claim.sh"
  REAL_GIT="$(command -v git)"
  REAL_JQ="$(command -v jq)"

  STATE_DIR="$BATS_TEST_TMPDIR/state"
  BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STATE_DIR" "$BIN_DIR"
  export GH_STATE="$STATE_DIR"
  export GH_LOG="$STATE_DIR/gh.log"
  export GIT_LOG="$STATE_DIR/git.log"
  export REAL_GIT REAL_JQ
  : >"$GH_LOG"
  : >"$GIT_LOG"
  printf '[]' >"$STATE_DIR/pr-list.json"
  printf '[]' >"$STATE_DIR/pr-list-head.json"
  write_gh_stub "$BIN_DIR/gh"
  write_git_shim "$BIN_DIR/git"
  export PATH="$BIN_DIR:$PATH"

  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  : >"$GIT_CONFIG_GLOBAL"
  export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
  export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"

  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  WORK="$BATS_TEST_TMPDIR/work"
  "$REAL_GIT" init -q --bare -b main "$ORIGIN"
  "$REAL_GIT" init -q -b main "$WORK"
  "$REAL_GIT" -C "$WORK" remote add origin "$ORIGIN"
  printf 'x\n' >"$WORK/file.txt"
  "$REAL_GIT" -C "$WORK" add file.txt
  "$REAL_GIT" -C "$WORK" commit -q -m "initial"
  "$REAL_GIT" -C "$WORK" push -q -u origin main
  WORK="$(cd "$WORK" && pwd -P)"
  CLAIM_BRANCH="update/v2.0.4-2026-10-18-1200"
  "$REAL_GIT" -C "$WORK" checkout -q -b "$CLAIM_BRANCH"
  : >"$GIT_LOG"
}

# A gh stub. Every call logs "<physical cwd> | <args>". `pr list` answers from
# pr-list.json (or pr-list-head.json when --head is given) and applies --jq
# through real jq, the way gh does. Behaviour switches come from files in
# $GH_STATE so a test sets one without re-exporting.
write_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
printf '%s | %s\n' "$(pwd -P)" "$*" >> "$GH_LOG"
state="$GH_STATE"
[ -e "$state/fail-all" ] && exit 1
has_body=0
jq_expression=""
previous=""
for argument in "$@"; do
  [ "$previous" = "--body" ] && [ -n "$argument" ] && has_body=1
  [ "$previous" = "--jq" ] && jq_expression="$argument"
  previous="$argument"
done
emit() {
  if [ -n "$jq_expression" ]; then "$REAL_JQ" -r "$jq_expression" < "$1"; else cat "$1"; fi
}
case "$1 $2" in
  "auth status")
    [ -e "$state/fail-auth" ] && exit 1
    exit 0 ;;
  "pr list")
    [ -e "$state/fail-list" ] && exit 1
    case " $* " in
      *" --head "*) emit "$state/pr-list-head.json" ;;
      *) emit "$state/pr-list.json" ;;
    esac
    exit 0 ;;
  "pr create")
    [ -e "$state/fail-create" ] && exit 1
    [ -e "$state/require-body" ] && [ "$has_body" -eq 0 ] && exit 1
    printf 'https://github.com/acme/widgets/pull/77\n'
    exit 0 ;;
  "pr view")
    [ -e "$state/fail-view" ] && exit 1
    cat "$state/view.tsv"
    exit 0 ;;
  "pr close")
    [ -e "$state/fail-close" ] && exit 1
    exit 0 ;;
esac
if [ "$1" = "api" ]; then
  case "$*" in
    *"user"*)
      [ -e "$state/fail-login" ] && exit 1
      cat "$state/login.txt"
      exit 0 ;;
    *"contents/.gaia/VERSION"*)
      [ -e "$state/fail-origin" ] && exit 1
      cat "$state/origin-version.txt"
      exit 0 ;;
  esac
fi
exit 1
EOF
  chmod +x "$1"
}

write_git_shim() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_LOG"
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$1"
}

# A PATH with the tools the script needs and no gh at all.
make_path_without_gh() {
  local tool_directory="$BATS_TEST_TMPDIR/nogh" tool
  mkdir -p "$tool_directory"
  for tool in grep tr wc cut head tail cat sed sort uname dirname basename mkdir rm; do
    ln -sf "$(command -v "$tool")" "$tool_directory/$tool"
  done
  ln -sf "$BIN_DIR/git" "$tool_directory/git"
  ln -sf "$REAL_JQ" "$tool_directory/jq"
  printf '%s' "$tool_directory"
}

claim_entry() {
  # claim_entry <number> <head> <login> <cross>
  jq -n --argjson number "$1" --arg head "$2" --arg login "$3" --argjson cross "$4" \
    '{number: $number, headRefName: $head, author: {login: $login}, createdAt: "2026-10-18T12:00:00Z", isCrossRepository: $cross}'
}

set_claims() {
  jq -s '.' >"$STATE_DIR/pr-list.json"
}

run_claim() {
  run bash -c 'exec bash "$0" "$@" 2>/dev/null' "$CLAIM_SCRIPT" "$@"
}

count_lines_matching() {
  grep -c -- "$1" "$2" || true
}

# Clear the logs, the gh behaviour switches, both hooks and the claim commit,
# so each case of a table starts from the state setup() built.
reset_case() {
  rm -f "$STATE_DIR"/fail-* "$STATE_DIR/require-body" \
    "$WORK/.git/hooks/pre-commit" "$ORIGIN/hooks/pre-receive"
  printf '[]' >"$STATE_DIR/pr-list.json"
  "$REAL_GIT" -C "$WORK" reset -q --hard main
  "$REAL_GIT" -C "$ORIGIN" update-ref -d "refs/heads/$CLAIM_BRANCH" 2>/dev/null || true
  : >"$GH_LOG"
  : >"$GIT_LOG"
}

@test "list prints a CLAIM line per same-repo update PR, parsing prerelease and compact stamps, dropping bad rows, ascending" {
  echo "case: one same-repo update PR, the rest dropped"
  {
    claim_entry 41 "update/v2.0.4-2026-10-18-1200" octo-cat false
    claim_entry 42 "update/v2.0.4-20261018T120000Z" forker true
    claim_entry 43 "update/readme" octo-cat false
    claim_entry 44 "update/v2.0.4-2026-10-18-1200" "$(printf 'bad\033name')" false
    claim_entry 45 "update/vnext-2026-10-18-1200" octo-cat false
  } | set_claims
  run_claim list --tree "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIM 41 v2.0.4 octo-cat 2026-10-18T12:00:00Z update/v2.0.4-2026-10-18-1200" ]
  grep -q -- '--limit 1000' "$GH_LOG"

  echo "case: a prerelease tag ahead of the minted stamp"
  claim_entry 41 "update/v2.1.0-rc.1-2026-10-18-1200" octo-cat false | set_claims
  run_claim list --tree "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIM 41 v2.1.0-rc.1 octo-cat 2026-10-18T12:00:00Z update/v2.1.0-rc.1-2026-10-18-1200" ]

  echo "case: a same-repo branch with a compact stamp parses to its core tag"
  claim_entry 41 "update/v2.0.4-20261018T120000Z" octo-cat false | set_claims
  run_claim list --tree "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIM 41 v2.0.4 octo-cat 2026-10-18T12:00:00Z update/v2.0.4-20261018T120000Z" ]

  echo "case: a malformed createdAt is dropped and the rest print in ascending number"
  {
    claim_entry 52 "update/v2.0.4-2026-10-18-1300" zed false
    claim_entry 51 "update/v2.0.4-2026-10-18-1200" amy false
    claim_entry 50 "update/v2.0.4-2026-10-18-1100" bob false | jq '.createdAt = "yesterday"'
  } | set_claims
  run_claim list --tree "$WORK"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -d' ' -f2 | tr '\n' ' ')" = "51 52 " ]
}

@test "list exits 3 with a skip token when gh fails or is missing" {
  echo "case: gh fails"
  : >"$STATE_DIR/fail-list"
  run_claim list --tree "$WORK"
  [ "$status" -eq 3 ]
  [ "$output" = "CLAIM_CHECK_SKIPPED gh-failed" ]

  echo "case: gh missing"
  local restricted
  restricted="$(make_path_without_gh)"
  run env PATH="$restricted" "$(command -v bash)" "$CLAIM_SCRIPT" list --tree "$WORK"
  [ "$status" -eq 3 ]
  [ "$output" = "CLAIM_CHECK_SKIPPED gh-missing" ]
}

@test "login prints the login and exits 3 when it is unavailable or out of set" {
  printf 'octo-cat\n' >"$STATE_DIR/login.txt"
  run_claim login --tree "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "LOGIN octo-cat" ]

  : >"$STATE_DIR/fail-login"
  run_claim login --tree "$WORK"
  [ "$status" -eq 3 ]
  [ "$output" = "LOGIN_UNAVAILABLE gh-failed" ]

  rm "$STATE_DIR/fail-login"
  printf 'bad\033name\n' >"$STATE_DIR/login.txt"
  run_claim login --tree "$WORK"
  [ "$status" -eq 3 ]
  [ "$output" = "LOGIN_UNAVAILABLE login-out-of-set" ]
}

@test "origin-version reads through gh api without git fetch and exits 3 on failure or a non-version" {
  echo "case: reads the file through gh api and never runs git fetch"
  printf '2.0.4\n' >"$STATE_DIR/origin-version.txt"
  run_claim origin-version --tree "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "ORIGIN_VERSION 2.0.4" ]
  grep -q -- 'api -H Accept: application/vnd.github.raw+json repos/{owner}/{repo}/contents/.gaia/VERSION' "$GH_LOG"
  grep -q -- 'fetch' "$GIT_LOG" && return 1

  echo "case: a gh failure"
  : >"$STATE_DIR/fail-origin"
  run_claim origin-version --tree "$WORK"
  [ "$status" -eq 3 ]
  [ "$output" = "ORIGIN_VERSION_UNAVAILABLE gh-failed" ]

  echo "case: a value that is not a version"
  rm "$STATE_DIR/fail-origin"
  printf 'not a version' >"$STATE_DIR/origin-version.txt"
  run_claim origin-version --tree "$WORK"
  [ "$status" -eq 3 ]
  [ "$output" = "ORIGIN_VERSION_UNAVAILABLE not-a-version" ]
}

@test "cache-fields prints all-empty JSON on failure or no jq, and carries the claims otherwise" {
  local empty='{"gaiaOriginVersion":null,"gaiaUpdateClaims":[],"ghLogin":""}'

  echo "case: every gh call fails"
  : >"$STATE_DIR/fail-all"
  run_claim cache-fields --tree "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "$empty" ]
  rm "$STATE_DIR/fail-all"

  echo "case: jq is missing"
  local restricted
  restricted="$(make_path_without_gh)"
  rm "$restricted/jq"
  run env PATH="$restricted" "$(command -v bash)" "$CLAIM_SCRIPT" cache-fields --tree "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "$empty" ]

  echo "case: carries the origin version, the claims and the login"
  printf '2.0.4\n' >"$STATE_DIR/origin-version.txt"
  printf 'octo-cat\n' >"$STATE_DIR/login.txt"
  claim_entry 41 "update/v2.0.4-2026-10-18-1200" other false | set_claims
  run_claim cache-fields --tree "$WORK"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.gaiaOriginVersion')" = "2.0.4" ]
  [ "$(printf '%s' "$output" | jq -r '.ghLogin')" = "octo-cat" ]
  [ "$(printf '%s' "$output" | jq -c '.gaiaUpdateClaims[0] | [.number, .tag, .authorLogin, .headRefName]')" = '[41,"v2.0.4","other","update/v2.0.4-2026-10-18-1200"]' ]
}

@test "malformed invocations exit 2: missing --tree, non-claim branch" {
  local subcommand
  for subcommand in list login origin-version cache-fields fetch-branch start tie-break close-own; do
    echo "case: $subcommand without --tree"
    run bash "$CLAIM_SCRIPT" "$subcommand"
    [ "$status" -eq 2 ]
  done

  echo "case: start on a branch that is not a claim branch"
  run_claim start --tree "$WORK" --tag v2.0.4 --branch "feature/x" --base main
  [ "$status" -eq 2 ]
}

@test "every gh call runs with the tree as its working directory" {
  printf '2.0.4\n' >"$STATE_DIR/origin-version.txt"
  printf 'octo-cat\n' >"$STATE_DIR/login.txt"
  claim_entry 41 "update/v2.0.4-2026-10-18-1200" other false | set_claims
  local before subcommand
  before="$(pwd -P)"
  for subcommand in list login origin-version cache-fields; do
    run_claim "$subcommand" --tree "$WORK"
    [ "$status" -eq 0 ]
  done
  [ "$(pwd -P)" = "$before" ]
  [ -s "$GH_LOG" ]
  local line
  while IFS= read -r line; do
    [ "${line%% | *}" = "$WORK" ]
  done <"$GH_LOG"
}

# bats test_tags=protected
@test "start skips with its reason before or after the failing step and never forces or bypasses" {
  echo "case: gh-missing before any commit"
  reset_case
  local restricted
  restricted="$(make_path_without_gh)"
  run env PATH="$restricted" "$(command -v bash)" "$CLAIM_SCRIPT" start --tree "$WORK" --tag v2.0.4 --branch "$CLAIM_BRANCH" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIM_SKIPPED gh-missing" ]
  [ "$(count_lines_matching ' commit ' "$GIT_LOG")" = "0" ]

  echo "case: gh-unauthenticated before any commit"
  reset_case
  : >"$STATE_DIR/fail-auth"
  run_claim start --tree "$WORK" --tag v2.0.4 --branch "$CLAIM_BRANCH" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIM_SKIPPED gh-unauthenticated" ]
  [ "$(count_lines_matching ' commit ' "$GIT_LOG")" = "0" ]

  echo "case: commit-refused when a hook refuses, never retried or bypassed"
  reset_case
  printf '#!/bin/sh\nexit 1\n' >"$WORK/.git/hooks/pre-commit"
  chmod +x "$WORK/.git/hooks/pre-commit"
  run_claim start --tree "$WORK" --tag v2.0.4 --branch "$CLAIM_BRANCH" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIM_SKIPPED commit-refused" ]
  [ "$(count_lines_matching ' commit ' "$GIT_LOG")" = "1" ]
  grep -q -- '--no-verify' "$GIT_LOG" && return 1
  grep -q -- 'pr create' "$GH_LOG" && return 1

  echo "case: push-rejected when origin refuses the push, never forced"
  reset_case
  printf '#!/bin/sh\nexit 1\n' >"$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  run_claim start --tree "$WORK" --tag v2.0.4 --branch "$CLAIM_BRANCH" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIM_SKIPPED push-rejected" ]
  grep -q -- 'force' "$GIT_LOG" && return 1
  grep -q -- 'pr create' "$GH_LOG" && return 1

  echo "case: pr-create-failed when gh pr create fails"
  reset_case
  : >"$STATE_DIR/fail-create"
  run_claim start --tree "$WORK" --tag v2.0.4 --branch "$CLAIM_BRANCH" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIM_SKIPPED pr-create-failed" ]
}

@test "start makes one empty commit, pushes it and opens a draft PR with a body" {
  echo "case: one empty commit, pushed, a draft PR with a body"
  run_claim start --tree "$WORK" --tag v2.0.4 --branch "$CLAIM_BRANCH" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIMED 77 https://github.com/acme/widgets/pull/77" ]
  [ "$("$REAL_GIT" -C "$WORK" rev-list --count origin/main..HEAD)" = "1" ]
  [ "$("$REAL_GIT" -C "$WORK" log -1 --format=%s)" = "chore(gaia): start update to v2.0.4" ]
  [ -z "$("$REAL_GIT" -C "$WORK" diff-tree --no-commit-id -r HEAD)" ]
  [ "$("$REAL_GIT" -C "$ORIGIN" rev-parse "refs/heads/$CLAIM_BRANCH")" = "$("$REAL_GIT" -C "$WORK" rev-parse HEAD)" ]
  grep -q -- "pr create --draft --base main --head $CLAIM_BRANCH --title chore(gaia): update to v2.0.4 --body Claims the GAIA v2.0.4 update" "$GH_LOG"
  local line
  while IFS= read -r line; do
    [ "${line%% | *}" = "$WORK" ]
  done <"$GH_LOG"

  echo "case: a gh that refuses a bodiless create still yields CLAIMED"
  reset_case
  : >"$STATE_DIR/require-body"
  run_claim start --tree "$WORK" --tag v2.0.4 --branch "$CLAIM_BRANCH" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIMED 77 https://github.com/acme/widgets/pull/77" ]
}

@test "a second start on the same branch makes no second commit and no second create" {
  run_claim start --tree "$WORK" --tag v2.0.4 --branch "$CLAIM_BRANCH" --base main
  [ "$status" -eq 0 ]
  printf '[{"number":77,"url":"https://github.com/acme/widgets/pull/77","isCrossRepository":false}]' >"$STATE_DIR/pr-list-head.json"
  run_claim start --tree "$WORK" --tag v2.0.4 --branch "$CLAIM_BRANCH" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIMED 77 https://github.com/acme/widgets/pull/77" ]
  [ "$("$REAL_GIT" -C "$WORK" rev-list --count origin/main..HEAD)" = "1" ]
  [ "$(count_lines_matching ' commit ' "$GIT_LOG")" = "1" ]
  [ "$(count_lines_matching 'pr create' "$GH_LOG")" = "1" ]
}

two_claims_with_origin_branches() {
  local branch_41="update/v2.0.4-2026-10-18-1100" branch_42="update/v2.0.4-2026-10-18-1300"
  "$REAL_GIT" -C "$WORK" push -q origin "main:refs/heads/$branch_41" "main:refs/heads/$branch_42"
  {
    claim_entry 41 "$branch_41" octo-cat false
    claim_entry 42 "$branch_42" other false
  } | set_claims
  : >"$GH_LOG"
  : >"$GIT_LOG"
  BRANCH_41="$branch_41"
  BRANCH_42="$branch_42"
}

@test "tie-break reports WON, LOST or SKIPPED and closes only the higher own claim" {
  echo "case: only the own claim reports WON and closes nothing"
  claim_entry 42 "update/v2.0.4-2026-10-18-1300" other false | set_claims
  run_claim tie-break --tree "$WORK" --own 42
  [ "$status" -eq 0 ]
  [ "$output" = "WON" ]
  grep -q -- 'pr close' "$GH_LOG" && return 1

  echo "case: a failing list reports TIE_BREAK_SKIPPED and closes nothing"
  reset_case
  : >"$STATE_DIR/fail-list"
  run_claim tie-break --tree "$WORK" --own 42
  [ "$status" -eq 0 ]
  [ "$output" = "TIE_BREAK_SKIPPED gh-failed" ]
  grep -q -- 'pr close' "$GH_LOG" && return 1

  echo "case: the lowest-numbered claim is the winner"
  reset_case
  two_claims_with_origin_branches
  run_claim tie-break --tree "$WORK" --own 41
  [ "$status" -eq 0 ]
  [ "$output" = "WON" ]

  echo "case: the higher-numbered own claim is closed, only its remote branch deleted, LOST"
  reset_case
  two_claims_with_origin_branches
  run_claim tie-break --tree "$WORK" --own 42
  [ "$status" -eq 0 ]
  [ "$output" = "LOST 41 octo-cat" ]
  grep -q -- 'pr close 42' "$GH_LOG"
  grep -q -- 'pr close 41' "$GH_LOG" && return 1
  "$REAL_GIT" -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$BRANCH_42" && return 1
  "$REAL_GIT" -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$BRANCH_41" >/dev/null
}

view_tsv() {
  # view_tsv <state> <head> <author> <cross>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >"$STATE_DIR/view.tsv"
}

# bats test_tags=protected
@test "close-own closes an open own PR from the named branch and refuses another head, a closed PR or a gh failure" {
  printf 'octo-cat\n' >"$STATE_DIR/login.txt"

  echo "case: refuses when the head differs from --branch"
  view_tsv OPEN "update/v2.0.4-2026-10-18-1999" octo-cat false
  run_claim close-own --tree "$WORK" --number 42 --branch "$CLAIM_BRANCH"
  [ "$status" -eq 1 ]
  [ "$output" = "CLOSE_REFUSED head-mismatch" ]
  grep -q -- 'pr close' "$GH_LOG" && return 1

  echo "case: refuses a PR that is not open"
  reset_case
  view_tsv MERGED "$CLAIM_BRANCH" octo-cat false
  run_claim close-own --tree "$WORK" --number 42 --branch "$CLAIM_BRANCH"
  [ "$status" -eq 1 ]
  [ "$output" = "CLOSE_REFUSED not-open" ]
  grep -q -- 'pr close' "$GH_LOG" && return 1

  echo "case: exits 3 when gh fails"
  reset_case
  : >"$STATE_DIR/fail-view"
  run_claim close-own --tree "$WORK" --number 42 --branch "$CLAIM_BRANCH"
  [ "$status" -eq 3 ]

  echo "case: closes an open PR the current user authored from the named branch"
  reset_case
  "$REAL_GIT" -C "$WORK" push -q origin "main:refs/heads/$CLAIM_BRANCH"
  view_tsv OPEN "$CLAIM_BRANCH" octo-cat false
  run_claim close-own --tree "$WORK" --number 42 --branch "$CLAIM_BRANCH"
  [ "$status" -eq 0 ]
  [ "$output" = "CLOSED 42" ]
  grep -q -- 'pr close 42' "$GH_LOG"
  "$REAL_GIT" -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$CLAIM_BRANCH" && return 1
  true
}

# bats test_tags=protected
@test "close-own refuses when the author is not the current login" {
  printf 'octo-cat\n' >"$STATE_DIR/login.txt"
  view_tsv OPEN "$CLAIM_BRANCH" someone-else false
  run_claim close-own --tree "$WORK" --number 42 --branch "$CLAIM_BRANCH"
  [ "$status" -eq 1 ]
  [ "$output" = "CLOSE_REFUSED not-author" ]
  grep -q -- 'pr close' "$GH_LOG" && return 1
  true
}

# bats test_tags=protected
@test "fetch-branch fetches a claim branch and refuses any other name" {
  "$REAL_GIT" -C "$WORK" push -q origin "main:refs/heads/update/v2.0.9-2026-10-18-1200"
  run_claim fetch-branch --tree "$WORK" --branch "update/v2.0.9-2026-10-18-1200"
  [ "$status" -eq 0 ]
  [ "$output" = "FETCHED update/v2.0.9-2026-10-18-1200" ]
  grep -q -- '--force\|+refs' "$GIT_LOG" && return 1
  run_claim fetch-branch --tree "$WORK" --branch "main"
  [ "$status" -eq 2 ]
}
