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

@test "the test-stage lens column names the digest as artifact and first read and keeps the focus text and code-map slot" {
  local digest='<PLAN_DIR>/test-stage-findings/digest.md' artifact first
  artifact="$(grep -F '| Artifact under audit (`<ARTIFACT>`) |' "$DISPATCH_MD" | awk -F'|' '{ print $(NF - 1) }')"
  first="$(grep -F '| First Read |' "$DISPATCH_MD" | awk -F'|' '{ print $(NF - 1) }')"
  grep -qF -- "$digest" <<<"$artifact" || return 1
  grep -qF -- "$digest" <<<"$first" || return 1
  grep -qF -- 'only when judging whether a test proves a case' <<<"$first" || return 1
  has "$DISPATCH_MD" '| Fallback artifact and First Read (digest unavailable) | n/a | n/a |' || return 1
  has "$STAGE_MD" 'The lens, id prefix `TST`, confirms every listed test proves a behavior the SPEC states, that the cap above holds, and that every test and phase gate obeys `## Phase placement`, reading each task'"'"'s phase from the task-graph rows and each gate from its phase entry. When it has a code map, it uses it only to locate existing test files and never derives an expected behavior from it.' || return 1
  has "$DISPATCH_MD" '| Code map (`<CODE_MAP_PATH>`) |' || return 1
  has "$DISPATCH_MD" 'When `<CODE_MAP_PATH>` is empty the caller drops the whole code-map bullet from the preamble.' || return 1
  has "$DISPATCH_MD" 'the re-clear is only `rm -rf <PLAN_DIR>/test-stage-findings/TST.json`' || return 1
}

@test "a failed, absent or changed digest prints the fallback line and dispatches the lens on the whole plan" {
  has "$STAGE_MD" '--digest <PLAN_DIR>/test-stage-findings/digest.md' || return 1
  has "$STAGE_MD" 'When the script exited non-zero, or the digest is gone or its hash differs, print `Test-stage digest unavailable; the lens reads the whole plan this run.` once' || return 1
  has "$STAGE_MD" 'Before each dispatch, the re-dispatch after a no-op included, recompute' || return 1
  has "$STAGE_MD" 'dispatch on the `Fallback artifact and First Read (digest unavailable)` cells' || return 1
  has "$DISPATCH_MD" '| Fallback artifact and First Read (digest unavailable) |' || return 1
}

@test "step 2 runs the lens once more on a fresh pre-clear and digest, with no third pass" {
  has "$STAGE_MD" 'run this step once more on a fresh pre-clear and digest, apply that pass'"'"'s findings and re-run both checks, with no third pass.' || return 1
}

@test "the phase placement rule keeps its body: latest delivering phase, gate move, file split and scope" {
  has "$STAGE_MD" 'A test goes in the task doc of the latest phase that delivers something one of its cases needs' || return 1
  has "$STAGE_MD" 'A gate that does is fixed in its phase entry in `<PLAN_DIR>/orchestrator-parts.md` by moving the run to the test'"'"'s phase.' || return 1
  has "$STAGE_MD" 'the moved test takes a file of its own, declared by its new phase'"'"'s task doc and owned by that task doc in the README' || return 1
  has "$STAGE_MD" 'The rule binds the first lists and every edit made while applying review findings.' || return 1
}

