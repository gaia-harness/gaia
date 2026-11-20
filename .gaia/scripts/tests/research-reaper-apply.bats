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

@test "apply --snooze keeps the folder and snoozes one window ahead, by default or by the configured retention days" {
  reaper_fixture
  add_research stale-notes closed
  add_research week-notes closed
  interactive_session
  run_reaper apply --snooze stale-notes
  [ "$status" -eq 0 ] || { echo "default window: status $status"; return 1; }
  [ -d "$RESEARCH/stale-notes" ] || { echo "default window: folder removed"; return 1; }
  local until expected actual
  until="$(jq -r '.items[] | select(.id == "stale-notes") | .snoozed_until' "$CATALOG")"
  expected="$(epoch_of "$(window_end_iso)")"
  actual="$(epoch_of "$until")"
  [ "$((actual - expected))" -lt 60 ] || { echo "default window: snoozed too far ahead"; return 1; }
  [ "$((expected - actual))" -lt 60 ] || { echo "default window: snoozed too short"; return 1; }

  GAIA_RESEARCH_RETENTION_DAYS=7 run_reaper apply --snooze week-notes
  [ "$status" -eq 0 ] || { echo "configured window: status $status"; return 1; }
  until="$(jq -r '.items[] | select(.id == "week-notes") | .snoozed_until' "$CATALOG")"
  expected="$(epoch_of "$(days_from_now_iso 7)")"
  actual="$(epoch_of "$until")"
  [ "$((actual - expected))" -lt 60 ] || { echo "configured window: snoozed too far ahead"; return 1; }
  [ "$((expected - actual))" -lt 60 ] || { echo "configured window: snoozed too short"; return 1; }

  run_reaper list
  [ "$(printf '%s' "$output" | jq '.eligible | length')" -eq 0 ] || { echo "list still offers a snoozed folder"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '[.kept[] | select(.slug == "stale-notes") | .rule] | first')" = "snoozed" ] || { echo "list does not keep the snoozed folder as snoozed"; return 1; }
}

# --- the interactive gate ---------------------------------------------------

# expect_session_refused <label> <before-tree> <before-catalog>: the apply just
# run was refused for its session and changed nothing.
expect_session_refused() {
  [ "$status" -eq 7 ] || { echo "$1: status $status"; return 1; }
  grep -qi 'interactive' <<<"$stderr" || { echo "$1: stderr '$stderr'"; return 1; }
  [ "$(tree_digest)" = "$2" ] || { echo "$1: the notebook tree changed"; return 1; }
  [ "$(catalog_snapshot)" = "$3" ] || { echo "$1: the catalog changed"; return 1; }
}

@test "apply refuses with exit 7 unless the session is an interactive CLI session, and makes no GitHub call" {
  reaper_fixture
  add_research stale-notes closed
  local before_tree before_catalog
  before_tree="$(tree_digest)"
  before_catalog="$(catalog_snapshot)"

  export CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_SESSION_ID=sess-fixture
  session_transcript sdk-cli
  run_reaper apply --reap stale-notes
  expect_session_refused "sdk-cli session" "$before_tree" "$before_catalog" || return 1

  export CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ID=sess-fixture
  session_transcript cli sdk-cli cli
  run_reaper apply --snooze stale-notes
  expect_session_refused "non-cli entrypoint in the transcript" "$before_tree" "$before_catalog" || return 1

  unset CLAUDE_CODE_ENTRYPOINT
  export CLAUDE_CODE_SESSION_ID=sess-fixture
  session_transcript cli
  run_reaper apply --reap stale-notes
  expect_session_refused "entrypoint unset" "$before_tree" "$before_catalog" || return 1

  export CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ID=sess-without-transcript
  run_reaper apply --reap stale-notes
  expect_session_refused "no transcript to read" "$before_tree" "$before_catalog" || return 1

  export CLAUDE_CODE_ENTRYPOINT=cli
  unset CLAUDE_CODE_SESSION_ID
  session_transcript cli
  run_reaper apply --reap stale-notes
  [ "$status" -eq 7 ] || { echo "no session id: status $status"; return 1; }
  [ -d "$RESEARCH/stale-notes" ] || { echo "no session id: folder removed"; return 1; }

  [ "$(gh_stub_call_count)" -eq 0 ] || { echo "a refused session still called GitHub"; return 1; }

  run_reaper list
  [ "$(printf '%s' "$output" | jq -c '[.eligible[].slug]')" = '["stale-notes"]' ] || { echo "list lost the folder"; return 1; }
}

# --- eligibility is decided at delete time -----------------------------------

# bats test_tags=protected
@test "apply refuses an active folder and a closed folder cited by a ready plan, exit 8, nothing changed" {
  reaper_fixture
  interactive_session
  local before_tree before_catalog slug

  add_research still-active active
  add_research cited-closed closed
  add_plan PLAN-201 ready '{"research":["cited-closed"]}'
  before_tree="$(tree_digest)"
  before_catalog="$(catalog_snapshot)"
  run_reaper apply --reap still-active --reap cited-closed
  [ "$status" -eq 8 ] || { echo "active and cited: status $status"; return 1; }
  for slug in still-active cited-closed status-active cited-by-plan; do
    grep -qF "$slug" <<<"$stderr" || { echo "active and cited: stderr lacks '$slug'"; return 1; }
  done
  [ "$(tree_digest)" = "$before_tree" ] || { echo "active and cited: the notebook tree changed"; return 1; }
  [ "$(catalog_snapshot)" = "$before_catalog" ] || { echo "active and cited: the catalog changed"; return 1; }

  # Cited after list proposed it.
  add_research stale-notes closed
  run_reaper list
  [ "$(printf '%s' "$output" | jq -c '[.eligible[].slug]')" = '["stale-notes"]' ] || { echo "cited after list: list proposed '$output'"; return 1; }
  add_spec SPEC-210 draft '{"research":["stale-notes"]}'
  run_reaper apply --reap stale-notes
  [ "$status" -eq 8 ] || { echo "cited after list: status $status"; return 1; }
  [ -d "$RESEARCH/stale-notes" ] || { echo "cited after list: folder removed"; return 1; }
  [ "$(jq '[.items[] | select(.id == "stale-notes") | has("reap")] | first' "$CATALOG")" = "false" ] || { echo "cited after list: reap recorded"; return 1; }

  # Still young, snoozed, or unknown to the catalog.
  add_research young-one closed '{}' "$(now_iso)"
  add_research snoozed-one closed "{\"snoozed_until\":\"$(days_from_now_iso 5)\"}"
  add_folder no-row-one
  run_reaper apply --reap young-one --reap snoozed-one --reap no-row-one --reap never-existed
  [ "$status" -eq 8 ] || { echo "young, snoozed, unknown: status $status"; return 1; }
  for slug in young-one snoozed-one no-row-one never-existed; do
    grep -qF "$slug" <<<"$stderr" || { echo "young, snoozed, unknown: stderr lacks '$slug'"; return 1; }
  done
  for slug in young-one snoozed-one no-row-one; do
    [ -d "$RESEARCH/$slug" ] || { echo "young, snoozed, unknown: '$slug' removed"; return 1; }
  done
  [ "$(jq '[.items[] | select(.id == "no-row-one")] | length' "$CATALOG")" -eq 0 ] || { echo "young, snoozed, unknown: a row was registered for no-row-one"; return 1; }

  # GitHub failing.
  add_research failing-gh closed
  gh_stub_mode fail
  run_reaper apply --reap failing-gh
  gh_stub_mode ok
  [ "$status" -eq 8 ] || { echo "gh failing: status $status"; return 1; }
  grep -qF "citation-query-unanswered" <<<"$stderr" || { echo "gh failing: stderr '$stderr'"; return 1; }
  [ -d "$RESEARCH/failing-gh" ] || { echo "gh failing: folder removed"; return 1; }

  # An already-reaped slug is refused, not repeated.
  add_research reaped-notes closed
  run_reaper apply --reap reaped-notes
  [ "$status" -eq 0 ] || { echo "already reaped: first apply status $status"; return 1; }
  local reaped_at
  reaped_at="$(jq -r '.items[] | select(.id == "reaped-notes") | .reap.at' "$CATALOG")"
  run_reaper apply --reap reaped-notes
  [ "$status" -eq 8 ] || { echo "already reaped: second apply status $status"; return 1; }
  [ "$(jq -r '.items[] | select(.id == "reaped-notes") | .reap.at' "$CATALOG")" = "$reaped_at" ] || { echo "already reaped: reap record rewritten"; return 1; }

  # A hostile slug is invalid, and nothing outside the research folder changes.
  add_research intact-notes closed
  printf 'sentinel\n' >"$REPO/.notebook/sentinel.txt"
  mkdir -p "$RESEARCH/a/b"
  printf 'sentinel\n' >"$RESEARCH/a/b/keep.txt"
  append_row "$(jq -cn --arg stamp "$OLD_STAMP" '{kind:"research", id:"..", path:"research/..", status:"closed", subject:"x", created_at:$stamp, status_changed_at:$stamp}')"
  append_row "$(jq -cn --arg stamp "$OLD_STAMP" '{kind:"research", id:"a/b", path:"research/a/b", status:"closed", subject:"x", created_at:$stamp, status_changed_at:$stamp}')"
  before_tree="$(tree_digest)"
  run_reaper apply --reap .. --reap a/b --snooze ../..
  [ "$status" -eq 8 ] || { echo "hostile slug: status $status"; return 1; }
  grep -qi 'invalid' <<<"$stderr" || { echo "hostile slug: stderr '$stderr'"; return 1; }
  [ -f "$REPO/.notebook/sentinel.txt" ] || { echo "hostile slug: sentinel removed"; return 1; }
  [ -f "$RESEARCH/a/b/keep.txt" ] || { echo "hostile slug: nested folder removed"; return 1; }
  [ "$(tree_digest)" = "$before_tree" ] || { echo "hostile slug: the notebook tree changed"; return 1; }
  [ -d "$RESEARCH/intact-notes" ] || { echo "hostile slug: bystander removed"; return 1; }

  # A folder with no row never gets one.
  add_folder orphan-folder
  run_reaper apply --reap orphan-folder
  [ "$status" -eq 8 ] || { echo "no row: status $status"; return 1; }
  [ -d "$RESEARCH/orphan-folder" ] || { echo "no row: folder removed"; return 1; }
  [ "$(jq '[.items[] | select(.id == "orphan-folder")] | length' "$CATALOG")" -eq 0 ] || { echo "no row: a row was registered"; return 1; }
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
