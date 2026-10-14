#!/usr/bin/env bats
#
# `usage.sh handoff` and `usage.sh join`: a recorded run continued in another
# session. The session that hands off prints a join line, the session that
# continues runs it, and `usage.sh record` then closes and sums every session
# bound to the run. Each case drives the real flusher over transcripts written
# under a temporary projects tree, with the main checkout, telemetry directory
# and projects root pinned under $BATS_TEST_TMPDIR. Figures are fresh input only.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-handoff.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RATES="$BATS_TEST_DIRNAME/fixtures/usage/resolve/rates-a.json"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  TEL="$MAIN/.gaia/local/telemetry"
  PROJECTS="$TEMPORARY_DIRECTORY/projects"
  mkdir -p "$MAIN/.claude" "$TEL"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  ENCODED_MAIN="$(printf '%s' "$MAIN" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$PROJECTS/$ENCODED_MAIN"
  unset GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD GAIA_LEDGER_LOCK_TIMEOUT_SECONDS
  unset GAIA_USAGE_MERGE_CAP_SECONDS GAIA_USAGE_RENDER_CAP_SECONDS GAIA_LEDGER_LOCK_FORCE_FALLBACK
  USAGE_SCRIPT="$SCRIPTS/usage.sh"
  in_session sess-a
}

# ---------- helpers ----------

in_session() {
  SID="$1"
  export CLAUDE_CODE_SESSION_ID="$SID"
}
usage() { bash "$USAGE_SCRIPT" "$@" --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"; }
main_file() { printf '%s/%s/%s.jsonl' "$PROJECTS" "$ENCODED_MAIN" "$SID"; }
stamp() { printf '2026-10-01T%s:00Z' "$1"; }

# main_usage <id> <hh:mm> <fresh input>
main_usage() {
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"%s","cwd":"%s","sessionId":"%s","gitBranch":"main","message":{"id":"%s","model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"ok"}]}}\n' \
    "$1" "$(stamp "$2")" "$MAIN" "$SID" "$1" "$3" >>"$(main_file)"
}
# main_start <id> <hh:mm> <workflow>: the transcript line a Skill call writes.
main_start() {
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"%s","cwd":"%s","sessionId":"%s","gitBranch":"main","message":{"id":"%s","model":"claude-opus-5-5","role":"assistant","content":[{"type":"tool_use","id":"t-%s","name":"Skill","input":{"skill":"%s"}}]}}\n' \
    "$1" "$(stamp "$2")" "$MAIN" "$SID" "$1" "$1" "$3" >>"$(main_file)"
}

ledger() { printf '%s/usage.jsonl' "$TEL"; }
last_stdout_line() { printf '%s' "${lines[$((${#lines[@]} - 1))]}"; }
initiative_tokens() { usage initiative "$1" --line --json | jq -r '.tokens'; }

# handoff_line: the join line `handoff` prints in the current session.
handoff_line() {
  run --separate-stderr usage handoff
  [ "$status" -eq 0 ] || return 1
  [ -z "$stderr" ] || return 1
  printf '%s' "$output"
}
# join_with <line>: runs a printed join line against the pinned roots.
join_with() {
  local prefix="bash .gaia/scripts/usage.sh "
  [[ "$1" == "$prefix"* ]] || return 1
  # shellcheck disable=SC2086  # the printed line is word-split into arguments on purpose
  usage ${1#"$prefix"}
}

# ---------- the cross-session run ----------

@test "a run started in one session and recorded in another reports and attributes both sessions' spend" {
  local line
  main_start s1 10:00 gaia-debt
  main_usage a1 10:10 1000
  line="$(handoff_line)"
  [ "$line" = "bash .gaia/scripts/usage.sh join --workflow gaia-debt --session sess-a --start $(stamp 10:00)" ]
  in_session sess-b
  main_usage b1 11:00 2000
  run join_with "$line"
  [ "$status" -eq 0 ]
  [ "$output" = "joined the gaia-debt run started $(stamp 10:00)" ]
  main_usage b2 11:30 4000
  run --separate-stderr usage record command:gaia-debt --workflow gaia-debt --json
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 7000 ]
  # Every session's close names the one run ref, so the initiative readout agrees.
  jq -s -e '[.[] | select(.kind == "binding" and .type == "close")] | length == 2 and (map(.ref) | unique | length == 1)
    and (map(.session_id) | sort == ["sess-a", "sess-b"])' "$(ledger)" >/dev/null
  [ "$(initiative_tokens "$(jq -rs '[.[] | select(.kind == "binding" and .type == "close")][0].ref' "$(ledger)")")" -eq 7000 ]
  # Every bound start is claimed now, so a second record finds nothing open.
  run usage record command:gaia-debt --workflow gaia-debt --json
  [ "$status" -eq 1 ]
}

@test "a chain of handoffs binds every session to the origin, and the close sums all three" {
  local line
  main_start s1 10:00 gaia-spec
  main_usage a1 10:10 1000
  line="$(handoff_line)"
  in_session sess-b
  run join_with "$line"
  [ "$status" -eq 0 ]
  main_usage b1 11:00 2000
  # The second handoff names the origin, never the session that joined it.
  [ "$(handoff_line)" = "$line" ]
  in_session sess-c
  run join_with "$line"
  [ "$status" -eq 0 ]
  main_usage c1 12:00 4000
  run usage record spec:SPEC-910 --workflow gaia-spec --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 7000 ]
  [ "$(initiative_tokens spec:SPEC-910)" -eq 7000 ]
}

@test "join is idempotent, and a session holding spend from before the run joins from now" {
  local line
  main_start s1 10:00 gaia-debt
  main_usage a1 10:10 1000
  line="$(handoff_line)"
  in_session sess-b
  main_usage b0 09:00 8000
  run join_with "$line"
  [ "$status" -eq 0 ]
  run join_with "$line"
  [ "$status" -eq 0 ]
  [ "$output" = "already joined the gaia-debt run started $(stamp 10:00)" ]
  jq -s -e '[.[] | select(.kind == "binding" and .type == "start" and .session_id == "sess-b")]
    | length == 1 and .[0].source == "join-command" and .[0].ts > "2026-10-02" and .[0].run == {session_id: "sess-a", ts: "2026-10-01T10:00:00Z"}' "$(ledger)" >/dev/null
  run usage record command:gaia-debt --workflow gaia-debt --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 1000 ]
}

@test "a run recorded where it started closes once, so a later record in a joined session sums only its own" {
  local line
  main_start s1 10:00 gaia-debt
  main_usage a1 10:10 1000
  line="$(handoff_line)"
  run usage record command:gaia-debt --workflow gaia-debt --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 1000 ]
  in_session sess-b
  run join_with "$line"
  main_usage b1 11:00 2000
  run usage record command:gaia-debt --workflow gaia-debt --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 2000 ]
}

# ---------- no open run, refusals, recovery ----------

@test "handoff with no open run prints nothing and exits 0" {
  main_usage a1 10:10 1000
  run --separate-stderr usage handoff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  main_start s1 10:20 gaia-debt
  run usage record command:gaia-debt --workflow gaia-debt
  [ "$status" -eq 0 ]
  run --separate-stderr usage handoff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "join refuses a malformed line with exit 2 and writes nothing; joining its own run is a no-op" {
  local case_arguments
  main_usage a1 10:10 1000
  for case_arguments in "--workflow gaia-debt --start 2026-10-01T10:00:00Z" "--workflow gaia-debt --session sess-a" \
    "--workflow nonsense --session sess-z --start 2026-10-01T10:00:00Z" "--session sess-z --start 2026-10-01T10:00:00Z" \
    "--workflow gaia-debt --session sess-z --start 2999-01-01T00:00:00Z" "--workflow gaia-debt --session sess-z --start yesterday" \
    "--workflow gaia-debt --session sess-z --start 2026-10-01T10:00:00Z --pr 5" "extra --workflow gaia-debt --session sess-z --start 2026-10-01T10:00:00Z"; do
    # shellcheck disable=SC2086  # the case string is word-split into arguments on purpose
    run --separate-stderr usage join $case_arguments
    [ "$status" -eq 2 ] || { printf 'case: %s status %s\n' "$case_arguments" "$status" >&2; return 1; }
    [ "${#stderr_lines[@]}" -eq 1 ] || { printf 'case: %s stderr: %s\n' "$case_arguments" "$stderr" >&2; return 1; }
  done
  run usage join --workflow gaia-debt --session sess-a --start 2026-10-01T10:00:00Z
  [ "$status" -eq 0 ]
  [ "$output" = "this session started the run; nothing to join" ]
  [ ! -s "$(ledger)" ] || jq -s -e '[.[] | select(.kind == "binding")] | length == 0' "$(ledger)" >/dev/null
}

@test "with no start in this session the refusal names the join line and the recovery, and the recovery's Cost line is marked this-session-only" {
  in_session sess-b
  main_usage b1 11:00 2000
  run --separate-stderr usage record command:gaia-debt --workflow gaia-debt
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"run the usage.sh join line its continuation prompt carries"* ]]
  [[ "$stderr" == *"--start <iso>, with <iso> the UTC time the run began"* ]]
  run --separate-stderr usage record command:gaia-debt --workflow gaia-debt --start "$(stamp 10:00)"
  [ "$status" -eq 0 ]
  [[ "$(last_stdout_line)" =~ ^Cost:\ .*\ \(partial:\ this\ session\ only\)$ ]]
}

@test "recording in the origin session after a join also closes the joined session, unmarked" {
  local line
  main_start s1 10:00 gaia-debt
  main_usage a1 10:10 1000
  line="$(handoff_line)"
  in_session sess-b
  run join_with "$line"
  main_usage b1 11:00 2000
  in_session sess-a
  run usage record command:gaia-debt --workflow gaia-debt
  [ "$status" -eq 0 ]
  [[ "$(last_stdout_line)" == *"partial"* ]] && return 1
  [ "$(jq -s '[.[] | select(.kind == "binding" and .type == "close")] | length' "$(ledger)")" -eq 2 ]
}
