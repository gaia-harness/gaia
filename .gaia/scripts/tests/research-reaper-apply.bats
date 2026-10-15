#!/usr/bin/env bats
#
# `apply` of the research reaper (.gaia/scripts/notebook/research-reaper.sh):
# the interactive-session gate, reap and snooze, the keep-rule re-check at
# delete time, containment of a hostile slug, and the readiness order. `list`
# and the keep rules live in research-reaper.bats.
#
# The interactive gate reads CLAUDE_CODE_ENTRYPOINT and the session's
# transcript; a fixture HOME holds the transcript the usage scripts' own
# resolvers find.
#
# Run under bash 5: bash .gaia/scripts/bats5.sh <this file> < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  load helpers/research-reaper-fixture.sh
  reaper_setup
}

# window_end_iso: the instant one retention window from now.
window_end_iso() { days_from_now_iso 30; }

# epoch_of <iso>
epoch_of() { jq -rn --arg iso "$1" '$iso | fromdateiso8601'; }

@test "apply --reap removes an eligible folder and records the reap on its row" {
  reaper_fixture
  add_research stale-notes closed
  interactive_session
  run_reaper apply --reap stale-notes
  [ "$status" -eq 0 ]
  [ ! -e "$RESEARCH/stale-notes" ]
  [ "$(jq -r '.items[] | select(.id == "stale-notes") | .reap.by' "$CATALOG")" = "research-reaper" ]
  [ -n "$(jq -r '.items[] | select(.id == "stale-notes") | .reap.at // empty' "$CATALOG")" ]
  [ "$(jq -r '.items[] | select(.id == "stale-notes") | .status' "$CATALOG")" = "closed" ]
  grep -qF 'reaped stale-notes' <<<"$output"
}

@test "apply --snooze keeps the folder, snoozes one window ahead, and list no longer offers it" {
  reaper_fixture
  add_research stale-notes closed
  interactive_session
  run_reaper apply --snooze stale-notes
  [ "$status" -eq 0 ]
  [ -d "$RESEARCH/stale-notes" ]
  local until expected actual
  until="$(jq -r '.items[] | select(.id == "stale-notes") | .snoozed_until' "$CATALOG")"
  expected="$(epoch_of "$(window_end_iso)")"
  actual="$(epoch_of "$until")"
  [ "$((actual - expected))" -lt 60 ]
  [ "$((expected - actual))" -lt 60 ]
  run_reaper list
  [ "$(printf '%s' "$output" | jq '.eligible | length')" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.kept[] | select(.slug == "stale-notes") | .rule] | first')" = "snoozed" ]
}

@test "apply snoozes by the configured window" {
  reaper_fixture
  add_research stale-notes closed
  interactive_session
  GAIA_RESEARCH_RETENTION_DAYS=7 run_reaper apply --snooze stale-notes
  [ "$status" -eq 0 ]
  local until expected actual
  until="$(jq -r '.items[] | select(.id == "stale-notes") | .snoozed_until' "$CATALOG")"
  expected="$(epoch_of "$(days_from_now_iso 7)")"
  actual="$(epoch_of "$until")"
  [ "$((actual - expected))" -lt 60 ]
  [ "$((expected - actual))" -lt 60 ]
}

# --- the interactive gate ---------------------------------------------------

# assert_refused_unchanged <before-tree> <before-catalog>
assert_refused_unchanged() {
  [ "$status" -eq 7 ]
  grep -qi 'interactive' <<<"$stderr"
  [ "$(tree_digest)" = "$1" ]
  [ "$(catalog_snapshot)" = "$2" ]
}

@test "apply refuses with exit 7 in an sdk-cli session and changes nothing" {
  reaper_fixture
  add_research stale-notes closed
  export CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_SESSION_ID=sess-fixture
  session_transcript sdk-cli
  local before_tree before_catalog
  before_tree="$(tree_digest)"
  before_catalog="$(catalog_snapshot)"
  run_reaper apply --reap stale-notes
  assert_refused_unchanged "$before_tree" "$before_catalog"
  run_reaper list
  [ "$(printf '%s' "$output" | jq -c '[.eligible[].slug]')" = '["stale-notes"]' ]
}

@test "apply refuses with exit 7 when the transcript carries a non-cli entrypoint" {
  reaper_fixture
  add_research stale-notes closed
  export CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ID=sess-fixture
  session_transcript cli sdk-cli cli
  local before_tree before_catalog
  before_tree="$(tree_digest)"
  before_catalog="$(catalog_snapshot)"
  run_reaper apply --snooze stale-notes
  assert_refused_unchanged "$before_tree" "$before_catalog"
}

@test "apply refuses with exit 7 when the entrypoint is unset" {
  reaper_fixture
  add_research stale-notes closed
  export CLAUDE_CODE_SESSION_ID=sess-fixture
  session_transcript cli
  local before_tree before_catalog
  before_tree="$(tree_digest)"
  before_catalog="$(catalog_snapshot)"
  run_reaper apply --reap stale-notes
  assert_refused_unchanged "$before_tree" "$before_catalog"
}

@test "apply refuses with exit 7 when the session has no transcript to read" {
  reaper_fixture
  add_research stale-notes closed
  export CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ID=sess-without-transcript
  local before_tree before_catalog
  before_tree="$(tree_digest)"
  before_catalog="$(catalog_snapshot)"
  run_reaper apply --reap stale-notes
  assert_refused_unchanged "$before_tree" "$before_catalog"
}

@test "apply refuses with exit 7 when no session id is set" {
  reaper_fixture
  add_research stale-notes closed
  export CLAUDE_CODE_ENTRYPOINT=cli
  session_transcript cli
  run_reaper apply --reap stale-notes
  [ "$status" -eq 7 ]
  [ -d "$RESEARCH/stale-notes" ]
}

@test "apply makes no GitHub call once the session is refused" {
  reaper_fixture
  add_research stale-notes closed
  export CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_SESSION_ID=sess-fixture
  session_transcript sdk-cli
  run_reaper apply --reap stale-notes
  [ "$status" -eq 7 ]
  [ "$(gh_stub_call_count)" -eq 0 ]
}

# --- eligibility is decided at delete time -----------------------------------

@test "apply refuses an active folder and a closed folder cited by a ready plan, exit 8, nothing changed" {
  reaper_fixture
  add_research still-active active
  add_research cited-closed closed
  add_plan PLAN-201 ready '{"research":["cited-closed"]}'
  interactive_session
  local before_tree before_catalog
  before_tree="$(tree_digest)"
  before_catalog="$(catalog_snapshot)"
  run_reaper apply --reap still-active --reap cited-closed
  [ "$status" -eq 8 ]
  grep -qF "still-active" <<<"$stderr"
  grep -qF "cited-closed" <<<"$stderr"
  grep -qF "status-active" <<<"$stderr"
  grep -qF "cited-by-plan" <<<"$stderr"
  [ "$(tree_digest)" = "$before_tree" ]
  [ "$(catalog_snapshot)" = "$before_catalog" ]
}

@test "apply refuses a folder that became cited after list proposed it" {
  reaper_fixture
  add_research stale-notes closed
  interactive_session
  run_reaper list
  [ "$(printf '%s' "$output" | jq -c '[.eligible[].slug]')" = '["stale-notes"]' ]
  add_spec SPEC-210 draft '{"research":["stale-notes"]}'
  run_reaper apply --reap stale-notes
  [ "$status" -eq 8 ]
  [ -d "$RESEARCH/stale-notes" ]
  [ "$(jq '[.items[] | select(.id == "stale-notes") | has("reap")] | first' "$CATALOG")" = "false" ]
}

@test "apply refuses a slug that is still young, snoozed, or unknown to the catalog" {
  reaper_fixture
  add_research young-one closed '{}' "$(now_iso)"
  add_research snoozed-one closed "{\"snoozed_until\":\"$(days_from_now_iso 5)\"}"
  add_folder no-row-one
  interactive_session
  run_reaper apply --reap young-one --reap snoozed-one --reap no-row-one --reap never-existed
  [ "$status" -eq 8 ]
  local slug
  for slug in young-one snoozed-one no-row-one never-existed; do
    grep -qF "$slug" <<<"$stderr"
  done
  [ -d "$RESEARCH/young-one" ]
  [ -d "$RESEARCH/snoozed-one" ]
  [ -d "$RESEARCH/no-row-one" ]
}

@test "apply with gh failing refuses everything and leaves the folder" {
  reaper_fixture
  add_research stale-notes closed
  interactive_session
  gh_stub_mode fail
  run_reaper apply --reap stale-notes
  [ "$status" -eq 8 ]
  grep -qF "citation-query-unanswered" <<<"$stderr"
  [ -d "$RESEARCH/stale-notes" ]
}

@test "apply reads GitHub once for the whole batch" {
  reaper_fixture
  add_research first-notes closed
  add_research second-notes closed
  interactive_session
  run_reaper apply --reap first-notes --snooze second-notes
  [ "$status" -eq 0 ]
  [ "$(grep -c '^api ' "$GH_STUB_DIR/calls.log")" -eq 1 ]
}

@test "apply carries on past a refused slug and still acts on the eligible one" {
  reaper_fixture
  add_research stale-notes closed
  add_research still-active active
  interactive_session
  run_reaper apply --reap still-active --reap stale-notes
  [ "$status" -eq 8 ]
  [ ! -e "$RESEARCH/stale-notes" ]
  [ -d "$RESEARCH/still-active" ]
}

@test "apply on an already-reaped slug is refused, not repeated" {
  reaper_fixture
  add_research stale-notes closed
  interactive_session
  run_reaper apply --reap stale-notes
  [ "$status" -eq 0 ]
  local reaped_at
  reaped_at="$(jq -r '.items[] | select(.id == "stale-notes") | .reap.at' "$CATALOG")"
  run_reaper apply --reap stale-notes
  [ "$status" -eq 8 ]
  [ "$(jq -r '.items[] | select(.id == "stale-notes") | .reap.at' "$CATALOG")" = "$reaped_at" ]
}

# --- one batch -----------------------------------------------------------------

@test "list is read-only; apply reaps one and snoozes another, touching nothing else" {
  reaper_fixture
  add_research folder-a closed
  add_research folder-b closed
  add_research bystander closed '{}' "$(now_iso)"
  add_spec SPEC-220 merged '{"research":["bystander"]}'
  interactive_session
  local before_tree before_catalog first_list
  before_tree="$(tree_digest)"
  before_catalog="$(catalog_snapshot)"
  run_reaper list
  first_list="$output"
  [ "$(printf '%s' "$output" | jq -c '[.eligible[].slug] | sort')" = '["folder-a","folder-b"]' ]
  run_reaper list
  [ "$output" = "$first_list" ]
  [ "$(tree_digest)" = "$before_tree" ]
  [ "$(catalog_snapshot)" = "$before_catalog" ]

  run_reaper apply --reap folder-a --snooze folder-b
  [ "$status" -eq 0 ]
  [ ! -e "$RESEARCH/folder-a" ]
  [ -d "$RESEARCH/folder-b" ]
  [ "$(jq -r '.items[] | select(.id == "folder-a") | .reap.by' "$CATALOG")" = "research-reaper" ]
  [ "$(jq '[.items[] | select(.id == "folder-b") | has("reap")] | first' "$CATALOG")" = "false" ]
  [ "$(jq '[.items[] | select(.id == "folder-a") | has("snoozed_until")] | first' "$CATALOG")" = "false" ]
  [ -n "$(jq -r '.items[] | select(.id == "folder-b") | .snoozed_until // empty' "$CATALOG")" ]
  # Every other row is byte-identical: compare the catalog minus the two edits.
  local stripped_before stripped_after
  stripped_before="$(printf '%s' "$before_catalog" | jq -S '.items |= map(select(.id != "folder-a" and .id != "folder-b"))')"
  stripped_after="$(jq -S '.items |= map(select(.id != "folder-a" and .id != "folder-b"))' "$CATALOG")"
  [ "$stripped_after" = "$stripped_before" ]
  [ "$(printf '%s' "$before_catalog" | jq -S '.items[] | select(.id == "folder-a") | del(.reap)')" = "$(jq -S '.items[] | select(.id == "folder-a") | del(.reap)' "$CATALOG")" ]
  [ "$(printf '%s' "$before_catalog" | jq -S '.items[] | select(.id == "folder-b")')" = "$(jq -S '.items[] | select(.id == "folder-b") | del(.snoozed_until)' "$CATALOG")" ]
  run_reaper list
  [ "$(printf '%s' "$output" | jq -c '.eligible')" = '[]' ]
}

# --- readiness, usage and containment ------------------------------------------

@test "a not-ready machine exits 3 for list and for a non-interactive apply, never 7" {
  reaper_fixture --legacy
  run_reaper list
  [ "$status" -eq 3 ]
  grep -qF 'bash .gaia/scripts/notebook/move.sh run' <<<"$stderr"
  run_reaper apply --reap x
  [ "$status" -eq 3 ]
  grep -qF 'bash .gaia/scripts/notebook/move.sh run' <<<"$stderr"
}

@test "a usage error exits 2 before readiness, and names nothing it did not change" {
  reaper_fixture --legacy
  run_reaper apply
  [ "$status" -eq 2 ]
  run_reaper apply --reap
  [ "$status" -eq 2 ]
  run_reaper apply --frobnicate x
  [ "$status" -eq 2 ]
  run_reaper apply --reap same --snooze same
  [ "$status" -eq 2 ]
}

@test "a slug that is .. or contains a slash is refused as invalid and nothing outside the research folder changes" {
  reaper_fixture
  add_research stale-notes closed
  printf 'sentinel\n' >"$REPO/.notebook/sentinel.txt"
  mkdir -p "$RESEARCH/a/b"
  printf 'sentinel\n' >"$RESEARCH/a/b/keep.txt"
  append_row "$(jq -cn --arg stamp "$OLD_STAMP" '{kind:"research", id:"..", path:"research/..", status:"closed", subject:"x", created_at:$stamp, status_changed_at:$stamp}')"
  append_row "$(jq -cn --arg stamp "$OLD_STAMP" '{kind:"research", id:"a/b", path:"research/a/b", status:"closed", subject:"x", created_at:$stamp, status_changed_at:$stamp}')"
  interactive_session
  local before_tree
  before_tree="$(tree_digest)"
  run_reaper apply --reap .. --reap a/b --snooze ../..
  [ "$status" -eq 8 ]
  grep -qi 'invalid' <<<"$stderr"
  [ -f "$REPO/.notebook/sentinel.txt" ]
  [ -f "$RESEARCH/a/b/keep.txt" ]
  [ "$(tree_digest)" = "$before_tree" ]
  [ -d "$RESEARCH/stale-notes" ]
}

@test "apply never registers a row for a folder that has none" {
  reaper_fixture
  add_folder orphan-folder
  interactive_session
  run_reaper apply --reap orphan-folder
  [ "$status" -eq 8 ]
  [ -d "$RESEARCH/orphan-folder" ]
  [ "$(jq '[.items[] | select(.id == "orphan-folder")] | length' "$CATALOG")" -eq 0 ]
}
