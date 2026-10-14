#!/usr/bin/env bats
#
# Pins the two contracts the /gaia-fitness judgment step relies on:
#   1. the no-op classification of the judge's reply once the main thread has
#      written it to disk (audit-noop-detect.sh --shape agent-report-file), and
#   2. the dispatch condition, a one-line jq filter extracted from the real
#      playbook and run over hand-written check reports.
#
# Run under bash 5: `.gaia/scripts/bats5.sh .gaia/scripts/tests/fitness-judge-dispatch.bats < /dev/null`
# (.claude/rules/bats-assertions.md).

setup() {
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
  PLAYBOOK="$REPO_ROOT/.claude/skills/gaia/references/fitness.md"
  REPLY="$BATS_TEST_TMPDIR/judgment.json"
}

classify() {
  run bash "$SCRIPTS_DIR/audit-noop-detect.sh" --shape agent-report-file --path "$REPLY"
}

# extract_filter <playbook>: prints the dispatch filter, the text between the
# single quotes of the playbook's first line that starts with `jq -er '[.inventory`.
# Fails when no such line exists or the line holds no quoted filter.
extract_filter() {
  local line filter
  line="$(grep -m1 -E "^jq -er '\[\.inventory" "$1")" || return 1
  filter="${line#*\'}"
  filter="${filter%\'*}"
  [ -n "$filter" ] || return 1
  printf '%s' "$filter"
}

# dispatch_exit <inventory-json>: runs the playbook's filter over a report whose
# inventory is the argument; echoes the filter's exit status.
dispatch_exit() {
  local filter report status
  filter="$(extract_filter "$PLAYBOOK")" || { echo "extract-failed"; return 0; }
  report="$BATS_TEST_TMPDIR/check.json"
  printf '{"scope":"adopter","findings":[],"inventory":%s}\n' "$1" >"$report"
  status=0
  jq -er "$filter" "$report" >/dev/null 2>&1 || status=$?
  echo "$status"
}

entry() {
  # entry <path> <kind> <ownership> <path_scoped>
  printf '{"path":"%s","kinds":["%s"],"words":10,"lines":3,"model":"unresolved","ownership":"%s","path_scoped":%s}' "$1" "$2" "$3" "$4"
}

@test "an absent reply file is a no-op" {
  classify
  [ "$status" -eq 1 ]
}

@test "an empty reply is a no-op" {
  : >"$REPLY"
  classify
  [ "$status" -eq 1 ]
}

@test "a reply that is prose and not an array is a no-op" {
  printf 'I found nothing wrong with these files.\n' >"$REPLY"
  classify
  [ "$status" -eq 1 ]
}

@test "a reply that is a JSON object and not an array is a no-op" {
  printf '{"judgment":"terminology"}\n' >"$REPLY"
  classify
  [ "$status" -eq 1 ]
}

@test "an empty array is a real reply" {
  printf '[]\n' >"$REPLY"
  classify
  [ "$status" -eq 0 ]
}

@test "a valid array of judgments is a real reply" {
  printf '[{"judgment":"terminology","file":".claude/skills/example/SKILL.md","line":3,"message":"m","remediation":"r"}]\n' >"$REPLY"
  classify
  [ "$status" -eq 0 ]
}

@test "the playbook's element-shape check passes a valid array and fails a malformed one" {
  local shape_line shape_filter
  shape_line="$(grep -m1 -E "^   jq -e 'all\(\.\[\]; \(\.judgment" "$PLAYBOOK" | sed 's/^ *//')" || return 1
  shape_filter="${shape_line#*\'}"
  shape_filter="${shape_filter%\'*}"
  [ -n "$shape_filter" ]
  printf '[{"judgment":"terminology","file":"a.md","line":3,"message":"m","remediation":"r"}]\n' >"$REPLY"
  jq -e "$shape_filter" "$REPLY" >/dev/null
  printf '[{"judgment":"vibes","file":"a.md","line":3,"message":"m","remediation":"r"}]\n' >"$REPLY"
  run jq -e "$shape_filter" "$REPLY"
  [ "$status" -ne 0 ]
  printf '[{"judgment":"terminology","file":"a.md","line":"3","message":"m","remediation":"r"}]\n' >"$REPLY"
  run jq -e "$shape_filter" "$REPLY"
  [ "$status" -ne 0 ]
}

@test "dispatch is skipped for an inventory of only third-party and ignored skills" {
  local inventory
  inventory="[$(entry .claude/skills/vendored/SKILL.md skill third-party false),$(entry .claude/skills/local/SKILL.md skill ignored false)]"
  [ "$(dispatch_exit "$inventory")" != "0" ]
  [ "$(dispatch_exit "$inventory")" != "extract-failed" ]
}

@test "dispatch is skipped for a rule that is not path scoped" {
  local inventory
  inventory="[$(entry .claude/rules/always.md rule adopter false)]"
  [ "$(dispatch_exit "$inventory")" != "0" ]
  [ "$(dispatch_exit "$inventory")" != "extract-failed" ]
}

@test "dispatch is skipped for references and wiki pages alone" {
  local inventory
  inventory="[$(entry .claude/skills/example/references/a.md reference adopter false),$(entry wiki/page.md wiki adopter false)]"
  [ "$(dispatch_exit "$inventory")" != "0" ]
  [ "$(dispatch_exit "$inventory")" != "extract-failed" ]
}

@test "dispatch is skipped for an empty inventory" {
  [ "$(dispatch_exit '[]')" != "0" ]
  [ "$(dispatch_exit '[]')" != "extract-failed" ]
}

@test "dispatch runs for a gaia-shipped command" {
  [ "$(dispatch_exit "[$(entry .claude/commands/example.md command gaia-shipped false)]")" = "0" ]
}

@test "dispatch runs for an unknown agent" {
  [ "$(dispatch_exit "[$(entry .claude/agents/example.md agent unknown false)]")" = "0" ]
}

@test "dispatch runs for an adopter skill" {
  [ "$(dispatch_exit "[$(entry .claude/skills/example/SKILL.md skill adopter false)]")" = "0" ]
}

@test "dispatch runs for an adopter rule that is path scoped" {
  [ "$(dispatch_exit "[$(entry .claude/rules/scoped.md rule adopter true)]")" = "0" ]
}

@test "the filter prints the paths to judge and only those" {
  local filter report inventory
  filter="$(extract_filter "$PLAYBOOK")"
  inventory="[$(entry .claude/skills/a/SKILL.md skill adopter false),$(entry .claude/skills/b/SKILL.md skill third-party false),$(entry wiki/page.md wiki adopter false)]"
  report="$BATS_TEST_TMPDIR/check.json"
  printf '{"scope":"adopter","findings":[],"inventory":%s}\n' "$inventory" >"$report"
  run jq -er "$filter" "$report"
  [ "$status" -eq 0 ]
  [ "$output" = ".claude/skills/a/SKILL.md" ]
}

@test "the extraction reads the real playbook: a copy without the filter line fails the helper" {
  local scratch_playbook
  scratch_playbook="$BATS_TEST_TMPDIR/playbook-without-filter.md"
  grep -vE "^jq -er '\[\.inventory" "$PLAYBOOK" >"$scratch_playbook"
  run extract_filter "$scratch_playbook"
  [ "$status" -ne 0 ]
  run extract_filter "$PLAYBOOK"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
