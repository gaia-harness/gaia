#!/usr/bin/env bats
# update-decisions.sh: the decision log's validator and its record, reconcile,
# deferred and context subcommands. Runs against fixture files in a temp
# directory, no network.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/update-decisions.sh"
  LOG="$BATS_TEST_TMPDIR/.gaia/update-decisions.json"
  mkdir -p "$BATS_TEST_TMPDIR/.gaia"
}

# $1 is the whole log text.
write_log() {
  printf '%s\n' "$1" > "$LOG"
}

# $1 is the decisions array body.
write_decisions() {
  write_log "{\"schemaVersion\": 1, \"decisions\": [$1]}"
}

VALID_ENTRY='{"path": "wiki/a.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
UNSAFE_PATH_ERROR='has a path that is empty, absolute, or holds a .. segment, a backslash or a control byte'

# Runs check on the log and asserts the pinned refusal, then that the file is
# byte-identical afterward. $1 is the expected error text.
assert_invalid() {
  local before after
  before="$(cat "$LOG")"
  run bash "$SCRIPT" check --file "$LOG"
  [ "$status" -eq 1 ]
  [ "$output" = "$(printf 'DECISIONS_INVALID %s: %s\nNext step: fix %s or restore it with git checkout -- %s, then re-run /update-gaia.' "$LOG" "$1" "$LOG" "$LOG")" ]
  after="$(cat "$LOG")"
  [ "$before" = "$after" ]
}

# bats test_tags=protected
@test "check accepts a valid file and an absent file and refuses each malformed shape with its message" {
  echo "case: an absent file"
  run bash "$SCRIPT" check --file "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 0 ]
  [ "$output" = 'DECISIONS_ABSENT' ]

  echo "case: a valid two-entry file"
  write_decisions "$VALID_ENTRY, {\"path\": \"package.json\", \"key\": \"devDependencies.vite\", \"decision\": \"keep\", \"tag\": \"v2.0.4\", \"baselineTag\": \"v2.0.0-rc.1\"}"
  run bash "$SCRIPT" check --file "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = 'DECISIONS_OK 2' ]

  echo "case: the same path under different keys and without a key"
  write_decisions '{"path": "package.json", "key": "scripts.x", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "package.json", "key": "scripts.y", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "package.json", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  run bash "$SCRIPT" check --file "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = 'DECISIONS_OK 3' ]

  echo "case: a file that is not JSON"
  printf '%s\n' '{"schemaVersion": 1,' > "$LOG"
  assert_invalid 'not valid JSON'

  echo "case: an empty file"
  : > "$LOG"
  assert_invalid 'not valid JSON'

  echo "case: a top level that is not an object"
  write_log '[]'
  assert_invalid 'top level is not an object'

  echo "case: a missing schemaVersion"
  write_log '{"decisions": []}'
  assert_invalid 'schemaVersion is missing or not 1'

  echo "case: schemaVersion 2"
  write_log '{"schemaVersion": 2, "decisions": []}'
  assert_invalid 'schemaVersion is missing or not 1'

  echo "case: decisions that is not an array"
  write_log '{"schemaVersion": 1, "decisions": {}}'
  assert_invalid 'decisions is not an array'

  echo "case: an entry that is not an object"
  write_decisions '"wiki/a.md"'
  assert_invalid 'entry 1 is not an object'

  echo "case: an entry missing path"
  write_decisions '{"decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  assert_invalid 'entry 1 is missing a string path'

  echo "case: an entry missing decision"
  write_decisions '{"path": "a", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  assert_invalid 'entry 1 is missing a string decision'

  echo "case: an entry missing tag"
  write_decisions '{"path": "a", "decision": "keep", "baselineTag": "v2.0.0"}'
  assert_invalid 'entry 1 is missing a string tag'

  echo "case: an entry missing baselineTag"
  write_decisions "$VALID_ENTRY, {\"path\": \"a\", \"decision\": \"keep\", \"tag\": \"v2.0.4\"}"
  assert_invalid 'entry 2 is missing a string baselineTag'

  echo "case: an unknown decision"
  write_decisions '{"path": "a", "decision": "maybe", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  assert_invalid 'entry 1 has an unknown decision'

  echo "case: a tag that is not semver"
  write_decisions '{"path": "a", "decision": "keep", "tag": "2.0.4; rm -rf", "baselineTag": "v2.0.0"}'
  assert_invalid 'entry 1 has a tag that is not a semver tag like v2.0.4'

  echo "case: a baselineTag that is not semver"
  write_decisions '{"path": "a", "decision": "keep", "tag": "v2.0.4", "baselineTag": "main"}'
  assert_invalid 'entry 1 has a baselineTag that is not a semver tag like v2.0.4'

  echo "case: an absolute path"
  write_decisions '{"path": "/etc/passwd", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  assert_invalid "entry 1 $UNSAFE_PATH_ERROR"

  echo "case: a path with a dot-dot segment"
  write_decisions '{"path": "wiki/../../x", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  assert_invalid "entry 1 $UNSAFE_PATH_ERROR"

  echo "case: a path with a backslash"
  write_decisions '{"path": "wiki\\a.md", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  assert_invalid "entry 1 $UNSAFE_PATH_ERROR"

  echo "case: a path with a control byte"
  write_decisions '{"path": "wiki/a\u0007.md", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  assert_invalid "entry 1 $UNSAFE_PATH_ERROR"

  echo "case: an empty key"
  write_decisions '{"path": "package.json", "key": "", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  assert_invalid 'entry 1 has a key that is empty or not a string'

  echo "case: a key that is not a string"
  write_decisions '{"path": "package.json", "key": 7, "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  assert_invalid 'entry 1 has a key that is empty or not a string'

  echo "case: a duplicate path and key"
  write_decisions '{"path": "package.json", "key": "scripts.x", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "package.json", "key": "scripts.x", "decision": "gaia", "tag": "v2.0.5", "baselineTag": "v2.0.0"}'
  assert_invalid 'duplicate entry for path package.json key scripts.x'
}

# bats test_tags=protected
@test "every subcommand but check refuses an invalid file with the check output" {
  write_log 'nonsense'
  for subcommand in deferred deferred-tags context; do
    run bash "$SCRIPT" "$subcommand" --file "$LOG" --path a
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" | grep -qF "DECISIONS_INVALID $LOG: not valid JSON" || return 1
    printf '%s\n' "$output" | grep -qF "Next step: fix $LOG or restore it with git checkout -- $LOG, then re-run /update-gaia." || return 1
  done
  run bash "$SCRIPT" record --file "$LOG" --path a --decision keep --tag v1.0.0 --baseline-tag v1.0.0
  [ "$status" -eq 1 ]
  [ "$(cat "$LOG")" = 'nonsense' ]
  mkdir -p "$BATS_TEST_TMPDIR/tree" "$BATS_TEST_TMPDIR/latest"
  printf '%s\n' '{"files": []}' > "$BATS_TEST_TMPDIR/report.json"
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$BATS_TEST_TMPDIR/tree" --latest-dir "$BATS_TEST_TMPDIR/latest" --report "$BATS_TEST_TMPDIR/report.json" --latest-tag v2.0.7
  [ "$status" -eq 1 ]
  [ "$(cat "$LOG")" = 'nonsense' ]
}

@test "record writes, replaces by path and key, keeps other keys and is idempotent" {
  echo "case: creates the wrapper and the parent directory for an absent file"
  local fresh_log="$BATS_TEST_TMPDIR/fresh/.gaia/update-decisions.json"
  run bash "$SCRIPT" record --file "$fresh_log" --path wiki/a.md --decision deferred --tag v2.0.4 --baseline-tag v2.0.0 --reason 'wants it later'
  [ "$status" -eq 0 ]
  [ "$output" = 'RECORDED wiki/a.md deferred' ]
  jq -e '. == {schemaVersion: 1, decisions: [{path: "wiki/a.md", decision: "deferred", tag: "v2.0.4", baselineTag: "v2.0.0", reason: "wants it later"}]}' "$fresh_log" >/dev/null

  echo "case: names the key in its output and stores it"
  rm -f "$LOG"
  run bash "$SCRIPT" record --file "$LOG" --path package.json --key devDependencies.vite --decision keep --tag v2.0.4 --baseline-tag v2.0.0
  [ "$status" -eq 0 ]
  [ "$output" = 'RECORDED package.json#devDependencies.vite keep' ]
  jq -e '.decisions == [{path: "package.json", key: "devDependencies.vite", decision: "keep", tag: "v2.0.4", baselineTag: "v2.0.0"}]' "$LOG" >/dev/null

  echo "case: replaces an existing path and key so one entry remains"
  write_decisions '{"path": "wiki/a.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  run bash "$SCRIPT" record --file "$LOG" --path wiki/a.md --decision gaia --tag v2.0.7 --baseline-tag v2.0.4
  [ "$status" -eq 0 ]
  jq -e '.decisions == [{path: "wiki/a.md", decision: "gaia", tag: "v2.0.7", baselineTag: "v2.0.4"}]' "$LOG" >/dev/null

  echo "case: keeps a same-path entry under another key and the whole-file entry"
  write_decisions '{"path": "package.json", "key": "scripts.x", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "package.json", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  run bash "$SCRIPT" record --file "$LOG" --path package.json --key scripts.y --decision gaia --tag v2.0.7 --baseline-tag v2.0.4
  [ "$status" -eq 0 ]
  jq -e '.decisions | length == 3' "$LOG" >/dev/null
  jq -e '[.decisions[] | select(.key == "scripts.x")] | length == 1' "$LOG" >/dev/null
  jq -e '[.decisions[] | select(has("key") | not)] | length == 1' "$LOG" >/dev/null

  echo "case: the same call twice leaves the file byte-identical"
  rm -f "$LOG"
  run bash "$SCRIPT" record --file "$LOG" --path b.md --decision blend --tag v2.0.4 --baseline-tag v2.0.0
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" record --file "$LOG" --path a.md --key k --decision keep --tag v2.0.4 --baseline-tag v2.0.0 --reason why
  [ "$status" -eq 0 ]
  local first
  first="$(cat "$LOG")"
  run bash "$SCRIPT" record --file "$LOG" --path a.md --key k --decision keep --tag v2.0.4 --baseline-tag v2.0.0 --reason why
  [ "$status" -eq 0 ]
  [ "$first" = "$(cat "$LOG")" ]
  jq -e '[.decisions[].path] == ["a.md", "b.md"]' "$LOG" >/dev/null
}

# bats test_tags=protected
@test "record refuses an unsafe argument and leaves the file untouched" {
  local before

  echo "case: a missing required argument is a usage error and writes no file"
  run bash "$SCRIPT" record --file "$LOG" --path a --decision keep
  [ "$status" -eq 2 ]
  [ ! -e "$LOG" ]

  write_decisions "$VALID_ENTRY"
  before="$(cat "$LOG")"

  echo "case: a tag that is not semver"
  run bash "$SCRIPT" record --file "$LOG" --path wiki/a.md --decision keep --tag 'v2.0.4 --evil' --baseline-tag v2.0.0
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'RECORD_REFUSED' || return 1
  [ "$before" = "$(cat "$LOG")" ]

  echo "case: a bad baseline tag"
  run bash "$SCRIPT" record --file "$LOG" --path a --decision keep --tag v2.0.4 --baseline-tag latest
  [ "$status" -eq 1 ]
  echo "case: an unknown decision"
  run bash "$SCRIPT" record --file "$LOG" --path a --decision skip --tag v2.0.4 --baseline-tag v2.0.0
  [ "$status" -eq 1 ]
  echo "case: an unsafe path"
  run bash "$SCRIPT" record --file "$LOG" --path ../a --decision keep --tag v2.0.4 --baseline-tag v2.0.0
  [ "$status" -eq 1 ]
  echo "case: an empty key"
  run bash "$SCRIPT" record --file "$LOG" --path a --key '' --decision keep --tag v2.0.4 --baseline-tag v2.0.0
  [ "$status" -eq 1 ]
  [ "$before" = "$(cat "$LOG")" ]
}

# Builds tree and latest directories for reconcile.
make_reconcile_dirs() {
  TREE="$BATS_TEST_TMPDIR/tree"
  LATEST="$BATS_TEST_TMPDIR/latest"
  rm -rf "$TREE" "$LATEST"
  mkdir -p "$TREE/wiki" "$LATEST/wiki"
}

# $1 is a JSON array body of file entries.
write_report() {
  RECONCILE_REPORT="$BATS_TEST_TMPDIR/report.json"
  printf '{"files": [%s]}\n' "$1" > "$RECONCILE_REPORT"
}

@test "reconcile drops an entry whose file or field already matches the latest" {
  local before

  echo "case: drops a whole-file entry that matches the latest copy and keeps one that differs"
  make_reconcile_dirs
  printf 'same\n' > "$TREE/wiki/same.md"; printf 'same\n' > "$LATEST/wiki/same.md"
  printf 'mine\n' > "$TREE/wiki/differs.md"; printf 'gaia\n' > "$LATEST/wiki/differs.md"
  write_decisions '{"path": "wiki/differs.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "wiki/same.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  write_report ''
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag v2.0.7
  [ "$status" -eq 0 ]
  [ "$output" = 'DROPPED wiki/same.md' ]
  jq -e '[.decisions[].path] == ["wiki/differs.md"]' "$LOG" >/dev/null

  echo "case: a path absent from both sides is in line"
  make_reconcile_dirs
  write_decisions '{"path": "wiki/gone.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  write_report ''
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag v2.0.7
  [ "$status" -eq 0 ]
  [ "$output" = 'DROPPED wiki/gone.md' ]
  jq -e '.decisions == []' "$LOG" >/dev/null

  echo "case: keeps a whole-file entry when only the tree has the file"
  make_reconcile_dirs
  printf 'mine\n' > "$TREE/wiki/a.md"
  write_decisions '{"path": "wiki/a.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  write_report ''
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag v2.0.7
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  jq -e '.decisions | length == 1' "$LOG" >/dev/null

  echo "case: drops a key entry listed under alreadyLatest and keeps one that is not"
  make_reconcile_dirs
  write_decisions '{"path": "package.json", "key": "devDependencies.vite", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "package.json", "key": "scripts.build", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "package.json", "key": "engines.node", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  write_report '{"path": "package.json", "status": "field-aware", "fieldMerge": {
  "applied": [{"kind": "key", "section": "scripts", "key": "build"}],
  "alreadyLatest": [{"kind": "key", "section": "devDependencies", "key": "vite"}, {"kind": "key", "key": "engines.node"}],
  "keptRemoved": [], "removedUpstream": []}}'
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag v2.0.7
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'DROPPED package.json#devDependencies.vite\nDROPPED package.json#engines.node')" ]
  jq -e '[.decisions[].key] == ["scripts.build"]' "$LOG" >/dev/null

  echo "case: a file with nothing to drop stays byte-identical"
  make_reconcile_dirs
  write_decisions '{"path": "package.json", "key": "scripts.build", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  before="$(cat "$LOG")"
  write_report ''
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag v2.0.7
  [ "$status" -eq 0 ]
  [ "$before" = "$(cat "$LOG")" ]
}

@test "reconcile rebases a deferred entry the run resolved and leaves open or non-deferred entries" {
  local before

  echo "case: rebases a deferred whole-file entry the run auto-merged, and deferred-tags stops listing its old tag"
  make_reconcile_dirs
  printf 'merged\n' > "$TREE/wiki/a.md"; printf 'gaia\n' > "$LATEST/wiki/a.md"
  write_decisions '{"path": "wiki/a.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0", "reason": "later"}'
  write_report '{"path": "wiki/a.md", "status": "auto-merged"}'
  run bash "$SCRIPT" deferred-tags --file "$LOG"
  [ "$output" = 'v2.0.0' ]
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag v2.0.7
  [ "$status" -eq 0 ]
  [ "$output" = 'REBASED wiki/a.md v2.0.7' ]
  jq -e '.decisions == [{path: "wiki/a.md", decision: "blend", tag: "v2.0.7", baselineTag: "v2.0.7"}]' "$LOG" >/dev/null
  run bash "$SCRIPT" deferred-tags --file "$LOG"
  [ -z "$output" ]
  run bash "$SCRIPT" context --file "$LOG" --path wiki/a.md
  [ "$output" = 'EARLIER v2.0.7 blend' ]

  echo "case: drops rather than rebases a resolved deferred entry whose file equals the latest copy"
  make_reconcile_dirs
  printf 'gaia\n' > "$TREE/wiki/a.md"; printf 'gaia\n' > "$LATEST/wiki/a.md"
  write_decisions '{"path": "wiki/a.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  write_report '{"path": "wiki/a.md", "status": "overwrite"}'
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag v2.0.7
  [ "$output" = 'DROPPED wiki/a.md' ]
  jq -e '.decisions == []' "$LOG" >/dev/null

  echo "case: leaves a deferred entry untouched while its report entry is open or pending judgment"
  make_reconcile_dirs
  printf 'mine\n' > "$TREE/wiki/a.md"; printf 'gaia\n' > "$LATEST/wiki/a.md"
  printf 'mine\n' > "$TREE/wiki/b.md"; printf 'gaia\n' > "$LATEST/wiki/b.md"
  write_decisions '{"path": "wiki/a.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "wiki/b.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  write_report '{"path": "wiki/a.md", "status": "open"}, {"path": "wiki/b.md", "status": "pending-judgment"}'
  before="$(cat "$LOG")"
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag v2.0.7
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$before" = "$(cat "$LOG")" ]

  echo "case: rebases a deferred key entry under applied, keptRemoved or removedUpstream and drops alreadyLatest"
  make_reconcile_dirs
  write_decisions '{"path": "package.json", "key": "scripts.a", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "package.json", "key": "scripts.b", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "package.json", "key": "scripts.c", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "package.json", "key": "scripts.d", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "package.json", "key": "scripts.e", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  write_report '{"path": "package.json", "status": "field-aware", "fieldMerge": {
    "applied": [{"kind": "key", "section": "scripts", "key": "a"}],
    "alreadyLatest": [{"kind": "key", "section": "scripts", "key": "d"}],
    "keptRemoved": [{"kind": "key", "key": "scripts.b"}],
    "removedUpstream": [{"kind": "key", "section": "scripts", "key": "c"}]},
    "items": [{"kind": "key", "section": "scripts", "key": "e"}]}'
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag v2.0.7
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'REBASED package.json#scripts.a v2.0.7\nREBASED package.json#scripts.b v2.0.7\nREBASED package.json#scripts.c v2.0.7\nDROPPED package.json#scripts.d')" ]
  jq -e '[.decisions[] | [.key, .decision, .baselineTag]] == [["scripts.a", "blend", "v2.0.7"], ["scripts.b", "blend", "v2.0.7"], ["scripts.c", "blend", "v2.0.7"], ["scripts.e", "deferred", "v2.0.0"]]' "$LOG" >/dev/null

  echo "case: does not rebase a non-deferred entry"
  make_reconcile_dirs
  printf 'mine\n' > "$TREE/wiki/a.md"; printf 'gaia\n' > "$LATEST/wiki/a.md"
  write_decisions '{"path": "wiki/a.md", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  write_report '{"path": "wiki/a.md", "status": "auto-merged"}'
  before="$(cat "$LOG")"
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag v2.0.7
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$before" = "$(cat "$LOG")" ]
}

# bats test_tags=protected
@test "reconcile refuses a missing or malformed latest tag with exit 2 and leaves the file byte-identical" {
  make_reconcile_dirs
  printf 'merged\n' > "$TREE/wiki/a.md"; printf 'gaia\n' > "$LATEST/wiki/a.md"
  write_decisions '{"path": "wiki/a.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  write_report '{"path": "wiki/a.md", "status": "auto-merged"}'
  before="$(cat "$LOG")"
  run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT"
  [ "$status" -eq 2 ]
  [ "$before" = "$(cat "$LOG")" ]
  for bad in 'main; rm -rf' '2.0.7' 'v2.0' 'v2.0.7 extra'; do
    run bash "$SCRIPT" reconcile --file "$LOG" --tree "$TREE" --latest-dir "$LATEST" --report "$RECONCILE_REPORT" --latest-tag "$bad"
    [ "$status" -eq 2 ] || return 1
    [ "$before" = "$(cat "$LOG")" ] || return 1
  done
}

@test "deferred and deferred-tags list deferred entries once, in semver order, and nothing for an absent file" {
  echo "case: deferred lists deferred entries only, with their baseline tag and key"
  write_decisions '{"path": "a.md", "decision": "deferred", "tag": "v2.0.10", "baselineTag": "v2.0.10"}, {"path": "b.md", "decision": "deferred", "tag": "v2.0.2", "baselineTag": "v2.0.2"}, {"path": "d.md", "decision": "keep", "tag": "v1.0.0", "baselineTag": "v1.0.0"}, {"path": "package.json", "key": "scripts.x", "decision": "deferred", "tag": "v2.0.2", "baselineTag": "v2.0.2-rc.1"}'
  run bash "$SCRIPT" deferred --file "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'DEFERRED v2.0.10 a.md\nDEFERRED v2.0.2 b.md\nDEFERRED v2.0.2-rc.1 package.json scripts.x')" ]

  echo "case: deferred-tags orders by semver with a prerelease before its release"
  write_decisions '{"path": "a.md", "decision": "deferred", "tag": "v2.0.10", "baselineTag": "v2.0.10"}, {"path": "b.md", "decision": "deferred", "tag": "v2.0.2", "baselineTag": "v2.0.2"}, {"path": "package.json", "key": "scripts.x", "decision": "deferred", "tag": "v2.0.2", "baselineTag": "v2.0.2-rc.1"}'
  run bash "$SCRIPT" deferred-tags --file "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'v2.0.2-rc.1\nv2.0.2\nv2.0.10')" ]

  echo "case: deferred-tags prints each tag once and never a non-deferred tag"
  write_decisions '{"path": "a.md", "decision": "deferred", "tag": "v2.0.10", "baselineTag": "v2.0.10"}, {"path": "b.md", "decision": "deferred", "tag": "v2.0.2", "baselineTag": "v2.0.2"}, {"path": "c.md", "decision": "deferred", "tag": "v2.0.2", "baselineTag": "v2.0.2"}, {"path": "d.md", "decision": "gaia", "tag": "v1.0.0", "baselineTag": "v1.0.0"}'
  run bash "$SCRIPT" deferred-tags --file "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'v2.0.2\nv2.0.10')" ]

  echo "case: both print nothing for an absent file"
  run bash "$SCRIPT" deferred --file "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$SCRIPT" deferred-tags --file "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "context prints earlier keep and blend decisions and nothing else" {
  echo "case: the earlier keep and blend decisions as machine lines"
  write_decisions '{"path": "a.md", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "b.md", "decision": "blend", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  run bash "$SCRIPT" context --file "$LOG" --path a.md
  [ "$status" -eq 0 ]
  [ "$output" = 'EARLIER v2.0.4 keep' ]
  run bash "$SCRIPT" context --file "$LOG" --path b.md
  [ "$status" -eq 0 ]
  [ "$output" = 'EARLIER v2.0.4 blend' ]

  echo "case: a key entry matches by path and key"
  write_decisions '{"path": "package.json", "key": "scripts.x", "decision": "keep", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  run bash "$SCRIPT" context --file "$LOG" --path package.json --key scripts.x
  [ "$output" = 'EARLIER v2.0.4 keep' ]
  run bash "$SCRIPT" context --file "$LOG" --path package.json --key scripts.y
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$SCRIPT" context --file "$LOG" --path package.json
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  echo "case: nothing for gaia, deferred and missing entries"
  write_decisions '{"path": "a.md", "decision": "gaia", "tag": "v2.0.4", "baselineTag": "v2.0.0"}, {"path": "b.md", "decision": "deferred", "tag": "v2.0.4", "baselineTag": "v2.0.0"}'
  local target
  for target in a.md b.md c.md; do
    run bash "$SCRIPT" context --file "$LOG" --path "$target"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  run bash "$SCRIPT" context --file "$BATS_TEST_TMPDIR/missing.json" --path a.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
