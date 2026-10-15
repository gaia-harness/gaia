#!/usr/bin/env bats
# Concurrency + behavior tests for the spec allocator on the notebook catalog.
#
# The N-parallel test is robust against flake by design: every background
# `next` job blocks until a shared start-flag file exists, then all race at
# once. A passing run with no contention proves nothing; the barrier forces
# genuine overlap, so the UNLOCKED read-modify-write would fail this test
# (two jobs read the same highest_number, allocate a duplicate id, and the
# second `mv` clobbers the first appended row → fewer than N rows and/or a
# duplicate id). The lock is what makes it green.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ALLOCATOR=".gaia/scripts/spec/spec-allocator.sh"
  LEDGER_UPDATE=".gaia/scripts/spec/ledger-update.sh"
}

# Every spec id in the fixture's catalog, one per line.
catalog_ids() {
  jq -r '.items[] | select(.kind == "spec") | .id' "$REPO/.notebook/catalog.json"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

# Launch N barrier-gated `next` jobs, then release the barrier and wait.
# Writes each job's stdout to "$REPO/out.<i>". $LOCK_ENV is prepended to each
# job so a caller can force the mkdir fallback.
_run_parallel_next() {
  local job_count="$1"
  local i
  rm -f "$REPO"/out.* "$REPO/start.flag"
  for i in $(seq 1 "$job_count"); do
    bash -c '
      repo="$1"; allocator_script="$2"; job_index="$3"
      until [ -f "$repo/start.flag" ]; do :; done
      '"${LOCK_ENV:-}"' bash "$repo/$allocator_script" next "$repo" > "$repo/out.$job_index" 2>/dev/null
    ' _ "$REPO" "$ALLOCATOR" "$i" &
  done
  # Release the barrier; all jobs were spinning on this file's existence.
  touch "$REPO/start.flag"
  wait
}

# --- Test 8: N-parallel next → N distinct ids, zero lost rows -----------------

@test "8a: N-parallel next (real flock if present); N distinct ids, N rows, no dupes" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh")"
  cd "$REPO"
  PARALLEL_JOB_COUNT=10
  LOCK_ENV="" _run_parallel_next "$PARALLEL_JOB_COUNT"

  printed="$(cat "$REPO"/out.* | sort)"
  distinct="$(printf '%s\n' "$printed" | sort -u)"
  [ "$(printf '%s\n' "$printed" | grep -c '^SPEC-[0-9]\{3\}$')" -eq "$PARALLEL_JOB_COUNT" ]
  [ "$(printf '%s\n' "$distinct" | wc -l | tr -d ' ')" -eq "$PARALLEL_JOB_COUNT" ]

  rows="$(catalog_ids)"
  [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" -eq "$PARALLEL_JOB_COUNT" ]
  # No duplicate ids in the ledger.
  [ "$(printf '%s\n' "$rows" | sort | uniq -d | wc -l | tr -d ' ')" -eq 0 ]
  # Every printed id appears in the ledger.
  while IFS= read -r id; do
    printf '%s\n' "$rows" | grep -qx "$id"
  done <<< "$distinct"
}

@test "8b: N-parallel next (forced mkdir fallback); N distinct ids, N rows, no dupes" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh")"
  cd "$REPO"
  PARALLEL_JOB_COUNT=10
  LOCK_ENV="GAIA_LEDGER_LOCK_FORCE_FALLBACK=1" _run_parallel_next "$PARALLEL_JOB_COUNT"

  printed="$(cat "$REPO"/out.* | sort)"
  distinct="$(printf '%s\n' "$printed" | sort -u)"
  [ "$(printf '%s\n' "$printed" | grep -c '^SPEC-[0-9]\{3\}$')" -eq "$PARALLEL_JOB_COUNT" ]
  [ "$(printf '%s\n' "$distinct" | wc -l | tr -d ' ')" -eq "$PARALLEL_JOB_COUNT" ]

  rows="$(catalog_ids)"
  [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" -eq "$PARALLEL_JOB_COUNT" ]
  [ "$(printf '%s\n' "$rows" | sort | uniq -d | wc -l | tr -d ' ')" -eq 0 ]
  while IFS= read -r id; do
    printf '%s\n' "$rows" | grep -qx "$id"
  done <<< "$distinct"
}

# --- Test 9: stale-lock recovery in `next` -----------------------------------

@test "9: stale-lock recovery in next; reclaims stale dir, allocates next id" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  cd "$REPO"
  mkdir -p "$REPO/.gaia/local/cache/shared/notebook-locks/mint-spec/specs.lock.d"
  sleep 2  # age past GAIA_LEDGER_LOCK_STALE_SECONDS=1
  run bash -c "GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_STALE_SECONDS=1 bash '$REPO/$ALLOCATOR' next '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-002" ]
  [ "$(catalog_ids | wc -l | tr -d ' ')" -eq 2 ]
}

# --- Test 10–12: in_progress contract ----------------------------------------

@test "10: in_progress surfaces a draft ledger row (defect-2 regression)" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-007 draft)"
  cd "$REPO"
  run bash -c "bash '$REPO/$ALLOCATOR' in_progress '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-007" ]
}

@test "11: in_progress no fallback; folder file without a catalog row is not surfaced" {
  # The SPEC-file frontmatter fallback is intentionally gone: in_progress
  # sources the catalog only. A foldered SPEC.md with no catalog row must NOT be
  # surfaced as in-flight, otherwise finalized work re-flags as resumable
  # forever (the staleness test 10 guards).
  REPO="$("$HELPERS/tmp-notebook-repo.sh" )"
  cd "$REPO"
  mkdir -p "$REPO/.notebook/specs/SPEC-013"
  printf '# SPEC-013\n' > "$REPO/.notebook/specs/SPEC-013/SPEC.md"
  run bash -c "bash '$REPO/$ALLOCATOR' in_progress '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "12: in_progress none; empty ledger, no files" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh")"
  cd "$REPO"
  run bash -c "bash '$REPO/$ALLOCATOR' in_progress '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

# --- Test 13: read-only modes take no lock -----------------------------------

@test "13: highest and in_progress create no lock file or dir" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  cd "$REPO"
  run bash -c "bash '$REPO/$ALLOCATOR' highest '$REPO'"
  [ "$status" -eq 0 ]
  run bash -c "bash '$REPO/$ALLOCATOR' in_progress '$REPO'"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/cache/shared/notebook-locks" ]
  [ ! -e "$REPO/.gaia/local/specs" ]
}

# --- Test 14: exit-code preservation -----------------------------------------

@test "14a: non-git dir; next exits 3" {
  # Build a tmp repo via the helper (so the scripts + sibling source resolve),
  # then strip .git so require_git fails. REPO is set so teardown cleans up.
  REPO="$("$HELPERS/tmp-notebook-repo.sh")"
  rm -rf "$REPO/.git"
  run bash -c "bash '$REPO/$ALLOCATOR' next '$REPO'"
  [ "$status" -eq 3 ]
}

@test "14b: forced jq failure; next exits 4 (exit code propagates THROUGH the lock)" {
  # Load-bearing negative assertion for a swallowed exit code: the catalog row
  # write returns 4 on jq failure; the mint lock must pass that 4 through
  # unchanged, and `next` must exit 4 (NOT 0). A failing `jq` is forced by
  # shadowing it with a stub early on PATH.
  REPO="$("$HELPERS/tmp-notebook-repo.sh")"
  cd "$REPO"
  realjq="$(command -v jq)"
  stub_directory="$REPO/stubbin"
  mkdir -p "$stub_directory"
  cat > "$stub_directory/jq" <<EOF
#!/usr/bin/env bash
# Fail only the row append ('.items += ...'); pass read-side jq through to the
# real jq so the script reaches the register critical section and the write jq
# is the one that fails.
for argument in "\$@"; do
  case "\$argument" in
    *".items += "*) exit 1 ;;
  esac
done
exec "$realjq" "\$@"
EOF
  chmod +x "$stub_directory/jq"
  run bash -c "PATH='$stub_directory:$PATH' bash '$REPO/$ALLOCATOR' next '$REPO'"
  [ "$status" -eq 4 ]
  # Catalog left unchanged; no row appended on the failed write.
  [ "$(catalog_ids | wc -l | tr -d ' ')" -eq 0 ]
}

@test "14c: lock timeout; next exits 4, catalog unchanged (75 maps to 4)" {
  # Hold the spec mint lock with a slow background job, then a real `next` with
  # a tiny timeout cannot acquire it. The helper returns 75; `next` maps that
  # to exit 4 (write-class failure). Asserts the timeout
  # path propagates THROUGH the lock as a non-zero exit, not a swallowed 0.
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  cd "$REPO"
  before="$(catalog_ids | wc -l | tr -d ' ')"
  run bash -c "
    export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
    . '$REPO/.gaia/scripts/spec/with-ledger-lock.sh'
    mkdir -p '$REPO/.gaia/local/cache/shared/notebook-locks/mint-spec'
    ( with_ledger_lock '$REPO/.gaia/local/cache/shared/notebook-locks/mint-spec' sleep 4 ) &
    holder=\$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      [ -d '$REPO/.gaia/local/cache/shared/notebook-locks/mint-spec/specs.lock.d' ] && break
      sleep 0.1
    done
    GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 bash '$REPO/$ALLOCATOR' next '$REPO'
    exit_status=\$?
    wait \"\$holder\" 2>/dev/null || true
    exit \"\$exit_status\"
  "
  [ "$status" -eq 4 ]
  after="$(catalog_ids | wc -l | tr -d ' ')"
  [ "$before" -eq "$after" ]
}

@test "14d: ledger-update invalid patch JSON exits 5 (propagates THROUGH the lock)" {
  # Companion negative assertion: a bad patch must pass its 5 through the
  # catalog lock and ledger-update.sh must exit 5 (NOT 0, and NOT the 4
  # reserved for lock timeout / missing row).
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  cd "$REPO"
  run bash -c "bash '$REPO/$LEDGER_UPDATE' '$REPO' SPEC-001 'not-json'"
  [ "$status" -eq 5 ]
}

# --- Test 15: ledger-update racing next ---------------------------------------

@test "15: ledger-update racing N-parallel next; catalog valid, no row lost" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh" --seed-spec SPEC-001 draft)"
  cd "$REPO"
  PARALLEL_JOB_COUNT=8
  rm -f "$REPO"/out.* "$REPO/start.flag"

  # N barrier-gated allocator jobs.
  for i in $(seq 1 "$PARALLEL_JOB_COUNT"); do
    bash -c '
      repo="$1"; allocator_script="$2"; job_index="$3"
      until [ -f "$repo/start.flag" ]; do :; done
      GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 bash "$repo/$allocator_script" next "$repo" > "$repo/out.$job_index" 2>/dev/null
    ' _ "$REPO" "$ALLOCATOR" "$i" &
  done
  # One barrier-gated step-9-style flip of the seeded draft row.
  bash -c '
    repo="$1"; ledger_update_script="$2"
    until [ -f "$repo/start.flag" ]; do :; done
    GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 bash "$repo/$ledger_update_script" "$repo" SPEC-001 "{\"status\":\"ready\"}" 2>/dev/null
  ' _ "$REPO" "$LEDGER_UPDATE" &

  touch "$REPO/start.flag"
  wait

  # Catalog is still valid JSON.
  run jq -e . "$REPO/.notebook/catalog.json"
  [ "$status" -eq 0 ]
  # Seeded row flipped to ready.
  [ "$(jq -r '.items[] | select(.kind == "spec" and .id == "SPEC-001") | .status' "$REPO/.notebook/catalog.json")" = "ready" ]
  # SPEC-001 + N freshly allocated rows, all present, no row lost.
  total="$(catalog_ids | wc -l | tr -d ' ')"
  [ "$total" -eq "$((PARALLEL_JOB_COUNT + 1))" ]
  # No duplicate ids.
  dupes="$(catalog_ids | sort | uniq -d | wc -l | tr -d ' ')"
  [ "$dupes" -eq 0 ]
}

# --- Test 16: a SPEC number held only on a branch still counts ---------------
#
# Remote-tracking branches are the one cross-machine signal the allocator has,
# since the catalog is machine-local. Each spelling below is one GAIA mints or
# the harness derives from it; the worktree one is invisible to a glob over
# `refs/heads/spec-*`.

@test "16: highest counts SPEC numbers held only on plan branches, in every minted spelling" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh")"
  cd "$REPO"
  git -C "$REPO" branch "plan/spec-004-local"
  run bash "$REPO/$ALLOCATOR" highest "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-004" ]

  git -C "$REPO" branch "worktree-plan+spec-007-wt"
  run bash "$REPO/$ALLOCATOR" highest "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-007" ]

  git -C "$REPO" update-ref refs/remotes/origin/plan/spec-011-peer HEAD
  run bash "$REPO/$ALLOCATOR" highest "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-011" ]
}

@test "16b: a missing branch-naming library refuses to allocate rather than under-count" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh")"
  cd "$REPO"
  rm "$REPO/.gaia/scripts/branch-name-lib.sh"
  run bash "$REPO/$ALLOCATOR" highest "$REPO"
  [ "$status" -eq 4 ]
  grep -qF "branch-naming library is unusable" <<<"$output"
}

# --- Test 7a: highest over a foldered SPEC; next never creates a folder ------

@test "7a: highest reads foldered SPEC.md; next does not create a folder" {
  REPO="$("$HELPERS/tmp-notebook-repo.sh")"
  cd "$REPO"
  mkdir -p "$REPO/.notebook/specs/SPEC-004"
  printf '# SPEC-004\n' > "$REPO/.notebook/specs/SPEC-004/SPEC.md"

  run bash -c "bash '$REPO/$ALLOCATOR' highest '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-004" ]

  run bash -c "bash '$REPO/$ALLOCATOR' next '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-005" ]
  # `next` only appends a catalog row; it must NOT create the folder.
  [ ! -e "$REPO/.notebook/specs/SPEC-005" ]
  [ "$(catalog_ids | tail -n 1)" = "SPEC-005" ]
  [ ! -e "$REPO/.gaia/local/specs" ]
}
