#!/usr/bin/env bats
#
# Acceptance suite for the headless review child: what the script passes and how it
# reacts, through a stand-in `claude` on PATH. A stand-in cannot show that Claude
# Code honors those flags; only the hand-run probe beside the claude-probe suite can.
#
# Placeholders are filled on a scratch copy, each constant replaced by name whatever
# it currently holds, so filling the real file changes no test here.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SHIPPED="$REPO_ROOT/.gaia/scripts"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/review
  alf_set_line src.txt 1 change
  alf_commit change
  RUN="$ALF_ROOT/.gaia/local/runs/feat/review"
  mkdir -p "$RUN"
  RECORD="$RUN/code-review.json"
  STAND_IN="$BATS_TEST_TMPDIR/stand-in"
  export STAND_IN
  mkdir -p "$STAND_IN/bin" "$STAND_IN/log"
  BEHAVIOR="$STAND_IN/behavior.sh"
  : >"$BEHAVIOR"
  write_stand_in_claude
  stand_in_gh false
  PATH="$STAND_IN/bin:$PATH"
  STAND_IN_SAMPLE="inherited value"
  export STAND_IN_SAMPLE
  make_tool_copy
}

teardown() {
  local recorded_pid
  if [ -f "$STAND_IN/pids" ]; then
    while IFS= read -r recorded_pid; do
      kill -KILL "$recorded_pid" 2>/dev/null || true
    done <"$STAND_IN/pids"
  fi
  [ -z "${LIVE_PID:-}" ] || kill -KILL "$LIVE_PID" "-$LIVE_PID" 2>/dev/null || true
}

write_stand_in_claude() {
  cat >"$STAND_IN/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1-}" = --version ]; then
  printf '%s (Claude Code)\n' "$(cat "$STAND_IN/version" 2>/dev/null || printf '2.1.319')"
  exit 0
fi
spawn_number=$(($(ls "$STAND_IN/log" | wc -l) + 1))
printf '%s\n' "$@" >"$STAND_IN/log/argv-$spawn_number"
printf '%s\n' "$PWD" >"$STAND_IN/cwd"
printf '%s\n' "$STAND_IN_SAMPLE" >"$STAND_IN/sample"
. "$STAND_IN/behavior.sh"
EOF
  chmod +x "$STAND_IN/bin/claude"
}

# stand_in_gh <true|false|fail>: the fork answer, or a gh that cannot answer.
stand_in_gh() {
  cat >"$STAND_IN/bin/gh" <<EOF
#!/usr/bin/env bash
case "$1" in
  fail) printf 'network down\n' >&2; exit 1 ;;
  *) printf '%s\n' "$1" ;;
esac
EOF
  chmod +x "$STAND_IN/bin/gh"
}

# make_tool_copy: the scripts under a scratch tree shaped like a checkout, every
# constant filled, so the review runs. TOOL is the copied entry script.
make_tool_copy() {
  local tool_root="$BATS_TEST_TMPDIR/tool" script_name
  mkdir -p "$tool_root/.gaia/scripts" "$tool_root/.claude/hooks/lib"
  for script_name in audit-code-review.sh audit-code-review-child.sh audit-code-review-judge.sh audit-code-review-guard.sh audit-code-review-record.sh audit-code-review-decide.sh audit-code-review-handover.sh audit-loop-record.sh; do
    cp "$SHIPPED/$script_name" "$tool_root/.gaia/scripts/$script_name"
  done
  cp "$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh" "$REPO_ROOT/.claude/hooks/lib/cross-repo-refusal.sh" "$tool_root/.claude/hooks/lib/"
  TOOL="$tool_root/.gaia/scripts/audit-code-review.sh"
  fill_constant REVIEW_CHILD_PROVEN yes
  fill_constant REVIEW_TARGET_FORMAT '<base-sha>...<head-sha>'
  fill_constant REVIEW_TIMEOUT_SECONDS 30
  fill_constant REVIEW_HOOK_DENIALS_VISIBLE no
}

# fill_constant <name> <value>: replace the constant's whole line, by name. Fails
# when the name is absent, so a renamed constant cannot leave a test vacuous.
fill_constant() {
  local replacement
  replacement="$1=$(printf '%q' "$2")"
  CONSTANT_NAME="$1" CONSTANT_LINE="$replacement" awk '
    index($0, ENVIRON["CONSTANT_NAME"] "=") == 1 { print ENVIRON["CONSTANT_LINE"]; found = 1; next }
    { print }
    END { if (!found) exit 3 }' "$TOOL" >"$TOOL.new" || return $?
  mv "$TOOL.new" "$TOOL"
}

run_review() {
  run --separate-stderr bash "$TOOL" run --root "$ALF_ROOT" --pr 7 --run-folder "$RUN"
}

spawn_count() {
  find "$STAND_IN/log" -name 'argv-*' | wc -l | tr -d ' '
}

record_field() {
  jq -r "$1" "$RECORD"
}

# behave_usable: the child prints a usable result with one finding.
behave_usable() {
  cat >"$BEHAVIOR" <<'EOF'
jq -n '{subtype: "success", is_error: false, local_command: "code_review", total_cost_usd: 0.5,
  modelUsage: {"claude-opus": {costUSD: 0.5}},
  result: "```json\n[{\"file\":\"src.txt\",\"line\":1,\"summary\":\"s\",\"failure_scenario\":\"f\"}]\n```"}'
EOF
}

behave_clean() {
  cat >"$BEHAVIOR" <<'EOF'
jq -n '{subtype: "success", is_error: false, local_command: "code_review", total_cost_usd: 0.25, result: "```json\n[]\n```"}'
EOF
}

# settings_violations <settings-json>: every row granting more than a read tool or
# a literal read-only git prefix. Empty means the set is clean.
settings_violations() {
  jq -r --arg root "$ALF_ROOT" '
    ["diff", "log", "show", "status", "rev-parse", "merge-base", "blame", "ls-files", "cat-file"] as $verbs
    | ([$verbs[] | "Bash(git \(.):*)", "Bash(git -C \($root) \(.):*)"]
       + ["Read", "Grep", "Glob", "Bash(git branch --show-current)", "Bash(git -C \($root) branch --show-current)"]) as $permitted
    | .permissions.allow[] | select(. as $row | $permitted | index($row) == null)' <<<"$1"
}

@test "the argv is the frozen set, one array, from the working root, environment inherited" {
  behave_clean
  run_review
  [ "$status" -eq 0 ]
  local argv_file="$STAND_IN/log/argv-1" base head
  [ -f "$argv_file" ]
  base="$(alf_git merge-base HEAD refs/remotes/origin/main)"
  head="$(alf_git rev-parse HEAD)"

  [ "$(sed -n 1p "$argv_file")" = -p ]
  [ "$(sed -n 2p "$argv_file")" = "/code-review high --max-findings all $base...$head" ]
  local flag
  for flag in --restricted --strict-mcp-config dontAsk --permission-mode Read,Grep,Glob,Bash --tools opus --model json --output-format; do
    grep -Fxq -- "$flag" "$argv_file"
  done
  grep -Fxq -- "$RUN/code-review-attempt-1/child-settings.json" "$argv_file"
  for flag in --effort --fix --comment --max-budget-usd --allowedTools --allowed-tools --dangerously-skip-permissions; do
    grep -Fxq -- "$flag" "$argv_file" && return 1
  done
  [ "$(wc -l <"$argv_file" | tr -d ' ')" = 14 ]
  [ "$(cat "$STAND_IN/cwd")" = "$ALF_ROOT" ]
  [ "$(cat "$STAND_IN/sample")" = "inherited value" ]
}

@test "the generated settings grant only reads and literal read-only git rows" {
  local settings mutated
  settings="$(bash "$TOOL" settings --root "$ALF_ROOT" --attempt-dir "$RUN/a" --guard-script "$ALF_ROOT/guard.sh")"
  [ -z "$(settings_violations "$settings")" ]
  [ "$(jq -r '.permissions.allow | length' <<<"$settings")" = 23 ]
  [ "$(jq -c '.permissions.deny' <<<"$settings")" = '["Bash(git * --output*)","Bash(git * --no-index*)","Bash(git * --ext-diff*)","Bash(git * --contents*)","Bash(git * /dev/null*)","Bash(git -c *)"]' ]

  local added
  for added in 'Edit(.gaia/**)' Write NotebookEdit Agent Skill 'Bash(*)' Bash 'Bash(git commit:*)' 'Bash(git grep:*)'; do
    mutated="$(jq --arg added "$added" '.permissions.allow += [$added]' <<<"$settings")"
    [ "$(settings_violations "$mutated")" = "$added" ]
  done
}

@test "a root and an attempt directory holding a space stay quoted in the hook command" {
  local settings command_line
  mkdir -p "$BATS_TEST_TMPDIR/with space"
  settings="$(bash "$TOOL" settings --root "$BATS_TEST_TMPDIR/with space" --attempt-dir "$BATS_TEST_TMPDIR/with space/attempt" \
    --guard-script "$BATS_TEST_TMPDIR/with space/guard.sh")"
  command_line="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' <<<"$settings")"
  cat >"$BATS_TEST_TMPDIR/with space/guard.sh" <<'EOF'
printf '%s\n' "$#" "$1" "$2"
EOF
  run bash -c "$command_line"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 2 ]
  [ "${lines[1]}" = "$BATS_TEST_TMPDIR/with space/attempt/guard-denials.jsonl" ]
  [ "${lines[2]}" = "$BATS_TEST_TMPDIR/with space" ]
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' <<<"$settings")" = 'Read|Grep|Bash' ]
}

@test "the guard denies and logs when its target hook is absent" {
  local log="$BATS_TEST_TMPDIR/guard.jsonl"
  run bash "$BATS_TEST_TMPDIR/tool/.gaia/scripts/audit-code-review-guard.sh" "$log" <<<'{"tool_name":"Read","tool_input":{"file_path":"a.txt"}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = deny ]
  [ "$(jq -c . "$log")" = '{"tool":"Read","path":"a.txt"}' ]
}

@test "the guard passes the real hook's answer through and logs only a denial" {
  local log="$BATS_TEST_TMPDIR/guard.jsonl" guard="$SHIPPED/audit-code-review-guard.sh"
  run bash "$guard" "$log" <<<'{"tool_name":"Read","tool_input":{"file_path":"src/a.ts"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$log" ]
  run bash "$guard" "$log" <<<'{"tool_name":"Read","tool_input":{"file_path":".env.local"}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = deny ]
  [ "$(jq -c . "$log")" = '{"tool":"Read","path":".env.local"}' ]
}

@test "the guard denies and logs a git command that reads outside the review root" {
  local log="$BATS_TEST_TMPDIR/guard.jsonl" guard="$SHIPPED/audit-code-review-guard.sh" root="/work/tree" command_text
  for command_text in 'git diff /dev/null .env' "git -C $root diff /dev/null ~/.aws/credentials" 'git blame --contents .env HEAD' \
    'git diff ../outside.txt HEAD' "git diff --no-index$root /etc/hosts"; do
    : >"$log"
    run bash "$guard" "$log" "$root" < <(jq -nc --arg command "$command_text" '{tool_name: "Bash", tool_input: {command: $command}}')
    [ "$status" -eq 0 ]
    [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = deny ]
    [ "$(jq -r '.tool' "$log")" = Bash ]
  done
}

# guard_decides <command>: the guard's decision on one Bash command under the
# review root, `deny` or `pass`, with a denial required to reach the log.
guard_decides() {
  local log="$BATS_TEST_TMPDIR/guard.jsonl" decision
  : >"$log"
  run bash "${GUARD_UNDER_TEST:-$SHIPPED/audit-code-review-guard.sh}" "$log" /work/tree \
    < <(jq -nc --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')
  [ "$status" -eq 0 ] || return 1
  decision="$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$output" 2>/dev/null)"
  if [ "$decision" = deny ] && [ -s "$log" ]; then printf 'deny\n'; else printf 'pass\n'; fi
}

@test "the guard denies blame's -S revs file, alone and in a short-option cluster" {
  [ "$(guard_decides 'git blame -S .env README')" = deny ]
  [ "$(guard_decides 'git blame -wS.env README')" = deny ]
}

@test "the guard denies blame's --ignore-revs-file family" {
  [ "$(guard_decides 'git blame --ignore-revs-f=.env README')" = deny ]
}

@test "the guard denies every abbreviation of --contents" {
  [ "$(guard_decides 'git blame --cont .env README')" = deny ]
}

@test "the guard denies --no-index" {
  [ "$(guard_decides 'git diff --no-index README .env')" = deny ]
}

@test "the guard reads a token as the shell will, with backslashes removed, in the verb and an argument" {
  [ "$(guard_decides 'git b\lame -S .env README')" = deny ]
  [ "$(guard_decides 'git diff \/dev/null .env')" = deny ]
}

@test "the guard denies a brace expansion that would assemble a denied form" {
  [ "$(guard_decides 'git blame {-S,.env} README')" = deny ]
  [ "$(guard_decides 'git diff {/dev/null,.env}')" = deny ]
}

@test "the guard denies a backtick command substitution" {
  [ "$(guard_decides 'git show `echo HEAD`')" = deny ]
}

@test "the guard denies a parameter or command expansion inside a token" {
  [ "$(guard_decides 'git diff --no-ind${x}ex README .env')" = deny ]
  [ "$(guard_decides 'git diff --no-$(echo)index README .env')" = deny ]
  [ "$(guard_decides 'git show HEAD$(cat${IFS}$HOME/.aws/credentials)')" = deny ]
  [ "$(guard_decides 'git diff --no-ind$x README .env')" = deny ]
}

@test "the guard passes a single-quoted path holding a literal dollar name" {
  [ "$(guard_decides "git log -1 -- 'app/routes/\$id.tsx'")" = pass ]
}

@test "the guard passes ordinary review reads, reflog and upstream braces included" {
  [ "$(guard_decides 'git log -S hunter2 -1')" = pass ]
  [ "$(guard_decides 'git log -p -1 README')" = pass ]
  [ "$(guard_decides 'git diff HEAD README')" = pass ]
  [ "$(guard_decides 'git log HEAD@{1} -1')" = pass ]
  [ "$(guard_decides 'git rev-parse @{upstream}')" = pass ]
}

@test "the guard lets an in-root git command through without a denial" {
  local log="$BATS_TEST_TMPDIR/guard.jsonl" guard="$SHIPPED/audit-code-review-guard.sh" root="/work/tree"
  : >"$log"
  run bash "$guard" "$log" "$root" < <(jq -nc --arg command "git -C $root diff main...HEAD -- src/a.ts" '{tool_name: "Bash", tool_input: {command: $command}}')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$log" ]
}

# expect_moved_tree: the shared refusal of every tree-moving stand-in.
expect_moved_tree() {
  run_review
  [ "$status" -eq 3 ]
  [ "$(spawn_count)" = 1 ]
  [ "$(record_field .outcome)" = 'not run' ]
  [ "$(record_field .reason)" = 'review moved the tree' ]
  [ "$(record_field '.attempts | length')" = 1 ]
  [ "${lines[${#lines[@]} - 1]}" = 'code-review exit 3' ]
}

@test "a child that edits a tracked file moved the tree" {
  printf 'printf x >>src.txt\n' >>"$BEHAVIOR"
  expect_moved_tree
}

@test "a child that creates an untracked file moved the tree" {
  printf 'mkdir -p fresh/deep; printf x >fresh/deep/new.txt\n' >>"$BEHAVIOR"
  expect_moved_tree
}

@test "a child that switches branch moved the tree" {
  printf 'git switch -q -c elsewhere\n' >>"$BEHAVIOR"
  expect_moved_tree
}

@test "a child that commits moved the tree" {
  printf 'git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m moved\n' >>"$BEHAVIOR"
  expect_moved_tree
}

@test "the deadline kills the whole group, even one ignoring TERM, then retries once and records" {
  fill_constant REVIEW_TIMEOUT_SECONDS 1
  fill_constant SUPERVISOR_GRACE_SECONDS 1
  cat >"$BEHAVIOR" <<'EOF'
trap '' TERM
sleep 300 &
printf '%s\n' "$!" >>"$STAND_IN/pids"
printf '%s\n' "$$" >>"$STAND_IN/pids"
sleep 300
EOF
  run_review
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = 'code-review exit 0' ]
  [ "$(wc -l <"$STAND_IN/pids" | tr -d ' ')" = 4 ]
  local recorded_pid
  while IFS= read -r recorded_pid; do
    kill -0 "$recorded_pid" 2>/dev/null && return 1
  done <"$STAND_IN/pids"
  [ "$(spawn_count)" = 2 ]
  [ "$(record_field .outcome)" = 'not run' ]
  [ "$(record_field .reason)" = 'timed out' ]
  [ "$(record_field .cost)" = unknown ]
  [ "$(record_field '.attempts | map(.reason) | unique | join(",")')" = 'timed out' ]
  [ "$(record_field '.attempts | map(.exit) | unique | join(",")')" = 124 ]
}

@test "the deadline sends TERM before KILL, so a child can flush" {
  fill_constant REVIEW_TIMEOUT_SECONDS 1
  fill_constant SUPERVISOR_GRACE_SECONDS 2
  cat >"$BEHAVIOR" <<'EOF'
trap 'touch "$STAND_IN/term-seen"; exit 0' TERM
sleep 300 &
printf '%s\n' "$!" >>"$STAND_IN/pids"
wait
EOF
  run_review
  [ "$status" -eq 0 ]
  [ -e "$STAND_IN/term-seen" ]
  [ "$(record_field .reason)" = 'timed out' ]
}

@test "a grandchild left running after a normal exit does not outlive the supervisor" {
  fill_constant SUPERVISOR_GRACE_SECONDS 1
  behave_clean
  cat >>"$BEHAVIOR" <<'EOF'
sleep 300 &
printf '%s\n' "$!" >>"$STAND_IN/pids"
EOF
  run_review
  [ "$status" -eq 0 ]
  [ "$(record_field .outcome)" = 'ran, clean' ]
  kill -0 "$(cat "$STAND_IN/pids")" 2>/dev/null && return 1
  true
}

@test "a usable result records ran, saves ids, opens the hand-over and sums the cost" {
  behave_usable
  run_review
  [ "$status" -eq 0 ]
  [ "$(spawn_count)" = 1 ]
  [ "$(record_field .outcome)" = ran ]
  [ "$(record_field .handover)" = open ]
  [ "$(record_field '.findings[0].id')" = cr-1 ]
  [ "$(record_field '.findings[0].state')" = null ]
  [ "$(record_field .cost)" = 0.5 ]
  [ "$(record_field .model)" = claude-opus ]
  [ "$(record_field .claude_version)" = 2.1.319 ]
}

@test "no findings is clean with no denial, and distinct from clean with one" {
  behave_clean
  run_review
  [ "$(record_field .outcome)" = 'ran, clean' ]
  [ "$(record_field .handover)" = none ]

  rm -f "$RECORD"
  rm -rf "$RUN/code-review-attempt-1"
  printf 'printf %%s\\\\n %s >"$PWD/.gaia/local/runs/feat/review/code-review-attempt-1/guard-denials.jsonl"\n' \
    "'{\"tool\":\"Read\",\"path\":\".env\"}'" >>"$BEHAVIOR"
  run_review
  [ "$(record_field .outcome)" = 'ran, no findings' ]
  [ "$(record_field .denials.count)" = 1 ]
  [ "$(record_field '.denials.tools | join(",")')" = Read ]
}

@test "a retry on an unusable result sums across attempts and an unparsed one reads unknown" {
  cat >"$BEHAVIOR" <<'EOF'
jq -n '{subtype: "success", is_error: false, local_command: null, total_cost_usd: 0.5, result: "```json\n[]\n```"}'
EOF
  run_review
  [ "$status" -eq 0 ]
  [ "$(spawn_count)" = 2 ]
  [ "$(record_field .reason)" = 'not the built-in' ]
  [ "$(record_field .cost)" = 1 ]

  rm -rf "$RECORD" "$STAND_IN/log" "$RUN"/code-review-attempt-*
  mkdir -p "$STAND_IN/log"
  printf 'printf not-json\n' >"$BEHAVIOR"
  run_review
  [ "$(record_field .reason)" = 'unusable result' ]
  [ "$(record_field .cost)" = unknown ]
}

@test "a failed launch reason names user settings on stderr only" {
  printf 'exit 9\n' >"$BEHAVIOR"
  run_review
  [ "$status" -eq 0 ]
  [ "$(spawn_count)" = 2 ]
  [ "$(record_field .reason)" = 'nonzero exit' ]
  grep -Fq 'ignores user settings' <<<"$stderr"
  grep -Fq 'user settings' <<<"$output" && return 1
  grep -Fq 'user settings' "$RECORD" && return 1
  true
}

@test "a missing claude records launch failed with no spawn" {
  rm "$STAND_IN/bin/claude"
  run --separate-stderr env PATH="$STAND_IN/bin:/usr/bin:/bin:/opt/homebrew/bin" bash "$TOOL" run --root "$ALF_ROOT" --pr 7 --run-folder "$RUN"
  [ "$status" -eq 0 ]
  [ "$(record_field .reason)" = 'launch failed' ]
}

@test "below the floor, or an unreadable version, makes no spawn and no retry" {
  local version
  for version in 2.1.295 2.0.999 1.9.999 garbage; do
    printf '%s\n' "$version" >"$STAND_IN/version"
    rm -f "$RECORD"
    run_review
    [ "$status" -eq 0 ]
    [ "$(spawn_count)" = 0 ]
    [ "$(record_field .reason)" = 'below version floor' ]
  done
  printf '2.1.296\n' >"$STAND_IN/version"
  rm -f "$RECORD"
  behave_clean
  run_review
  [ "$(spawn_count)" = 1 ]
}

@test "a fork answer and an unanswered gh make no spawn" {
  local answer
  for answer in true fail; do
    stand_in_gh "$answer"
    rm -f "$RECORD"
    run_review
    [ "$status" -eq 0 ]
    [ "$(spawn_count)" = 0 ]
    [ "$(record_field .reason)" = 'fork or unanswered fork check' ]
    [ "$(record_field .pr)" = 7 ]
  done
}

@test "each blocking placeholder makes no spawn and names its reason" {
  local pair constant reason
  for pair in 'REVIEW_CHILD_PROVEN:child isolation unproven' 'REVIEW_TARGET_FORMAT:target unproven' 'REVIEW_TIMEOUT_SECONDS:timeout unmeasured'; do
    constant="${pair%%:*}"
    reason="${pair#*:}"
    make_tool_copy
    fill_constant "$constant" UNMEASURED
    rm -f "$RECORD"
    behave_clean
    run_review
    [ "$status" -eq 0 ]
    [ "$(spawn_count)" = 0 ]
    [ "$(record_field .reason)" = "$reason" ]
    [ "$(record_field .cost)" = none ]
  done
}

@test "the recorded-only placeholder still spawns" {
  fill_constant REVIEW_HOOK_DENIALS_VISIBLE UNMEASURED
  behave_clean
  run_review
  [ "$status" -eq 0 ]
  [ "$(spawn_count)" = 1 ]
  [ "$(record_field .outcome)" = 'ran, clean' ]
}

@test "the shipped script has its three blocking constants measured" {
  local constant
  for constant in REVIEW_CHILD_PROVEN REVIEW_TARGET_FORMAT REVIEW_TIMEOUT_SECONDS; do
    grep -q "^$constant=" "$SHIPPED/audit-code-review.sh"
    grep -q "^$constant=UNMEASURED\$" "$SHIPPED/audit-code-review.sh" && return 1
  done
  true
}

@test "the fill helper replaces a constant already holding a filled value" {
  fill_constant REVIEW_TIMEOUT_SECONDS 1200
  fill_constant REVIEW_TIMEOUT_SECONDS 1500
  grep -Fxq 'REVIEW_TIMEOUT_SECONDS=1500' "$TOOL"
  fill_constant REVIEW_TARGET_FORMAT '<a>...<b>'
  [ "$(grep -c '^REVIEW_TARGET_FORMAT=' "$TOOL")" = 1 ]
  run bash -c "$(grep '^REVIEW_TARGET_FORMAT=' "$TOOL"); printf '%s' \"\$REVIEW_TARGET_FORMAT\""
  [ "$output" = '<a>...<b>' ]
  run fill_constant REVIEW_NOT_A_CONSTANT 1
  [ "$status" -eq 3 ]
}

@test "wait-ms prints nothing and fails while unmeasured, twice the timeout plus a margin once filled" {
  fill_constant REVIEW_TIMEOUT_SECONDS UNMEASURED
  run bash "$TOOL" wait-ms
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  fill_constant REVIEW_TIMEOUT_SECONDS 1080
  run bash "$TOOL" wait-ms
  [ "$status" -eq 0 ]
  [ "$output" -gt $((2 * 1080 * 1000)) ]
}

@test "an interrupted attempt on resume counts, closes as failed and leaves one attempt" {
  behave_clean
  outcome_seed '.outcome = "pending" | .attempts = [{n: 1, opened_at: "t", closed_at: null, exit: null, cost: "unknown", reason: null}]'
  run_review
  [ "$status" -eq 0 ]
  [ "$(spawn_count)" = 1 ]
  [ "$(record_field '.attempts[0].reason')" = interrupted ]
  [ "$(record_field '.attempts | length')" = 2 ]
  [ "$(record_field .cost)" = unknown ]
  [ "$(record_field .outcome)" = 'ran, clean' ]
}

@test "two attempts already on the record make no spawn and record interrupted" {
  behave_clean
  outcome_seed '.outcome = "pending" | .attempts = [
    {n: 1, opened_at: "t", closed_at: "t", exit: 1, cost: 1, reason: "nonzero exit"},
    {n: 2, opened_at: "t", closed_at: null, exit: null, cost: "unknown", reason: null}]'
  run_review
  [ "$status" -eq 0 ]
  [ "$(spawn_count)" = 0 ]
  [ "$(record_field .outcome)" = 'not run' ]
  [ "$(record_field .reason)" = interrupted ]
  [ "$(record_field .cost)" = unknown ]
}

record_script() {
  bash "$SHIPPED/audit-code-review-record.sh" "$@"
}

# outcome_seed <jq-edit>: a record as earlier runs would have left it, current for
# this branch unless the edit says otherwise.
outcome_seed() {
  local base head
  base="$(alf_git merge-base HEAD refs/remotes/origin/main)"
  head="$(alf_git rev-parse HEAD)"
  jq -n --arg base "$base" --arg head "$head" '{version: 1, pr: 7, base: $base, head: $head, outcome: "ran", reason: null,
    level: "high", model: null, claude_version: null, attempts: [], cost: "none",
    denials: {count: 0, tools: [], detail: []}, findings: [], handover: "none", reconcile_passes: 0,
    rounds: null, members_dispatched: null, convergence: null}' | jq "$1" >"$RECORD"
}

@test "outcome refuses an unknown reason, leaving the record untouched" {
  outcome_seed '.outcome = "pending"'
  local before
  before="$(cat "$RECORD")"
  run record_script outcome --run-folder "$RUN" --pr 7 --outcome 'not run' --reason 'free text from a review'
  [ "$status" -eq 2 ]
  [ "$(cat "$RECORD")" = "$before" ]
  run record_script outcome --run-folder "$RUN" --pr 7 --outcome 'not run'
  [ "$status" -eq 2 ]
  run record_script outcome --run-folder "$RUN" --outcome 'ran, clean'
  [ "$status" -eq 2 ]
  [ "$(cat "$RECORD")" = "$before" ]
}

@test "outcome refuses while an open attempt's group or script is alive, and proceeds once gone" {
  outcome_seed '.outcome = "pending" | .attempts = [{n: 1, opened_at: "t", closed_at: null, exit: null, cost: "unknown", reason: null}]'
  local before
  before="$(cat "$RECORD")"
  mkdir -p "$RUN/code-review-attempt-1"

  perl -e 'setpgrp(0, 0); sleep 60' >/dev/null 2>&1 &
  LIVE_PID=$!
  sleep 0.3
  printf '%s\n' "$LIVE_PID" >"$RUN/code-review-attempt-1/pgid"
  run record_script outcome --run-folder "$RUN" --pr 7 --outcome 'not run' --reason interrupted
  [ "$status" -eq 4 ]
  [ "$(cat "$RECORD")" = "$before" ]
  kill -KILL "$LIVE_PID"
  wait "$LIVE_PID" 2>/dev/null || true
  rm -f "$RUN/code-review-attempt-1/pgid"

  sleep 60 >/dev/null 2>&1 &
  LIVE_PID=$!
  printf '%s\n' "$LIVE_PID" >"$RUN/code-review-attempt-1/script.pid"
  run record_script outcome --run-folder "$RUN" --pr 7 --outcome 'not run' --reason interrupted
  [ "$status" -eq 4 ]
  kill -KILL "$LIVE_PID"
  wait "$LIVE_PID" 2>/dev/null || true

  run record_script outcome --run-folder "$RUN" --pr 7 --outcome 'not run' --reason interrupted
  [ "$status" -eq 0 ]
  [ "$(record_field '.attempts[0].reason')" = interrupted ]
  [ "$(record_field .cost)" = unknown ]
}

@test "outcome creates a record carrying its pull request when there is none" {
  run record_script outcome --run-folder "$RUN" --pr 41 --outcome 'not needed' --reason 'quick review cleared'
  [ "$status" -eq 0 ]
  [ "$(record_field .pr)" = 41 ]
  [ "$(record_field .version)" = 1 ]
  [ "$(record_field .cost)" = none ]
  [ "$(find "$RUN" -name '.code-review.json.*' | wc -l | tr -d ' ')" = 0 ]
}

@test "outcome leaves an unreadable record as found" {
  printf 'garbage' >"$RECORD"
  run record_script outcome --run-folder "$RUN" --pr 7 --outcome 'not run' --reason interrupted
  [ "$status" -eq 5 ]
  [ "$(cat "$RECORD")" = garbage ]
}

@test "every reason literal the review scripts can emit is on the closed list" {
  local listed literals literal count=0
  listed="$(bash "$SHIPPED/audit-loop-record.sh" --list-review-reasons)"
  literals="$(cat "$SHIPPED"/audit-code-review*.sh \
    | sed -nE "s/.*(record_not_run|decide_write existing|decide_write fresh|decide_write \"\\\$source_kind\"|--reason|reason=) ?'([^']+)'.*/\\2/p; s/.*failed\\(\"([^\"]+)\"\\).*/\\1/p;" \
    | sort -u)"
  while IFS= read -r literal; do
    [ -n "$literal" ] || continue
    count=$((count + 1))
    grep -Fxq -- "$literal" <<<"$listed"
  done <<<"$literals"
  [ "$count" -ge 12 ]
  grep -Fxq 'review moved the tree' <<<"$literals"
  grep -Fxq 'unusable result' <<<"$literals"
  grep -Fxq 'audit already under way' <<<"$literals"
  grep -Fxq 'release branch' <<<"$literals"
  grep -Fxq 'timed out' <<<"$literals"
}

# A library left off the list would let a change to it keep every member's marker.
# An unmatched glob stays a literal path, which is no machinery, so an empty set fails.
# bats test_tags=whole-tree
@test "every review script and library is on the audit machinery list" {
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  local script_path
  for script_path in "$SHIPPED"/audit-code-review*.sh; do
    audit_path_is_machinery ".gaia/scripts/${script_path##*/}" || {
      printf 'not on the machinery list: %s\n' "${script_path##*/}"
      return 1
    }
  done
}

@test "the reason list prints with no pull request and every name is unique" {
  run bash "$SHIPPED/audit-loop-record.sh" --list-review-reasons
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l | tr -d ' ')" ]
  [ "${lines[0]}" = 'no record' ]
  [ "${lines[${#lines[@]} - 1]}" = 'quick review cleared' ]
}

decide() {
  run record_script decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes "${1:-mixed}"
  [ "$status" -eq 0 ]
}

# record_mark: an identity for the record file that any write through mv changes.
record_mark() {
  ls -i "$RECORD"
  cat "$RECORD"
}

add_closing_unit() {
  alf_state_edit '.history.units = [{unit: 1, start_round: 1, k: 1, through_round: 1, after_checkpoint: 1, admitted_on: "accept"}]'
}

add_rounds() {
  local remaining="$1"
  while [ "$remaining" -gt 0 ]; do
    alf_add_round '["code-audit-frontend"]'
    remaining=$((remaining - 1))
  done
}

FINDINGS_SEED='.handover = "open" | .findings = [{id: "cr-1", state: null}, {id: "cr-2", state: "kept"}]'

@test "decide: an unreadable record writes nothing and prints none" {
  printf 'garbage' >"$RECORD"
  decide
  [ "$output" = none ]
  [ "$(cat "$RECORD")" = garbage ]
}

@test "decide: an unknown version writes nothing and prints none" {
  outcome_seed '.version = 2 | .outcome = "pending"'
  local before
  before="$(record_mark)"
  decide
  [ "$output" = none ]
  [ "$(record_mark)" = "$before" ]
}

@test "decide: a pull request mismatch reads as no record" {
  outcome_seed '.pr = 8'
  decide
  [ "$output" = run ]
}

@test "decide: a head that is not an ancestor reads as no record" {
  outcome_seed '.head = "1111111111111111111111111111111111111111"'
  decide
  [ "$output" = run ]
}

@test "decide: a base past the fork point reads as no record" {
  outcome_seed '.base = "1111111111111111111111111111111111111111"'
  decide
  [ "$output" = run ]
}

@test "decide: a stale record with rounds on the loop reads as no record and records under way" {
  outcome_seed '.pr = 8'
  alf_add_round '[]'
  decide
  [ "$output" = none ]
  [ "$(record_field .pr)" = 7 ]
  [ "$(record_field .reason)" = 'audit already under way' ]
}

@test "decide: pending with one attempt prints run and writes nothing" {
  outcome_seed '.outcome = "pending" | .attempts = [{n: 1, closed_at: "t", cost: 1, reason: "timed out"}]'
  local before
  before="$(record_mark)"
  decide
  [ "$output" = run ]
  [ "$(record_mark)" = "$before" ]
}

@test "decide: pending with two attempts writes interrupted" {
  outcome_seed '.outcome = "pending" | .attempts = [{n: 1, closed_at: "t", cost: 1, reason: "timed out"}, {n: 2, closed_at: "t", cost: 1, reason: "timed out"}]'
  decide
  [ "$output" = none ]
  [ "$(record_field .outcome)" = 'not run' ]
  [ "$(record_field .reason)" = interrupted ]
}

@test "decide: pending with a closing window writes interrupted" {
  outcome_seed '.outcome = "pending"'
  alf_add_round '[]'
  add_closing_unit
  decide
  [ "$output" = none ]
  [ "$(record_field .reason)" = interrupted ]
}

@test "decide: pending at the cap writes interrupted" {
  outcome_seed '.outcome = "pending"'
  add_rounds 10
  decide
  [ "$output" = none ]
  [ "$(record_field .reason)" = interrupted ]
}

@test "decide: ran with the hand-over open and no assignment prints deliver" {
  outcome_seed "$FINDINGS_SEED"
  local before
  before="$(record_mark)"
  decide
  [ "$output" = deliver ]
  [ "$(record_mark)" = "$before" ]
}

@test "decide: not run with the hand-over open prints deliver" {
  outcome_seed "$FINDINGS_SEED"' | .outcome = "not run" | .reason = "timed out"'
  decide
  [ "$output" = deliver ]
}

@test "decide: closing force-closes, marking only null ids unaccounted" {
  outcome_seed "$FINDINGS_SEED"
  alf_add_round '[]'
  add_closing_unit
  decide
  [ "$output" = none ]
  [ "$(record_field .handover)" = closed ]
  [ "$(record_field '.findings[0].state')" = unaccounted ]
  [ "$(record_field '.findings[1].state')" = kept ]
}

@test "decide: at the cap force-closes" {
  outcome_seed "$FINDINGS_SEED"
  add_rounds 10
  decide
  [ "$output" = none ]
  [ "$(record_field .handover)" = closed ]
  [ "$(record_field '.findings[0].state')" = unaccounted ]
}

@test "decide: ran, closed, prints none and writes nothing" {
  outcome_seed '.handover = "closed"'
  local before
  before="$(record_mark)"
  decide
  [ "$output" = none ]
  [ "$(record_mark)" = "$before" ]
}

@test "decide: ran, clean and not run with no hand-over print none" {
  outcome_seed '.outcome = "ran, clean"'
  decide
  [ "$output" = none ]
  outcome_seed '.outcome = "not run" | .reason = "timed out"'
  decide
  [ "$output" = none ]
}

# release_branch: the branch changes .gaia/VERSION against a fork point that holds it.
release_branch() {
  alf_git checkout -q main
  printf '.gaia/*\n!.gaia/VERSION\n' >"$ALF_ROOT/.gitignore"
  printf '1.0.0\n' >"$ALF_ROOT/.gaia/VERSION"
  alf_git add -A
  alf_git commit -q -m version
  alf_git push -q origin main 2>/dev/null
  alf_git fetch -q origin
  alf_git checkout -q -B feat/review
  printf '1.0.1\n' >"$ALF_ROOT/.gaia/VERSION"
  alf_commit bump
}

@test "decide: a release branch records not needed once and makes no write on a second wave" {
  release_branch
  decide
  [ "$output" = none ]
  [ "$(record_field .outcome)" = 'not needed' ]
  [ "$(record_field .reason)" = 'release branch' ]
  local before
  before="$(record_mark)"
  decide
  [ "$output" = none ]
  [ "$(record_mark)" = "$before" ]
}

@test "decide: an unchanged .gaia/VERSION is no release signal" {
  alf_git checkout -q main
  printf '.gaia/*\n!.gaia/VERSION\n' >"$ALF_ROOT/.gitignore"
  printf '1.0.0\n' >"$ALF_ROOT/.gaia/VERSION"
  alf_git add -A
  alf_git commit -q -m version
  alf_git push -q origin main 2>/dev/null
  alf_git fetch -q origin
  alf_git checkout -q -B feat/review
  alf_set_line src.txt 2 change
  alf_commit change
  decide
  [ "$output" = run ]
  [ ! -e "$RECORD" ]
}

@test "decide: no record plus any round writes audit already under way" {
  alf_add_round '[]'
  decide
  [ "$output" = none ]
  [ "$(record_field .outcome)" = 'not run' ]
  [ "$(record_field .reason)" = 'audit already under way' ]
  [ "$(record_field .pr)" = 7 ]
}

@test "decide: not needed plus a round with members writes audit already under way" {
  outcome_seed '.outcome = "not needed" | .reason = "quick review cleared"'
  alf_add_round '["code-audit-frontend"]'
  decide
  [ "$output" = none ]
  [ "$(record_field .reason)" = 'audit already under way' ]
}

@test "decide: not needed plus a closing round writes audit already under way" {
  outcome_seed '.outcome = "not needed" | .reason = "quick review cleared"'
  alf_add_round '[]' true
  decide
  [ "$output" = none ]
  [ "$(record_field .reason)" = 'audit already under way' ]
}

@test "decide: not needed plus a closing window writes audit already under way" {
  outcome_seed '.outcome = "not needed" | .reason = "quick review cleared"'
  alf_add_round '[]'
  add_closing_unit
  decide
  [ "$output" = none ]
  [ "$(record_field .reason)" = 'audit already under way' ]
}

@test "decide: not needed plus only a memberless reopened round keeps its review" {
  outcome_seed '.outcome = "not needed" | .reason = "quick review cleared"'
  alf_add_round '[]'
  alf_state_edit '.history.rounds[0].reopened = true'
  decide mixed
  [ "$output" = run ]
  decide all-light
  [ "$output" = quick-first ]
}

@test "decide: no record prints quick-first on all-light and run on mixed, writing nothing" {
  decide all-light
  [ "$output" = quick-first ]
  [ ! -e "$RECORD" ]
  decide mixed
  [ "$output" = run ]
  [ ! -e "$RECORD" ]
}

@test "decide: an unknown route is a usage error" {
  run record_script decide --root "$ALF_ROOT" --run-folder "$RUN" --pr 7 --routes other
  [ "$status" -eq 2 ]
}

# Probe arm logic only, with a stand-in. Whether a real child behaves this way is
# what the probe itself exists to find out.
probe_fixture() {
  PROBE="$REPO_ROOT/.gaia/tests/claude-probe/review-child-read-only.sh"
  alf_git checkout -q main
  printf '.env.*\n.gaia/*\n!.gaia/VERSION\n!.gaia/release-exclude\n' >"$ALF_ROOT/.gitignore"
  printf '1.0.0\n' >"$ALF_ROOT/.gaia/VERSION"
  printf 'x\n' >"$ALF_ROOT/.gaia/release-exclude"
  alf_git add -A
  alf_git commit -q -m probe
  WORKTREE="$BATS_TEST_TMPDIR/worktree"
  alf_git worktree add -q --detach "$WORKTREE"
  WORKTREE="$(cd "$WORKTREE" && pwd -P)"
  OUT="$BATS_TEST_TMPDIR/probe-out"
  cat >"$BEHAVIOR" <<'EOF'
settings_file=""
previous=""
for argument in "$@"; do
  [ "$previous" != --settings ] || settings_file="$argument"
  previous="$argument"
done
if [ -z "$settings_file" ]; then
  printf '{"type":"system","subtype":"init","tools":["Read","Edit","Bash"]}\n'
  [ -f "$STAND_IN/control-does-not-move" ] || printf 'moved\n' >>.gaia/VERSION
  exit 0
fi
printf '{"type":"system","subtype":"init","tools":["Read","Grep","Glob","Bash"]}\n'
if [ ! -f "$STAND_IN/hook-does-not-fire" ]; then
  hook_command="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings_file")"
  printf '{"tool_name":"Read","tool_input":{"file_path":".env.review-probe"}}' | bash -c "$hook_command" >/dev/null
fi
[ ! -f "$STAND_IN/subtraction-moves" ] || printf 'moved\n' >>.gaia/VERSION
[ ! -f "$STAND_IN/leak" ] || cat .env.review-probe
printf '{"type":"result","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git switch -c review-probe"}}]}\n'
EOF
}

run_probe() {
  run --separate-stderr bash "$PROBE" --root "$WORKTREE" --out "$OUT"
}

@test "probe: a moved control, an unmoved subtraction arm and a denied dotenv read prove it" {
  probe_fixture
  run_probe
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = proven ]
  [ "$(jq -r .subtraction.switch_denied <<<"$output")" = true ]
  [ "$(jq -r .subtraction.denials_visible <<<"$output")" = false ]
  [ "$(git -C "$WORKTREE" status --porcelain)" = "" ]
  [ ! -e "$WORKTREE/.env.review-probe" ]
}

@test "probe: a control that does not move the tree is inconclusive" {
  probe_fixture
  touch "$STAND_IN/control-does-not-move"
  run_probe
  [ "$status" -eq 1 ]
  [ "$(jq -r .verdict <<<"$output")" = inconclusive ]
}

@test "probe: a missing dotenv denial fails, so a non-firing hook leaves a halt" {
  probe_fixture
  touch "$STAND_IN/hook-does-not-fire"
  run_probe
  [ "$status" -eq 1 ]
  [ "$(jq -r .verdict <<<"$output")" = failed ]
  [ "$(jq -r .subtraction.dotenv_denied <<<"$output")" = false ]
}

@test "probe: a subtraction arm that moves the tree fails" {
  probe_fixture
  touch "$STAND_IN/subtraction-moves"
  run_probe
  [ "$status" -eq 1 ]
  [ "$(jq -r .verdict <<<"$output")" = failed ]
  [ "$(jq -r .subtraction.tree_moved <<<"$output")" = true ]
}

@test "probe: dotenv content in the output fails even with a guard line" {
  probe_fixture
  touch "$STAND_IN/leak"
  run_probe
  [ "$status" -eq 1 ]
  [ "$(jq -r .subtraction.content_leaked <<<"$output")" = true ]
}

@test "probe: a checkout that is not a detached linked worktree is refused" {
  probe_fixture
  run --separate-stderr bash "$PROBE" --root "$ALF_ROOT" --out "$OUT"
  [ "$status" -eq 2 ]
  alf_git switch -q --detach
  run --separate-stderr bash "$PROBE" --root "$ALF_ROOT" --out "$OUT"
  [ "$status" -eq 2 ]
  grep -Fq 'linked worktree' <<<"$stderr"
  [ "$(spawn_count)" = 0 ]
}
