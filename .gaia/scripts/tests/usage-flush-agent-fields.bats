#!/usr/bin/env bats
#
# usage-flush.sh: the agent_type and agent_id fields on segment rows, close
# bindings as split points (including one appended while a flush is in
# flight), the --all-sidecars-finished flag, and the hard error on a missing
# library.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-flush-agent-fields.bats
#
# The fixture session holds a main file (two messages half an hour apart) and
# sidecars whose metas name code-audit-frontend (two dispatches), general-purpose,
# nothing, a decoy file name, and a workflow sidecar named Explore. golden.json
# holds the segments the flusher produced before the two fields existed.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FLUSH="$SCRIPTS/usage-flush.sh"
  FIXTURES_DIRECTORY="$BATS_TEST_DIRNAME/fixtures/usage/agent-fields"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD GAIA_TALLY_PROJECTS_ROOT
  unset GAIA_LEDGER_LOCK_FORCE_FALLBACK GAIA_LEDGER_LOCK_TIMEOUT_SECONDS
  ROOT="$TEMPORARY_DIRECTORY/repo"
  PROJECTS_DIRECTORY="$TEMPORARY_DIRECTORY/projects"
  TEL="$ROOT/.gaia/local/telemetry"
  mkdir -p "$ROOT" "$PROJECTS_DIRECTORY"
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
    commit -q --allow-empty -m init
}

# ---------- helpers ----------

encode_project_path() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

# install [live]: the fixture's projects tree into PROJECTS_DIRECTORY. Transcripts
# are aged past every quiet window unless `live` is passed; metas are copied as
# they are.
install() {
  local source_directory="$FIXTURES_DIRECTORY/projects" relative_path destination_path encoded_root
  encoded_root="$(encode_project_path "$ROOT")"
  while IFS= read -r relative_path; do
    destination_path="$PROJECTS_DIRECTORY/${relative_path#./}"
    destination_path="${destination_path//@MAIN@/$encoded_root}"
    mkdir -p "${destination_path%/*}"
    sed -e "s|@ROOT@|$ROOT|g" "$source_directory/$relative_path" >"$destination_path"
    case "$destination_path" in
      *.jsonl) [ "${1:-}" = live ] || touch -t 202001010000 "$destination_path" ;;
    esac
  done < <(cd "$source_directory" && find . -type f)
}

flush() { bash "$FLUSH" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" "$@"; }

flush_session() { flush --session s-af --finished-main --all-sidecars-finished; }

segments() { jq -s '[.[] | select(.kind == "segment")]' "$TEL/usage.jsonl"; }

# close_row <ts>: a close binding for the fixture session.
close_row() {
  printf '{"schema_version":1,"kind":"binding","type":"close","session_id":"s-af","ts":"%s","ref":"command:gaia-wiki-1","workflow":"gaia-wiki","source":"record-command"}\n' "$1"
}

# A segment whose span contains the instant strictly inside it.
straddling_count() {
  segments | jq --arg at "$1" '[.[] | select(.first_ts < $at and $at < .last_ts)] | length'
}

wait_for() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$1" ]
}

# race_a_close: flush the session, parking the first file after its parse; a
# close at T lands in the ledger inside the main file's span, then the flush is
# released.
race_a_close() {
  local pid
  GAIA_USAGE_TEST_BARRIER="$TEMPORARY_DIRECTORY/bar" flush_session 3>&- &
  pid=$!
  wait_for "$TEMPORARY_DIRECTORY/bar.parsed"
  mkdir -p "$TEL"
  close_row 2026-10-01T00:15:00Z >>"$TEL/usage.jsonl"
  : >"$TEMPORARY_DIRECTORY/bar"
  wait "$pid"
}

# race_a_torn_close: as race_a_close, but the close row is half written when
# the flush first reads the ledger, the shape of a writer caught mid-append,
# and finished while the flush is parked. The cut falls before the row's
# session id and type, so its second half alone still names both. Another
# session's whole row comes first, as in any ledger past its first write.
race_a_torn_close() {
  local pid row
  row="$(close_row 2026-10-01T00:15:00Z)"
  mkdir -p "$TEL"
  close_row 2026-10-01T00:05:00Z | sed 's/"s-af"/"s-other"/' >"$TEL/usage.jsonl"
  printf '%s' "${row:0:20}" >>"$TEL/usage.jsonl"
  GAIA_USAGE_TEST_BARRIER="$TEMPORARY_DIRECTORY/bar" flush_session 3>&- &
  pid=$!
  wait_for "$TEMPORARY_DIRECTORY/bar.parsed"
  printf '%s\n' "${row:20}" >>"$TEL/usage.jsonl"
  : >"$TEMPORARY_DIRECTORY/bar"
  wait "$pid"
}

# ---------- agent fields ----------

@test "agent fields: each sidecar kind carries its type and id, an unparseable meta reads unknown, dispatches sum per agent_id, and a sweep keeps each session's metas separate" {
  install
  printf '{"agentType":"code-audit-fro' >"$PROJECTS_DIRECTORY/$(encode_project_path "$ROOT")/s-af/subagents/agent-bad1.meta.json"
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(segments | jq -c '[.[] | select(.agent_id) | {agent_id, agent_type, first_ts}] | sort_by(.agent_id)')" = \
    '[{"agent_id":"ca1","agent_type":"code-audit-frontend","first_ts":"2026-10-01T00:00:05.000Z"},{"agent_id":"ca2","agent_type":"code-audit-frontend","first_ts":"2026-10-01T00:00:10.000Z"},{"agent_id":"dc1","agent_type":"unknown","first_ts":"2026-10-01T00:00:25.000Z"},{"agent_id":"gp1","agent_type":"general-purpose","first_ts":"2026-10-01T00:00:15.000Z"},{"agent_id":"nm1","agent_type":"unknown","first_ts":"2026-10-01T00:00:20.000Z"},{"agent_id":"wf1","agent_type":"Explore","first_ts":"2026-10-01T00:00:30.000Z"}]' ] ||
    { echo "case sidecar kinds: agent ids and types differ"; return 1; }
  [ "$(segments | jq -c '[.[] | select(.agent_type == "main") | has("agent_id")] | unique')" = '[false]' ] ||
    { echo "case sidecar kinds: a main segment carries an agent_id"; return 1; }
  [ "$(segments | jq '[.[] | select(.agent_type == "main")] | length')" -eq 1 ] ||
    { echo "case sidecar kinds: main segment count"; return 1; }
  [ "$(segments | jq -c '[.[].schema_version] | unique')" = '[1]' ] ||
    { echo "case sidecar kinds: schema_version"; return 1; }
  [ "$(segments | jq -c '[.[] | select(.agent_type == "code-audit-frontend")] | group_by(.agent_id)
      | map({agent_id: .[0].agent_id, tokens: ([.[].by_model[] | [.[]] | add] | add)})')" = \
    '[{"agent_id":"ca1","tokens":3363},{"agent_id":"ca2","tokens":4484}]' ] ||
    { echo "case dispatch sum: tokens per agent_id differ"; return 1; }

  local project_directory source_file
  project_directory="$PROJECTS_DIRECTORY/$(encode_project_path "$ROOT")"
  while IFS= read -r source_file; do
    mkdir -p "$project_directory/s-af2/${source_file%/*}"
    sed 's/s-af/s-af2/g' "$project_directory/s-af/$source_file" >"$project_directory/s-af2/$source_file"
    case "$source_file" in *.jsonl) touch -t 202001010000 "$project_directory/s-af2/$source_file" ;; esac
  done < <(cd "$project_directory/s-af" && find . -type f | sed 's|^\./||')
  sed 's/s-af/s-af2/g' "$project_directory/s-af.jsonl" >"$project_directory/s-af2.jsonl"
  touch -t 202001010000 "$project_directory/s-af2.jsonl"
  rm -rf "$ROOT/.gaia/local"
  run flush --sweep
  [ "$status" -eq 0 ]
  [ "$(segments | jq -c '[.[] | select(.agent_id) | {session_id, agent_type}] | group_by(.session_id) | map(map(.agent_type) | sort)')" = \
    '[["Explore","code-audit-frontend","code-audit-frontend","general-purpose","unknown","unknown"],["Explore","code-audit-frontend","code-audit-frontend","general-purpose","unknown","unknown"]]' ] ||
    { echo "case sweep: two sessions' sidecar types differ"; return 1; }
}

@test "agent fields: dropping the two fields leaves exactly the segments the flusher produced without them" {
  install
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(segments | jq -S 'map(del(.agent_type, .agent_id) | {key, inherit, first_ts, last_ts, messages, by_model}) | sort_by(.first_ts)')" = \
    "$(jq -S . "$FIXTURES_DIRECTORY/golden.json")" ]
}

@test "agent fields: the metas are read in one pass, not one jq per sidecar" {
  install
  local shim_directory="$TEMPORARY_DIRECTORY/shim" real_jq
  real_jq="$(command -v jq)"
  mkdir -p "$shim_directory"
  printf '#!/usr/bin/env bash\ncase "$*" in *.meta.json*) echo x >>"%s/meta-reads" ;; esac\nexec "%s" "$@"\n' "$shim_directory" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  PATH="$shim_directory:$PATH" run flush_session
  [ "$status" -eq 0 ]
  [ "$(segments | jq '[.[] | select(.agent_id)] | length')" -eq 6 ]
  [ "$(wc -l <"$shim_directory/meta-reads" | tr -d ' ')" -eq 1 ]
}

# ---------- sidecar quiet window ----------

@test "all-sidecars-finished: a sidecar written moments ago commits whole with the flag and is held back without it" {
  install live
  run flush --session s-af --finished-main
  [ "$status" -eq 0 ]
  [ "$(segments | jq '[.[] | select(.agent_id)] | length')" -eq 0 ]
  [ "$(segments | jq '[.[] | select(.agent_type == "main")] | length')" -eq 1 ]
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(segments | jq '[.[] | select(.agent_id)] | length')" -eq 6 ]
}

# ---------- close bindings split segments ----------

@test "close split: messages before and after a close land in different segments" {
  install
  mkdir -p "$TEL"
  close_row 2026-10-01T00:15:00Z >"$TEL/usage.jsonl"
  run flush_session
  [ "$status" -eq 0 ]
  [ "$(segments | jq '[.[] | select(.agent_type == "main")] | length')" -eq 2 ]
  [ "$(straddling_count 2026-10-01T00:15:00Z)" -eq 0 ]
}

@test "close race: a close appended while a flush is parked makes it re-prepare, so no segment straddles it" {
  install
  race_a_close
  [ "$(straddling_count 2026-10-01T00:15:00Z)" -eq 0 ]
  [ "$(segments | jq '[.[] | select(.agent_type == "main")] | length')" -eq 2 ]
  [ "$(segments | jq '[.[] | select(.agent_id)] | length')" -eq 6 ]
}

@test "torn close: a close row half written at the first ledger read is read whole once finished, so no segment straddles it" {
  install
  race_a_torn_close
  [ "$(straddling_count 2026-10-01T00:15:00Z)" -eq 0 ]
  [ "$(segments | jq '[.[] | select(.agent_type == "main")] | length')" -eq 2 ]
  [ "$(segments | jq '[.[] | select(.agent_id)] | length')" -eq 6 ]
}

# ---------- libraries and the start set ----------

@test "start set: the flusher reads GAIA_USAGE_START_SET and keeps no list of its own" {
  run grep -n 'UF_STARTSET' "$FLUSH"
  [ "$status" -eq 1 ]
  run grep -c 'GAIA_USAGE_START_SET' "$FLUSH"
  [ "$output" -ge 1 ]
  [ "$(bash -c '. "$1"; printf "%s" "$GAIA_USAGE_START_SET" | jq -c "length"' _ "$SCRIPTS/usage-lib.sh")" -ge 1 ]
}
