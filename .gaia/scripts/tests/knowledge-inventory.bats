#!/usr/bin/env bats
#
# Suite for .gaia/scripts/knowledge-inventory.sh, the deterministic half of
# /gaia-cleanse (.claude/skills/gaia/references/cleanse.md): the ownership
# answer both stages act on and the check that lets a 0-action report finalize
# without a human. The store listing and counts are the CLI's
# (`gaia fitness inventory --json`) and are covered by its own vitest; verify
# takes its recount from the committed CLI bundle. Each refusal has a green
# case and a red twin that changes one input, so every rule is shown to decide
# the answer rather than merely agree with it.
#
# Every test builds its own throwaway project and HOME. Set
# KNOWLEDGE_INVENTORY_SCRIPT to run the same assertions against a scratch copy.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/knowledge-inventory.bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="${KNOWLEDGE_INVENTORY_SCRIPT:-$REPO_ROOT/.gaia/scripts/knowledge-inventory.sh}"
  export HOME="$BATS_TEST_TMPDIR/home"
  PROJECT="$BATS_TEST_TMPDIR/project"
  MEMORY="$HOME/.claude/projects/$(printf %s "$PROJECT" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
  USER_AGENT_MEMORY="$HOME/.claude/agent-memory"
  mkdir -p "$PROJECT/.gaia/vendor" "$PROJECT/.claude/rules" "$PROJECT/wiki/concepts" \
    "$PROJECT/.claude/agent-memory/reviewer" "$PROJECT/frontend" "$MEMORY" "$USER_AGENT_MEMORY/helper"
  git -C "$PROJECT" init -q
  jq -n '{version: "2.0.0", files: {".claude/rules/quality-gate.md": "owned", "CLAUDE.md": "shared", "wiki/concepts/Page.md": "wiki-owned"}}' \
    >"$PROJECT/.gaia/manifest.json"
  jq -n '{package: "pkg", version: "1.0.0", target: "frontend/.claude/skills/playwright-cli", files: {}}' \
    >"$PROJECT/.gaia/vendor/playwright-cli.json"
  printf '**/.claude/agent-memory/\n**/.claude/skills/react-doctor/\n' >"$PROJECT/.gitignore"

  printf 'one two three\n' >"$MEMORY/MEMORY.md"
  printf 'a fact\n' >"$MEMORY/fact.md"
  printf 'not markdown\n' >"$MEMORY/notes.txt"
  printf 'helper note\n' >"$USER_AGENT_MEMORY/helper/note.md"
  printf 'reviewer note\n' >"$PROJECT/.claude/agent-memory/reviewer/note.md"
  printf 'gate\n' >"$PROJECT/.claude/rules/quality-gate.md"
  printf 'mine\n' >"$PROJECT/.claude/rules/house.md"
  printf 'index\n' >"$PROJECT/wiki/index.md"
  printf 'page\n' >"$PROJECT/wiki/concepts/Page.md"
  printf 'root\n' >"$PROJECT/CLAUDE.md"
  printf 'nested\n' >"$PROJECT/frontend/CLAUDE.md"
}

EXPECTED_COUNTS="memory=2 user_agent_memory=1 project_agent_memory=1 rules=2 wiki=2 claude_md=2"

inventory() {
  run --separate-stderr bash "$SCRIPT" "$1" --root "$PROJECT" "${@:2}"
}

# write_report <store-counts> [scope]: a clean 0-action report whose
# frontmatter records <store-counts> and <scope> (default full).
write_report() {
  REPORT="$BATS_TEST_TMPDIR/KNOWLEDGE-2026-10-08-1200.md"
  cat >"$REPORT" <<EOF
---
generated: 2026-10-08 12:00
status: draft
scope: ${2:-full}
store_counts: $1
project_root: $PROJECT
---

# Knowledge Audit, 2026-10-08 12:00

## Summary

- Actions proposed: 0
- Applied scope: ${2:-full}

## Actions

## Out-of-scope findings

None.
EOF
}

# class_of <path>: the class column of the output line for <path>.
class_of() {
  local line
  while IFS= read -r line; do
    if [ "${line#*$'\t'}" = "$1" ]; then
      printf '%s' "${line%%$'\t'*}"
      return 0
    fi
  done <<<"$output"
  return 1
}

# --- classify ---

@test "classify: project memory classifies project-memory" {
  inventory classify "$MEMORY/fact.md"
  [ "$status" -eq 0 ]
  [ "$(class_of "$MEMORY/fact.md")" = "project-memory" ]
}

@test "classify: project agent memory classifies project-memory although gitignored" {
  inventory classify "$PROJECT/.claude/agent-memory/reviewer/note.md"
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/agent-memory/reviewer/note.md)" = "project-memory" ]
}

@test "classify: user-scope agent memory classifies user-memory" {
  inventory classify "$USER_AGENT_MEMORY/helper/note.md"
  [ "$status" -eq 0 ]
  [ "$(class_of "$USER_AGENT_MEMORY/helper/note.md")" = "user-memory" ]
}

@test "classify red twin: a path climbing out of the memory dir is third-party" {
  inventory classify "$MEMORY/../../other/memory/x.md"
  [ "$status" -eq 0 ]
  [ "$(class_of "$MEMORY/../../other/memory/x.md")" = "third-party" ]
}

@test "classify: in-repo paths take the ownership classifier's classes" {
  inventory classify "$PROJECT/.claude/rules/quality-gate.md" "$PROJECT/.claude/rules/house.md" \
    "$PROJECT/frontend/.claude/skills/playwright-cli/SKILL.md" "$PROJECT/.claude/skills/react-doctor/SKILL.md" \
    "$PROJECT/wiki/concepts/Page.md"
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/rules/quality-gate.md)" = "gaia-shipped" ]
  [ "$(class_of .claude/rules/house.md)" = "adopter" ]
  [ "$(class_of frontend/.claude/skills/playwright-cli/SKILL.md)" = "third-party" ]
  [ "$(class_of .claude/skills/react-doctor/SKILL.md)" = "ignored" ]
  [ "$(class_of wiki/concepts/Page.md)" = "adopter" ]
}

@test "classify: output keeps input order across memory and in-repo paths" {
  inventory classify "$PROJECT/.claude/rules/house.md" "$MEMORY/fact.md" "$PROJECT/.claude/rules/quality-gate.md"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = $'adopter\t.claude/rules/house.md' ]
  [ "${lines[1]}" = "project-memory"$'\t'"$MEMORY/fact.md" ]
  [ "${lines[2]}" = $'gaia-shipped\t.claude/rules/quality-gate.md' ]
}

@test "classify: an unreadable manifest fails closed with nothing on stdout" {
  rm "$PROJECT/.gaia/manifest.json"
  run --separate-stderr bash "$SCRIPT" classify --root "$PROJECT" "$PROJECT/.claude/rules/house.md"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"manifest"* ]]
}

# --- verify ---

@test "verify: a full-scope 0-action report with matching counts is verified" {
  write_report "$EXPECTED_COUNTS"
  inventory verify "$REPORT"
  [ "$status" -eq 0 ]
  [ "$output" = "verified: $EXPECTED_COUNTS" ]
}

@test "verify red twin: a store whose count changed refuses and names the store" {
  write_report "$EXPECTED_COUNTS"
  printf 'new\n' >"$PROJECT/wiki/new.md"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refuse: store wiki: report 2, recomputed 3"* ]]
}

@test "verify red twin: a report that never counted a store refuses and names it" {
  write_report "memory=2 user_agent_memory=1 project_agent_memory=1 rules=2 claude_md=2"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refuse: store wiki: report none, recomputed 2"* ]]
}

@test "verify red twin: a report with no store counts refuses" {
  write_report "$EXPECTED_COUNTS"
  sed '/^store_counts:/d' "$REPORT" >"$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refuse: store memory: report none, recomputed 2"* ]]
}

@test "verify red twin: a scope hint refuses even with matching counts" {
  write_report "$EXPECTED_COUNTS"
  inventory verify "$REPORT" --scope-hint "memory only"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refuse: scope hint given"* ]]
}

@test "verify red twin: a report whose scope is not full refuses" {
  write_report "$EXPECTED_COUNTS" "wiki/"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refuse: report scope is wiki/, not full"* ]]
}

@test "verify red twin: a report carrying an action block refuses" {
  write_report "$EXPECTED_COUNTS"
  sed 's/^## Actions$/## Actions\
\
- [ ] `delete-001`/' "$REPORT" >"$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refuse: report carries 1 action block(s)"* ]]
}

@test "verify red twin: a Summary that does not say 0 actions refuses" {
  write_report "$EXPECTED_COUNTS"
  sed 's/^- Actions proposed: 0$/- Actions proposed: 2/' "$REPORT" >"$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refuse: Summary does not read Actions proposed: 0"* ]]
}

@test "verify red twin: a report cut off before its out-of-scope section refuses" {
  write_report "$EXPECTED_COUNTS"
  sed '/^## Out-of-scope findings$/,$d' "$REPORT" >"$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refuse: report has no ## Out-of-scope findings section"* ]]
}

@test "verify: every refusal is named, not only the first" {
  write_report "$EXPECTED_COUNTS" "wiki/"
  printf 'new\n' >"$MEMORY/new.md"
  inventory verify "$REPORT" --scope-hint "wiki/"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^refuse: ' <<<"$stderr")" -eq 3 ]
}

@test "verify: a missing report exits 3" {
  inventory verify "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 3 ]
}

@test "verify: a refusal prints nothing on stdout and a verified run prints nothing on stderr" {
  write_report "$EXPECTED_COUNTS"
  inventory verify "$REPORT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  inventory verify "$REPORT" --scope-hint "memory only"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# scratch_script <cli-body>: a copy of the script beside a stand-in
# cli/gaia whose body is <cli-body>, so the recount runs against a CLI that
# fails in a chosen way. Sets SCRATCH_SCRIPT.
scratch_script() {
  mkdir -p "$BATS_TEST_TMPDIR/scratch/scripts" "$BATS_TEST_TMPDIR/scratch/cli"
  cp "$SCRIPT" "$BATS_TEST_TMPDIR/scratch/scripts/knowledge-inventory.sh"
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$BATS_TEST_TMPDIR/scratch/cli/gaia"
  chmod +x "$BATS_TEST_TMPDIR/scratch/cli/gaia"
  SCRATCH_SCRIPT="$BATS_TEST_TMPDIR/scratch/scripts/knowledge-inventory.sh"
}

@test "verify red twin: a CLI that exits 3 makes verify exit 3 and never verify" {
  write_report "$EXPECTED_COUNTS"
  scratch_script 'exit 3'
  run --separate-stderr bash "$SCRATCH_SCRIPT" verify --root "$PROJECT" "$REPORT"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"store recount failed"* ]]
}

@test "verify red twin: a CLI that prints something other than a store map makes verify exit 3" {
  write_report "$EXPECTED_COUNTS"
  scratch_script "printf 'not json\\n'"
  run --separate-stderr bash "$SCRATCH_SCRIPT" verify --root "$PROJECT" "$REPORT"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"did not print a store map"* ]]
}

@test "verify red twin: a missing CLI makes verify exit 3" {
  write_report "$EXPECTED_COUNTS"
  scratch_script 'exit 0'
  rm "$BATS_TEST_TMPDIR/scratch/cli/gaia"
  run --separate-stderr bash "$SCRATCH_SCRIPT" verify --root "$PROJECT" "$REPORT"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"cannot run"* ]]
}

@test "verify green twin: a stand-in CLI that prints the matching store map verifies" {
  write_report "$EXPECTED_COUNTS"
  scratch_script "printf '%s\\n' '{\"stores\":{\"memory\":{\"count\":2},\"user_agent_memory\":{\"count\":1},\"project_agent_memory\":{\"count\":1},\"rules\":{\"count\":2},\"wiki\":{\"count\":2},\"claude_md\":{\"count\":2}}}'"
  run --separate-stderr bash "$SCRATCH_SCRIPT" verify --root "$PROJECT" "$REPORT"
  [ "$status" -eq 0 ]
  [ "$output" = "verified: $EXPECTED_COUNTS" ]
}

@test "verify red twin: a stand-in CLI whose count differs refuses and names the store" {
  write_report "$EXPECTED_COUNTS"
  scratch_script "printf '%s\\n' '{\"stores\":{\"memory\":{\"count\":2},\"user_agent_memory\":{\"count\":1},\"project_agent_memory\":{\"count\":1},\"rules\":{\"count\":2},\"wiki\":{\"count\":9},\"claude_md\":{\"count\":2}}}'"
  run --separate-stderr bash "$SCRATCH_SCRIPT" verify --root "$PROJECT" "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refuse: store wiki: report 2, recomputed 9"* ]]
}

# --- relocate-reports ---

# relocate_fixture: a main checkout in $PROJECT with one commit, so a linked
# worktree can be added to it.
relocate_fixture() {
  git -C "$PROJECT" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  mkdir -p "$PROJECT/.gaia/local/audit"
  cd "$PROJECT" || return 1
}

@test "relocate-reports: moves an applied report into cleanse/ keeping its mtime" {
  relocate_fixture
  printf 'report\n' >"$PROJECT/.gaia/local/audit/KNOWLEDGE-2026-01-01-1200.md"
  touch -t 202601011200 "$PROJECT/.gaia/local/audit/KNOWLEDGE-2026-01-01-1200.md"
  before="$(stat -c %Y "$PROJECT/.gaia/local/audit/KNOWLEDGE-2026-01-01-1200.md" 2>/dev/null || stat -f %m "$PROJECT/.gaia/local/audit/KNOWLEDGE-2026-01-01-1200.md")"
  run --separate-stderr bash "$SCRIPT" relocate-reports --root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$PROJECT/.gaia/local/cleanse/KNOWLEDGE-2026-01-01-1200.md" ]
  [ ! -e "$PROJECT/.gaia/local/audit/KNOWLEDGE-2026-01-01-1200.md" ]
  after="$(stat -c %Y "$PROJECT/.gaia/local/cleanse/KNOWLEDGE-2026-01-01-1200.md" 2>/dev/null || stat -f %m "$PROJECT/.gaia/local/cleanse/KNOWLEDGE-2026-01-01-1200.md")"
  [ "$before" = "$after" ]
}

@test "relocate-reports: a same-named report already in cleanse/ is kept and the old one stays" {
  relocate_fixture
  mkdir -p "$PROJECT/.gaia/local/cleanse"
  printf 'old\n' >"$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md"
  printf 'new\n' >"$PROJECT/.gaia/local/cleanse/KNOWLEDGE-a.md"
  printf 'other\n' >"$PROJECT/.gaia/local/audit/KNOWLEDGE-b.md"
  run bash "$SCRIPT" relocate-reports --root "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/.gaia/local/cleanse/KNOWLEDGE-a.md")" = "new" ]
  [ "$(cat "$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md")" = "old" ]
  [ "$(cat "$PROJECT/.gaia/local/cleanse/KNOWLEDGE-b.md")" = "other" ]
  [ ! -e "$PROJECT/.gaia/local/audit/KNOWLEDGE-b.md" ]
}

@test "relocate-reports: only reports already in cleanse/ leaves them untouched" {
  relocate_fixture
  mkdir -p "$PROJECT/.gaia/local/cleanse"
  printf 'new\n' >"$PROJECT/.gaia/local/cleanse/KNOWLEDGE-a.md"
  run bash "$SCRIPT" relocate-reports --root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$PROJECT/.gaia/local/cleanse/KNOWLEDGE-a.md")" = "new" ]
}

@test "relocate-reports: nothing to move exits 0 silently and creates no cleanse/" {
  relocate_fixture
  run bash "$SCRIPT" relocate-reports --root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -d "$PROJECT/.gaia/local/cleanse" ]
}

@test "relocate-reports: leaves non-report files in audit/ alone" {
  relocate_fixture
  printf 'x\n' >"$PROJECT/.gaia/local/audit/issue-body-1.md"
  printf 'r\n' >"$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md"
  run bash "$SCRIPT" relocate-reports --root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.gaia/local/audit/issue-body-1.md" ]
  [ -f "$PROJECT/.gaia/local/cleanse/KNOWLEDGE-a.md" ]
}

@test "relocate-reports red twin: --help exits 0 and moves nothing" {
  relocate_fixture
  printf 'r\n' >"$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md"
  run bash "$SCRIPT" relocate-reports --help --root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md" ]
  [ ! -d "$PROJECT/.gaia/local/cleanse" ]
}

@test "relocate-reports red twin: an unknown flag exits 2 and moves nothing" {
  relocate_fixture
  printf 'r\n' >"$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md"
  run bash "$SCRIPT" relocate-reports --bogus --root "$PROJECT"
  [ "$status" -eq 2 ]
  [ -f "$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md" ]
  [ ! -d "$PROJECT/.gaia/local/cleanse" ]
}

@test "relocate-reports red twin: a linked worktree skips the move" {
  relocate_fixture
  printf 'r\n' >"$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md"
  git -C "$PROJECT" worktree add -q "$BATS_TEST_TMPDIR/linked" -b linked
  cd "$BATS_TEST_TMPDIR/linked"
  run --separate-stderr bash "$SCRIPT" relocate-reports --root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md" ]
  [ ! -e "$PROJECT/.gaia/local/cleanse" ]
}

@test "relocate-reports red twin: a working directory outside any repository skips the move" {
  relocate_fixture
  printf 'r\n' >"$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md"
  mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
  cd "$BATS_TEST_TMPDIR/not-a-repo"
  run bash "$SCRIPT" relocate-reports --root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.gaia/local/audit/KNOWLEDGE-a.md" ]
  [ ! -e "$PROJECT/.gaia/local/cleanse" ]
}

# --- usage ---

@test "usage: an unknown subcommand exits 2" {
  run bash "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}

@test "usage: classify with no path exits 2" {
  inventory classify
  [ "$status" -eq 2 ]
}
