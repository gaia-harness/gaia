#!/usr/bin/env bats

# Hermetic suite for .gaia/tests/report-main-status.sh, the reporter each
# push-to-main job runs to keep one `ci-red-main` issue per workflow open while
# that workflow is red on main.
# Push behavior cannot run before merge, so every transition is driven here
# through a PATH-stubbed `gh` that records its argv and answers from fixture
# files. Nothing reads the real tree, the network or a real repository.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../report-main-status.sh"
  STUB_DIRECTORY="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIRECTORY/bin"
  GH_LOG="${STUB_DIRECTORY}/argv.log"
  BODY_LOG="${STUB_DIRECTORY}/body.log"
  : > "$GH_LOG"
  : > "$BODY_LOG"
  : > "$STUB_DIRECTORY/issues.txt"
  write_issue_view "github-actions" ""
  printf '%s\n' 'shard-alpha' 'shard-beta' > "$STUB_DIRECTORY/jobs-failed.txt"
  printf 'ahead\n' > "$STUB_DIRECTORY/compare.txt"
  cat > "$STUB_DIRECTORY/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
previous=""
for argument in "$@"; do
  if [ "$previous" = "--body-file" ]; then
    { printf '=== %s %s\n' "$1" "$2"; cat "$argument"; } >> "$BODY_LOG"
  fi
  previous="$argument"
done
if [ -n "${GH_FAIL_ON:-}" ] && [ "$1 $2" = "$GH_FAIL_ON" ]; then
  exit 1
fi
case "$1 $2" in
  "issue list") cat "$STUB_DIRECTORY/issues.txt" ;;
  "issue view")
    expression=""
    previous=""
    for argument in "$@"; do
      [ "$previous" = "--jq" ] && expression="$argument"
      previous="$argument"
    done
    jq -r "$expression" "$STUB_DIRECTORY/issue-view.json"
    ;;
  "issue create") printf 'https://example.test/issues/9\n' ;;
  "api --paginate") cat "$STUB_DIRECTORY/jobs-failed.txt" ;;
  api\ repos/*/compare/*)
    [ -f "$STUB_DIRECTORY/compare-fails" ] && exit 1
    cat "$STUB_DIRECTORY/compare.txt"
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIRECTORY/bin/gh"
  export GH_LOG BODY_LOG STUB_DIRECTORY
  export PATH="$STUB_DIRECTORY/bin:$PATH"
  export GH_TOKEN="$BATS_TEST_NAME"
  export REPOSITORY="example/repo"
  export RUN_ID="777"
  export RUN_ATTEMPT="1"
  export RUN_URL="https://example.test/example/repo/actions/runs/777"
  export BEFORE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  export HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  export SHARDS_RESULT="failure"
}

# write_issue_view <body author login> <body text> [<comment author login> <comment text>]...
write_issue_view() {
  local body_login="$1" body_text="$2"
  shift 2
  local comments='[]'
  while [ "$#" -ge 2 ]; do
    comments=$(jq -c --arg login "$1" --arg text "$2" '. + [{author: {login: $login}, body: $text}]' <<<"$comments")
    shift 2
  done
  jq -n --arg login "$body_login" --arg text "$body_text" --argjson comments "$comments" \
    '{author: {login: $login}, body: $text, comments: $comments}' > "$STUB_DIRECTORY/issue-view.json"
}

# open_issues <number>... [-- <title>]: the open ci-red-main issues the stubbed
# `issue list` answers with, in the number<TAB>title form the script asks for,
# titled for GAIA: Audit CI Tests unless a title follows `--`.
open_issues() {
  local numbers=() title='Main is red: GAIA: Audit CI Tests' number
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--" ]; then
      title="$2"
      break
    fi
    numbers+=("$1")
    shift
  done
  for number in "${numbers[@]}"; do
    printf '%s\t%s\n' "$number" "$title"
  done >> "$STUB_DIRECTORY/issues.txt"
}

calls_matching() {
  grep -c -- "$1" "$GH_LOG" || true
}

# reset_case: clears the gh logs and returns every stub answer to its setup
# default, so one table test can run its cases in sequence.
reset_case() {
  : > "$GH_LOG"
  : > "$BODY_LOG"
  : > "$STUB_DIRECTORY/issues.txt"
  rm -f "$STUB_DIRECTORY/compare-fails"
  printf 'ahead\n' > "$STUB_DIRECTORY/compare.txt"
  write_issue_view "github-actions" ""
}

@test "red with no open issue creates the label then exactly one issue" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue create ')" -eq 1 ]
  [ "$(calls_matching '^label create ci-red-main --force')" -eq 1 ]
  label_line=$(grep -n '^label create' "$GH_LOG" | head -1 | cut -d: -f1)
  create_line=$(grep -n '^issue create' "$GH_LOG" | head -1 | cut -d: -f1)
  [ "$label_line" -lt "$create_line" ]
  grep -q -- '--label ci-red-main' "$GH_LOG"
  grep -qF -- '--title Main is red: GAIA: Audit CI Tests' "$GH_LOG"
  grep -qF -- "$RUN_URL" "$BODY_LOG"
  grep -qF -- "${BEFORE_SHA}..${HEAD_SHA}" "$BODY_LOG"
  grep -qF -- 'shard-alpha' "$BODY_LOG"
  grep -qF -- 'shard-beta' "$BODY_LOG"
  grep -qF -- "<!-- red-main-sha: ${HEAD_SHA} -->" "$BODY_LOG"
  grep -qF -- 'passing-shard' "$BODY_LOG" && return 1
  [ "$(calls_matching '^issue comment ')" -eq 0 ]
}

@test "the failing-leg listing reads only this run attempt's jobs" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "api --paginate repos/${REPOSITORY}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/jobs" "$GH_LOG"
}

@test "a zero or empty before-commit names the head commit alone" {
  local case_name
  for case_name in zero empty; do
    reset_case
    case "$case_name" in
      zero) export BEFORE_SHA="0000000000000000000000000000000000000000" ;;
      empty) export BEFORE_SHA="" ;;
    esac
    run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "case $case_name: status $status"; return 1; }
    grep -qF -- "$HEAD_SHA" "$BODY_LOG" || { echo "case $case_name: head commit not named"; return 1; }
    grep -qF -- '0000000' "$BODY_LOG" && { echo "case $case_name: zero commit named"; return 1; }
    grep -qF -- '..' "$BODY_LOG" && { echo "case $case_name: range named"; return 1; }
  done
  true
}

@test "red with an open issue comments on it and creates nothing" {
  open_issues 42
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue comment 42 ')" -eq 1 ]
  [ "$(calls_matching '^issue create ')" -eq 0 ]
  grep -qF -- "$RUN_URL" "$BODY_LOG"
  grep -qF -- 'shard-alpha' "$BODY_LOG"
  grep -qF -- "<!-- red-main-sha: ${HEAD_SHA} -->" "$BODY_LOG"
}

@test "two open issues: acts on the lowest number and creates nothing" {
  open_issues 51 42
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_matching '^issue comment 42 ')" -eq 1 ]
  [ "$(calls_matching '^issue comment 51 ')" -eq 0 ]
  [ "$(calls_matching '^issue create ')" -eq 0 ]
}

# bats test_tags=protected
@test "green closes the issue only when its marker commit is an ancestor of or equal to head" {
  export SHARDS_RESULT="success"
  local case_name
  for case_name in descendant identical behind diverged no-marker unresolvable; do
    reset_case
    open_issues 42
    case "$case_name" in
      descendant) write_issue_view "github-actions" $'body\n<!-- red-main-sha: cccccccccccccccccccccccccccccccccccccccc -->' ;;
      identical)
        write_issue_view "github-actions" "<!-- red-main-sha: ${HEAD_SHA} -->"
        printf 'identical\n' > "$STUB_DIRECTORY/compare.txt" ;;
      behind|diverged)
        write_issue_view "github-actions" "<!-- red-main-sha: cccccccccccccccccccccccccccccccccccccccc -->"
        printf '%s\n' "$case_name" > "$STUB_DIRECTORY/compare.txt" ;;
      no-marker) write_issue_view "github-actions" "hand-written issue" ;;
      unresolvable)
        write_issue_view "github-actions" "<!-- red-main-sha: cccccccccccccccccccccccccccccccccccccccc -->"
        : > "$STUB_DIRECTORY/compare-fails" ;;
    esac
    run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "case $case_name: status $status"; return 1; }
    case "$case_name" in
      descendant|identical)
        [ "$(calls_matching '^issue close 42')" -eq 1 ] || { echo "case $case_name: issue not closed"; return 1; } ;;
      *)
        [ "$(calls_matching '^issue close ')" -eq 0 ] || { echo "case $case_name: issue closed"; return 1; }
        [ "$(calls_matching '^issue comment 42 ')" -eq 1 ] || { echo "case $case_name: no comment on 42"; return 1; } ;;
    esac
    if [ "$case_name" = descendant ]; then
      grep -qF -- "repos/${REPOSITORY}/compare/cccccccccccccccccccccccccccccccccccccccc...${HEAD_SHA}" "$GH_LOG" || { echo "case $case_name: compare not called"; return 1; }
      grep -qF -- "$RUN_URL" "$BODY_LOG" || { echo "case $case_name: no run link"; return 1; }
    fi
    case "$case_name" in
      behind|diverged) grep -qF -- 'did not close' "$BODY_LOG" || { echo "case $case_name: does not say it did not close"; return 1; } ;;
    esac
  done
}

# bats test_tags=protected
@test "only the newest marker the workflow token wrote counts" {
  export SHARDS_RESULT="success"
  local case_name
  for case_name in newest stranger-comment stranger-only; do
    reset_case
    open_issues 42
    case "$case_name" in
      newest) write_issue_view "github-actions" "<!-- red-main-sha: 1111111111111111111111111111111111111111 -->" \
        "github-actions" "<!-- red-main-sha: 2222222222222222222222222222222222222222 -->" ;;
      stranger-comment) write_issue_view "github-actions" "<!-- red-main-sha: cccccccccccccccccccccccccccccccccccccccc -->" \
        "some-stranger" "<!-- red-main-sha: dddddddddddddddddddddddddddddddddddddddd -->" ;;
      stranger-only) write_issue_view "some-stranger" "<!-- red-main-sha: cccccccccccccccccccccccccccccccccccccccc -->" ;;
    esac
    run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "case $case_name: status $status"; return 1; }
    case "$case_name" in
      newest)
        grep -qF -- "compare/2222222222222222222222222222222222222222...${HEAD_SHA}" "$GH_LOG" || { echo "case $case_name: newest marker not compared"; return 1; }
        grep -qF -- "compare/1111111111111111111111111111111111111111" "$GH_LOG" && { echo "case $case_name: older marker compared"; return 1; } ;;
      stranger-comment)
        grep -qF -- "compare/cccccccccccccccccccccccccccccccccccccccc...${HEAD_SHA}" "$GH_LOG" || { echo "case $case_name: author marker not compared"; return 1; }
        grep -qF -- "compare/dddddddddddddddddddddddddddddddddddddddd" "$GH_LOG" && { echo "case $case_name: stranger marker compared"; return 1; } ;;
      stranger-only)
        [ "$(calls_matching '^issue close ')" -eq 0 ] || { echo "case $case_name: issue closed"; return 1; }
        [ "$(calls_matching '^api repos/')" -eq 0 ] || { echo "case $case_name: compare called"; return 1; } ;;
    esac
  done
}

@test "green with no open issue makes no write" {
  export SHARDS_RESULT="success"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qE '^(issue (create|comment|close)|label)' "$GH_LOG" && return 1
  true
}

@test "cancelled and skipped make no gh call at all" {
  for result in cancelled skipped; do
    : > "$GH_LOG"
    SHARDS_RESULT="$result" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$GH_LOG" ]
  done
}

# bats test_tags=protected
@test "untrusted event text never reaches the issue" {
  export GITHUB_HEAD_REF='evil-branch $(touch pwned)'
  export GITHUB_REF_NAME='hostile-ref-name'
  export COMMIT_MESSAGE='fix: hostile commit message'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- 'evil-branch' "$BODY_LOG" "$GH_LOG" && return 1
  grep -qF -- 'hostile' "$BODY_LOG" "$GH_LOG" && return 1
  true
}

@test "a failing gh call exits non-zero with a report-main-status line" {
  export GH_FAIL_ON="issue create"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"report-main-status:"* ]]
}

# bats test_tags=protected
@test "CHECK_NAME scopes the issue title, lookup and close to its own workflow" {
  export CHECK_NAME='GAIA: Distribution Harness'
  local case_name
  for case_name in title red-own-issue red-other-only green-other; do
    reset_case
    export SHARDS_RESULT="failure"
    case "$case_name" in
      red-own-issue)
        open_issues 42
        open_issues 57 -- 'Main is red: GAIA: Distribution Harness' ;;
      red-other-only) open_issues 42 ;;
      green-other)
        export SHARDS_RESULT="success"
        write_issue_view "github-actions" "<!-- red-main-sha: ${HEAD_SHA} -->"
        open_issues 42 ;;
    esac
    run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "case $case_name: status $status"; return 1; }
    case "$case_name" in
      title)
        [ "$(calls_matching '^issue create ')" -eq 1 ] || { echo "case $case_name: not one create"; return 1; }
        grep -qF -- '--title Main is red: GAIA: Distribution Harness' "$GH_LOG" || { echo "case $case_name: title"; return 1; }
        grep -q -- '--label ci-red-main' "$GH_LOG" || { echo "case $case_name: label"; return 1; } ;;
      red-own-issue)
        [ "$(calls_matching '^issue comment 57 ')" -eq 1 ] || { echo "case $case_name: no comment on 57"; return 1; }
        [ "$(calls_matching '^issue comment 42 ')" -eq 0 ] || { echo "case $case_name: commented on 42"; return 1; }
        [ "$(calls_matching '^issue create ')" -eq 0 ] || { echo "case $case_name: created an issue"; return 1; } ;;
      red-other-only)
        [ "$(calls_matching '^issue create ')" -eq 1 ] || { echo "case $case_name: not one create"; return 1; }
        [ "$(calls_matching '^issue comment 42 ')" -eq 0 ] || { echo "case $case_name: commented on 42"; return 1; } ;;
      green-other)
        grep -qE '^issue (comment|close) 42' "$GH_LOG" && { echo "case $case_name: touched 42"; return 1; } ;;
    esac
  done
  true
}

@test "a missing variable exits 2 before any gh call" {
  for variable in GH_TOKEN REPOSITORY RUN_ID RUN_ATTEMPT RUN_URL HEAD_SHA SHARDS_RESULT; do
    : > "$GH_LOG"
    run env -u "$variable" bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"report-main-status:"* ]]
    [[ "$output" == *"$variable"* ]]
    [ ! -s "$GH_LOG" ]
  done
}
