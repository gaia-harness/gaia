#!/usr/bin/env bats
#
# `list` of the research reaper (.gaia/scripts/notebook/research-reaper.sh):
# every keep rule, each proven live by a twin that differs only in the rule no
# longer applying; the GitHub-cannot-answer cases; the landed verdict and the
# recommendation; the readiness gate; and the Usage Ledger link. `apply` lives
# in research-reaper-apply.bats.
#
# Fixtures are throwaway repositories with a fake HOME and a `gh` stand-in on
# PATH (helpers/research-reaper-fixture.sh); nothing reaches GitHub or the real
# notebook.
#
# Run under bash 5: bash .gaia/scripts/bats5.sh <this file> < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  load helpers/research-reaper-fixture.sh
  reaper_setup
}

# name|rule: one kept folder (keep-<name>) per row, with a twin (twin-<name>)
# identical except that the rule no longer applies.
KEEP_RULE_TABLE='active|status-active
pending|status-pending
untagged|status-untagged
norow|no-row
young-status|too-young
young-readme|too-young
young-state|too-young
spec-draft|cited-by-spec
spec-ready|cited-by-spec
plan-ready|cited-by-plan
memory-old-prefix|cited-in-memory
memory-new-prefix|cited-in-memory
open-issue|named-by-open-issue-or-pr
open-pull-request|named-by-open-issue-or-pr
snoozed|snoozed'

# seed_table_case <name>: seeds keep-<name> and twin-<name>.
seed_table_case() {
  local name="$1" keep="keep-$1" twin="twin-$1" future past
  future="$(days_from_now_iso 10)"
  past="$(days_from_now_iso -10)"
  case "$name" in
    active) add_research "$keep" active; add_research "$twin" closed ;;
    pending) add_research "$keep" pending; add_research "$twin" closed ;;
    untagged) add_research "$keep" untagged; add_research "$twin" closed ;;
    norow) add_folder "$keep"; add_research "$twin" closed ;;
    young-status)
      add_research "$keep" closed '{}' "$(now_iso)"
      add_research "$twin" closed
      ;;
    young-readme)
      add_research "$keep" closed
      touch "$RESEARCH/$keep/README.md"
      add_research "$twin" closed
      ;;
    young-state)
      add_research "$keep" closed
      printf 'state\n' >"$RESEARCH/$keep/STATE.md"
      add_research "$twin" closed
      printf 'state\n' >"$RESEARCH/$twin/STATE.md"
      age_folder "$twin"
      ;;
    spec-draft)
      add_research "$keep" closed; add_research "$twin" closed
      add_spec SPEC-101 draft "{\"research\":[\"$keep\"]}"
      add_spec SPEC-102 merged "{\"research\":[\"$twin\"]}"
      ;;
    spec-ready)
      add_research "$keep" closed; add_research "$twin" closed
      add_spec SPEC-103 ready "{\"research\":[\"$keep\"]}"
      add_spec SPEC-104 abandoned "{\"research\":[\"$twin\"]}"
      ;;
    plan-ready)
      add_research "$keep" closed; add_research "$twin" closed
      add_plan PLAN-101 ready "{\"research\":[\"$keep\"]}"
      add_plan PLAN-102 merged "{\"research\":[\"$twin\"]}"
      ;;
    memory-old-prefix)
      add_research "$keep" closed; add_research "$twin" closed
      memory_cites old-prefix.md "read ${OLD_PREFIX}${keep}/README.md first"
      memory_cites old-prefix-near-miss.md "read ${OLD_PREFIX}${twin}-extended/README.md first"
      ;;
    memory-new-prefix)
      add_research "$keep" closed; add_research "$twin" closed
      memory_cites new-prefix.md "notes live in ${NEW_PREFIX}${keep}/README.md"
      memory_cites new-prefix-near-miss.md "notes live in ${NEW_PREFIX}${twin}-extended/README.md"
      ;;
    open-issue)
      add_research "$keep" closed; add_research "$twin" closed
      gh_stub_issue 301 "Follow up on $keep" "details"
      gh_stub_issue 302 "Unrelated" "mentions ${twin}-extended only"
      ;;
    open-pull-request)
      add_research "$keep" closed; add_research "$twin" closed
      gh_stub_issue 303 "A change" "see $keep for the findings" pr
      gh_stub_issue 304 "Another change" "mentions ${twin}-extended only" pr
      ;;
    snoozed)
      add_research "$keep" closed "{\"snoozed_until\":\"$future\"}"
      add_research "$twin" closed "{\"snoozed_until\":\"$past\"}"
      ;;
    *) return 1 ;;
  esac
}

# The table fixture, plus a loose file and a folder cited only by an abandoned
# spec's lineage.
build_table_fixture() {
  local name rule seeded=0
  reaper_fixture
  while IFS='|' read -r name rule; do
    [ -n "$name" ] || continue
    seed_table_case "$name" || return 1
    seeded=$((seeded + 1))
  done <<EOF
$KEEP_RULE_TABLE
EOF
  [ "$seeded" -eq "$(printf '%s\n' "$KEEP_RULE_TABLE" | grep -c .)" ] || return 1
  add_research lineage-abandoned closed
  add_spec SPEC-110 abandoned '{"research":["lineage-abandoned"]}'
  printf 'loose\n' >"$RESEARCH/loose-notes.txt"
}

@test "list: every folder failing a keep rule is kept with that rule and never eligible" {
  build_table_fixture
  run_reaper list
  [ "$status" -eq 0 ]
  local name rule checked=0 expected_rule
  while IFS='|' read -r name rule; do
    [ -n "$name" ] || continue
    expected_rule="$(printf '%s' "$output" | jq -r --arg slug "keep-$name" '[.kept[] | select(.slug == $slug) | .rule] | first // "absent"')"
    if [ "$expected_rule" != "$rule" ]; then
      echo "keep-$name: expected kept rule $rule, got $expected_rule" >&2
      return 1
    fi
    if printf '%s' "$output" | jq -e --arg slug "keep-$name" 'any(.eligible[]; .slug == $slug)' >/dev/null; then
      echo "keep-$name is eligible but a rule applies" >&2
      return 1
    fi
    checked=$((checked + 1))
  done <<EOF
$KEEP_RULE_TABLE
EOF
  [ "$checked" -eq "$(printf '%s\n' "$KEEP_RULE_TABLE" | grep -c .)" ]
  [ "$(printf '%s' "$output" | jq '.kept | length')" -eq "$checked" ]
}

@test "list: a twin that differs only in the rule no longer applying is eligible, so each rule is live" {
  build_table_fixture
  run_reaper list
  [ "$status" -eq 0 ]
  local name rule checked=0
  while IFS='|' read -r name rule; do
    [ -n "$name" ] || continue
    if ! printf '%s' "$output" | jq -e --arg slug "twin-$name" 'any(.eligible[]; .slug == $slug)' >/dev/null; then
      echo "twin-$name should be eligible (rule $rule not applying)" >&2
      return 1
    fi
    checked=$((checked + 1))
  done <<EOF
$KEEP_RULE_TABLE
EOF
  # Eligible = every twin plus the abandoned-lineage folder, nothing else.
  [ "$(printf '%s' "$output" | jq '.eligible | length')" -eq "$((checked + 1))" ]
  printf '%s' "$output" | jq -e 'any(.eligible[]; .slug == "lineage-abandoned")' >/dev/null
}

@test "list: untagged, row-less and loose files are reported, and a folder cited only by an abandoned spec is eligible" {
  build_table_fixture
  run_reaper list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.reported.untagged | sort')" = '["keep-untagged"]' ]
  [ "$(printf '%s' "$output" | jq -c '.reported.rowless')" = '["keep-norow"]' ]
  [ "$(printf '%s' "$output" | jq -c '.reported.loose_files')" = '["loose-notes.txt"]' ]
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "lineage-abandoned") | .verdict')" = "not landed" ]
  [ "$(printf '%s' "$output" | jq -r '.citation_query.answered')" = "true" ]
}

@test "list: runs one GitHub read for all candidates, never one per folder" {
  build_table_fixture
  run_reaper list
  [ "$status" -eq 0 ]
  [ "$(grep -c '^api ' "$GH_STUB_DIR/calls.log")" -eq 1 ]
}

@test "list: a folder with nothing left to ask GitHub about makes no GitHub call" {
  reaper_fixture
  add_research still-active active
  run_reaper list
  [ "$status" -eq 0 ]
  [ "$(gh_stub_call_count)" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.recommended')" = "none" ]
}

@test "list: the retention window follows GAIA_RESEARCH_RETENTION_DAYS and a non-numeric value falls back to the default" {
  reaper_fixture
  add_research aged-two-hundred closed '{}' "$(days_from_now_iso -200)"
  add_research aged-ten closed '{}' "$(days_from_now_iso -10)"
  GAIA_RESEARCH_RETENTION_DAYS=5 run_reaper list
  [ "$(printf '%s' "$output" | jq -c '[.eligible[].slug] | sort')" = '["aged-ten","aged-two-hundred"]' ]
  GAIA_RESEARCH_RETENTION_DAYS=300 run_reaper list
  [ "$(printf '%s' "$output" | jq -c '[.eligible[].slug]')" = '[]' ]
  GAIA_RESEARCH_RETENTION_DAYS=soon run_reaper list
  [ "$(printf '%s' "$output" | jq -c '[.eligible[].slug]')" = '["aged-two-hundred"]' ]
}

# --- GitHub cannot answer -------------------------------------------------

@test "list: gh failing leaves nothing eligible and says why" {
  reaper_fixture
  add_research otherwise-eligible closed
  gh_stub_mode fail
  run_reaper list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.eligible | length')" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.citation_query.answered')" = "false" ]
  [ -n "$(printf '%s' "$output" | jq -r '.citation_query.reason // empty')" ]
  [ "$(printf '%s' "$output" | jq -r '[.kept[] | select(.slug == "otherwise-eligible") | .rule] | first')" = "citation-query-unanswered" ]
  [ "$(printf '%s' "$output" | jq -r '.recommended')" = "none" ]
}

@test "list: gh printing something that is not JSON leaves nothing eligible" {
  reaper_fixture
  add_research otherwise-eligible closed
  gh_stub_mode nonjson
  run_reaper list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.eligible | length')" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.citation_query.answered')" = "false" ]
  [ -n "$(printf '%s' "$output" | jq -r '.citation_query.reason // empty')" ]
}

@test "list: gh answering with an object instead of a list is not an answer" {
  reaper_fixture
  add_research otherwise-eligible closed
  printf '{"message":"Not Found"}\n' >"$GH_STUB_DIR/issues.json"
  run_reaper list
  [ "$(printf '%s' "$output" | jq '.eligible | length')" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.citation_query.answered')" = "false" ]
}

@test "list: no GitHub remote leaves nothing eligible and says why" {
  reaper_fixture --no-remote
  add_research otherwise-eligible closed
  run_reaper list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.eligible | length')" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.citation_query.answered')" = "false" ]
  printf '%s' "$output" | jq -r '.citation_query.reason' | grep -qi 'remote'
  [ "$(gh_stub_call_count)" -eq 0 ]
}

@test "list: an unauthenticated gh leaves nothing eligible and the reason names authentication" {
  reaper_fixture
  add_research otherwise-eligible closed
  gh_stub_mode unauth
  run_reaper list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.eligible | length')" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.citation_query.answered')" = "false" ]
  printf '%s' "$output" | jq -r '.citation_query.reason' | grep -qi 'authenticat'
}

@test "list: a gh that outlasts the time bound is cut off and reads as unanswered" {
  reaper_fixture
  add_research otherwise-eligible closed
  gh_stub_mode slow
  GAIA_RESEARCH_GH_TIMEOUT_SECONDS=1 run_reaper list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.eligible | length')" -eq 0 ]
  printf '%s' "$output" | jq -r '.citation_query.reason' | grep -qi 'timed out'
}

@test "list: text from an issue is data, never a command or a reason" {
  reaper_fixture
  add_research otherwise-eligible closed
  gh_stub_issue 9 "\$(touch $SCRATCH/never-created-by-reaper)" "otherwise-eligible\"; touch $SCRATCH/never-created-by-reaper #"
  run_reaper list
  [ ! -e "$SCRATCH/never-created-by-reaper" ]
  [ "$(printf '%s' "$output" | jq -r '[.kept[] | select(.slug == "otherwise-eligible") | .rule] | first')" = "named-by-open-issue-or-pr" ]
}

# --- landed verdict and recommendation -------------------------------------

@test "list: verdicts are landed, no evidence and not landed, and any doubt recommends snooze" {
  reaper_fixture
  add_research via-merged-pr closed
  add_spec SPEC-120 merged '{"research":["via-merged-pr"],"pr":41}'
  add_research no-links closed
  add_research via-closed-pr closed
  add_spec SPEC-121 abandoned '{"research":["via-closed-pr"],"pr":42}'
  gh_stub_pull_request 41 MERGED feat/merged-one
  gh_stub_pull_request 42 CLOSED feat/closed-one
  run_reaper list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "via-merged-pr") | .verdict')" = "landed" ]
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "no-links") | .verdict')" = "no evidence" ]
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "via-closed-pr") | .verdict')" = "not landed" ]
  [ "$(printf '%s' "$output" | jq -r '.recommended')" = "snooze" ]
}

@test "list: recommends reap only when every eligible folder is landed" {
  reaper_fixture
  add_research via-merged-pr closed
  add_spec SPEC-120 merged '{"research":["via-merged-pr"],"pr":41}'
  add_research another-merged closed
  add_spec SPEC-122 merged '{"research":["another-merged"]}'
  gh_stub_pull_request 41 MERGED feat/merged-one
  run_reaper list
  [ "$(printf '%s' "$output" | jq -r '.recommended')" = "reap" ]
  [ "$(printf '%s' "$output" | jq -c '[.eligible[].verdict] | unique')" = '["landed"]' ]
}

@test "list: a spec with one merged and one open pull request is not landed" {
  reaper_fixture
  add_research merged-and-open closed
  add_spec SPEC-123 merged '{"research":["merged-and-open"],"pr":51}'
  add_spec SPEC-126 abandoned '{"research":["merged-and-open"],"pr":52}'
  gh_stub_pull_request 51 MERGED feat/first
  gh_stub_pull_request 52 OPEN feat/second
  run_reaper list
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "merged-and-open") | .verdict')" = "not landed" ]
  [ "$(printf '%s' "$output" | jq -r '.recommended')" = "snooze" ]
}

@test "list: a plan linked to a merged spec counts toward landed through its own pull request" {
  reaper_fixture
  add_research through-plan closed
  add_spec SPEC-124 merged '{"research":["through-plan"]}'
  add_plan PLAN-124 merged '{"spec":"SPEC-124","pr":61}'
  gh_stub_pull_request 61 MERGED feat/plan-branch
  run_reaper list
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "through-plan") | .verdict')" = "landed" ]
}

@test "list: a pull request the listing does not contain makes the verdict not landed, never landed" {
  reaper_fixture
  add_research pr-missing closed
  add_spec SPEC-125 merged '{"research":["pr-missing"],"pr":71}'
  run_reaper list
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "pr-missing") | .verdict')" = "not landed" ]
}

@test "list: a Usage Ledger edge from a branch makes a merged pull request count as landed, and no edge means no evidence" {
  reaper_fixture
  add_research via-edge closed
  gh_stub_pull_request 81 MERGED feat/x
  run_reaper list
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "via-edge") | .verdict')" = "no evidence" ]
  bash "$REPO/.gaia/scripts/usage.sh" link branch:feat/x research:via-edge --main-root "$REPO"
  [ -s "$REPO/.gaia/local/telemetry/links.jsonl" ]
  run_reaper list
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "via-edge") | .verdict')" = "landed" ]
  bash "$REPO/.gaia/scripts/usage.sh" unlink branch:feat/x research:via-edge --main-root "$REPO"
  run_reaper list
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "via-edge") | .verdict')" = "no evidence" ]
}

@test "list: an edge to a branch whose pull request is still open is not landed" {
  reaper_fixture
  add_research via-open-edge closed
  gh_stub_pull_request 82 OPEN feat/y
  bash "$REPO/.gaia/scripts/usage.sh" link branch:feat/y research:via-open-edge --main-root "$REPO"
  run_reaper list
  [ "$(printf '%s' "$output" | jq -r '.eligible[] | select(.slug == "via-open-edge") | .verdict')" = "not landed" ]
}

# --- read-only, usage and readiness ----------------------------------------

@test "list: twice in a row prints byte-identical output and changes nothing on disk" {
  build_table_fixture
  local before_tree before_catalog first_output
  before_tree="$(tree_digest)"
  before_catalog="$(catalog_snapshot)"
  run_reaper list
  first_output="$output"
  run_reaper list
  [ "$output" = "$first_output" ]
  [ "$(tree_digest)" = "$before_tree" ]
  [ "$(catalog_snapshot)" = "$before_catalog" ]
}

@test "list: with no verb is the same as list, and a stray operand is a usage error" {
  reaper_fixture
  add_research once closed
  run_reaper list
  local explicit="$output"
  run_reaper
  [ "$output" = "$explicit" ]
  run_reaper list extra
  [ "$status" -eq 2 ]
  run_reaper bogus
  [ "$status" -eq 2 ]
}

@test "list: a not-ready machine exits 3 with the move command and reads nothing" {
  reaper_fixture --legacy
  run_reaper list
  [ "$status" -eq 3 ]
  grep -qF 'bash .gaia/scripts/notebook/move.sh run' <<<"$stderr"
  [ "$(gh_stub_call_count)" -eq 0 ]
}

@test "list: a corrupt catalog exits non-zero and prints no eligible list" {
  reaper_fixture
  add_research once closed
  printf '{not json' >"$CATALOG"
  run_reaper list
  [ "$status" -ne 0 ]
  grep -q 'eligible' <<<"$output" && return 1
  true
}

@test "list: a folder the catalog calls closed but whose row has a reap record and no folder is simply absent" {
  reaper_fixture
  add_research gone closed '{"reap":{"at":"2026-02-01T00:00:00Z","by":"research-reaper"}}'
  rm -rf "$RESEARCH/gone"
  run_reaper list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.eligible, .kept]')" = '[[],[]]' ]
}
