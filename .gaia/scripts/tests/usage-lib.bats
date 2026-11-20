#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/usage-lib.sh: the shared paths, default
# branch, repo membership, ref grammar, key derivation, locked append, and
# component-presence checks the usage ledger is built on.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/usage-lib.bats
#
# Expected values are literals, hand-spelled in the test, so a regression in
# the library cannot be mirrored by the assertion that checks it.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  USAGE_LIBRARY="$SCRIPTS/usage-lib.sh"
  REPO_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  # shellcheck disable=SC1090
  source "$USAGE_LIBRARY"
}

# make_repo <dir> [branch]: a one-commit repo with no remote.
make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b "${2:-main}"
  git -C "$1" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
    commit -q --allow-empty -m init
}

# key_json <raw branch> <session_id> <default>: usage_key's answer, compact.
key_json() {
  local branch_map
  branch_map="$(gaia_usage_branch_map "$1")"
  jq -nc --arg branch "$1" --arg session_id "$2" --arg default_branch "$3" --argjson branch_map "$branch_map" \
    "$GAIA_USAGE_JQ_DEFS"' usage_key($branch; $session_id; $default_branch; $branch_map)'
}

# expect_equal <case> <got> <want>: fails the calling test naming the case.
expect_equal() {
  [ "$2" = "$3" ] || { printf 'case %s: got [%s] want [%s]\n' "$1" "$2" "$3" >&2; return 1; }
}

# ---------- 1. source-time purity and the function set ----------

@test "sourcing under set -u with an empty PATH defines every C6 name (bash 3.2 and 5)" {
  local bash_binary function_name
  for bash_binary in /bin/bash "$BASH"; do
    for function_name in $(grep -o '^gaia_usage_[a-z_]*()' "$USAGE_LIBRARY" | tr -d '()'); do
      "$bash_binary" -c 'set -u; PATH=/nonexistent; source "$1"; type "$2" >/dev/null 2>&1 && [ -n "$GAIA_USAGE_JQ_DEFS" ]' _ "$USAGE_LIBRARY" "$function_name" ||
        { printf '%s: %s not defined after sourcing\n' "$bash_binary" "$function_name" >&2; return 1; }
    done
    "$bash_binary" -n "$USAGE_LIBRARY"
  done
}

@test "no jq reimplementation of branch normalization" {
  local definition_count
  definition_count="$(grep -c 'def usage_normalize' "$USAGE_LIBRARY" || true)"
  [ "$definition_count" = 0 ]
}

@test "zsh caller: sourcing succeeds, pure functions work, sibling-backed ones return 1" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  run zsh -c 'source "$1"; gaia_usage_valid_reference issue:5 || exit 10
    [ "$(gaia_usage_encode_path "/a b")" = "-a-b" ] || exit 11
    gaia_usage_branch_map x >/dev/null && exit 12
    exit 0' _ "$USAGE_LIBRARY"
  [ "$status" -eq 0 ]
}

# ---------- 2. branch map and hash parity ----------

@test "branch map: every spelling normalizes as gaia_branch_normalize, including a dash-leading spelling" {
  local -a raw_branches=('fix/foo' 'worktree-debt+123-slug' 'worktree-worktree-x' 'a+b+c' 'HEAD' ''
    'release/v2.0.0-rc.1' 'worktree-agent-a109ec9e' 'feat/has space' 'feat/dollar$x'
    'main' 'worktree-plan+spec-087-x' 'a.b.c/d' "$(printf 'z%.0s' $(seq 1 130))")
  [ "${#raw_branches[@]}" -ge 12 ]
  # shellcheck disable=SC1091
  source "$SCRIPTS/branch-name-lib.sh"
  local branch_map raw_branch want got
  branch_map="$(gaia_usage_branch_map "${raw_branches[@]}")"
  [ "$(jq 'length' <<<"$branch_map")" -eq "${#raw_branches[@]}" ]
  for raw_branch in "${raw_branches[@]}"; do
    want="$(gaia_branch_normalize "$raw_branch")"
    got="$(jq -r --arg raw_branch "$raw_branch" '.[$raw_branch].norm' <<<"$branch_map")"
    [ "$got" = "$want" ] || { printf 'norm of [%s]: got [%s] want [%s]\n' "$raw_branch" "$got" "$want" >&2; return 1; }
  done
  [ "$(jq -r '.["worktree-debt+123-slug"].key' <<<"$branch_map")" = "branch:debt/123-slug" ]
  [ "$(jq -r '.["worktree-worktree-x"].norm' <<<"$branch_map")" = "worktree-x" ]
  [ "$(jq -r '.["a+b+c"].key' <<<"$branch_map")" = "branch:a/b/c" ]
  [ "$(jq -r '.[""].key' <<<"$branch_map")" = "null" ]
  # A spelling that starts with a dash survives intact.
  branch_map="$(gaia_usage_branch_map '-x' '--args')"
  [ "$(jq -r '.["-x"].norm' <<<"$branch_map")" = "-x" ] || { echo "case dash-leading: -x norm differs"; return 1; }
  [ "$(jq -r '.["--args"].norm' <<<"$branch_map")" = "--args" ] || { echo "case dash-leading: --args norm differs"; return 1; }
}

@test "branch key: a failing branch hashes to the first 16 hex characters of its sha256" {
  local normalized_branch='feat/has space' want
  # Pinned literal: the sha256 prefix of the input.
  want=622b769126303c10
  [ "$(gaia_usage_branch_key "$normalized_branch")" = "branch:%$want" ]
  # A 129-character name fails the grammar by length alone.
  normalized_branch="$(printf 'q%.0s' $(seq 1 129))"
  want=f0886d9cc70695b4
  [ "$(gaia_usage_branch_key "$normalized_branch")" = "branch:%$want" ]
  [ "$(gaia_usage_branch_key "$(printf 'q%.0s' $(seq 1 128))")" = "branch:$(printf 'q%.0s' $(seq 1 128))" ]
}

# ---------- 3. key derivation ----------

@test "key derivation: default branch, master default, HEAD, empty and agent worktrees" {
  local default_branch

  # case: default branch resolved through origin/HEAD keys session, never branch
  make_repo "$TEMPORARY_DIRECTORY/km"
  git -C "$TEMPORARY_DIRECTORY/km" update-ref refs/remotes/origin/main HEAD
  git -C "$TEMPORARY_DIRECTORY/km" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  default_branch="$(gaia_usage_default_branch "$TEMPORARY_DIRECTORY/km")"
  expect_equal "origin/HEAD main" "$default_branch" main || return 1
  expect_equal "main keys session" "$(key_json main S1 "$default_branch")" '{"key":"session:S1","inherit":false}' || return 1
  expect_equal "fix/foo keys branch" "$(key_json fix/foo S1 "$default_branch")" '{"key":"branch:fix/foo","inherit":false}' || return 1
  expect_equal "worktree-fix+bar keys branch" "$(key_json worktree-fix+bar S1 "$default_branch")" '{"key":"branch:fix/bar","inherit":false}' || return 1

  # case: a master default, named by origin/HEAD, keys session and never branch:master
  make_repo "$TEMPORARY_DIRECTORY/kmaster" master
  git -C "$TEMPORARY_DIRECTORY/kmaster" update-ref refs/remotes/origin/master HEAD
  git -C "$TEMPORARY_DIRECTORY/kmaster" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
  default_branch="$(gaia_usage_default_branch "$TEMPORARY_DIRECTORY/kmaster")"
  expect_equal "origin/HEAD master" "$default_branch" master || return 1
  expect_equal "master keys session" "$(key_json master S2 "$default_branch")" '{"key":"session:S2","inherit":false}' || return 1
  expect_equal "main keys branch under a master default" "$(key_json main S2 "$default_branch")" '{"key":"branch:main","inherit":false}' || return 1

  # case: HEAD and empty key session; agent worktrees inherit
  expect_equal "HEAD" "$(key_json HEAD S3 main)" '{"key":"session:S3","inherit":false}' || return 1
  expect_equal "empty" "$(key_json '' S3 main)" '{"key":"session:S3","inherit":false}' || return 1
  expect_equal "agent worktree" "$(key_json worktree-agent-abc123 S3 main)" '{"key":"session:S3","inherit":true}' || return 1
  # A branch key is never produced for a missing gitBranch (null reaches jq as null).
  run jq -nc --argjson branch_map '{}' --arg session_id S3 "$GAIA_USAGE_JQ_DEFS"' usage_key(null; $session_id; "main"; $branch_map)'
  expect_equal "null branch" "$output" '{"key":"session:S3","inherit":false}' || return 1
}

@test "key: a command-substitution branch is hashed and runs nothing" {
  cd "$TEMPORARY_DIRECTORY"
  local key_json_output
  key_json_output="$(key_json 'x$(touch pwned)' S4 main)"
  [ "$(jq -r '.key | test("^branch:%[0-9a-f]{16}$")' <<<"$key_json_output")" = true ]
  [ ! -e "$TEMPORARY_DIRECTORY/pwned" ]
  [ ! -e "$REPO_ROOT/pwned" ]
}

# ---------- 4. default branch fallback ----------

@test "default branch resolution: master only, main and master, neither" {
  make_repo "$TEMPORARY_DIRECTORY/dm" master
  expect_equal "only master" "$(gaia_usage_default_branch "$TEMPORARY_DIRECTORY/dm")" master || return 1
  make_repo "$TEMPORARY_DIRECTORY/dboth" main
  git -C "$TEMPORARY_DIRECTORY/dboth" branch master
  expect_equal "main and master" "$(gaia_usage_default_branch "$TEMPORARY_DIRECTORY/dboth")" main || return 1
  make_repo "$TEMPORARY_DIRECTORY/dneither" trunk
  expect_equal "neither ref" "$(gaia_usage_default_branch "$TEMPORARY_DIRECTORY/dneither")" main || return 1
}

# ---------- 5. membership and candidate directories ----------

# is_member <cwd> <roots-json>
is_member() {
  jq -nc --arg cwd "$1" --argjson roots "$2" "$GAIA_USAGE_JQ_DEFS"' usage_member($cwd; $roots)'
}

@test "membership: trailing slash is load-bearing; removed and outside worktrees behave" {
  local main="$TEMPORARY_DIRECTORY/main"
  make_repo "$main"
  git -C "$main" worktree add -q "$main/.claude/worktrees/x" -b wt-x
  git -C "$main" worktree add -q "$main/.claude/worktrees/y" -b wt-y
  git -C "$main" worktree add -q "$TEMPORARY_DIRECTORY/outside-wt" -b wt-out
  git -C "$main" worktree remove --force "$main/.claude/worktrees/y"
  local roots
  roots="$(gaia_usage_tree_roots "$main" | jq -R . | jq -sc .)"
  [ "$(jq -r '.[0]' <<<"$roots")" = "$main" ]
  [ "$(jq 'length' <<<"$roots")" -eq 3 ]
  [ "$(is_member "$main" "$roots")" = true ]
  [ "$(is_member "$main/src/deep" "$roots")" = true ]
  [ "$(is_member "$main/.claude/worktrees/x" "$roots")" = true ]
  [ "$(is_member "$main/.claude/worktrees/y/sub" "$roots")" = true ]
  [ "$(is_member "$TEMPORARY_DIRECTORY/outside-wt/sub" "$roots")" = true ]
  [ "$(is_member "${main}-web" "$roots")" = false ]
  [ "$(is_member "${main}-web/src" "$roots")" = false ]
  [ "$(is_member "$TEMPORARY_DIRECTORY/other" "$roots")" = false ]
  [ "$(is_member "" "$roots")" = false ]
}

@test "candidate directories: decoy dropped, main, worktree and outside-worktree dirs listed, encoding" {
  local main="$TEMPORARY_DIRECTORY/main" encoded_path projects_directory="$TEMPORARY_DIRECTORY/projects" got

  # case: decoy dropped; main and worktree-prefixed project dirs listed
  make_repo "$main"
  encoded_path="$(printf '%s' "$main" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$projects_directory/$encoded_path" "$projects_directory/$encoded_path--claude-worktrees-x" "$projects_directory/$encoded_path-web" "$projects_directory/unrelated"
  : >"$projects_directory/loose-file.jsonl"
  got="$(gaia_usage_candidate_directories "$projects_directory" "$main")"
  expect_equal "decoy dropped" "$(sort <<<"$got")" "$(printf '%s\n%s' "$projects_directory/$encoded_path" "$projects_directory/$encoded_path--claude-worktrees-x" | sort)" || return 1

  # case: a project dir of a worktree outside the main root is listed
  rm -rf "$main" "$projects_directory"
  make_repo "$main"
  git -C "$main" worktree add -q "$TEMPORARY_DIRECTORY/outside-wt" -b wt-out
  encoded_path="$(printf '%s' "$TEMPORARY_DIRECTORY/outside-wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$projects_directory/$encoded_path"
  expect_equal "outside worktree" "$(gaia_usage_candidate_directories "$projects_directory" "$main")" "$projects_directory/$encoded_path" || return 1

  # case: underscore and plus map to dash, proven against a hand-spelled dir and a narrow encoder
  local literal_name narrow narrow_projects_directory="$TEMPORARY_DIRECTORY/projects-narrow"
  main="$TEMPORARY_DIRECTORY/my_repo+x"
  rm -rf "$projects_directory"
  make_repo "$main"
  literal_name="$(printf '%s' "$main" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$projects_directory/$literal_name"
  expect_equal "encoded directory" "$(gaia_usage_candidate_directories "$projects_directory" "$main")" "$projects_directory/$literal_name" || return 1
  expect_equal "encode_path" "$(gaia_usage_encode_path "$main")" "$literal_name" || return 1
  # The narrow encoder (only / and .) names a different directory and is not matched.
  narrow="$(printf '%s' "$main" | sed 's/[/.]/-/g')"
  [ "$narrow" != "$literal_name" ] || { echo "case narrow encoder: names the same directory"; return 1; }
  mkdir -p "$narrow_projects_directory/$narrow"
  [ -z "$(gaia_usage_candidate_directories "$narrow_projects_directory" "$main")" ] || { echo "case narrow encoder: matched"; return 1; }
}

@test "projects root: transcript_path wins, then GAIA_TALLY_PROJECTS_ROOT, then CLAUDE_CONFIG_DIR" {
  [ "$(GAIA_TALLY_PROJECTS_ROOT=/env/root gaia_usage_projects_root /p/projects/enc/sid.jsonl)" = /p/projects ]
  [ "$(GAIA_TALLY_PROJECTS_ROOT=/env/root gaia_usage_projects_root)" = /env/root ]
  [ "$(GAIA_TALLY_PROJECTS_ROOT='' CLAUDE_CONFIG_DIR=/cfg gaia_usage_projects_root)" = /cfg/projects ]
  [ "$(GAIA_TALLY_PROJECTS_ROOT='' CLAUDE_CONFIG_DIR='' HOME=/h gaia_usage_projects_root)" = /h/.claude/projects ]
}

# ---------- 6. research slug ----------

# slug_of <path> <research roots json>: the slug, or the literal null.
slug_of() {
  jq -nr --arg path "$1" --argjson research_roots "$2" "$GAIA_USAGE_JQ_DEFS"' usage_research_slug($path; $research_roots) | tostring'
}

@test "research slug: the binding and non-binding cases" {
  local main_checkout="$TEMPORARY_DIRECTORY/main" roots
  make_repo "$main_checkout"
  git -C "$main_checkout" worktree add -q "$main_checkout/.claude/worktrees/lw" -b wt-lw
  roots="$(jq -nc --arg research_root "$main_checkout/.notebook/research/" '[$research_root]')"
  [ "$(slug_of "$main_checkout/.notebook/research/topic-a-2026-10-01/README.md" "$roots")" = topic-a-2026-10-01 ]
  [ "$(slug_of "$main_checkout/.notebook/research/release-2.0.0-readiness/notes/a.md" "$roots")" = release-2.0.0-readiness ]
  [ "$(slug_of "$main_checkout/.notebook/research/DEBT-LOOP-DIAGNOSIS.md" "$roots")" = DEBT-LOOP-DIAGNOSIS ]
  [ "$(slug_of "$main_checkout/.notebook/research/2250-carryover.patch" "$roots")" = null ]
  [ "$(slug_of "/other/repo/.notebook/research/x/README.md" "$roots")" = null ]
  [ "$(slug_of ".notebook/research/x/README.md" "$roots")" = null ]
  [ "$(slug_of "$main_checkout/.notebook/research/../../x/README.md" "$roots")" = null ]
  [ "$(slug_of "$main_checkout/.notebook/research/./x/a.md" "$roots")" = null ]
  [ "$(slug_of "$main_checkout/.notebook/research//x/a.md" "$roots")" = null ]
  [ "$(slug_of "$main_checkout/.notebook/research/x\"y/README.md" "$roots")" = null ]
  [ "$(slug_of "$main_checkout/.notebook/research/.md" "$roots")" = null ]
  [ "$(slug_of "$main_checkout/.notebook/research" "$roots")" = null ]
  [ "$(slug_of "$main_checkout/.claude/worktrees/lw/.notebook/research/x/README.md" "$roots")" = null ]
  [ "$(slug_of "$main_checkout/.gaia/local/research/topic-a-2026-10-01/README.md" "$roots")" = null ]
}

# ---------- 7. ref grammar ----------

@test "ref grammar: bash and jq agree on every valid and invalid case" {
  local long129 long128 valid invalid reference
  long128="$(printf 'a%.0s' $(seq 1 128))"
  long129="$(printf 'a%.0s' $(seq 1 129))"
  valid=("research:topic-a-2026-10-01" "research:release-2.0.0" "init:my_slug" "issue:1" "issue:2367"
    "pr:9999999999" "spec:SPEC-087" "spec:SPEC-1000" "plan:PLAN-091" "branch:fix/foo" "branch:a.b/c-d_e"
    "branch:%0123456789abcdef" "branch:$long128" "session:abc-123_X" "command:run.1-a" "research:$long128")
  invalid=("spec:spec-087" "spec:SPEC-87" "plan:plan-091" "issue:0" "issue:01" "issue:12345678901" "pr:x"
    "research:" "research:$long129" "research:-lead" "init:" "branch:" "branch:$long129" "branch:%abc"
    "branch:%0123456789ABCDEF" "branch:has space" 'branch:x$(y)' "session:" "session:$(printf 's%.0s' $(seq 1 65))"
    "command:" "command:a b" "bogus:x" "nocolon" "" $'research:x\n' $'issue:5\nextra')
  [ "${#valid[@]}" -ge 16 ]
  [ "${#invalid[@]}" -ge 25 ]
  for reference in "${valid[@]}"; do
    gaia_usage_valid_reference "$reference" || { printf 'bash rejects valid [%s]\n' "$reference" >&2; return 1; }
    [ "$(jq -nr --arg reference "$reference" "$GAIA_USAGE_JQ_DEFS"' usage_valid_reference($reference)')" = true ] ||
      { printf 'jq rejects valid [%s]\n' "$reference" >&2; return 1; }
  done
  for reference in "${invalid[@]}"; do
    gaia_usage_valid_reference "$reference" && { printf 'bash accepts invalid [%s]\n' "$reference" >&2; return 1; }
    [ "$(jq -nr --arg reference "$reference" "$GAIA_USAGE_JQ_DEFS"' usage_valid_reference($reference)')" = false ] ||
      { printf 'jq accepts invalid [%s]\n' "$reference" >&2; return 1; }
  done
  true
}

# ---------- 8. locked append ----------

# append_in_fresh_process <dir> <target> <rows>: the append in a fresh process. with_ledger_lock
# installs EXIT/INT/TERM traps in its caller, which inside a bats test body
# displaces bats' own EXIT handler.
append_in_fresh_process() {
  bash -c 'source "$1"; gaia_usage_append "$2" "$3" "$4"' _ "$USAGE_LIBRARY" "$@"
}

@test "append refuses: lock timeout 75, locked-out first write, bad basename 2, unreachable mutex 1" {
  local telemetry_directory rows

  # case: lock timeout returns 75 and leaves the ledger byte-identical; the same call lands once unlocked
  telemetry_directory="$TEMPORARY_DIRECTORY/tel" rows="$TEMPORARY_DIRECTORY/rows.jsonl"
  mkdir -p "$telemetry_directory"
  printf '{"n":1}\n' >"$rows"
  run append_in_fresh_process "$telemetry_directory" usage.jsonl "$rows"
  [ "$status" -eq 0 ] || { echo "case lock timeout: first append exited $status"; return 1; }
  cp "$telemetry_directory/usage.jsonl" "$TEMPORARY_DIRECTORY/before"
  mkdir "$telemetry_directory/specs.lock.d"
  printf '{"n":2}\n' >"$rows"
  GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_LEDGER_LOCK_POLL_SECONDS=0.1 \
    run append_in_fresh_process "$telemetry_directory" usage.jsonl "$rows"
  [ "$status" -eq 75 ] || { echo "case lock timeout: locked append exited $status, want 75"; return 1; }
  cmp "$telemetry_directory/usage.jsonl" "$TEMPORARY_DIRECTORY/before" || { echo "case lock timeout: ledger changed"; return 1; }
  rmdir "$telemetry_directory/specs.lock.d"
  GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 run append_in_fresh_process "$telemetry_directory" usage.jsonl "$rows"
  [ "$status" -eq 0 ] || { echo "case lock timeout: unlocked append exited $status"; return 1; }
  [ "$(cat "$telemetry_directory/usage.jsonl")" = "$(printf '{"n":1}\n{"n":2}')" ] || { echo "case lock timeout: ledger rows differ"; return 1; }

  # case: a locked-out first write leaves the file absent
  telemetry_directory="$TEMPORARY_DIRECTORY/tel2" rows="$TEMPORARY_DIRECTORY/rows2.jsonl"
  mkdir -p "$telemetry_directory/specs.lock.d"
  printf '{"n":1}\n' >"$rows"
  GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_LEDGER_LOCK_POLL_SECONDS=0.1 \
    run append_in_fresh_process "$telemetry_directory" links.jsonl "$rows"
  [ "$status" -eq 75 ] || { echo "case locked-out first write: exited $status, want 75"; return 1; }
  [ -e "$telemetry_directory/links.jsonl" ] && { echo "case locked-out first write: file exists"; return 1; }

  # case: any other target basename returns 2 and writes nothing
  telemetry_directory="$TEMPORARY_DIRECTORY/tel3" rows="$TEMPORARY_DIRECTORY/rows3.jsonl"
  printf '{"n":1}\n' >"$rows"
  run append_in_fresh_process "$telemetry_directory" other.jsonl "$rows"
  [ "$status" -eq 2 ] || { echo "case bad basename: other.jsonl exited $status, want 2"; return 1; }
  [ -e "$telemetry_directory/other.jsonl" ] && { echo "case bad basename: other.jsonl written"; return 1; }
  run append_in_fresh_process "$telemetry_directory" ../usage.jsonl "$rows"
  [ "$status" -eq 2 ] || { echo "case bad basename: ../usage.jsonl exited $status, want 2"; return 1; }
  if [ -e "$telemetry_directory" ] && [ -n "$(ls -A "$telemetry_directory")" ]; then
    echo "case bad basename: telemetry directory not empty"
    return 1
  fi

  # case: with the mutex helper unreachable it returns 1 and never appends unlocked
  local isolated_directory="$TEMPORARY_DIRECTORY/iso"
  telemetry_directory="$TEMPORARY_DIRECTORY/tel4" rows="$TEMPORARY_DIRECTORY/rows4.jsonl"
  mkdir -p "$isolated_directory/.gaia/scripts"
  cp "$USAGE_LIBRARY" "$isolated_directory/.gaia/scripts/usage-lib.sh"
  printf '{"n":1}\n' >"$rows"
  run bash -c 'source "$1"; gaia_usage_append "$2" usage.jsonl "$3"' _ "$isolated_directory/.gaia/scripts/usage-lib.sh" "$telemetry_directory" "$rows"
  [ "$status" -eq 1 ] || { echo "case unreachable mutex: exited $status, want 1"; return 1; }
  [ -e "$telemetry_directory/usage.jsonl" ] && { echo "case unreachable mutex: appended unlocked"; return 1; }
  true
}

# ---------- 9. hook registration ----------

# write_settings <dir> <stop cmd or ""> <start cmd or "">
write_settings() {
  mkdir -p "$1/.claude"
  jq -n --arg stop "$2" --arg start "$3" '{hooks: {
      Stop: [{matcher: "", hooks: ([{type: "command", command: "x/other.sh"}] + (if $stop == "" then [] else [{type: "command", command: $stop}] end))}],
      SessionStart: [{matcher: "startup", hooks: (if $start == "" then [] else [{type: "command", command: $start}] end)}]}}' >"$1/.claude/settings.json"
}

@test "hooks registered: red with Stop only, SessionStart only, neither; green with both" {
  local hook_command='"$(git rev-parse --show-toplevel)/.claude/hooks/usage-capture.sh"'
  write_settings "$TEMPORARY_DIRECTORY/h1" "$hook_command" ""
  run gaia_usage_hooks_registered "$TEMPORARY_DIRECTORY/h1"
  [ "$status" -ne 0 ]
  write_settings "$TEMPORARY_DIRECTORY/h2" "" "$hook_command"
  run gaia_usage_hooks_registered "$TEMPORARY_DIRECTORY/h2"
  [ "$status" -ne 0 ]
  write_settings "$TEMPORARY_DIRECTORY/h3" "" ""
  run gaia_usage_hooks_registered "$TEMPORARY_DIRECTORY/h3"
  [ "$status" -ne 0 ]
  write_settings "$TEMPORARY_DIRECTORY/h4" "$hook_command" "$hook_command"
  run gaia_usage_hooks_registered "$TEMPORARY_DIRECTORY/h4"
  [ "$status" -eq 0 ]
  mkdir -p "$TEMPORARY_DIRECTORY/h5/.claude"
  printf 'not json' >"$TEMPORARY_DIRECTORY/h5/.claude/settings.json"
  run gaia_usage_hooks_registered "$TEMPORARY_DIRECTORY/h5"
  [ "$status" -ne 0 ]
  run gaia_usage_hooks_registered "$TEMPORARY_DIRECTORY/absent"
  [ "$status" -ne 0 ]
}

# ---------- 10. inactive reason, CI ----------

@test "inactive reason: prints jq not found without jq, nothing with jq" {
  mkdir -p "$TEMPORARY_DIRECTORY/bin"
  ln -s "$(command -v cat)" "$TEMPORARY_DIRECTORY/bin/cat"
  run env PATH="$TEMPORARY_DIRECTORY/bin" "$BASH" -c 'source "$1"; gaia_usage_inactive_reason' _ "$USAGE_LIBRARY"
  [ "$status" -eq 0 ]
  [ "$output" = "jq not found" ]
  run gaia_usage_inactive_reason
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 12. due files ----------

# make_due_fixture: sets PROJECTS_DIRECTORY, MAIN, TELEMETRY_DIRECTORY and the file paths CURRENT_FILE, GROWN_FILE, UNCACHED_FILE and TRUNCATED_FILE (the current one is up to date).
make_due_fixture() {
  MAIN="$TEMPORARY_DIRECTORY/main"
  PROJECTS_DIRECTORY="$TEMPORARY_DIRECTORY/projects"
  TELEMETRY_DIRECTORY="$TEMPORARY_DIRECTORY/tel"
  make_repo "$MAIN"
  local encoded_path project_directory
  encoded_path="$(printf '%s' "$MAIN" | sed 's/[^A-Za-z0-9]/-/g')"
  project_directory="$PROJECTS_DIRECTORY/$encoded_path"
  mkdir -p "$project_directory/sid1/subagents/workflows/wf_1" "$project_directory/sid1/other" "$TELEMETRY_DIRECTORY" "$PROJECTS_DIRECTORY/$encoded_path-web"
  CURRENT_FILE="$project_directory/a.jsonl"; GROWN_FILE="$project_directory/b.jsonl"; UNCACHED_FILE="$project_directory/sid1/subagents/agent-c.jsonl"; TRUNCATED_FILE="$project_directory/sid1/subagents/workflows/wf_1/agent-d.jsonl"
  head -c 100 /dev/zero | tr '\0' a >"$CURRENT_FILE"
  head -c 50 /dev/zero | tr '\0' b >"$GROWN_FILE"
  head -c 70 /dev/zero | tr '\0' c >"$UNCACHED_FILE"
  head -c 5 /dev/zero | tr '\0' d >"$TRUNCATED_FILE"
  # Not transcripts: a wrong-shape jsonl, a decoy project dir, an empty uncursored file.
  head -c 9 /dev/zero | tr '\0' x >"$project_directory/sid1/other/x.jsonl"
  head -c 9 /dev/zero | tr '\0' x >"$PROJECTS_DIRECTORY/$encoded_path-web/web.jsonl"
  : >"$project_directory/empty.jsonl"
  touch -t 202601010000 "$GROWN_FILE"; touch -t 202601020000 "$UNCACHED_FILE"; touch -t 202601030000 "$TRUNCATED_FILE"; touch -t 202601040000 "$CURRENT_FILE"
  jq -n --arg current_file "$CURRENT_FILE" --arg grown_file "$GROWN_FILE" --arg truncated_file "$TRUNCATED_FILE" '{schema_version: 1, ledger_bytes: 0,
    files: {($current_file): {session_id: "s", role: "main", offset: 100, size: 100},
            ($grown_file): {session_id: "s", role: "main", offset: 10, size: 10},
            ($truncated_file): {session_id: "s", role: "main", offset: 50, size: 50}}, pairs: {}}' >"$TELEMETRY_DIRECTORY/usage-cursors.json"
}

@test "due files: grown, uncached, truncated, missing cache, no candidates" {
  make_due_fixture
  local got want
  # case: grown, uncached and truncated files are listed oldest first; the current one is not
  got="$(gaia_usage_due_files "$PROJECTS_DIRECTORY" "$MAIN" "$TELEMETRY_DIRECTORY")"
  want="$(printf '50\t10\t%s\n70\t0\t%s\n5\t50\t%s' "$GROWN_FILE" "$UNCACHED_FILE" "$TRUNCATED_FILE")"
  [ "$got" = "$want" ] || { printf 'case oldest first: got:\n%s\nwant:\n%s\n' "$got" "$want" >&2; return 1; }
  grep -qF "$CURRENT_FILE" <<<"$got" && { echo "case oldest first: the current file is listed"; return 1; }

  # case: a missing or unparseable cache lists every non-empty transcript with offset 0
  want="$(printf '50\t0\t%s\n70\t0\t%s\n5\t0\t%s\n100\t0\t%s' "$GROWN_FILE" "$UNCACHED_FILE" "$TRUNCATED_FILE" "$CURRENT_FILE")"
  rm "$TELEMETRY_DIRECTORY/usage-cursors.json"
  expect_equal "missing cache" "$(gaia_usage_due_files "$PROJECTS_DIRECTORY" "$MAIN" "$TELEMETRY_DIRECTORY")" "$want" || return 1
  printf '{ not json' >"$TELEMETRY_DIRECTORY/usage-cursors.json"
  expect_equal "unparseable cache" "$(gaia_usage_due_files "$PROJECTS_DIRECTORY" "$MAIN" "$TELEMETRY_DIRECTORY")" "$want" || return 1
  printf '{"files": 7}' >"$TELEMETRY_DIRECTORY/usage-cursors.json"
  expect_equal "cache with a non-object files" "$(gaia_usage_due_files "$PROJECTS_DIRECTORY" "$MAIN" "$TELEMETRY_DIRECTORY")" "$want" || return 1

  # case: no candidate directory prints nothing and succeeds
  make_repo "$TEMPORARY_DIRECTORY/main-empty"
  mkdir -p "$TEMPORARY_DIRECTORY/empty-projects"
  run gaia_usage_due_files "$TEMPORARY_DIRECTORY/empty-projects" "$TEMPORARY_DIRECTORY/main-empty" "$TEMPORARY_DIRECTORY/tel-empty"
  [ "$status" -eq 0 ] || { echo "case no candidates: exited $status"; return 1; }
  [ -z "$output" ] || { echo "case no candidates: printed [$output]"; return 1; }
}
