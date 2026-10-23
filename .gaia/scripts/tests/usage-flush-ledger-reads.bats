#!/usr/bin/env bats
#
# usage-flush.sh: how often a flush reads the whole ledger and the whole
# cursor cache, and that the cache is only a hint. Both files grow with every
# session ever flushed, so a whole read per committed file makes a session's
# flush cost grow with rows that are not its own; the guard counts whole reads
# instead of timing them, so it does not depend on machine speed.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-flush-ledger-reads.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FLUSH="$SCRIPTS/usage-flush.sh"
  FIXTURES_DIRECTORY="$BATS_TEST_DIRNAME/fixtures/usage/flush"
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

# install <scenario>: the scenario's projects tree into PROJECTS_DIRECTORY, aged
# past every quiet window.
install() {
  local source_directory="$FIXTURES_DIRECTORY/$1/projects" relative_path destination_path encoded_root
  encoded_root="$(encode_project_path "$ROOT")"
  while IFS= read -r relative_path; do
    destination_path="$PROJECTS_DIRECTORY/${relative_path#./}"
    destination_path="${destination_path//@MAIN@/$encoded_root}"
    mkdir -p "${destination_path%/*}"
    sed -e "s|@ROOT@|$ROOT|g" "$source_directory/$relative_path" >"$destination_path"
    touch -t 202001010000 "$destination_path"
  done < <(cd "$source_directory" && find . -type f -name '*.jsonl')
}

flush() { bash "${FLUSHER:-$FLUSH}" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" "$@"; }

flush_multi() { flush --session s-multi --finished-main --all-sidecars-finished; }

totals() {
  jq -S -s '[.[] | select(.kind == "segment")]
    | reduce .[] as $segment ({}; reduce ($segment.by_model | to_entries[]) as $model (.;
        reduce ($model.value | to_entries[]) as $bucket (.; .[$segment.key][$model.key][$bucket.key] += $bucket.value)))' "$TEL/usage.jsonl"
}

assert_golden() {
  local want got
  want="$(jq -S . "$FIXTURES_DIRECTORY/$1/golden.json")"
  got="$(totals)"
  [ "$got" = "$want" ] || { printf 'want:\n%s\ngot:\n%s\n' "$want" "$got" >&2; return 1; }
}

cursor_rows() { jq -s --arg session_id "$1" '[.[] | select(.kind == "cursor" and .session_id == $session_id)] | length' "$TEL/usage.jsonl"; }

# scratch_flusher <sed-expr>: a copy of the flusher and its libraries with one
# mutation applied to usage-flush.sh; fails when the sed changed nothing.
scratch_flusher() {
  local scratch_directory="$TEMPORARY_DIRECTORY/scratch"
  mkdir -p "$scratch_directory/.gaia/scripts/spec" "$scratch_directory/.gaia/scripts/notebook"
  cp "$SCRIPTS"/usage-flush.sh "$SCRIPTS"/usage-parse-lib.sh "$SCRIPTS"/usage-lib.sh "$SCRIPTS"/main-root-lib.sh \
    "$SCRIPTS"/branch-name-lib.sh "$scratch_directory/.gaia/scripts/"
  cp "$SCRIPTS/spec/with-ledger-lock.sh" "$scratch_directory/.gaia/scripts/spec/"
  cp "$SCRIPTS"/notebook/*.sh "$scratch_directory/.gaia/scripts/notebook/"
  sed "$1" "$SCRIPTS/usage-flush.sh" >"$scratch_directory/.gaia/scripts/usage-flush.sh"
  if cmp -s "$SCRIPTS/usage-flush.sh" "$scratch_directory/.gaia/scripts/usage-flush.sh"; then
    echo "mutation did not apply to usage-flush.sh" >&2
    return 1
  fi
  FLUSHER="$scratch_directory/.gaia/scripts/usage-flush.sh"
}

# whole_reads <flusher args...>: one flush with PATH shims over the commands
# that read files by name, printing "<ledger reads> <cache reads>": the
# invocations that name the ledger or the cursor cache and read all of it. A
# tail from a byte past the first, and a head of the cache's fixed-length
# ledger_bytes prefix, read part of a file and are not counted.
whole_reads() {
  local shim_directory="$TEMPORARY_DIRECTORY/read-shims" command_name real_command
  mkdir -p "$shim_directory"
  : >"$shim_directory/reads"
  for command_name in grep head tail jq cat sed awk sort cmp; do
    real_command="$(command -v "$command_name")"
    printf '#!/usr/bin/env bash\nfor argument in "$@"; do case "$argument" in */telemetry/usage.jsonl | */telemetry/usage-cursors.json) printf "%%s\\t%%s\\n" "%s" "$*" >>"%s/reads"; break ;; esac; done\nexec "%s" "$@"\n' \
      "$command_name" "$shim_directory" "$real_command" >"$shim_directory/$command_name"
    chmod +x "$shim_directory/$command_name"
  done
  PATH="$shim_directory:$PATH" flush "$@" >/dev/null 2>&1
  awk -F '\t' '
    {
      partial = 0
      if ($1 == "tail" && match($2, /-c \+[0-9]+/)) { offset = substr($2, RSTART + 4, RLENGTH - 4); if (offset + 0 > 1) partial = 1 }
      if ($1 == "head" && $2 ~ /\/telemetry\/usage-cursors\.json/ && match($2, /-c [0-9]+/)) { count = substr($2, RSTART + 3, RLENGTH - 3); if (count + 0 < 1000) partial = 1 }
      if (partial) next
      if ($2 ~ /\/telemetry\/usage\.jsonl/) ledger++
      if ($2 ~ /\/telemetry\/usage-cursors\.json/) cache++
    }
    END { printf "%d %d\n", ledger, cache }' "$shim_directory/reads"
}

# seed_unrelated: another session's rows and cursors in the ledger and the
# cache, so neither file is empty when the measured flush starts.
seed_unrelated() {
  install branch
  flush --session s-branch --finished-main
  [ "$(cursor_rows s-branch)" -ge 1 ]
}

# ---------- whole reads per run ----------

@test "a cold flush reads the whole ledger once and the whole cursor cache twice, however many files it commits" {
  local reads
  seed_unrelated
  install multi
  reads="$(whole_reads --session s-multi --finished-main --all-sidecars-finished)"
  [ "$(cursor_rows s-multi)" -ge 4 ] || { echo "only $(cursor_rows s-multi) files committed; the bound proves nothing below 4" >&2; return 1; }
  [ "$reads" = "1 2" ] || { echo "ledger and cache whole reads: $reads, expected 1 2" >&2; return 1; }
}

@test "guard red: a scratch copy that rereads the whole ledger for every file reads it once per committed file" {
  local reads
  seed_unrelated
  install multi
  scratch_flusher 's/^  _uf_refresh_session_rows "\$session_id"$/  UF_SESSION_ROWS_ID=""; _uf_refresh_session_rows "$session_id"/'
  reads="$(whole_reads --session s-multi --finished-main --all-sidecars-finished)"
  [ "${reads% *}" -ge 4 ]
}

@test "guard red: a scratch copy that rewrites the cursor cache after every commit reads the cache once per committed file" {
  local reads
  seed_unrelated
  install multi
  scratch_flusher 's/^  cat "\$batch" >>"\$UF_LEDGER" || return 1$/&; _uf_write_cache "$(_uf_file_size "$UF_LEDGER")" 0/'
  reads="$(whole_reads --session s-multi --finished-main --all-sidecars-finished)"
  [ "${reads#* }" -ge 5 ]
}

# ---------- the cache is a hint ----------

# A flusher killed after its second commit, before the run-end cache write:
# kill -9 skips the EXIT trap, as a real kill does.
kill_after_two_commits() {
  scratch_flusher 's/^      0) UF_COMMITTED=1; return 0 ;;$/      0) UF_COMMITTED=1; UF_KILL_COUNT=$((${UF_KILL_COUNT:-0} + 1)); [ "$UF_KILL_COUNT" -lt 2 ] || kill -9 $$; return 0 ;;/'
  run flush_multi
  FLUSHER=""
  [ "$(cursor_rows s-multi)" -eq 2 ]
  [ -e "$TEL/usage-cursors.json" ] && return 1
  true
}

@test "a flush killed between its commits and its cache write leaves no cache, and the next flush counts every row once" {
  install multi
  kill_after_two_commits
  run flush_multi
  [ "$status" -eq 0 ]
  assert_golden multi
  [ "$(jq -r '.files | length' "$TEL/usage-cursors.json")" -eq "$(cursor_rows s-multi)" ]
}

@test "a cache behind the ledger costs a reparse, never a duplicate: the next flush matches golden" {
  install multi
  kill_after_two_commits
  printf '{"schema_version":1,"ledger_bytes":0,"files":{},"pairs":{}}\n' >"$TEL/usage-cursors.json"
  run flush_multi
  [ "$status" -eq 0 ]
  assert_golden multi
}

@test "guard red: a scratch copy that folds no ledger cursor rows recounts the killed flush's files" {
  install multi
  kill_after_two_commits
  scratch_flusher 's/grep -F '"'"'"kind":"cursor"'"'"' "\$UF_WORK\/session_rows"/grep -F '"'"'"kind":"no-such-kind"'"'"' "$UF_WORK\/session_rows"/'
  run flush_multi
  run assert_golden multi
  [ "$status" -ne 0 ]
}
