#!/usr/bin/env bats
#
# Doc-conformance suite for the test stage reference: it tells the stage to
# write its test lines in the formats test-stage-check.mjs parses, and the
# review findings folder never shares the TEST-STAGE record's name ignoring
# case.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016 # the pinned literals carry backticks as literal Markdown

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STAGE_MD="$REPO_ROOT/.claude/skills/gaia/references/test-stage.md"
  DISPATCH_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/lens-dispatch.md"
}

# has <file> <literal>: the file holds the literal.
has() {
  grep -qF -- "$2" "$1"
}

@test "the stage writes its test lines in the formats the coverage check parses" {
  has "$STAGE_MD" '`## Tests`' || return 1
  has "$STAGE_MD" '- Test (<behavior id>, <layer>, <security kind>): <repo-relative file> › <title>' || return 1
  has "$STAGE_MD" '- Flow test (<flow_id>): <repo-relative test path>' || return 1
  has "$STAGE_MD" 'node .gaia/scripts/spec/test-stage-check.mjs --plan-dir'
}

# A case-insensitive filesystem (the macOS default) treats two names that differ
# only in case as one path, so a findings folder named like the record makes the
# lens pre-clear's rm -rf delete the record.
@test "the review findings folder never shares the TEST-STAGE record's name ignoring case" {
  local record='TEST-STAGE' row folder
  has "$STAGE_MD" "write \`<PLAN_DIR>/$record\`" || return 1
  row="$(grep -F '| Findings directory (`<FINDINGS_DIR>`) |' "$DISPATCH_MD")"
  folder="$(awk -F'|' '{ print $(NF - 1) }' <<<"$row" | tr -d ' `')"
  folder="${folder#<PLAN_DIR>/}"
  folder="${folder%/}"
  [ -n "$folder" ] || return 1
  [ "$(tr '[:upper:]' '[:lower:]' <<<"$folder")" != "$(tr '[:upper:]' '[:lower:]' <<<"$record")" ] || return 1
  has "$STAGE_MD" "\`<PLAN_DIR>/$folder/\`" || return 1
  has "$DISPATCH_MD" "\`rm -rf <PLAN_DIR>/$folder\`, then \`mkdir -p <PLAN_DIR>/$folder\`" || return 1
}

